#!/usr/bin/env bash
# Prepares a Docker host to run the media-stack compose files: kernel module,
# credential files, directories, host-side scripts, systemd units, firewall
# rules, and the cross-stack network.
#
# RUN THIS ON THE DOCKER HOST ITSELF, as a user with real sudo — not from
# a workstation, and not from an unprivileged automation account. It prompts
# for VPN credentials interactively, and it is the only part of this repo
# that mutates host state.
#
# WHY AN INSTALL SCRIPT rather than relative bind mounts in the compose
# files: if you deploy these as git-repository stacks, the orchestrator
# clones the repo INTO ITS OWN CONTAINER. A `./scripts/…:/…` bind then
# resolves against the Docker host, not against that clone, and silently
# mounts an empty directory. Host-side files have to get onto the host by
# some path the orchestrator is not involved in. That is this script.
#
# Safe to re-run: every step checks current state before changing anything,
# so re-running after a repo update only touches what actually needs it.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -t 0 ]; then
    cat >&2 <<'NOTTY'
ERROR: stdin is not a terminal. This script prompts for VPN credentials and
the qBittorrent WebUI password, and refuses to run where those prompts can't
be answered interactively (and where secrets could end up in a log). Run it
from a real terminal on the Docker host:

    cd media-stack
    ./install-on-host.sh
NOTTY
    exit 1
fi

echo "==> Step 0: configuration"
# One file feeds both `docker compose` (which reads ./.env by itself) and the
# host-side scripts and units (which source /etc/media-stack/env). Copying it
# here rather than duplicating values is what keeps the two from drifting.
if [ ! -f .env ]; then
    echo "    ERROR: .env not found. Copy .env.example to .env and fill it in first." >&2
    exit 1
fi
set -a; . ./.env; set +a
: "${MEDIA_ROOT:?set MEDIA_ROOT in .env}"
: "${LAN_IP:?set LAN_IP in .env}"
: "${LAN_SUBNET:?set LAN_SUBNET in .env}"
: "${MEDIA_USER:?set MEDIA_USER in .env}"
: "${MEDIA_GROUP:?set MEDIA_GROUP in .env}"
OWNER="${MEDIA_USER}:${MEDIA_GROUP}"

id -u "$MEDIA_USER" >/dev/null 2>&1 || {
    echo "    ERROR: user '$MEDIA_USER' does not exist on this host." >&2; exit 1; }

sudo mkdir -p /etc/media-stack
sudo install -o root -g root -m 600 .env /etc/media-stack/env
echo "    installed /etc/media-stack/env (mode 600, root:root)"
echo "    MEDIA_ROOT=$MEDIA_ROOT  LAN_IP=$LAN_IP  LAN_SUBNET=$LAN_SUBNET  owner=$OWNER"

echo
echo "==> Step 1: preload the wireguard kernel module"
# NOT `cap_add: SYS_MODULE` in the compose file — that capability is
# host-root-equivalent, and loading the module once here means the vpn
# container only ever needs NET_ADMIN.
if [ -f /etc/modules-load.d/wireguard.conf ] && grep -qxF wireguard /etc/modules-load.d/wireguard.conf; then
    echo "    /etc/modules-load.d/wireguard.conf already has 'wireguard' -- skipping"
else
    echo wireguard | sudo tee /etc/modules-load.d/wireguard.conf >/dev/null
fi
sudo modprobe wireguard
# `lsmod | grep -q ...` is unsafe under `set -o pipefail`: grep -q closes the
# pipe as soon as it matches, sending lsmod a SIGPIPE (exit 141) before it
# finishes writing, and pipefail then reports that 141 as the pipeline's exit
# status even though grep itself matched. Capture lsmod's output first so grep
# never reads from a live pipe.
if grep -q '^wireguard ' <<<"$(lsmod)"; then
    echo "    verified: wireguard.ko loaded ($(modinfo -F version wireguard 2>/dev/null))"
else
    echo "    ERROR: wireguard module did not load" >&2
    exit 1
fi

