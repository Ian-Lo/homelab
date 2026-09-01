#!/usr/bin/env bash
# drop-import: import whatever has been dropped into the manual drop folders
# by driving each *arr's ManualImport API — the same call its own UI makes.
# Runs from media-drop-import.timer every 5 min.
#
#   $MEDIA_ROOT/downloads/drop/tv      -> Sonarr ManualImport
#   $MEDIA_ROOT/downloads/drop/movies  -> Radarr ManualImport
#
# WHY THIS IS NOT DownloadedEpisodesScan:
# The original version POSTed DownloadedEpisodesScan / DownloadedMoviesScan
# with path=<the drop folder>. That can never work, and never did. Those
# commands treat `path` as ONE completed download and parse the FOLDER NAME
# as the release name — so Sonarr parsed the literal string "tv", failed to
# match a series, and gave up WITHOUT EVER OPENING THE FOLDER:
#
#   DownloadedEpisodesImportService | Processing path: /data/downloads/drop/tv
#   Parser                          | Unable to parse tv
#   DownloadedEpisodesImportService | Unknown Series tv
#   DownloadedEpisodesCommandService| Failed to import
#
# Those commands want a single file, or a folder NAMED AFTER THE RELEASE
# (`Silo.S03E01.1080p.WEB.h264-GROUP/`) — they are not inbox scanners. A fixed generic
# inbox like drop/tv is structurally incompatible with them. This is the
# single most useful thing in this file: the API you want is manualimport,
# not the scan commands that look like they should work.
#
# WHAT IT DOES INSTEAD, per drop folder:
#   1. Skip silently if the folder holds no real files (macOS ._* / .DS_Store
#      droppings don't count) — no API call, no log noise.
#   2. GET /api/v3/manualimport?folder=<drop folder> — the *arr walks the
#      folder itself and returns, per file, its series/movie match, episode
#      match, parsed quality, languages, release group, and any rejections.
#   3. Forward ONLY the entries the *arr itself judged clean, as
#      POST /api/v3/command {"name":"ManualImport", ..., "importMode":"move"}.
#      We never re-guess: every field posted came out of step 2's response.
#   4. Anything not forwarded is logged by name with the reason and LEFT
#      WHERE IT IS, to be resolved by hand in the Manual Import UI.
#
# TWO HARD SAFETY RULES, both enforced in the filter below:
#   * NEVER REPLACE AN EXISTING FILE. A dropped file whose matched episode
#     already hasFile is skipped, not imported. Import-over-existing makes
#     the *arr delete/recycle the old file, and this pipeline is not allowed
#     to cause a deletion. Genuine upgrades are a deliberate manual act in
#     the UI, never automatic here.
#   * NEVER GUESS. Any rejection at all, or a missing series/movie/episode
#     match, means the file stays put. There is no "close enough" path.
#
# HARD EXCLUSION: only these two exact paths are ever scanned. Never widen
# to /data/downloads wholesale -- sibling directories under downloads/ may be
# backup trees or anything else that must not be imported from, and the *arr
# will happily MOVE files out of whatever you point it at.
#
# SECURITY SHAPE: runs as root via systemd, only to read the API keys in
# /etc/media-stack/{sonarr,radarr}-api-key (root:root 400, installed by
# install-on-host.sh). Dropped filenames NEVER enter a shell word:
# they travel API -> python -> API and are serialised by json.dumps, so
# quoting/escaping is the JSON encoder's job, not the shell's (these very
# filenames contain [ and ]). The API key is passed to python through the
# ENVIRONMENT, never argv — argv is world-readable via ps, and the old
# curl -H "X-Api-Key: $(cat ...)" form leaked the key to any local user.
#
# TOLERANT BY DESIGN (same philosophy as netns-guard.sh): a missing key
# file, an unreachable *arr, or a malformed response logs a warning to the
# journal and exits 0 — the timer just tries again in 5 minutes.
#
# DRY RUN: `DROP_IMPORT_DRY_RUN=1 /opt/media-stack/drop-import.sh` does
# everything except the final POST, and prints what it would have imported.
set -u

# Configuration comes from /etc/media-stack/env (root:root 600, installed by
# install-on-host.sh). Sourced here rather than declared EnvironmentFile= in
# the unit so that a hand-run and a systemd run resolve identically -- a
# script that only works under systemd is a script nobody can debug.
[ -r /etc/media-stack/env ] && { set -a; . /etc/media-stack/env; set +a; }

