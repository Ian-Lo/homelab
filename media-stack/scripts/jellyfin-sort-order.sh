#!/usr/bin/env bash
# jellyfin-sort-order: make the "Shows" library sort newest-added-first for
# every existing Jellyfin user, by driving the same DisplayPreferences API
# the web UI's sort dropdown calls.
#
# WHY THIS EXISTS: Jellyfin has no server-wide "default sort" setting -- sort
# field/direction for a library is stored per-user in DisplayPreferences.
# Without this, each household member has to open Shows and change the sort
# dropdown themselves. This is a one-off script, run by hand, not a timer.
#
# SECURITY SHAPE (same rule as drop-import.sh): the API key is read from
# /etc/media-stack/jellyfin-api-key (root:root, mode 400) into the ENVIRONMENT
# and passed to python that way -- never via curl -H on argv, which is
# world-readable through ps.
#
# PRIVILEGE NOTE: /etc/media-stack is root:root and its key files are mode
# 400, deliberately. An unprivileged automation account can therefore neither
# install the key nor read it, which means both the one-time key install and
# every run of this script are the operator's to do, e.g.:
#   sudo install -o root -g root -m 400 jellyfin-api-key.txt \
#       /etc/media-stack/jellyfin-api-key
#   sudo ./jellyfin-sort-order.sh
#
# KNOWN LIMITATION: this only fixes users that exist at run time. A user
# created afterward starts back at Jellyfin's factory sort and needs this
# re-run -- there is no per-server default to set instead, so that's an
# accepted manual step, not a bug.
#
# DRY RUN: `DRY_RUN=1 ./jellyfin-sort-order.sh` prints what would change,
# without POSTing anything.
set -u

# Configuration comes from /etc/media-stack/env (root:root 600, installed by
# install-on-host.sh). Sourced here rather than declared EnvironmentFile= in
# the unit so that a hand-run and a systemd run resolve identically -- a
# script that only works under systemd is a script nobody can debug.
[ -r /etc/media-stack/env ] && { set -a; . /etc/media-stack/env; set +a; }

# Host address is configuration, not a constant -- sourced from
# /etc/media-stack/env. No default: a wrong address here silently rewrites
# display preferences on somebody else's server.
: "${LAN_IP:?set LAN_IP in /etc/media-stack/env}"
BASE="http://${LAN_IP}:8096"
KEY_DIR="/etc/media-stack"
KEYFILE="$KEY_DIR/jellyfin-api-key"

if [ ! -s "$KEYFILE" ]; then
    echo "jellyfin-sort-order: $KEYFILE is missing/empty -- install the API key first (see header comment)" >&2
    exit 0
fi

# Key via env, not argv -- see SECURITY SHAPE above.
BASE="$BASE" JELLYFIN_API_KEY="$(cat "$KEYFILE")" DRY_RUN="${DRY_RUN:-}" \
python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

base = os.environ["BASE"]
key  = os.environ["JELLYFIN_API_KEY"]
dry  = os.environ.get("DRY_RUN", "") not in ("", "0")

def warn(msg):
    print("jellyfin-sort-order: %s" % msg, file=sys.stderr)

def api(method, path, body=None):
    req = urllib.request.Request(base + path, method=method)
    req.add_header("X-Emby-Token", key)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None

# --- 1. find the Shows library's ItemId -----------------------------------
try:
    folders = api("GET", "/Library/VirtualFolders") or []
except urllib.error.HTTPError as e:
    if e.code in (401, 403):
        warn("VirtualFolders query rejected (HTTP %d) -- the API key is wrong or was regenerated" % e.code)
    else:
        warn("VirtualFolders query failed (HTTP %d)" % e.code)
    sys.exit(0)
except urllib.error.URLError as e:
    warn("VirtualFolders query failed (%s) -- is Jellyfin up?" % e)
    sys.exit(0)

shows = [f for f in folders if f.get("CollectionType") == "tvshows"]
if not shows:
    warn("no library with CollectionType=tvshows found -- nothing to do")
    sys.exit(0)
if len(shows) > 1:
    warn("multiple tvshows libraries found (%s) -- using the first; re-run manually for the rest"
         % ", ".join(s.get("Name", "?") for s in shows))

library_item_id = (shows[0].get("ItemId") or shows[0].get("ItemIds", [None])[0])
if not library_item_id:
    warn("Shows library %r has no ItemId -- cannot address its DisplayPreferences" % shows[0].get("Name"))
    sys.exit(0)

# --- 2. list every existing user -------------------------------------------
try:
    users = api("GET", "/Users") or []
except (urllib.error.HTTPError, urllib.error.URLError) as e:
    warn("Users query failed (%s)" % e)
    sys.exit(0)

changed = already = failed = 0
for u in users:
    uid, name = u.get("Id"), u.get("Name", "?")
    if not uid:
        continue
    dp_path = "/DisplayPreferences/%s?userId=%s&client=emby" % (library_item_id, uid)
    try:
        prefs = api("GET", dp_path)
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        warn("%s: could not fetch DisplayPreferences (%s)" % (name, e))
        failed += 1
        continue

    if prefs.get("SortBy") == "DateCreated" and prefs.get("SortOrder") == "Descending":
        already += 1
        continue

    if dry:
        print("jellyfin-sort-order: %s: would set SortBy=DateCreated, SortOrder=Descending "
              "(currently %s/%s)" % (name, prefs.get("SortBy"), prefs.get("SortOrder")))
        changed += 1
        continue

    prefs["SortBy"] = "DateCreated"
    prefs["SortOrder"] = "Descending"
    try:
        api("POST", dp_path, prefs)
    except (urllib.error.HTTPError, urllib.error.URLError) as e:
        warn("%s: could not update DisplayPreferences (%s)" % (name, e))
        failed += 1
        continue

    print("jellyfin-sort-order: %s: sort order updated" % name)
    changed += 1

print("jellyfin-sort-order: done -- %d changed, %d already set, %d failed%s"
      % (changed, already, failed, " (dry run, nothing POSTed)" if dry else ""))
PY