echo
echo "==> Step 2: root-only credential files (mode 400, root:root)"
# The *_FILE convention: the container reads a path, not an environment
# variable. One fewer "is this actually safe?" question than baking a secret
# into the compose file, and nothing lands in `docker inspect`.
prompt_secret_file() {
    local path="$1" desc="$2" value
    if sudo test -f "$path"; then
        echo "    $path already exists -- skipping ($desc). Remove it first to rotate."
        return 0
    fi
    # Re-prompt on an empty value rather than returning non-zero: this runs
    # under `set -euo pipefail`, so a plain non-zero return would abort the
    # whole script mid-install (two credential files written, the third
    # missing) instead of just asking again.
    while true; do
        read -r -s -p "    Enter $desc (input hidden, goes straight to $path): " value
        echo
        [ -n "$value" ] && break
        echo "    Empty value, try again (Ctrl-C to abort the whole script)." >&2
    done
    printf '%s' "$value" | sudo tee "$path" >/dev/null
    sudo chmod 400 "$path"
    sudo chown root:root "$path"
    unset value
    echo "    wrote $path (mode $(sudo stat -c %a "$path"), owner $(sudo stat -c %U:%G "$path"))"
}
prompt_secret_file /root/pia-user "your VPN provider username"
prompt_secret_file /root/pia-pass "your VPN provider password"
prompt_secret_file /root/qbt-pass "the qBittorrent WebUI password you want to use (you set this password IN qBittorrent's WebUI yourself at first start; this file is only what the port-sync script logs in with)"
for f in pia-user pia-pass qbt-pass; do
    perm="$(sudo stat -c %a "/root/$f")"
    [ "$perm" = "400" ] || { echo "    ERROR: /root/$f is mode $perm, expected 400" >&2; exit 1; }
done

echo
echo "==> Step 3: media directories"
sudo mkdir -p "$MEDIA_ROOT/downloads" "$MEDIA_ROOT/library"
# chown ONLY these three directories, never -R. Once real media exists a
# recursive chown is a multi-hour tree walk on every re-run, and it would
# stomp the ownership the *arrs deliberately set on imported files. Today
# those two happen to produce the same result; repeating the wrong operation
# because it is currently harmless is how it stops being harmless.
for d in "$MEDIA_ROOT" "$MEDIA_ROOT/downloads" "$MEDIA_ROOT/library"; do
    owner="$(stat -c %U:%G "$d" 2>/dev/null || true)"
    if [ "$owner" = "$OWNER" ]; then
        echo "    $d already $OWNER -- skipping"
    else
        sudo chown "$OWNER" "$d"
        echo "    chowned $d to $OWNER (was $owner)"
    fi
done
echo "    verified:"
ls -ld "$MEDIA_ROOT" "$MEDIA_ROOT/downloads" "$MEDIA_ROOT/library"

echo
echo "==> Step 4: install scripts + systemd units to /opt/media-stack"
# Owner root:root, and deliberately NOT the media user or any automation
# account. Upstream's pf_success.sh runs `eval "$PORT_SCRIPT $1"` AS ROOT
# inside the vpn container, so whoever can write qbt-portsync.sh effectively
# owns a root shell holding the VPN credentials, the qBittorrent admin
# password, and a LAN-open firewall. Keeping these root-owned on the host
# (755: readable, not writable) means compromising an ordinary account does
# not let you rewrite what runs as root inside that container.
#
# qbt-portsync.sh lives in its OWN subdirectory, /opt/media-stack/vpn/, which
# docker-compose.vpn.yml bind-mounts as a DIRECTORY rather than a single
# file. `install(1)` below unlinks-then-creates on every re-run, giving the
# file a new inode each time; a single-file bind mount would keep an
# already-running container pinned to the OLD inode, silently breaking this
# script's "safe to re-run, refreshes the scripts" promise. Mounting the
# containing directory means the running container always sees current
# content. netns-guard.sh stays one level up, since it is host-only and must
# never be reachable from inside a container.
sudo mkdir -p /opt/media-stack/vpn
sudo install -o root -g root -m 755 scripts/qbt-portsync.sh /opt/media-stack/vpn/qbt-portsync.sh
sudo install -o root -g root -m 755 scripts/netns-guard.sh /opt/media-stack/netns-guard.sh
echo "    verified:"
ls -l /opt/media-stack/ /opt/media-stack/vpn/

