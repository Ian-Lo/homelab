# DESIGN.md — three things worth knowing before you build this

This file is the part of the design that outlives the deployment. Each
section is a trap that cost real time to find, stated so you can avoid it
without repeating the discovery.

---

## 1. The netns lifecycle trap

### The mechanism

`network_mode: service:vpn` puts a container inside another container's
network namespace. The dependant owns no interface, no address, no routing
table of its own. That is precisely why it makes a good kill switch: if the
VPN container stops, there is no interface left for traffic to escape
through. Nothing to leak, rather than a firewall that ought to catch it.

The same property is the failure mode.

**When the namespace owner stops, its netns is destroyed. The dependants
keep running.** They do not exit, do not restart, and do not report a
problem. They sit there with no networking at all, showing `Up` in
`docker ps`, and every healthcheck that does not actually cross the network
continues to pass.

Upstream issue:
[thrnz/docker-wireguard-pia#44](https://github.com/thrnz/docker-wireguard-pia/issues/44)
— open, with no maintainer resolution. This is not specific to that image;
it is how `network_mode: container:`/`service:` works.

`depends_on: condition: service_healthy` does not help. It orders startup.
It re-attaches nothing afterwards.

### The distinction that actually matters

Not all owner restarts are equal, and this is the part that determines
whether recovery is easy or impossible:

| Event | Container ID | Dependants can re-attach? |
|---|---|---|
| `docker restart owner` | **unchanged** | usually yes, on their own restart |
| recreate (image bump, compose change) | **new** | **no** — their stored `NetworkMode` names a container that no longer exists |

A recreate is the dangerous one, and it is also the one that happens during
routine maintenance. The dependants' `NetworkMode` still points at the dead
container ID; `docker restart` on them fails outright. The only real repair
is to **recreate the dependants too**, which requires the compose file — and
with a git-repository stack, that file may live in an orchestrator's clone
on a different machine entirely.

Hence the operational rule, which is worth more than any tooling:

> **Redeploy the stack. Never restart the namespace owner on its own.**

### Mitigation, and its honest limit

A host-side guard (`scripts/netns-guard.sh`) plus a systemd timer, comparing
each dependant's `/proc/<pid>/ns/net` against the owner's.

Two implementation notes that are easy to get wrong:

- **Compare `/proc/<pid>/ns/net`, not `docker inspect`'s `SandboxKey`.** For
  a container using `network_mode: service:`, `SandboxKey` is empty — it
  does not own a sandbox. A check built on it silently passes forever.
- **Treat Docker's `restarting` status as a fault, not as "not running".**
  A container in a crash-restart loop is not `running` at the instant you
  look, and the naive check skips it quietly.

The limit, stated up front rather than discovered during an incident:
`docker restart` is the **only** repair the guard performs, and it only
reliably helps in the restart case above. **It detects and alerts; it does
not pretend to heal.** It never attempts to recreate a container, because
doing that correctly requires state it does not have.

That is a feature. A guard that half-fixes things produces incidents whose
history is unreadable.

### Debounce, or you have only moved the silence

The failure this guard exists to end is a *silent* one. It is tempting to
make it alert on every check. Don't:

- alert only on a state **transition**, not on every tick;
- while stuck in the same bad state, re-alert at most once an hour;
- send a one-shot `recovered` when a key returns to normal.

A guard that alerts every two minutes through a four-hour outage has
relocated the silence, not removed it — the alerts become the thing you mute.

Keep the state file on tmpfs (`/run`), so it resets cleanly across reboots
rather than carrying a stale "already alerted" flag past the event.

One more: **a 2xx from a webhook receiver is not proof of delivery.** Home
Assistant, among others, returns 2xx for a POST to a webhook id that no
longer exists. The only proof is confirming inside the receiver. Build the
test into the install, not into the intentions.

---

## 2. The `iptables-persistent` incident

Two separate failures, one package. Both are worth knowing even if you never
touch this stack.

### Failure one: it removes your firewall, silently

`iptables-persistent` declares `Conflicts: ufw`.

Running `apt-get install -y iptables-persistent` resolves that conflict
inside the same non-interactive transaction by **removing ufw** — and with
it, every INPUT rule on the host. The `-y` you added so the script would not
block is exactly what removes the confirmation prompt that would have told
you. There is no error. The install succeeds.

If the next thing your script does is `netfilter-persistent save`, you have
now also persisted the empty ruleset as the boot state.

### Failure two: it snapshots chains that are not yours

`netfilter-persistent save` snapshots the **entire current ruleset**, not
just the rules you added — including Docker's own dynamically generated
`DOCKER`, `DOCKER-ISOLATION` and DNAT chains as they exist at that instant.

At boot, that whole snapshot is restored **before** dockerd starts and
rebuilds its chains from actual container state. So you boot with a stale
picture of Docker's networking layered under the live one.

This does not show up in the obvious check. `iptables -S DOCKER-USER` looks
correct either way. If published ports or port-forwarding misbehave *only*
after a reboot, suspect this first, and compare a full `iptables-save` from
before and after — not just the one chain you own.

### What to do instead

A systemd oneshot, ordered `After=docker.service`, that re-inserts **only
its own rules**, idempotently:

- no package to install, so nothing for apt to remove;
- no whole-ruleset snapshot, so nothing to go stale;
- ordering after `docker.service` means the `DOCKER-USER` chain already
  exists when it runs;
- idempotent (`-C` before every `-I`) means re-running it — at boot, or by
  hand after adding a port — never duplicates a rule.

Use `RemainAfterExit=yes`, and note the consequence: once the unit is active
a plain `systemctl start` is a no-op. An install script re-run must
`restart` it, or a newly added rule silently waits for the next reboot.

### Why the rules have to be in `DOCKER-USER` at all

A host firewall cannot filter published container ports. Docker DNATs them
in PREROUTING, so the traffic is forwarded, not local — it never traverses
INPUT, where ufw's rules live. `DOCKER-USER` is the chain Docker guarantees
to jump to first from FORWARD, and never flushes.

This is the single most common misunderstanding about Docker and host
firewalls: `ufw status` can look perfect while every published port is
reachable from anywhere.

---

## 3. `internal: true` as a structural guarantee

### The problem it solves

Containers inside a VPN namespace needed to reach a service *outside* it on
the same host — the *arrs notifying Jellyfin. Dialling the LAN-published
port does not work: the container's packet is DNAT'd into FORWARD, where the
LAN-only DROP rule catches it, because the source is a Docker bridge address
rather than a LAN address.

It fails closed, so it is a functional gap rather than a leak. The obvious
fix — a firewall exception for the bridge subnet — is the wrong one.

### Why the internal network wins

Attach both containers to a dedicated network created `--internal`.

**Docker adds no masquerade rule and no gateway for an internal network.**
Not "we chose not to route it" — there is no route to configure. The network
is *structurally incapable* of carrying traffic off the host.

That matters because the requirement was "all app egress goes through the
VPN". A firewall exception makes that true *by rule*, and rules get edited by
someone debugging at midnight. `internal: true` makes it true *by
construction*. When you can convert a policy into a structural property,
take it — the property survives people, and the rule does not.

Second benefit: if `br_netfilter` is not loaded, same-bridge container
traffic never traverses `DOCKER-USER` at all, so this needs no host firewall
change whatsoever. Nothing to weaken, nothing to remember to re-tighten.

Pick a subnet outside Docker's default pool (`172.16.0.0/12`) so it can
never collide with an auto-allocated network.

### Two traps that bite implementers

**Service-name DNS does not work inside the VPN namespace.**

`wg-quick` rewrites `/etc/resolv.conf` to the VPN provider's resolvers when
the tunnel comes up. That is a *feature* — it is what stops DNS queries
leaking around the tunnel — but it means Docker's embedded DNS at
`127.0.0.11` is simply not in the picture. `http://jellyfin:8096` never
resolves from in there.

So pin the address in compose IPAM and use the literal IP. And pin it in
**mapping form** (`ipv4_address:`), not list form: a list-form attachment
gets a dynamic lease that merely *happens* to be the lowest free address.
Anything hard-coding that address is then one container-creation-order
change away from silently pointing at the wrong backend — and the usual
escape hatch, using the service name instead, is closed for the reason
above.

**Attaching a user-defined network is exactly when Docker wants to rewrite
`resolv.conf`.**

This is a race you cannot see. If Docker's write to `127.0.0.11` beats
wg-quick's, your DNS is now outside the tunnel — while every IP-based leak
test stays green, because the *data* path is still tunnelled. Only DNS
leaked.

Re-run your DNS-leak check specifically after attaching or re-attaching a
network, and check the actual `resolv.conf` contents rather than inferring
from a working lookup.
