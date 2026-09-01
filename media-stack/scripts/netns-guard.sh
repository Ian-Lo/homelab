#!/usr/bin/env bash
# netns-guard.sh — detects when qbittorrent/prowlarr/sonarr/radarr have
# drifted out of media-vpn's network namespace and restarts them; ALSO
# detects when media-vpn is running but UNHEALTHY (a dead tunnel) and acts on
# it; alerts via a Home Assistant webhook when it can't fix something.
# DESIGN.md § "The netns lifecycle trap" has the full rationale, and the
# README documents the webhook payload shape and severity values below --
# that's the contract the receiving automation must be built against.
#
# WHY THIS EXISTS: `network_mode: service:vpn` is the kill switch — the four
# dependants own no interface of their own. But that same design means that
# if `vpn`'s namespace is destroyed (container stopped, or recreated with a
# new container ID after e.g. an image bump), the dependants keep running
# but silently lose ALL networking (thrnz/docker-wireguard-pia issue #44,
# open, unresolved upstream). They look healthy in `docker ps`. That silence
# is the actual failure mode this script exists to end.
#
# Runs as ROOT on the HOST via a systemd timer (media-netns-guard.timer),
# talking to the LOCAL Docker socket directly — deliberately NOT inside a
# container, and this is the one design choice here worth arguing about.
# The usual answer is an autoheal container; the objection to it is that the
# Docker socket is root-equivalent on the host, so a long-lived container
# holding it is a standing escalation path that outlives the 30 seconds of
# work it does. A root systemd unit invoking the socket per run adds no
# privilege that root did not already have.
#
# What it does, every run:
#   1. If media-vpn doesn't exist as a container at all, exits quietly —
#      that's the expected pre-deploy state, not a fault.
#   2. Otherwise checks media-vpn is running with a readable netns, then
#      compares each dependant's network namespace against it, via
#      /proc/<pid>/ns/net — NOT `docker inspect`'s SandboxKey, which is
#      empty for containers using network_mode: service:vpn (they don't own
#      a sandbox of their own). A dependant that doesn't exist yet (Phase 1,
#      before COMPOSE_PROFILES=apps is set) is likewise skipped quietly. A
#      dependant that exists but isn't "running" — including Docker's
#      "restarting" status, i.e. a crash-restart loop — is flagged, not
#      silently skipped.
#   3. Drift -> `docker restart <dependant>` — the ONLY repair this script
#      ever performs — then re-checks. Success or failure, alert Home
#      Assistant.
#   4. If restart didn't fix it (e.g. `vpn` was recreated with a new
#      container ID — the R1 case — and the dependant's stored
#      NetworkMode now points at a dead container), alert LOUDER and stop.
#      This script never attempts to recreate a container: that needs the
#      compose file, which may not even be on this host (with a
#      git-repository stack it lives in the orchestrator's clone). Detect and
#      alert; never pretend to heal. See DESIGN.md.
#
# The media-vpn HEALTH check: a dead-but-up tunnel does NOT
# strand the dependants — the netns is intact, so step 2 above sees no drift —
# yet egress is dead (failing closed behind the kill switch, so no leak, but no
# connectivity and, before this check, no visibility). With ACTIVE_HEALTHCHECKS=1
# on the vpn service the image reports the container `unhealthy` in that state.
# This guard reads that health status once media-vpn is confirmed running:
#   - Default (RESTART_VPN_ON_UNHEALTHY unset/0): ALERT and stop. The safe
#     recovery is a stack redeploy (or a deliberate restart + dependant
#     repair), which is disruptive and the operator's call — so the guard
#     makes the dead tunnel VISIBLE rather than acting on it silently.
#   - Opt-in (RESTART_VPN_ON_UNHEALTHY=1): restart media-vpn, wait (bounded by
#     VPN_HEALTHY_TIMEOUT, default 120s) for it to return to `healthy`, then
#     let the drift loop below repair the dependants the restart necessarily
#     strands. Restarting media-vpn is the one action this guard otherwise
#     NEVER performs (it strands dependants — I1), so it is gated behind this
#     flag and always repairs what it strands. A tunnel dead from a persistent
#     cause (bad endpoint/credentials) will just flap here — which is why the
#     default is alert-only.
#
# Alerting is debounced against a small state file (STATE_FILE, default on
# tmpfs under /run so it resets cleanly across reboots): each tracked key
# (the owner, or one dependant) only alerts on a state TRANSITION, or at
# most once every RE_ALERT_INTERVAL while stuck in the same bad state —
# otherwise a test run, or any real multi-hour outage, would re-alert on
# every single timer tick -- which is just a different way of not being
# heard. A one-shot "recovered"
# notification fires when a key returns to "ok" from a bad state.
#
# Safe to run repeatedly / concurrently is not assumed — the systemd unit
# is Type=oneshot on a timer, so normally only one instance runs at a time.
set -u

