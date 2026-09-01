# hermes-agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent) (NousResearch,
MIT-licensed — a self-hosted AI agent with persistent memory, skills, and an
OpenAI-compatible API), containerised and run as a headless gateway backed by
a hosted model API. No local LLM.

The compose file is the artefact here. Everything below is the reasoning
behind the non-default bits, because most of them look like they could be
tightened further and two of them genuinely cannot.

## Run mode

Gateway mode, API-only: an always-on background service exposing the
OpenAI-compatible endpoint on `8642`, **published on loopback only**. No web
dashboard, no chat-platform bots — the smallest surface that still satisfies
"an agent running in a container". Reach it over an SSH tunnel:

```sh
ssh -N -L 8642:127.0.0.1:8642 <user>@<host>
```

`tunnel.sh` in this directory does exactly that.

Loopback publishing is the actual access control, not a convenience. Do not
assume a host firewall behind it; if you republish this on `0.0.0.0`, the API
key is the only thing left.

The dashboard and bots can be added later (`HERMES_DASHBOARD=1` plus a
loopback `9119` publish) without disturbing any of this.

## Why `HERMES_UID`/`HERMES_GID`, not `user:`

This is the one that looks wrong and isn't.

The image bakes a `hermes` account at uid 10000 and starts its entrypoint as
**root on purpose**. s6-overlay's stage2 hook (`docker/stage2-hook.sh`) reads
`HERMES_UID`/`HERMES_GID` (`PUID`/`PGID` are a documented fallback),
`usermod`/`groupmod`s the baked account to match, `chown`s the top level of
the `/opt/data` tree, tightens `.env` to 600 and `config.yaml` to 640, and
*only then* drops the supervised gateway process to that uid via
`s6-setuidgid`.

Setting `user: "1000:1000"` at the Docker level skips that root phase
entirely, and leaves `/opt/data` unwritable or the entrypoint failing
outright. This was verified against the image source rather than assumed —
and it is worth saying plainly, because "just add `user:`" is the obvious
review comment on a container that starts as root, and here it is wrong.

`cap_drop: ALL` plus a minimal `cap_add`
(`CHOWN`/`SETUID`/`SETGID`/`DAC_OVERRIDE`/`FOWNER`) is what lets that root
phase still succeed while giving up everything else. Trim anything in that
list you can demonstrate is unused on your image version.

### Why `read_only: true` was tried and dropped

Not rollout caution — a structural conflict with this image:

- the `usermod`/`groupmod` step must write `/etc/passwd`, `/etc/group` and
  `/etc/shadow`, and it always triggers, since the baked uid 10000 never
  equals `HERMES_UID: 1000`;
- s6-overlay v3 separately needs a writable, **exec-able** `/run` to launch
  its own service scripts.

A bare `read_only: true` plus `tmpfs: [/tmp]` breaks both. `cap_drop`,
`no-new-privileges`, non-root and `pids_limit` remain the controls instead.
A read-only rootfs here is an upstream image change, not a compose change.

## Egress containment

An agent-class service is different from the other containers on a host: its
tool calls are steerable by whatever content it processes — a fetched page, a
tool result, a file it was pointed at. Prompt injection is a routine input,
not an exotic attack. Nothing limits where such a container can reach by
default.

There are **two distinct paths, and they need two distinct controls**, which
is the part that gets missed:

| Path | How the packet is seen | What filters it |
|---|---|---|
| Container → other hosts on the LAN | routed, `FORWARD` | Docker's `DOCKER-USER` chain |
| Container → a service on the Docker host itself | local, `INPUT` | the host firewall (ufw, etc.) |

A `DOCKER-USER` rule alone leaves the container able to reach the host's own
listening services. A host firewall alone does nothing about traffic forwarded
past it to the rest of the LAN. Close both, and verify both separately —
testing one and inferring the other is how a gap survives a review.

`docker-compose.yml` pins `hermes-net` to a fixed subnet (`172.30.0.0/24`)
**specifically so a `DOCKER-USER` drop rule for it is stable**. On a
default-created network the subnet is a lease that merely happens to be
stable, and a rule written against it silently stops matching the day it
changes. `media-stack/scripts/docker-user-rules.sh` in this repo shows the
shape of such a rule.