echo
echo "==> Step 4b: netns-guard systemd service + timer (installed, NOT started)"
sudo install -o root -g root -m 644 systemd/media-netns-guard.service /etc/systemd/system/media-netns-guard.service
sudo install -o root -g root -m 644 systemd/media-netns-guard.timer /etc/systemd/system/media-netns-guard.timer
sudo systemctl daemon-reload
echo "    verified: unit files load cleanly:"
sudo systemctl cat media-netns-guard.timer >/dev/null && echo "    media-netns-guard.timer OK"
sudo systemctl cat media-netns-guard.service >/dev/null && echo "    media-netns-guard.service OK"
# Deliberately NOT `enable --now`: before the vpn stack exists there is
# nothing for the guard to check, and enabling it as an install-time side
# effect buries a step that should be a visible part of the deploy sequence.
# Enable it explicitly once media-vpn is actually running:
#     sudo systemctl enable --now media-netns-guard.timer

echo
echo "==> Step 4c (optional): alerting webhook for netns-guard"
# Optional by mechanism, not by design: netns-guard.sh logs to the journal
# and continues if this is absent, but a guard that repairs silently has only
# relocated the silence this architecture is prone to. Press Enter to skip
# and re-run this script later to add it.
if sudo test -s /etc/media-stack/ha-webhook-url; then
    echo "    /etc/media-stack/ha-webhook-url already set -- skipping"
else
    read -r -p "    Alert webhook URL (blank to skip): " ha_url
    if [ -n "$ha_url" ]; then
        printf '%s' "$ha_url" | sudo tee /etc/media-stack/ha-webhook-url >/dev/null
        sudo chmod 400 /etc/media-stack/ha-webhook-url
        sudo chown root:root /etc/media-stack/ha-webhook-url
        echo "    wrote /etc/media-stack/ha-webhook-url"
        echo "    NOTE: writing the URL is NOT the same as having a working alert."
        echo "    Home Assistant (and most webhook receivers) return 2xx for a POST"
        echo "    to a webhook id that no longer exists, so a 2xx proves the request"
        echo "    left this host and nothing more. You still need to:"
        echo "      1. Create the automation that turns these POSTs into a"
        echo "         notification (payload shape is documented in README.md)."
        echo "      2. Fire a test POST and confirm INSIDE the receiver that it"
        echo "         arrived, e.g.:"
        echo "           curl -X POST -H 'Content-Type: application/json' \\"
        echo "             -d '{\"severity\":\"drift\",\"message\":\"netns-guard install test\"}' \\"
        echo "             \"\$ALERT_URL\""
        echo "    Do this before treating silence from netns-guard as good news."
    else
        echo "    skipped -- netns-guard will log to the journal only until this is set"
    fi
fi

echo
echo "==> Step 4d: manual-drop import pipeline"
# Drop folders: owned by the media user, group-writable, so both a human
# (over SMB/scp) and the *arrs (uid/gid 1000, UMASK 002) can write them.
# Same non-recursive chown rationale as Step 3.
sudo mkdir -p "$MEDIA_ROOT/downloads/drop/tv" "$MEDIA_ROOT/downloads/drop/movies"
for d in "$MEDIA_ROOT/downloads/drop" "$MEDIA_ROOT/downloads/drop/tv" "$MEDIA_ROOT/downloads/drop/movies"; do
    sudo chown "$OWNER" "$d"
    sudo chmod 775 "$d"
done
echo "    verified:"
ls -ld "$MEDIA_ROOT/downloads/drop" "$MEDIA_ROOT/downloads/drop/tv" "$MEDIA_ROOT/downloads/drop/movies"