OWNER="${MEDIA_VPN_CONTAINER:-media-vpn}"
# Every container that runs network_mode: service:vpn belongs here —
# a netns resident missing from this list is the one whose drift nothing
# detects (Byparr review B3). The guard tolerates not-yet-deployed names,
# so byparr may be listed before its first deploy.
DEPENDANTS=(qbittorrent prowlarr sonarr radarr byparr)
HA_WEBHOOK_FILE="${HA_WEBHOOK_FILE:-/etc/media-stack/ha-webhook-url}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
STATE_FILE="${STATE_FILE:-/run/media-stack/netns-guard.state}"
RE_ALERT_INTERVAL="${RE_ALERT_INTERVAL:-3600}"  # re-alert at most hourly while a bad state persists

now_epoch="$(date +%s)"

log() {
    printf '%s netns-guard: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

json_escape() {
    # Escapes a string for embedding in a JSON string literal. Log messages
    # here are effectively single-line; newlines/tabs are collapsed to a
    # space rather than round-tripped, which is fine for an alert payload
    # and keeps this to two sed substitutions (no dead pipeline stages).
    printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ha_notify MESSAGE SEVERITY
# SEVERITY is one of:
#   "drift"         netns drift was detected AND repaired via docker
#                   restart — informational, no action needed.
#   "not-running"   a dependant exists but isn't running (stopped, or
#                   Docker's "restarting" status i.e. a crash-restart
#                   loop) — needs a human, this is not something the
#                   guard can fix by restarting it further.
#   "repair-failed" drift was detected and docker restart did NOT fix it,
#                   or media-vpn itself isn't running/readable — needs a
#                   human (see "The namespace lifecycle problem").
#   "unhealthy"     media-vpn is running but Docker reports it UNHEALTHY — a
#                   dead tunnel (egress failing closed, no leak). Alert-only
#                   by default; with RESTART_VPN_ON_UNHEALTHY=1 this severity
#                   also announces the automated restart, paired with a
#                   later "recovered".
#   "recovered"     a key that was previously non-"ok" is back to normal.
# Payload shape: {"severity": "...", "message": "..."}. See README.md for
# the full contract, including the two-notification sequence a routine
# auto-repair produces, and how the HA-side automation is meant to consume
# it.
ha_notify() {
    local message="$1" severity="$2" webhook_url
    if [ ! -r "$HA_WEBHOOK_FILE" ]; then
        log "(no HA webhook configured at $HA_WEBHOOK_FILE — logging only) [$severity] $message"
        return 0
    fi
    webhook_url="$(tr -d '[:space:]' < "$HA_WEBHOOK_FILE")"
    if [ -z "$webhook_url" ]; then
        log "(HA webhook file is empty — logging only) [$severity] $message"
        return 0
    fi
    local payload http_status
    payload="$(printf '{"severity":"%s","message":"%s"}' "$severity" "$(json_escape "$message")")"
    http_status="$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' -d "$payload" "$webhook_url" 2>/dev/null)"
    case "$http_status" in
        2??)
            # Home Assistant returns 2xx for a syntactically valid POST
            # even to a webhook ID that no longer exists -- a 2xx here
            # proves the POST left this host, not that HA actually did
            # anything with it. Delivery must be verified inside Home
            # Assistant itself, not inferred from this log line.
            log "HA webhook POSTed ($severity), HTTP $http_status"
            ;;
        *)
            log "WARNING: HA webhook POST returned '$http_status' — alert did not leave this host. [$severity] $message"
            ;;
    esac
}

