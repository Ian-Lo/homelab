# media-stack

**WireGuard (PIA) · qBittorrent · Prowlarr/Sonarr/Radarr · Jellyfin ·
Maintainerr**, as three independent Docker Compose stacks.

The engineering rationale that outlives this particular deployment is in
[`DESIGN.md`](DESIGN.md) — the netns lifecycle trap, the
`iptables-persistent` incident, and why `internal: true` is a structural
guarantee rather than a nicety. This file is the day-to-day view.

## The core requirement

**The kill switch must be structural.** If the VPN is down, the tunnelled
containers have *no* internet — not "a firewall that ought to catch it."

Everything else here follows from taking that literally.

## Architecture

```
docker host  ${LAN_IP}
│
├── stack: media-vpn
│   ├── vpn                 thrnz/docker-wireguard-pia
│   │                       cap NET_ADMIN · sysctl src_valid_mark=1 · FIREWALL=1
│   │                       owns the netns · port-forward loop
│   │                       publishes ${LAN_IP}: 8080 9696 8989 7878
│   ├── qbittorrent         network_mode: service:vpn   ┐
│   ├── prowlarr            network_mode: service:vpn   │ no interface of their own
│   ├── sonarr              network_mode: service:vpn   │ all egress via the tunnel
│   ├── radarr              network_mode: service:vpn   │
│   └── byparr              network_mode: service:vpn   ┘ (challenge solver)
│
├── stack: media            (normal bridge)
│   └── jellyfin            ${LAN_IP}:8096 · /dev/dri/renderD128 · group_add ${RENDER_GID}
│
└── stack: maintainerr      (normal bridge, loopback UI only)

link:     media-jf-link  10.89.0.0/24, internal: true  (*arrs ⇄ Jellyfin)
storage:  ${MEDIA_ROOT}/{downloads,library}  bound as /data everywhere
```

**Everything that talks to the internet on your behalf is inside the
tunnel** — indexer queries, tracker announces, peer traffic, *and* the *arr
apps' own metadata lookups. Not just the torrent client. That is the part
people leave out, and it materially raises the stakes of the VPN
container's own lifecycle (see below).

**Jellyfin stays out of the tunnel, deliberately.** It serves LAN clients
and must stay reachable while the tunnel cycles. Tunnelling video back to
the same LAN is pure overhead, and its outbound traffic is artwork and
metadata with no privacy value. Assert its egress IP as part of your test
pass, so this stays a decision rather than something that quietly drifts
the other way.

**Three stacks, deliberately.** The VPN stack's members share a lifecycle —
the namespace. Jellyfin's does not: restarting the tunnel must not interrupt
playback. Maintainerr is separate again because it can *delete library files
on a schedule*, and that blast radius argues for being independently
stoppable without redeploying anything else.

### Two-phase first deploy, via Compose profiles

`qbittorrent`/`prowlarr`/`sonarr`/`radarr` carry `profiles: ["apps"]`. Leave
`COMPOSE_PROFILES` unset for the first deploy and only `vpn` starts, so the
tunnel and kill-switch tests run against nothing else. Then set
`COMPOSE_PROFILES=apps` and redeploy.

This uses profiles rather than per-service scaling because some deployment
paths give you no "start just one service" control at all — a git-repository
stack in an orchestrator deploys every service in the file, every time.
Profiles work identically whether you are on the CLI or not.

**Side benefit of four-in-one-namespace:** they all share `localhost`, so
Prowlarr → Sonarr is `127.0.0.1:8989` and Sonarr → qBittorrent is
`127.0.0.1:8080`. No hairpinning through published ports, no inter-container
DNS.

**Side cost:** all four WebUIs are published on the `vpn` container, so when
the tunnel is down the UIs go with it. That is the right trade — a visible
failure beats a silent leak — but know it in advance rather than at 1am.

## The namespace lifecycle problem

This is the biggest operational risk in the design, and it is the one thing
to read before deploying. Full treatment in [`DESIGN.md`](DESIGN.md); the
short version:

