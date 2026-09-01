#!/usr/bin/env bash
# Inserts the five DOCKER-USER LAN-only DROP rules for the media-stack's
# published WebUI ports. ufw cannot filter published container ports --
# Docker DNATs them in PREROUTING, so forwarded traffic never traverses
# INPUT -- which is why these live in DOCKER-USER (the chain Docker
# guarantees to jump to first from FORWARD and never flushes itself).
#
# Run as root by systemd at boot (media-docker-user.service, After=
# docker.service so the DOCKER-USER chain exists) and by install-on-host.sh
# Step 5 at install time. Idempotent: -C before every -I, so re-runs and
# boot-time runs never duplicate rules.
#
# This replaces the iptables-persistent/netfilter-persistent approach an
# earlier revision used. Two independent reasons, both learned the hard way
# and both worth knowing before you reach for that package:
#
#   1. iptables-persistent declares `Conflicts: ufw`. Installing it does not
#      warn you -- apt removes ufw and every INPUT rule on the host goes with
#      it. `apt-get install -y` makes that silent and instant.
#   2. `netfilter-persistent save` snapshots Docker's own dynamically
#      generated chains and restores them at boot BEFORE dockerd starts and
#      rebuilds them, so you end up with a stale ruleset shadowing the live
#      one.
#
# Re-inserting the rules at boot from here needs no package, cannot conflict
# with the host firewall, and touches only its own rules. See DESIGN.md.
#
# IPv4 only, deliberately: every port below is published on the host's IPv4
# LAN address in the compose files; Docker performs no IPv6 DNAT for them.
set -euo pipefail

# Configuration comes from /etc/media-stack/env (root:root 600, installed by
# install-on-host.sh). Sourced here rather than declared EnvironmentFile= in
# the unit so that a hand-run and a systemd run resolve identically -- a
# script that only works under systemd is a script nobody can debug.
[ -r /etc/media-stack/env ] && { set -a; . /etc/media-stack/env; set +a; }

# Sourced from /etc/media-stack/env (root-only) -- no default. A firewall
# script that falls back to a guessed subnet is worse than one that refuses
# to run: the fallback silently protects the wrong network.
: "${LAN_SUBNET:?set LAN_SUBNET in /etc/media-stack/env, e.g. 192.168.1.0/24}"
LAN="$LAN_SUBNET"

# Create the chain only if Docker hasn't yet (never flush it -- Docker owns
# its lifecycle and will add its own FORWARD jump). With After=docker.service
# this is belt-and-braces; it matters if this script is ever run by hand
# before dockerd is up.
iptables -N DOCKER-USER 2>/dev/null || true

# 8096 (Jellyfin) is included deliberately even though it is the one service
# meant to be reachable: it publishes on the same host address as the rest,
# and a defence-in-depth rule that matters for four ports matters for the
# fifth. LAN-only is still the intent; this is not an internet exposure.
for p in 8080 9696 8989 7878 8096; do
    if iptables -C DOCKER-USER ! -s "$LAN" -p tcp --dport "$p" -j DROP 2>/dev/null; then
        echo "DOCKER-USER DROP rule for port $p already present -- skipping"
    else
        iptables -I DOCKER-USER ! -s "$LAN" -p tcp --dport "$p" -j DROP
        echo "inserted DOCKER-USER DROP rule for port $p"
    fi
done

# Agent-container egress containment (see the hermes-agent directory in this
# repo, "Egress containment"). This is a different SHAPE from the rules
# above, which is the point worth noticing: those protect published host
# ports from non-LAN *sources*; this one blocks a container, as a *source*,
# from reaching the LAN at all. An agent's tool calls are steerable by
# whatever content it processes, so container->LAN forwarding stays closed by
# default rather than open-by-omission. hermes-net is pinned to
# 172.30.0.0/24 in hermes-agent/docker-compose.yml specifically so this rule
# stays valid across redeploys.
HERMES_NET=172.30.0.0/24
if iptables -C DOCKER-USER -s "$HERMES_NET" -d "$LAN" -j DROP 2>/dev/null; then
    echo "DOCKER-USER DROP rule for hermes-net -> LAN already present -- skipping"
else
    iptables -I DOCKER-USER -s "$HERMES_NET" -d "$LAN" -j DROP
    echo "inserted DOCKER-USER DROP rule for hermes-net -> LAN"
fi