# --- persistent per-key state, for the debouncing described above ---
mkdir -p "$(dirname "$STATE_FILE")"
touch "$STATE_FILE"

get_state() {
    # Prints "state epoch" for key $1, or nothing if never recorded.
    awk -v k="$1" '$1==k {print $2, $3; found=1} END{if(!found) print ""}' "$STATE_FILE"
}

set_state() {
    local key="$1" state="$2" epoch="$3" tmp
    # mktemp in the SAME directory as STATE_FILE (not the default /tmp):
    # /run/media-stack and /tmp can be different filesystems, in which case
    # `mv` across them is a copy+unlink, not an atomic rename -- defeating
    # the point of writing to a temp file first.
    tmp="$(mktemp -p "$(dirname "$STATE_FILE")")"
    awk -v k="$key" '$1!=k' "$STATE_FILE" > "$tmp" 2>/dev/null || true
    printf '%s %s %s\n' "$key" "$state" "$epoch" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# maybe_alert KEY STATE MESSAGE SEVERITY
#   STATE "ok": clears any tracked bad state for KEY; if it WAS bad, sends
#   a one-shot "recovered" notification (message/severity args ignored).
#   Any other STATE: alerts once on transition into it, then at most once
#   per RE_ALERT_INTERVAL while KEY stays in that same state.
maybe_alert() {
    local key="$1" state="$2" message="$3" severity="$4"
    local prev prev_state prev_epoch

    prev="$(get_state "$key")"
    prev_state="${prev%% *}"
    prev_epoch="${prev#* }"
    [ "$prev_epoch" = "$prev" ] && prev_epoch=""
    [ -z "$prev_epoch" ] && prev_epoch=0

    if [ "$state" = "ok" ]; then
        if [ -n "$prev_state" ] && [ "$prev_state" != "ok" ]; then
            ha_notify "$key: RECOVERED" "recovered"
        fi
        set_state "$key" "ok" "$now_epoch"
        return
    fi

    if [ "$prev_state" != "$state" ] || [ $(( now_epoch - prev_epoch )) -ge "$RE_ALERT_INTERVAL" ]; then
        ha_notify "$message" "$severity"
        set_state "$key" "$state" "$now_epoch"
    else
        log "(suppressing repeat alert for '$key' — still '$state', last alerted $(( now_epoch - prev_epoch ))s ago)"
        set_state "$key" "$state" "$prev_epoch"
    fi
}

container_status() {
    # Prints docker's State.Status ("running", "exited", "restarting", ...)
    # or nothing at all if the container doesn't exist.
    "$DOCKER_BIN" inspect -f '{{.State.Status}}' "$1" 2>/dev/null
}

container_health() {
    # Prints docker's health status ("healthy"/"unhealthy"/"starting"), or
    # nothing when the container has no healthcheck (or doesn't exist). The
    # `{{if .State.Health}}` guard is deliberate: without it a container with
    # no healthcheck renders the literal "<no value>", which would be
    # indistinguishable from a real status here.
    "$DOCKER_BIN" inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$1" 2>/dev/null
}

container_pid() {
    "$DOCKER_BIN" inspect -f '{{.State.Pid}}' "$1" 2>/dev/null
}

netns_id() {
    local pid="$1"
    [ -n "$pid" ] && [ "$pid" != "0" ] || return 1
    readlink "/proc/$pid/ns/net" 2>/dev/null
}

owner_status="$(container_status "$OWNER")"
if [ -z "$owner_status" ]; then
    log "$OWNER: no such container (not deployed yet) — nothing to check"
    exit 0
fi

if [ "$owner_status" != "running" ]; then
    log "ALERT: $OWNER exists but is not running (docker state: $owner_status). By design, that means qbittorrent/prowlarr/sonarr/radarr have no working network right now — this is not something a container restart can fix. An operator needs to redeploy the media-vpn stack."
    maybe_alert "OWNER" "stopped" "media-vpn exists but is not running (state: $owner_status). qbittorrent/prowlarr/sonarr/radarr have no network as a result. Redeploy the media-vpn stack (never 'docker restart media-vpn' alone)." "repair-failed"
    exit 0
fi

owner_pid="$(container_pid "$OWNER")"
owner_ns="$(netns_id "$owner_pid")"
if [ -z "$owner_ns" ]; then
    log "ALERT: $OWNER is running but its network namespace could not be read (pid=$owner_pid) — cannot compare dependants this cycle"
    maybe_alert "OWNER" "unreadable-ns" "netns-guard could not read media-vpn's network namespace (pid=$owner_pid)." "repair-failed"
    exit 0
fi

# media-vpn is running with a readable netns — but "running" is not "working".
# With ACTIVE_HEALTHCHECKS=1 the image pings THROUGH wg0, so Docker marks the
# container `unhealthy` when the interface is up but no traffic flows (dead or
# blackholed VPN endpoint, stale handshake). The netns is
# intact (dependants below will show no drift) yet egress is dead — failing
# closed behind the kill switch (no leak), but before this check, invisible.
owner_health="$(container_health "$OWNER")"
case "$owner_health" in
    unhealthy)
        if [ "${RESTART_VPN_ON_UNHEALTHY:-0}" = "1" ]; then
            log "ALERT: $OWNER is UNHEALTHY (dead tunnel). RESTART_VPN_ON_UNHEALTHY=1 → restarting it and repairing dependants."
            maybe_alert "OWNER" "unhealthy-recovering" "media-vpn is UNHEALTHY (running, tunnel dead, egress failing closed). Auto-recovery is ON: restarting media-vpn and repairing the dependants it strands (I1). A tunnel dead from a persistent cause will flap — watch for repeated alerts." "unhealthy"
            if ! restart_out="$("$DOCKER_BIN" restart "$OWNER" 2>&1)"; then
                log "ALERT: 'docker restart $OWNER' FAILED: $restart_out"
                maybe_alert "OWNER" "repair-failed" "Auto-recovery: 'docker restart media-vpn' FAILED ($restart_out). Manual redeploy of the media-vpn stack required." "repair-failed"
                exit 1
            fi
            # Wait (bounded) for the tunnel to come back before repairing
            # dependants — restarting them against a still-unhealthy vpn would
            # only re-strand them.
            waited=0
            while [ "$waited" -lt "${VPN_HEALTHY_TIMEOUT:-120}" ]; do
                sleep 5
                waited=$(( waited + 5 ))
                [ "$(container_health "$OWNER")" = "healthy" ] && break
            done
            owner_health="$(container_health "$OWNER")"
            if [ "$owner_health" != "healthy" ]; then
                log "ALERT: $OWNER did not return to healthy within ${VPN_HEALTHY_TIMEOUT:-120}s (health=$owner_health) after restart"
                maybe_alert "OWNER" "repair-failed" "Auto-recovery: media-vpn restarted but is still not healthy after ${VPN_HEALTHY_TIMEOUT:-120}s (health=$owner_health) — likely a persistent cause a restart can't fix (bad endpoint/credentials). Dependants are now stranded on the replaced netns; manual redeploy required." "repair-failed"
                exit 1
            fi
            # Healthy again, but the restart REPLACED media-vpn's netns, so
            # every dependant has now drifted. Re-read the new owner netns and
            # fall through: the drift loop below detects and repairs them.
            owner_pid="$(container_pid "$OWNER")"
            owner_ns="$(netns_id "$owner_pid")"
            if [ -z "$owner_ns" ]; then
                log "ALERT: $OWNER healthy after restart but its netns is unreadable (pid=$owner_pid)"
                maybe_alert "OWNER" "unreadable-ns" "media-vpn healthy after auto-restart but its network namespace is unreadable (pid=$owner_pid)." "repair-failed"
                exit 0
            fi
            log "$OWNER healthy again after restart; repairing dependants stranded by the netns replacement"
            maybe_alert "OWNER" "ok" "" ""   # transition out of unhealthy-recovering → fires one "recovered"
        else
            # Default: make the dead tunnel VISIBLE and stop. The safe recovery
            # (redeploy, or a deliberate restart + dependant repair) is
            # disruptive and the operator's call; the netns is intact so the
            # dependant loop below still runs and will correctly report no
            # drift (the fault is the tunnel, not the namespace).
            log "ALERT: $OWNER is running but Docker reports it UNHEALTHY — dead tunnel (egress failing closed, no leak)."
            maybe_alert "OWNER" "unhealthy" "media-vpn is UNHEALTHY: running but the tunnel is dead (egress failing closed — no leak, but no connectivity). Auto-restart is off (RESTART_VPN_ON_UNHEALTHY=0). Redeploy or restart the media-vpn stack to recover — never 'docker restart media-vpn' alone by hand; see README.md." "unhealthy"
        fi
        ;;
    ""|starting)
        # No healthcheck reported (e.g. ACTIVE_HEALTHCHECKS not yet enabled),
        # or still inside the image's start-period grace window after a
        # (re)start — transitional, not a fault. Treat as ok.
        maybe_alert "OWNER" "ok" "" ""
        ;;
    *)
        # healthy
        maybe_alert "OWNER" "ok" "" ""
        ;;