Host-side, scope the firewall rules for anything you expose to your own LAN
range rather than `Anywhere`, so a container subnet like `172.30.0.0/24` is
excluded by construction rather than by an explicit deny.

If the agent *should* be allowed to reach something on purpose, that is a
legitimate call — make it an explicit written decision, not a
default-by-omission gap.

## Tool execution sandboxing

Hermes' own startup log self-flags: `terminal backend is 'local'
(unsandboxed) ... runs as the host user with full terminal/file access.`

That warning is aimed at bare-metal installs, where "local" means the real
host. In this deployment it does not apply: **the container is the sandbox**.
Shell-exec tool calls landing at uid 1000 inside it is the design — non-root,
`cap_drop: ALL` plus a minimal `cap_add`, `no-new-privileges`,
`pids_limit: 512`, no Docker socket or API reach, a loopback-only
authenticated API, and the egress rules above.

**Do not "fix" the warning with `terminal.backend: docker`.**

Hermes supports several terminal backends (local, Docker, SSH, Singularity,
Modal, Daytona, Vercel Sandbox). The Docker one runs exec in a *separate*
container — which means the gateway itself needs Docker API or socket reach in
order to create it. Handing a Docker socket to a prompt-injectable agent is a
host-compromise path: it is precisely the capability that stops a container
from being a boundary. The setting that looks like sandboxing is the one that
removes the sandbox.

This compose mounts no socket and should stay that way. If you do not need the
terminal tool for your use case, disable it in the tool-surface trim instead —
strictly better than sandboxing something you never wanted.

**Persistent-state risk, separate from exec.** `/opt/data` holds the agent's
writable memories, skills and sessions, and they survive restarts. A
prompt-injected agent can poison its own persisted state, turning a one-time
injection into one that comes back after every restart — and nothing in the
container security model addresses this, because an agent writing its own
memory is the intended behaviour.

Standing mitigation: treat everything under `/opt/data` as agent-tainted.
Never execute or trust it outside the container, and review anything under
`skills/` before promoting it anywhere, including into a git repo.

## Secrets

One, set as a stack environment variable — never committed, never written
into `docker-compose.yml`:

- `HERMES_API_KEY` — the gateway's own API auth. `openssl rand -hex 16`
  (32 characters).

Model credentials are **not** in the compose file. Hermes can authenticate
either with a plain provider API key or through an interactive OAuth flow run
once against the started container (`hermes setup --portal`); `auth.json` then
persists in the `/opt/data` bind mount, so it is one step per deployment
rather than per restart.

Given the choice, prefer a **dedicated, spend-limited, independently revocable
API key** over interactive OAuth against a personal account. The reason is
specific to this class of service rather than general hygiene: an agent that
processes untrusted content holds those credentials in a container reachable
by that content, so a compromise costs whatever the credential can reach. A
scoped key gets revoked in a minute; an account session is a much larger
conversation. If you take the OAuth path anyway, know you have made that
trade, check `auth.json` really does end up mode 600 owned by the runtime uid,
and work out how to revoke that one session *before* you need to.

Note also that provider OAuth flows can carry plan requirements and a
different billing model than a pay-per-token key — check which one you are
signing up for rather than discovering it on an invoice.

That choice feeds back into the section above: with account-level tokens
living in the container, the egress rules stop being LAN hygiene and become
part of what limits a credential compromise. Don't relax them without
treating it as a credential decision rather than a networking one.

## Image pinning

Pinned to a released version tag **and** its content digest, because registry
tags are mutable and a tag alone is not an identity. `nousresearch/
hermes-agent` publishes real version tags, so tag-plus-digest is
belt-and-braces; images that publish only rolling tags need digest-only
pinning, which is what `media-stack/` in this repo does.

Re-resolve and bump deliberately. A floating `:latest` turns every unrelated
redeploy into an unreviewed version jump — and on an agent, that includes
unreviewed changes to what tools it has.
