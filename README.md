# homelab

The reusable parts of a personal homelab: compose files, host-prep scripts,
systemd units, and the reasoning behind the choices that are not obvious.

Everything here ran somewhere real. The write-ups are deliberately specific
about what was *tried and dropped*, and about the limits of each control,
because that is the part usually missing from published configs.

| Directory | What's in it |
|---|---|
| [`media-stack/`](media-stack/) | WireGuard kill switch, qBittorrent, Prowlarr/Sonarr/Radarr, Jellyfin, Maintainerr — three compose stacks, host-side guard and import scripts, systemd units. [`DESIGN.md`](media-stack/DESIGN.md) is the reusable engineering |
| [`hermes-agent/`](hermes-agent/) | A self-hosted AI agent in a container: privilege model, egress containment, and why the setting that looks like sandboxing removes the sandbox |
| [`portainer/`](portainer/) | Portainer CE itself — why not to deploy it as its own stack, plus two undocumented API/permission behaviours worth knowing before you automate it |
| [`docker-socket-proxy/`](docker-socket-proxy/) | A regex-allowlisted Docker API proxy, so an automation account can leave the docker group. Includes an honest statement of its ceiling |
| [`claude-statusline/`](claude-statusline/) | Claude Code statusline with a drift-checking installer |
| [`onedrive-links/`](onedrive-links/) | Microsoft Graph OneDrive sharing-link CLI, with tests |

## Configuration

Nothing here hardcodes an address, a path, or a group id. Each directory
that needs configuration ships a `.env.example` listing every variable and,
where it matters, **why that variable has no default**. The general rule
used throughout:

> A script that falls back to a guessed LAN address or media root is worse
> than one that refuses to start. The guess fails silently, later, and
> somewhere else.

## A few recurring themes

Not a philosophy section — these are the specific things that shaped more
than one directory here:

- **Prefer structural guarantees to rules.** `internal: true` cannot carry
  egress; a firewall exception can be edited at midnight by someone
  debugging. Where a policy can be converted into a property, it was.
- **State the ceiling.** The socket proxy cannot scope exec per container.
  The netns guard cannot heal a recreate. Both say so, in the file, rather
  than looking stronger than they are.
- **Fail closed and loudly.** Required variables use `${VAR:?}` so a
  half-configured deploy dies at parse time.
- **Record what was tried and dropped.** `read_only: true` on the agent
  container, autoheal for the netns guard, `iptables-persistent` for
  firewall persistence — each has a note saying why not, so the next person
  doesn't spend the same afternoon.

## Licence and scope

[MIT](LICENSE).

**The licence covers the compose files, scripts and documentation in this
repository — not the upstream images they pull.** Each of those carries its
own licence and its own security posture; pinning a digest is not the same
as vouching for what is inside it.

**No support, no warranty.** This is published because the write-ups may
save someone time, not as a product. It publishes firewall rules, a VPN kill
switch, and privilege-model decisions that were correct for one environment
and may be wrong for yours — read the reasoning, don't copy the values.
Verify the security properties yourself before relying on any of them,
particularly anything involving a kill switch or a firewall: a leak test you
did not run yourself is not a leak test.
