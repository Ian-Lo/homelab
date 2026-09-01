#!/usr/bin/env bash
# qbt-portsync.sh — reconciles qBittorrent's WebUI listen_port with the PIA
# forwarded port. Three load-bearing ideas, in case you are writing your own:
# keep the state in a file rather than a shell variable (the process that
# holds it will be restarted), retry until applied rather than assuming one
# push worked, and make the apply idempotent so retrying is free.
#
# Runs INSIDE the vpn container (thrnz/docker-wireguard-pia's Alpine base
# ships bash, curl, jq), reaching qBittorrent on 127.0.0.1:8080 because they
# share a network namespace (network_mode: service:vpn). QBT_HOST is set
# explicitly on the vpn service in docker-compose.vpn.yml, next to
# qbittorrent's WEBUI_PORT, so the two can't silently drift apart.
#
# Invoked by thrnz's pf_success.sh as:
#     eval "$PORT_SCRIPT $port"
# — as root inside the vpn container, backgrounded with `&`, once per
# successful getSignature (on connect, and roughly every ~2 months). That
# is NOT the 15-minute bindPort refresh, which leaves two gaps this script's
# own reconcile loop exists to close:
#   Gap 1 — qBittorrent restarts, the VPN does not: nothing re-pushes the
#           port, so a crash or image update silently reverts it.
#   Gap 2 — this script can be invoked before qBittorrent is listening on
#           8080 (both start together on a cold boot).
#
# BOOTSTRAP ORDER MATTERS, and it is not obvious: a fresh
# linuxserver/qbittorrent generates a random temporary WebUI password, and
# nothing makes it match QBT_PASSWORD_FILE until the operator logs in once
# and sets it. That first-start step MUST happen before this loop is allowed
# to run unattended. qBittorrent bans the source IP
# after repeated failed WebUI logins, and the source here is 127.0.0.1 —
# shared with prowlarr/sonarr/radarr — so a hot-retrying syncer here can
# lock the ENTIRE namespace out of qBittorrent's API. Two safeguards:
#   - on an auth failure this backs off hard (>= AUTH_BACKOFF seconds)
#     rather than retrying every cycle;
#   - after AUTH_FAIL_LIMIT *consecutive* auth failures it gives up
#     entirely and exits (releasing the flock) rather than grinding forever
#     at a slower rate, which still eventually accumulates to a ban since
#     qBittorrent's failed-login counter only decays on success or ban
#     expiry. Backing off more slowly does not help; only stopping does.
set -u

QBT_HOST="${QBT_HOST:-127.0.0.1:8080}"
QBT_USERNAME="${QBT_USERNAME:-admin}"
QBT_PASSWORD_FILE="${QBT_PASSWORD_FILE:-/qbt-pass}"
STATE_DIR="${STATE_DIR:-/pia-shared}"
DESIRED_PORT_FILE="$STATE_DIR/desired-port"
LOCK_FILE="$STATE_DIR/qbt-portsync.lock"
RECONCILE_INTERVAL="${RECONCILE_INTERVAL:-60}"  # Gap 1: keep re-checking even with no new invocation
AUTH_BACKOFF="${AUTH_BACKOFF:-600}"             # >=10 min -- avoid qBittorrent's failed-auth IP ban of 127.0.0.1
AUTH_FAIL_LIMIT="${AUTH_FAIL_LIMIT:-3}"         # consecutive auth failures before giving up (B3)
CURL_OPTS=(--connect-timeout 5 -m 20)           # S5: never let a hung qBittorrent block forever while holding the flock
COOKIE_JAR=""
auth_fail_count=0

log() {
    # S6: prefixed so these lines are greppable out of `docker logs
    # media-vpn`, which also carries the image's own log lines.
    printf '%s qbt-portsync: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1"
}

# nap SECONDS — like `sleep`, but responsive to INT/TERM (N9). A plain
# foreground `sleep` is a separate process; bash only runs pending traps
# once it returns, so a signal sent during a 10-minute AUTH_BACKOFF sleep
# would sit queued until the sleep finished. Backgrounding it and using the
# interruptible `wait` builtin fixes that.
nap() {
    sleep "$1" &
    wait $!
}