# Sourced from /etc/media-stack/env, no defaults -- see .env.example.
: "${MEDIA_ROOT:?set MEDIA_ROOT in /etc/media-stack/env}"
: "${LAN_IP:?set LAN_IP in /etc/media-stack/env}"
DROP_HOST_ROOT="${MEDIA_ROOT}/downloads/drop"
KEY_DIR="/etc/media-stack"
# D2: a dropped file must be untouched for this many minutes before we hand
# it to an *arr. Files arrive over the network from macOS; ManualImport has
# no "still being written" check of its own (the *arrs' unpacking/age logic
# only covers download-client working folders), so without this a 5-minute
# timer can import a half-copied file and record its size/mediainfo.
SETTLE_MIN=5
# D1: where the "already reported as skipped" sets live, so unresolved files
# are not re-listed every tick forever. RuntimeDirectory=media-stack in the
# unit creates and cleans this; the fallback keeps a hand-run working.
STATE_DIR="${RUNTIME_DIRECTORY:-/run/media-stack}"
mkdir -p "$STATE_DIR" 2>/dev/null || STATE_DIR=""

run_app() { # run_app <app> <base-url> <keyfile> <host-dir> <container-dir>
    local app="$1" base="$2" keyfile="$3" hpath="$4" cpath="$5"

    # Nothing dropped, or nothing that has finished landing yet -> stay
    # silent. -mmin +$SETTLE_MIN is the cheap half of the D2 settle guard
    # (the authoritative per-file check is in the python filter): a file
    # still being copied in from macOS keeps getting its mtime bumped, so
    # this also stops us waking Sonarr mid-copy just to be told no.
    if ! find "$hpath" -type f ! -name '._*' ! -name '.DS_Store' -mmin +"$SETTLE_MIN" -print -quit 2>/dev/null | grep -q .; then
        return 0
    fi
    if [ ! -s "$keyfile" ]; then
        echo "drop-import: $app: files waiting in $hpath but $keyfile is missing/empty -- run install-on-host.sh Step 4d" >&2
        return 0
    fi

    # Key via env, not argv (see SECURITY SHAPE above). The python block is
    # embedded rather than a sibling .py so there is exactly one file to
    # install and no chance of a half-updated deployment.
    APP="$app" BASE="$base" FOLDER="$cpath" HOST_FOLDER="$hpath" \
    SETTLE_MIN="$SETTLE_MIN" STATE_DIR="$STATE_DIR" \
    MEDIA_API_KEY="$(cat "$keyfile")" \
    python3 - <<'PY'
import hashlib, json, os, sys, time, urllib.error, urllib.parse, urllib.request

app     = os.environ["APP"]
base    = os.environ["BASE"]
folder  = os.environ["FOLDER"]
hfolder = os.environ.get("HOST_FOLDER", "")
key     = os.environ["MEDIA_API_KEY"]
settle  = int(os.environ.get("SETTLE_MIN", "5")) * 60
state   = os.environ.get("STATE_DIR", "")
dry     = os.environ.get("DROP_IMPORT_DRY_RUN", "") not in ("", "0")

def warn(msg):
    print("drop-import: %s: %s" % (app, msg), file=sys.stderr)

def api(method, path, body=None):
    req = urllib.request.Request(base + path, method=method)
    req.add_header("X-Api-Key", key)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, data, timeout=60) as r:
        raw = r.read()
    return json.loads(raw) if raw else None

# --- 1. ask the *arr what it makes of the folder -------------------------
# HTTPError is a subclass of URLError, so it must be caught FIRST or a 401
# gets reported as "is sonarr up?", which sends you looking at the wrong
# thing entirely (D3).
try:
    q = urllib.parse.urlencode({"folder": folder, "filterExistingFiles": "false"})
    entries = api("GET", "/api/v3/manualimport?" + q) or []
except urllib.error.HTTPError as e:
    if e.code in (401, 403):
        warn("manualimport query rejected (HTTP %d) -- the API key in "
             "/etc/media-stack is wrong or has been regenerated; re-run "
             "install-on-host.sh Step 4d" % e.code)
    else:
        warn("manualimport query failed (HTTP %d) -- retrying next tick" % e.code)
    sys.exit(0)
except urllib.error.URLError as e:
    warn("manualimport query failed (%s) -- is %s up? retrying next tick" % (e, app))
    sys.exit(0)
except (ValueError, OSError) as e:
    warn("manualimport query returned something unusable (%s) -- retrying next tick" % e)
    sys.exit(0)

# An error body deserialises to a dict, not a list; without this the first
# e.get() below is an AttributeError and the unit exits 1 (D3).
if not isinstance(entries, list):
    warn("manualimport returned %s, expected a list -- retrying next tick"
         % type(entries).__name__)
    sys.exit(0)

def host_path(cpath):
    """Container path -> host path, or None if it is not under our folder."""
    if not (cpath and hfolder and cpath.startswith(folder)):
        return None
    return hfolder + cpath[len(folder):]