esac

drifted=()
for c in "${DEPENDANTS[@]}"; do
    status="$(container_status "$c")"

    if [ -z "$status" ]; then
        log "$c: no such container (not deployed yet) — nothing to check"
        continue
    fi

    if [ "$status" != "running" ]; then
        # Covers a plain stopped/exited container AND Docker's
        # "restarting" status — a container stuck in a crash-restart loop
        # under its own restart policy is flagged, not silently skipped
        # just because it isn't currently "running" at the instant we look.
        log "$c is not running (docker state: $status)"
        maybe_alert "$c" "stopped" "$c exists but is not running (docker state: $status) — check 'docker logs $c'" "not-running"
        continue
    fi

    pid="$(container_pid "$c")"
    ns="$(netns_id "$pid")"
    if [ -z "$ns" ] || [ "$ns" != "$owner_ns" ]; then
        log "DRIFT: $c's netns ('$ns') does not match $OWNER's ('$owner_ns')"
        drifted+=("$c")
    else
        maybe_alert "$c" "ok" "" ""
    fi
done

if [ "${#drifted[@]}" -eq 0 ]; then
    log "OK: all running dependants share $OWNER's network namespace"
    exit 0
fi

log "Attempting repair for: ${drifted[*]} (docker restart is the only repair this guard performs)"