if [ "${1:-}" = "" ]; then
    echo "usage: $0 <port>" >&2
    exit 1
fi
NEW_PORT="$1"
case "$NEW_PORT" in
    ''|*[!0-9]*)
        log "ERROR: '$NEW_PORT' is not a numeric port; ignoring"
        exit 1
        ;;
esac

mkdir -p "$STATE_DIR"

# Write the desired port FIRST and unconditionally — even if this
# invocation doesn't win the lock below, whichever instance already holds
# it will pick this value up on its next loop iteration (within
# RECONCILE_INTERVAL seconds), so the new port is never silently dropped.
printf '%s' "$NEW_PORT" > "$DESIRED_PORT_FILE"
log "Desired port set to $NEW_PORT"

cleanup() {
    [ -n "$COOKIE_JAR" ] && rm -f "$COOKIE_JAR"
}
trap cleanup EXIT
trap 'exit 0' INT TERM

# pf_success.sh backgrounds every invocation with `&`. Without this guard,
# each successful getSignature (or a restart of this container) would spawn
# a second permanent reconcile loop running alongside the first.
exec 200>"$LOCK_FILE"
flock -n 200
flock_rc=$?
if [ "$flock_rc" -ne 0 ]; then
    # N1: rc 1 specifically means "already held" (flock(1)'s documented
    # exit status for -n); anything else is a real error worth surfacing
    # rather than silently treating like a benign lock contention.
    if [ "$flock_rc" -eq 1 ]; then
        log "Another qbt-portsync instance already holds the lock; it will pick up $NEW_PORT on its next cycle. Exiting."
        exit 0
    else
        log "ERROR: flock failed unexpectedly (rc=$flock_rc) on $LOCK_FILE"
        exit 1
    fi
fi

log "Lock acquired; starting reconcile loop (checking every ${RECONCILE_INTERVAL}s)"

COOKIE_JAR="$(mktemp)"

# record_auth_failure — call ONLY from qbt_login's own rejection, never from
# a 401/403 on a preferences (or other) call: pre-login, preferences returns
# 403 unconditionally — see the NOTE in the reconcile loop for why counting
# it reintroduces a fatal cold-start bug. Resets to 0 on any
# successful login. At AUTH_FAIL_LIMIT consecutive failures, gives up for
# good (B3) rather than grinding at a slower rate forever — qBittorrent's
# failed-login counter for a source IP only decays on success or on the ban
# itself expiring, so *any* nonzero retry rate eventually accumulates to a
# ban if the password is simply wrong, not transiently unavailable.
record_auth_failure() {
    auth_fail_count=$((auth_fail_count + 1))
    if [ "$auth_fail_count" -ge "$AUTH_FAIL_LIMIT" ]; then
        log "FATAL: $auth_fail_count consecutive qBittorrent auth failures. Refusing further login attempts to avoid banning 127.0.0.1 for the whole namespace (prowlarr/sonarr/radarr share it). Set the qBittorrent WebUI password to match \$QBT_PASSWORD_FILE for the first-start step, then redeploy or restart this container to try again."
        exit 1
    fi
    log "AUTH BACKOFF: auth failure $auth_fail_count/$AUTH_FAIL_LIMIT — backing off ${AUTH_BACKOFF}s before retrying. Check that the qBittorrent WebUI password matches \$QBT_PASSWORD_FILE (the first-start step) before this recurs."
}