# API keys for drop-import.sh: read out of each *arr's own config.xml via
# docker exec, so they never transit the network or land in this repo. Stored
# root:root 400 in /etc/media-stack/, the same custody model as the webhook
# URL above. Tolerant on purpose: if the containers are not running yet
# (first install) this is skipped, drop-import.sh logs a pointer back here,
# and re-running this script later completes it.
for app in sonarr radarr; do
    keyfile="/etc/media-stack/${app}-api-key"
    if sudo test -s "$keyfile"; then
        echo "    $keyfile already set -- skipping"
    elif key=$(docker exec "$app" sed -n 's/.*<ApiKey>\(.*\)<\/ApiKey>.*/\1/p' /config/config.xml 2>/dev/null) && [ -n "$key" ]; then
        printf '%s' "$key" | sudo tee "$keyfile" >/dev/null
        sudo chmod 400 "$keyfile"
        sudo chown root:root "$keyfile"
        echo "    wrote $keyfile"
    else
        echo "    $app container not running -- key skipped; re-run this script once the apps stack is up"
    fi
done

# Script + units: root-owned like everything in /opt/media-stack.
# drop-import.sh is host-only and never mounted into a container. It needs
# python3, which drives the ManualImport API and does the JSON escaping —
# dropped filenames must never become shell words.
command -v python3 >/dev/null || echo "    WARNING: python3 missing -- drop-import.sh will not run"
sudo install -o root -g root -m 755 scripts/drop-import.sh /opt/media-stack/drop-import.sh
sudo install -o root -g root -m 644 systemd/media-drop-import.service /etc/systemd/system/media-drop-import.service
sudo install -o root -g root -m 644 systemd/media-drop-import.timer /etc/systemd/system/media-drop-import.timer
sudo systemctl daemon-reload
sudo systemctl cat media-drop-import.timer >/dev/null && echo "    media-drop-import.timer OK"
sudo systemctl cat media-drop-import.service >/dev/null && echo "    media-drop-import.service OK"
# Same deliberate-enable convention as the netns-guard timer.
echo "    installed but NOT enabled -- enable with:"
echo "      sudo systemctl enable --now media-drop-import.timer"

echo
echo "==> Step 5: DOCKER-USER firewall rules + boot persistence (systemd oneshot)"
# A host firewall cannot filter published container ports: Docker DNATs them
# in PREROUTING, so the traffic never traverses INPUT. DOCKER-USER is the
# chain Docker guarantees to jump to first from FORWARD and never flushes.
#
# DO NOT reach for iptables-persistent to make these survive a reboot. That
# package declares `Conflicts: ufw`, and apt will resolve the conflict inside
# a single `-y` transaction by removing ufw — taking every INPUT rule on the
# host with it, silently. Worse, `netfilter-persistent save` snapshots
# Docker's own dynamically generated chains and restores them at boot BEFORE
# dockerd starts and rebuilds them, so you also inherit a stale ruleset
# shadowing the live one.
#
# Persistence here is a systemd oneshot (media-docker-user.service) ordered
# After=docker.service that re-inserts only its own rules, idempotently. No
# package to install, nothing for apt to remove, no snapshot to go stale.
# This step deliberately runs NO apt command at all.
if ! grep -q '^ii' <<<"$(dpkg -l ufw 2>/dev/null)"; then
    echo "    WARNING: ufw is not installed -- this host may have NO inbound" >&2
    echo "    filtering at all (INPUT policy ACCEPT). Continuing, since the" >&2
    echo "    DOCKER-USER rules below are worth having either way." >&2
elif ! sudo ufw status 2>/dev/null | grep -q '^Status: active'; then
    echo "    WARNING: ufw is installed but NOT active." >&2
fi
if grep -q '^ii' <<<"$(dpkg -l iptables-persistent 2>/dev/null)"; then
    echo "    WARNING: iptables-persistent is installed. It conflicts with ufw," >&2
    echo "    and its boot-time snapshot restore is superseded by" >&2
    echo "    media-docker-user.service. Consider removing it." >&2