# --- 2. keep only what the *arr itself judged clean -----------------------
ready, skipped, settling = [], [], 0
now = time.time()
for e in entries:
    name = e.get("relativePath") or e.get("path") or "<unnamed>"
    why  = [r.get("reason", "unspecified rejection") for r in (e.get("rejections") or [])]

    # D2: never hand over a file that is still being written. The *arrs'
    # own age/unpacking checks apply to download-client working folders,
    # NOT to ManualImport, and drop/ is filled over the network from macOS.
    # Same-filesystem rename means the bytes would end up complete, but the
    # *arr records the size and mediainfo of whatever it saw at import time,
    # and Jellyfin then scans a truncated file.
    hp = host_path(e.get("path"))
    if hp is None:
        why.append("cannot map %r to a host path -- refusing to import blind" % e.get("path"))
    else:
        try:
            if now - os.stat(hp).st_mtime < settle:
                settling += 1
                continue          # transient: not an error, just not yet
        except OSError as err:
            why.append("cannot stat on the host (%s)" % err)

    f = {
        "path":         e.get("path"),
        "quality":      e.get("quality"),
        "languages":    e.get("languages"),
        "releaseGroup": e.get("releaseGroup") or "",
        "indexerFlags": e.get("indexerFlags", 0),
    }

    if app == "sonarr":
        series_id = (e.get("series") or {}).get("id")
        episodes  = e.get("episodes") or []
        if not series_id:
            why.append("no series match")
        if not episodes:
            why.append("no episode match")
        # additive-only: refuse to import over an episode that already has a file
        have = [ep for ep in episodes if ep.get("hasFile")]
        if have:
            why.append("episode already has a file (S%02dE%02d) -- upgrade by hand if you meant to"
                       % (have[0].get("seasonNumber", 0), have[0].get("episodeNumber", 0)))
        f["seriesId"] = series_id
        # .get, not ep["id"]: this was the only direct index into an API
        # response in the whole script, and the try/except blocks wrap only
        # the HTTP calls -- so one malformed episode raised KeyError and took
        # the oneshot unit to `failed`, in a file that exits 0 on every other
        # bad-input path. Losing an episode silently would be worse than
        # noisy, so a shrunk list is a rejection.
        ids = [ep["id"] for ep in episodes if ep.get("id")]
        if len(ids) != len(episodes):
            why.append("%d of %d matched episodes had no id in the API response"
                       % (len(episodes) - len(ids), len(episodes)))
        f["episodeIds"] = ids
        if e.get("releaseType"):
            f["releaseType"] = e["releaseType"]
    else:
        movie = e.get("movie") or {}
        if not movie.get("id"):
            why.append("no movie match")
        # additive-only, same rule as above
        if movie.get("hasFile"):
            why.append("movie already has a file -- upgrade by hand if you meant to")
        f["movieId"] = movie.get("id")

    if why:
        skipped.append((name, why))
    else:
        ready.append(f)

# --- 3. report what stays put, then import the rest -----------------------
# D1: an unresolved file sits in drop/ indefinitely BY DESIGN (never-guess),
# so listing every reason every 5 minutes is permanent journal spam, not a
# transient. Emit the full list only when the set of skipped files actually
# changes; otherwise one line. State lives in a tmpfs runtime dir, so a
# reboot re-states the list once, which is what you want anyway.
digest = hashlib.sha256(
    "\0".join(sorted("%s\0%s" % (n, "; ".join(sorted(w)))
                     for n, w in skipped)).encode()
).hexdigest()
statefile = os.path.join(state, "drop-import.%s.skipped" % app) if state else ""

previous = ""
if statefile:
    try:
        with open(statefile) as fh:
            previous = fh.read().strip()
    except OSError:
        previous = ""

if skipped and digest != previous:
    for name, why in skipped:
        warn("LEFT IN PLACE: %s -- %s" % (name, "; ".join(why)))
elif skipped:
    warn("%d file(s) still awaiting manual resolution (unchanged since last "
         "report; see the Manual Import UI)" % len(skipped))

if statefile:
    try:
        with open(statefile, "w") as fh:
            fh.write(digest if skipped else "")
    except OSError as err:
        warn("could not record skipped-set state in %s (%s) -- will re-report next tick"
             % (statefile, err))

if settling:
    print("drop-import: %s: %d file(s) still being written, will retry" % (app, settling))

if not ready:
    sys.exit(0)

if dry:
    print("drop-import: %s: DRY RUN, would import %d file(s):" % (app, len(ready)))
    for f in ready:
        print("    %s" % f["path"])
    sys.exit(0)

try:
    resp = api("POST", "/api/v3/command",
               {"name": "ManualImport", "files": ready, "importMode": "move"}) or {}
except urllib.error.HTTPError as e:
    warn("ManualImport POST rejected (HTTP %d) -- retrying next tick" % e.code)
    sys.exit(0)
except urllib.error.URLError as e:
    warn("ManualImport POST failed (%s) -- retrying next tick" % e)
    sys.exit(0)

print("drop-import: %s: ManualImport queued for %d file(s) (command id %s)"
      % (app, len(ready), resp.get("id", "?")))
PY
}

run_app sonarr "http://${LAN_IP}:8989" "$KEY_DIR/sonarr-api-key" \
        "$DROP_HOST_ROOT/tv" /data/downloads/drop/tv
run_app radarr "http://${LAN_IP}:7878" "$KEY_DIR/radarr-api-key" \
        "$DROP_HOST_ROOT/movies" /data/downloads/drop/movies
exit 0