# qbt_login — logs in and refreshes $COOKIE_JAR. Return codes:
#   0  success (resets auth_fail_count)
#   1  auth rejected — caller must call record_auth_failure and back off
#   2  QBT_PASSWORD_FILE unreadable
#   3  qBittorrent unreachable (connection failed) — tolerate, retry later
#   4  unexpected status
#
# qBittorrent's login-failure contract changed in 5.2.0. Checked against
# upstream source release-4.6.7 through 5.1.2: a bad login returns HTTP
# **200** with body "Fails." (success is "Ok.") — the public WebUI API wiki
# still documents this "always 200, read the body" contract as current.
# 5.2.0+ (this stack's pinned digest is 5.2.3) instead returns HTTP 401/403
# on failure. This stack is pinned to 5.2.3 today, so 401/403 is what fires
# right now — but a digest rollback, or trusting the wiki's documented
# contract over the actual pinned version, would silently invert finding
# R4: a "Fails." body would be read as an empty listen_port, which looks
# just like "not logged in yet", triggering ANOTHER login attempt every
# cycle instead of backing off. So: treat BOTH shapes as an auth failure.
qbt_login() {
    if [ ! -r "$QBT_PASSWORD_FILE" ]; then
        log "ERROR: QBT_PASSWORD_FILE ($QBT_PASSWORD_FILE) is not readable"
        return 2
    fi
    local pass status body_file body
    pass="$(cat "$QBT_PASSWORD_FILE")"
    : > "$COOKIE_JAR"
    body_file="$(mktemp)"
    status="$(curl -s "${CURL_OPTS[@]}" -o "$body_file" -w '%{http_code}' -c "$COOKIE_JAR" \
        --data-urlencode "username=$QBT_USERNAME" \
        --data-urlencode "password=$pass" \
        "http://$QBT_HOST/api/v2/auth/login")"
    body="$(cat "$body_file" 2>/dev/null)"
    rm -f "$body_file"

    if [ "$status" = "401" ] || [ "$status" = "403" ]; then
        log "qBittorrent login rejected: HTTP $status"
        return 1
    fi
    if [ "$status" = "200" ] || [ "$status" = "204" ]; then
        # 5.2.0+ returns 204 No Content (+ the QBT_SID cookie) on success;
        # pre-5.2.0 returned 200 with body "Ok."/"Fails.". Before 204 was
        # listed here, a successful login fell through to the "unexpected
        # status" branch: the cookie still worked next cycle (curl -c had
        # already saved it), but each login cost an extra reconcile cycle
        # and — the real bug — auth_fail_count was never reset on success,
        # so the "3 CONSECUTIVE failures → FATAL" counter could accumulate
        # across genuinely successful logins.
        if printf '%s' "$body" | grep -q '^Fails\.'; then
            log "qBittorrent login rejected: HTTP $status body 'Fails.' (pre-5.2.0 API contract — see qbt_login comment)"
            return 1
        fi
        auth_fail_count=0
        return 0
    fi
    if [ "$status" = "000" ]; then
        log "qBittorrent unreachable at $QBT_HOST (connection failed) — tolerating, will retry"
        return 3
    fi
    log "qBittorrent login returned unexpected HTTP status $status"
    return 4
}

# qbt_get_preferences — fetches app/preferences. Sets globals PREF_STATUS
# (HTTP code) and PREF_LISTEN_PORT (empty if absent/unparseable). Never
# itself decides what an auth failure means — callers do, since this is
# used both for "am I logged in" and "did the write take" checks.
qbt_get_preferences() {
    local body_file
    body_file="$(mktemp)"
    PREF_STATUS="$(curl -s "${CURL_OPTS[@]}" -o "$body_file" -w '%{http_code}' -b "$COOKIE_JAR" \
        "http://$QBT_HOST/api/v2/app/preferences")"
    PREF_LISTEN_PORT="$(jq -r '.listen_port // empty' < "$body_file" 2>/dev/null)"
    rm -f "$body_file"
}

last_valid_desired="$NEW_PORT"