fi
sudo install -o root -g root -m 755 scripts/docker-user-rules.sh /opt/media-stack/docker-user-rules.sh
sudo install -o root -g root -m 644 systemd/media-docker-user.service /etc/systemd/system/media-docker-user.service
sudo systemctl daemon-reload
# Unlike the netns-guard timer, this IS enabled at install time: the rules are
# wanted from now on unconditionally, there is no "nothing to check yet"
# state, and running it now doubles as the verification.
# `restart`, not `enable --now`: the unit is RemainAfterExit=yes, so once
# active a plain `start` is a no-op and a re-run (after adding a port, say)
# would silently not apply the new rule until the next reboot.
sudo systemctl enable media-docker-user.service
sudo systemctl restart media-docker-user.service
echo "    verified: current DOCKER-USER rules:"
sudo iptables -S DOCKER-USER
echo "    verified: $(sudo systemctl is-enabled media-docker-user.service) / $(sudo systemctl is-active media-docker-user.service)"

echo
echo "==> Step 6: media-jf-link network (*arr -> Jellyfin, no firewall hole)"
# Lets Sonarr/Radarr reach Jellyfin WITHOUT punching a hole in the
# DOCKER-USER rules from Step 5. A container dialling the LAN-published
# 8096 is DNAT'd into FORWARD, where the LAN-only DROP for 8096 drops it —
# its source is a docker bridge address, not the LAN. If br_netfilter is not
# loaded, same-bridge container traffic bypasses netfilter entirely, so a
# shared network needs no firewall change at all.
#
# --internal is the load-bearing flag, not a nicety: Docker adds no
# masquerade and no gateway for an internal network, so this link can never
# become an egress path. "All app egress goes through the VPN" then holds by
# construction rather than by rule. Do not drop --internal to make debugging
# easier.
#
# Created here, and declared `external: true` in the compose files, because
# it spans separate stacks and none of them may own its lifecycle. It must
# exist BEFORE any of them deploy.
#
# 10.89.0.0/24 sits outside Docker's default address pool (172.16.0.0/12) so
# it can never collide with an auto-allocated network. Jellyfin is pinned to
# 10.89.0.10 in docker-compose.media.yml, and the *arrs must target that
# literal address: service-name DNS does not resolve inside the vpn netns,
# because wg-quick rewrites resolv.conf to the VPN's resolvers by design.
if docker network inspect media-jf-link >/dev/null 2>&1; then
    echo "    media-jf-link already exists -- skipping"
else
    docker network create --internal --subnet 10.89.0.0/24 media-jf-link
    echo "    created media-jf-link"
fi
echo "    verified: internal=$(docker network inspect -f '{{.Internal}}' media-jf-link), subnet=$(docker network inspect -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' media-jf-link)"

cat <<'DONE'

==> Host prep complete. Remaining steps are NOT done by this script:

  1. Deploy the vpn stack (docker-compose.vpn.yml), with COMPOSE_PROFILES
     UNSET for this first deploy -- qbittorrent/prowlarr/sonarr/radarr carry
     profiles: ["apps"], so an unset COMPOSE_PROFILES starts only `vpn`.
     See that file's header for why this replaces per-service scaling.
  2. Verify the tunnel ALONE before anything else touches it: egress IP,
     DNS resolver, and that stopping the vpn container kills the dependants'
     networking rather than leaking around it.
  3. Enable the netns-guard timer, now that there is something for it to
     check:  sudo systemctl enable --now media-netns-guard.timer
  4. Set COMPOSE_PROFILES=apps and redeploy. This starts
     qbittorrent/prowlarr/sonarr/radarr.
  5. FIRST START, BEFORE ANYTHING ELSE TOUCHES qBittorrent: log into its
     WebUI with the random temporary password from `docker logs qbittorrent`
     and change it to match what you entered into /root/qbt-pass above. Do
     this BEFORE the port-sync loop gets a chance to run, or it will hammer
     the login endpoint with the wrong credential and risk banning 127.0.0.1
     for every service sharing that namespace.
  6. If you set an alert webhook, confirm delivery INSIDE the receiver with
     a manual test POST. Do not rely on an HTTP 2xx as proof it works.
  7. Deploy the Jellyfin stack (docker-compose.media.yml), same MEDIA_ROOT.
  8. Run your own leak tests before trusting any of this.

DONE
