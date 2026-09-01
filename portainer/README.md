# portainer

Compose definition for the **Portainer CE server itself** — the instance that
manages every other stack, including remote Docker hosts reached over the
direct Docker API (TCP 2376, mTLS).

That last part is what makes this file worth care rather than a shrug. The
Portainer datastore holds the TLS client key for every remote host it manages,
and that key is root-equivalent on those hosts. Portainer is not just another
container on the box; it is the thing that can start containers everywhere
else.

## Deploy with the CLI, not as a Portainer stack

```sh
cd portainer
docker compose up -d
```

**Do not deploy this as a Portainer-managed stack.** It will appear to work,
and it will bite you on the one operation you'd want it for — upgrading
Portainer. Three reasons, in order of how much they hurt:

1. **Self-management deadlock.** Portainer runs `docker compose` *inside its
   own container*, against the mounted socket. Redeploying a stack that
   contains `portainer` means that process removes the container it is running
   in. It dies mid-run. Whether the replacement container comes up is down to
   timing, and you have no UI left to inspect the result — you're back on the
   CLI, but now with a half-applied stack instead of a clean one.
2. **The container-name collision makes the first cutover a CLI job anyway.**
   An existing container called `portainer` that was not created by a stack
   cannot be adopted by compose; it fails with *"container name /portainer is
   already in use"* until you `docker rm` it by hand. So the stack never
   actually removes the CLI step — it just relocates it.
3. **One mistake in the volume declaration destroys the datastore.** Without
   `external: true`, compose creates a *new, empty* volume named for the stack
   and starts Portainer on it. Everything — environments, client certs, users,
   stack definitions — is still on disk but no longer attached, and the first
   thing you'd see is a fresh "create an admin account" screen.

What you actually wanted from "make it a stack" — the run configuration living
in git instead of only inside a running container — you get from this file
regardless of who runs `docker compose`.

If you deploy it as a stack anyway, deploy it to the **local** environment.
Pointing it at a *remote* environment starts a second Portainer server there,
on a new empty datastore, publishing 9443 on a host whose firewall posture was
never designed for it.

## Upgrading

```sh
cd portainer
# 1. back up first — the datastore migration is one-way
docker stop portainer
docker run --rm -v portainer_data:/data -v "$HOME/portainer-backups:/backup" alpine \
  tar czf "/backup/portainer_data-$(date +%F-%H%M%S).tar.gz" -C /data .
docker start portainer

# 2. edit the pinned tag in docker-compose.yml, then
docker compose pull
docker compose up -d
docker compose logs -f          # watch the datastore migration
```

The image tag is **pinned**, not `:lts`. A floating tag turns every unrelated
redeploy into an unreviewed version jump, and there is no going back from a
migrated datastore without a restore. Bump it deliberately.

Backups go somewhere outside this repo, mode 700 — the datastore contains
client keys that are root-equivalent on the hosts they authenticate to.

### Rollback

```sh
docker rm -f portainer
docker volume rm portainer_data && docker volume create portainer_data
docker run --rm -v portainer_data:/data -v "$HOME/portainer-backups:/backup" alpine \
  tar xzf /backup/portainer_data-<stamp>.tar.gz -C /data
# set the tag back to the old version, then
docker compose up -d
```

## Notes on the published ports

- **9443** (HTTPS UI) is published on `127.0.0.1` in this file. Community
  Edition has no MFA, and this datastore holds root-equivalent credentials for
  other hosts, so LAN exposure of the UI is a bigger deal than it looks.
  If Portainer runs on a machine you don't browse from, tunnel rather than
  republishing on all interfaces:

  ```sh
  ssh -N -L 9443:127.0.0.1:9443 <user>@<host>
  ```

  The reflex fix when the UI is unreachable is to change the line back to
  `"9443:9443"`, which silently restores the exposure. Don't.
- **8000** (Edge agent tunnel) is deliberately not published. Publish it only
  if you actually run an Edge agent.
- The Docker socket bind is root-equivalent on the machine Portainer runs on.
  It's required for Portainer to manage the local environment, and it's the
  reason the 9443 placement above is worth a thought.

## Two Portainer behaviours worth knowing before you automate it

Both of these were established the hard way, against a real instance, and
neither is documented anywhere obvious.

**1. Non-administrator restrictions test for the *presence* of a directive,
not whether it grants or removes privilege.**

Portainer environments can restrict which compose directives a
non-administrator may deploy — capabilities, devices, bind mounts, and so on.
The check is syntactic. `cap_drop: ALL`, which is pure hardening and strictly
reduces what the container can do, is refused exactly like
`cap_add: NET_ADMIN`. The practical consequence is counter-intuitive enough to
plan around:

> **Hardening a compose file moves the stack to admin-only.**

So a hardening pass across your stacks is also, silently, a change to who can
redeploy them. Decide which of the two you want before you start; you may not
get both. This was observed rather than assumed — the initial prediction was
that `cap_drop` would be allowed, and it was wrong, corrected against a real
HTTP 500.

**2. `PUT /api/stacks/{id}/git/redeploy` must carry
`repositoryAuthentication: true`.**

Even when Portainer already holds the git credential for that stack. Omitting
the flag does *not* fall back to the stored credential — the clone is attempted
anonymously, and for a private repo it fails with a message that names neither
authentication nor the repository. You will read that error several times
before it occurs to you that it is about auth at all.

## Scripts

`scripts/verify-endpoint-security.py` reports an environment's
non-administrator restrictions; `scripts/set-endpoint-security.py` applies
them. Both need an API key and an environment id — neither is hardcoded. See
each script's `--help`.