still_bad=()
for c in "${drifted[@]}"; do
    log "Restarting $c"
    if restart_out="$("$DOCKER_BIN" restart "$c" 2>&1)"; then
        sleep 3
        pid="$(container_pid "$c")"
        ns="$(netns_id "$pid")"
        if [ -n "$ns" ] && [ "$ns" = "$owner_ns" ]; then
            log "RESOLVED: $c restarted and now shares $OWNER's netns"
            maybe_alert "$c" "repaired" "$c: netns drift was detected and repaired via docker restart" "drift"
        else
            log "ALERT: $c restarted but still does NOT share $OWNER's netns ('$ns' vs '$owner_ns') — restart alone was not sufficient repair"
            maybe_alert "$c" "repair-failed" "$c: netns drift detected, docker restart did NOT fix it ('$ns' vs '$owner_ns'). Manual redeploy of the media-vpn stack is required — see README.md, never 'docker restart media-vpn' alone." "repair-failed"
            still_bad+=("$c")
        fi
    else
        log "ALERT: 'docker restart $c' FAILED: $restart_out — likely because $OWNER was recreated with a new container ID (R1: the dependant's stored NetworkMode now points at a dead container). This needs a stack redeploy, not a restart."
        maybe_alert "$c" "repair-failed" "$c: netns drift detected, 'docker restart $c' FAILED ($restart_out). Likely $OWNER was recreated with a new container ID (R1). Manual redeploy of the media-vpn stack is required." "repair-failed"
        still_bad+=("$c")
    fi
done

if [ "${#still_bad[@]}" -gt 0 ]; then
    exit 1
fi
exit 0