while true; do
    # N2: re-validate the desired-port file's content as numeric every
    # cycle before it's ever interpolated into a JSON body — it's written
    # by a *different* process invocation and could in principle be
    # empty/partial if read mid-write, or corrupted.
    desired="$(cat "$DESIRED_PORT_FILE" 2>/dev/null || true)"
    case "$desired" in
        ''|*[!0-9]*)
            log "WARNING: desired-port file has invalid content ('$desired'); using last known-good $last_valid_desired"
            desired="$last_valid_desired"
            ;;
        *)
            last_valid_desired="$desired"
            ;;
    esac

    qbt_get_preferences
    current_port="$PREF_LISTEN_PORT"

    # NOTE, deliberately NOT branching on PREF_STATUS here: qBittorrent's
    # /api/v2/app/preferences requires an active session and returns
    # 401/403 for ANY unauthenticated request -- including a cold start
    # with a perfectly correct password that just hasn't logged in on this
    # process yet, or a session that expired since the last cycle. That
    # status is therefore NOT itself evidence of a wrong password, and
    # cannot be told apart from a real auth failure without first
    # attempting a login. An earlier version of this script treated a
    # direct 401/403 here as an auth failure and called record_auth_failure
    # -- which on every cold start incremented the counter three times
    # (once per reconcile cycle) and hit AUTH_FAIL_LIMIT's FATAL exit
    # WITHOUT EVER ATTEMPTING A LOGIN, even with the correct password. Only
    # qbt_login()'s own check (which actually presents credentials) may
    # treat a rejection as an auth failure. An empty current_port --
    # produced by a 401/403 here among other causes -- simply falls through
    # to the login attempt below, which is the only place that can tell a
    # bad password apart from "not logged in yet."
    if [ -z "$current_port" ]; then
        # Not logged in yet (fresh cookie jar), qBittorrent isn't up yet
        # (Gap 2), or the session expired -- logged for diagnostics only,
        # this HTTP status is never itself a reason to skip the login
        # attempt (see the NOTE above). Try a fresh login before giving up
        # on this cycle.
        log "listen_port unavailable (preferences read: HTTP $PREF_STATUS) — attempting login"
        qbt_login
        rc=$?
        case "$rc" in
            1)
                record_auth_failure
                nap "$AUTH_BACKOFF"
                continue
                ;;
            0)
                qbt_get_preferences
                current_port="$PREF_LISTEN_PORT"
                ;;
            *)
                nap "$RECONCILE_INTERVAL"
                continue
                ;;
        esac
    fi

    if [ -z "$current_port" ]; then
        log "Could not read listen_port from qBittorrent preferences; retrying in ${RECONCILE_INTERVAL}s"
        nap "$RECONCILE_INTERVAL"
        continue
    fi

    if [ "$current_port" != "$desired" ]; then
        log "listen_port drift: qBittorrent has $current_port, desired is $desired — applying"
        set_status="$(curl -s "${CURL_OPTS[@]}" -o /dev/null -w '%{http_code}' -b "$COOKIE_JAR" \
            --data-urlencode "json={\"listen_port\":${desired},\"random_port\":false,\"upnp\":false}" \
            "http://$QBT_HOST/api/v2/app/setPreferences")"
        case "$set_status" in
            401|403)
                # Deliberately NOT record_auth_failure here: a 401/403 on
                # the WRITE can just as easily mean the session expired in
                # the gap between the preceding read and this write as it
                # can mean bad credentials -- and unlike qbt_login, no
                # credentials were even presented on this call, so there is
                # nothing here to actually validate. Clear the stale
                # session and let the next cycle's qbt_login (the only
                # place that counts toward AUTH_FAIL_LIMIT) sort out which
                # one it was.
                log "setPreferences returned HTTP $set_status -- likely a session expired between the read and this write, not necessarily bad credentials. Clearing the session and retrying next cycle (not counted as an auth failure)."
                : > "$COOKIE_JAR"
                nap "$RECONCILE_INTERVAL"
                continue
                ;;
            200)
                qbt_get_preferences
                confirm_port="$PREF_LISTEN_PORT"
                if [ "$confirm_port" = "$desired" ]; then
                    log "Confirmed listen_port is now $desired"
                else
                    log "WARNING: set listen_port to $desired but readback shows '$confirm_port'"
                fi
                ;;
            *)
                log "setPreferences returned unexpected HTTP status $set_status; will retry next cycle"
                ;;
        esac
    fi

    nap "$RECONCILE_INTERVAL"
done