`network_mode: "service:vpn"` places a container inside `vpn`'s network
namespace. It owns no interface of its own — which is exactly what makes the
kill switch structural.

But it cuts both ways. When the namespace owner stops, its netns is
destroyed. The dependants keep **running** while losing all networking. They
look healthy in `docker ps` and do nothing. Upstream:
[thrnz #44](https://github.com/thrnz/docker-wireguard-pia/issues/44), still
open, no maintainer resolution. `depends_on` orders startup; it re-attaches
nothing afterwards.

The distinction that matters: a **restart** of `vpn` keeps its container ID;
a **recreate** (an image bump, say) gives it a new one — and only the latter
can leave dependants permanently unable to re-attach.

> **Redeploy the stack. Never `docker restart` the namespace owner on its
> own.**

**Mitigation:** `scripts/netns-guard.sh` plus a systemd timer, installed by
`install-on-host.sh`. It compares each dependant's netns against the owner's
every ~2 minutes and restarts any that have drifted.

**Its limit, stated honestly:** `docker restart` is the only repair it ever
performs, and that only reliably helps when the owner was *restarted* with
the same container ID. If the owner was *recreated*, the dependants' stored
`NetworkMode` may reference a dead container ID and the restart fails
outright. Real repair then means *recreating* the dependants, which needs
the compose file — which may not even be on that host. So in that case the
guard **detects and alerts; it does not pretend to heal.** It never attempts
to recreate a container.

**Alerting is part of the design, not an optional extra.** This
architecture's failure mode is *silent*, and a guard that repairs quietly
has only relocated the silence.

Deliberately **not** an autoheal container: that requires bind-mounting the
Docker socket into a long-lived container, which is a standing
root-equivalent escalation path that outlives the few seconds of work it
does. A root systemd unit invoking the socket per run adds no privilege root
did not already have.

**Alerting is debounced, not silenced.** The guard keeps a small state file
under `/run` (tmpfs, so it resets cleanly across reboots) and alerts only on
a state *transition*, and at most once an hour while stuck in the same bad
state. Without that, a real multi-hour outage would re-alert every two
minutes — which is just a different way of not being heard. It also
distinguishes "the container doesn't exist" (not deployed yet; exits
quietly) from "exists but isn't running", including Docker's `restarting`
status, i.e. a container stuck in its own crash-restart loop, which is
flagged rather than skipped just because it wasn't `running` at the instant
checked.

### The webhook contract

`netns-guard.sh` POSTs JSON to the URL in `/etc/media-stack/ha-webhook-url`
(root-only, optional — if unset it logs to the journal and continues):

```json
{"severity": "drift" | "not-running" | "repair-failed" | "unhealthy" | "recovered", "message": "<free text>"}
```

- **`drift`** — a dependant drifted and the guard's `docker restart`
  **repaired** it. Informational: "FYI", never "needs you".
- **`not-running`** — a dependant exists but isn't running (stopped, or
  Docker's `restarting` status). This is **not** netns drift and the guard
  makes no repair attempt: there is nothing to restart into the right
  namespace, because the container isn't up at all. Needs a human — check
  `docker logs`.
- **`repair-failed`** — drift was detected and the restart did **not** fix
  it (or the owner itself isn't running). The dependant is stuck outside the
  namespace with no networking. Needs a human.
- **`unhealthy`** — the owner is running but Docker reports it unhealthy: a
  dead tunnel, interface up, no traffic. Egress is failing **closed**, so
  this is **not a leak** — but there is no connectivity. Requires
  `ACTIVE_HEALTHCHECKS=1` on the vpn service to be detectable at all. By
  default the guard alerts and stops, because the safe recovery is a stack
  redeploy and that is your call. With `RESTART_VPN_ON_UNHEALTHY=1` it
  instead announces an automated restart plus dependant repair, paired with
  a later `recovered` — that path deliberately strands the dependants for a
  moment and will *flap* if the tunnel is dead from a persistent cause, so
  it is opt-in and off by default.
- **`recovered`** — a key previously in any non-`ok` state is back to
  normal. One-shot, not repeated.

**A routine auto-repair sends two notifications, by design.** The run that
detects and fixes drift sends `drift`; the next tick finds everything `ok`,
which is itself a transition, and fires the one-shot `recovered`. Treat
`recovered` shortly after `drift` as confirmation, not a second incident.

**The script does not verify delivery, and cannot.** Webhook receivers
generally return 2xx for a POST to a webhook id that no longer exists, so an
"HTTP 2xx" log line proves only that the request left the host. Confirm
inside the receiver with a manual test POST before treating silence from the
guard as good news.

## Storage

`${MEDIA_ROOT}/{downloads,library}`, and the single hard requirement is that
**downloads and library sit under one parent on one filesystem.** Hardlinked
imports — the whole seed-without-duplicating model the *arrs are built on —
cannot cross a filesystem boundary. Two separate mounts turn every import
into a silent full copy, and you find out from a disk-usage graph weeks
later.

Keeping everything under a single top-level directory also keeps a future
migration cheap: moving to different storage is "move the directory, change
`MEDIA_ROOT`", not a compose rewrite.

**A less obvious fact, worth stating plainly:** the qBittorrent and *arr
**config volumes** — API keys, databases, torrent state — are Docker named
volumes under `/var/lib/docker`, **not** under `MEDIA_ROOT`. Whatever backs
up your media almost certainly does not cover them. Losing them costs hours
of reconfiguration rather than data, but that is a choice you should make
knowingly rather than discover.

If you are placing `MEDIA_ROOT` on a disk that is also a backup target: that
puts media and backups in one failure domain. It can be a reasonable call on
space grounds; it should be a deliberate one.

## Firewall rules and boot persistence

Published container ports cannot be filtered by a host firewall: Docker
DNATs them in PREROUTING, so the traffic never traverses INPUT. The rules
live in `DOCKER-USER` instead — the chain Docker guarantees to jump to first
from FORWARD and never flushes.

Making them survive a reboot is where the trap is. **Do not use
`iptables-persistent`.** It declares `Conflicts: ufw`, so a single
`apt-get install -y` removes your host firewall and every INPUT rule with
it, silently — and `netfilter-persistent save` additionally snapshots
Docker's own dynamic chains and restores them at boot *before* dockerd
rebuilds them. [`DESIGN.md`](DESIGN.md) has the full write-up.

Persistence here is `systemd/media-docker-user.service`: a oneshot ordered
`After=docker.service` that re-inserts only its own rules, idempotently. No
package, nothing for apt to remove, no whole-ruleset snapshot to go stale.

## Reaching Jellyfin from the *arrs — the `media-jf-link` network

The problem: Sonarr/Radarr need to notify Jellyfin, but a container dialling
the LAN-published `8096` gets DNAT'd into FORWARD, where the LAN-only DROP
for 8096 drops it — the container's source is a Docker bridge address, not a
LAN address. It fails closed, so it is a functional gap rather than a leak,
but it does block the notification.

The fix is a dedicated **`internal: true`** network joining `vpn` and
`jellyfin`, rather than a firewall exception. Two reasons it wins:

- **No host firewall change at all.** If `br_netfilter` is not loaded,
  same-bridge container traffic never traverses `DOCKER-USER`, so the DROP
  rules stay untouched.
- **`internal: true` is load-bearing.** Docker adds no masquerade and no
  gateway for such a network, so it can *structurally* never become an
  internet path. "All egress goes through the VPN" then holds by
  construction rather than by rule — which is the whole reason this beat
  giving the vpn container an ordinary second network.

Two things that will bite whoever implements it — both in `DESIGN.md`, both
worth repeating:

- **Do not use `http://jellyfin:8096`.** Inside the vpn netns the resolver
  is the VPN's, written by wg-quick, not Docker's embedded DNS — so Docker
  service names never resolve there. Pin Jellyfin's address in compose IPAM
  and use the literal IP.
- **Re-run your DNS-leak checks after attaching the network.** Attaching a
  user-defined network is exactly when Docker wants to rewrite
  `/etc/resolv.conf` to `127.0.0.11`. If that write beats wg-quick's, DNS
  leaves outside the tunnel while every IP-based leak test stays green.

**Accepted cost:** because the host cannot filter this path, the entire vpn
netns — qBittorrent included — can reach every port Jellyfin listens on, not
just 8096. The *arrs share the namespace and so have no separate address to
filter on. This is a floor imposed by the kill-switch design, not a tunable.
Mitigate on the Jellyfin side: keep auth on, use a scoped API key, disable
DLNA and autodiscovery if unused.

## Known risks, accepted rather than solved

- **`LOCAL_NETWORK` is a LAN-wide exception to the kill switch.** The vpn
  container's firewall must permit your LAN, or WebUI replies and Jellyfin
  notifications never reach LAN clients. But qBittorrent and the *arrs parse
  untrusted remote content and have real RCE history, and a compromised one
  gets network position on the *entire* LAN from inside what is meant to be
  a contained namespace. The exception cannot simply be removed; this bullet
  is the written acceptance of it. **Sub-risk:** your router sits inside that
  exception too, so any app that ever falls back to the router's DNS quietly
  leaks queries around the tunnel — and none of the obvious tests catch it.
- **`vpn` is a single point of failure for four containers**, and their
  WebUIs go down with it. Judged correct behaviour rather than a defect.
- **`DOCKER-USER` rules are hard to test honestly.** On a host with one
  interface and no second subnet, their presence and ordering can be
  checked; their effect against a genuinely off-LAN source is reasoned, not
  measured. Say which of those you have actually done.
- **The challenge solver's browser gets loopback reach to every WebUI in
  the namespace, and to Jellyfin.** A solver must share the vpn namespace —
  the Cloudflare clearance is bound to the egress IP — and same-netns
  placement necessarily lets a headless browser whose *job* is rendering
  hostile web content reach the *arrs on `127.0.0.1`. `-m owner` cannot
  separate them, since the *arrs run as the same uid. Residual risk is low
  (every target requires auth, and same-origin policy blunts hostile JS) but
  it is a real change to the namespace's trust model, and belongs written
  down rather than folded into "no new exposure".

## Digest pinning

linuxserver.io and `thrnz/docker-wireguard-pia` publish no per-version tags
— only a floating `latest`. Both compose files therefore pin every image by
**content digest**, each with a comment recording when it was resolved and
confirming a `linux/amd64` entry is present in the manifest list. Pin the
list digest rather than a single-platform one, so the reference stays
portable and Docker resolves the right platform itself.

Re-resolve and bump deliberately. A floating tag turns every unrelated
redeploy into an unreviewed version jump.

## Conventions

- Pre-built upstream images only, no `build:` keys — some orchestrators
  cannot build on the target host at all.
- `restart: unless-stopped`, explicit `container_name:`, and
  `security_opt: [no-new-privileges:true]` everywhere except `vpn`, which
  needs `NET_ADMIN`.
- `${VAR:?description}` for required and `${VAR:-default}` for optional
  variables. Required means required: fail at parse time rather than
  deploying something half-configured.
- Secrets as `*_FILE` pointing at root-only host paths, never in git.
- Every published port bound to an explicit LAN address, never bare
  `0.0.0.0`.

## Files

| Path | What it is |
|---|---|
| `docker-compose.vpn.yml` | tunnel + qBittorrent + *arrs + solver |
| `docker-compose.media.yml` | Jellyfin |
| `docker-compose.maintainerr.yml` | retention rules |
| `install-on-host.sh` | host prep: module, credentials, dirs, units, firewall, network |
| `scripts/` | host-side guard, import, cleanup, firewall, port-sync |
| `systemd/` | the units `install-on-host.sh` installs |
| `.env.example` | every variable, with why each has no default |
| `DESIGN.md` | the reusable engineering, independent of this deployment |
