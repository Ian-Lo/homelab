#!/usr/bin/env bash
# drop-clean: remove files from the manual drop folders that are ALREADY in
# the library, identified by hardlink identity, never by name.
#
# WHY THIS EXISTS
# A manual import done through the *arr UI in hardlink/copy mode leaves the
# source file sitting in drop/. It costs ~0 bytes (the library file and the
# drop file are the same inode) but it accumulates, and once drop-import.sh
# is running it makes the journal shout "LEFT IN PLACE: ... already has a
# file" about the same files every 5 minutes forever. This clears them.
#
# THE SAFETY RULE
# A file is removed ONLY if some file under library/ shares its
# (device, inode) pair. That is proof — not inference — that the bytes are
# still reachable from the library after this unlink: removing one of N>=2
# hardlinks cannot destroy data. No name matching, no substring matching,
# no globbing is used to decide what goes.
#
# That rule is not fussiness. A deletion path that matches by SUBSTRING
# rather than by exact identity will eventually match something it was
# never meant to, and the *arrs' delete APIs remove the file from disk, not
# just the database row. Identity, never resemblance. Nothing here matches
# by name.
#
# WHY (DEVICE, INODE) AND NOT INODE ALONE
# Inode numbers are only unique within a single filesystem. Today drop/ and
# library/ are typically on the same filesystem, so a bare inode match
# happens to be sound
# — but the safety argument must not depend on a fact that a future bind
# mount, USB disk or dataset split could silently change. If library/ ever
# spans two filesystems, two different files can share an inode number, and
# an inode-only match would "prove" a twin that does not exist and delete an
# unimported file. So: key on device+inode, -xdev on both walks, and abort
# up front if drop and library are not on the same device (in which case no
# hardlink between them is even possible and every file would be kept).
#
# ARBITRARY FILENAMES
# The library map is keyed on device:inode and built from a NUL-delimited
# walk, so filenames containing tabs, newlines, quotes or brackets are
# handled exactly like any other. Nothing is parsed out of a text table.
#
# HARD EXCLUSION: only $MEDIA_ROOT/downloads/drop/{tv,movies} are ever
# touched. Never widen this to /data/downloads or downloads/ wholesale --
# other things live under downloads/ that must not be walked, and this
# script's whole job is unlinking.
#
# DRY RUN BY DEFAULT. It prints what it would do and changes nothing unless
# given --apply.
#
#   ./drop-clean.sh            # report only
#   ./drop-clean.sh --apply    # actually unlink
#
# Must run as a user that can write to the drop dirs (mode 775, owned by the
# media user). Do NOT run this under sudo: it never needs root, and root
# would let it remove things the owning user could not.
set -uo pipefail

# Configuration comes from /etc/media-stack/env (root:root 600, installed by
# install-on-host.sh). Sourced here rather than declared EnvironmentFile= in
# the unit so that a hand-run and a systemd run resolve identically -- a
# script that only works under systemd is a script nobody can debug.
[ -r /etc/media-stack/env ] && { set -a; . /etc/media-stack/env; set +a; }

# Sourced from /etc/media-stack/env. No default: a wrong root here is a
# wrong tree to unlink from.
: "${MEDIA_ROOT:?set MEDIA_ROOT in /etc/media-stack/env}"
DROP_ROOT="${MEDIA_ROOT}/downloads/drop"
LIBRARY_ROOT="${MEDIA_ROOT}/library"
DROP_DIRS=("$DROP_ROOT/tv" "$DROP_ROOT/movies")

APPLY=0
case "${1:-}" in
    --apply) APPLY=1 ;;
    ""|--dry-run) APPLY=0 ;;
    *) echo "usage: $0 [--apply]" >&2; exit 2 ;;
esac
# The header says this never needs root; enforce that rather than advise it.
# Running as root would let it unlink files the owning user could not, which
# is precisely the reach this script should not have.
if [ "$(id -u)" -eq 0 ]; then
    echo "drop-clean: refusing to run as root -- run as the owner of the drop dirs" >&2
    exit 1
fi

[ "$APPLY" = 1 ] || echo "== DRY RUN == nothing will be removed; re-run with --apply to act"

for d in "${DROP_DIRS[@]}" "$LIBRARY_ROOT"; do
    [ -d "$d" ] || { echo "drop-clean: $d missing -- aborting" >&2; exit 1; }
done

# Same-filesystem precondition (see WHY (DEVICE, INODE) above).
lib_dev=$(stat -c %d -- "$LIBRARY_ROOT") || exit 1
for d in "${DROP_DIRS[@]}"; do
    d_dev=$(stat -c %d -- "$d") || exit 1
    if [ "$d_dev" != "$lib_dev" ]; then
        echo "drop-clean: $d (dev $d_dev) and $LIBRARY_ROOT (dev $lib_dev) are on" >&2
        echo "  different filesystems -- no hardlink between them is possible, so" >&2
        echo "  nothing here could ever be proven safe to remove. Aborting rather" >&2
        echo "  than silently keeping everything." >&2
        exit 1
    fi
done

# --- build the library map: device:inode -> one library path --------------
# Only multi-link files can possibly be a twin, so the map stays small.
declare -A TWIN=()
# Files pass 1 removes (or would remove). Pass 2 treats these as already gone,
# so the DRY RUN's sidecar count is a genuine forecast of --apply rather than a
# measurement of a different set: without this, dry run leaves every X in place,
# so every ._X still has a counterpart and pass 2 reports ~0 orphans, while
# --apply removes X first and orphans them all. Same code path, both modes.
declare -A GONE=()
while IFS= read -r -d '' p; do
    k=$(stat -c '%d:%i' -- "$p" 2>/dev/null) || continue
    [ -n "${TWIN[$k]:-}" ] || TWIN["$k"]="$p"
done < <(find "$LIBRARY_ROOT" -xdev -type f -links +1 -print0 2>/dev/null)
echo "drop-clean: library has ${#TWIN[@]} multi-link inode(s) to match against"

removed=0 kept=0 failed=0

# --- pass 1: real media files, matched to the library by device+inode -----
while IFS= read -r -d '' f; do
    k=$(stat -c '%d:%i' -- "$f" 2>/dev/null) || { echo "  ?? cannot stat: $f" >&2; continue; }
    twin="${TWIN[$k]:-}"

    if [ -z "$twin" ]; then
        echo "  KEEP (not in library, unimported): ${f##*/}"
        kept=$((kept + 1))
        continue
    fi

    echo "  REMOVE: ${f##*/}"
    echo "      twin: $twin"

    if [ "$APPLY" != 1 ]; then
        removed=$((removed + 1)); GONE["$f"]=1; continue
    fi

    # Re-verify immediately before unlinking: the twin must still exist and
    # still be the same (device, inode). Guards against anything having
    # moved between building the map and acting on it.
    tk=$(stat -c '%d:%i' -- "$twin" 2>/dev/null)
    if [ "$tk" != "$k" ]; then
        echo "      ABORT this file: twin no longer shares (device, inode)" >&2
        failed=$((failed + 1))
        continue
    fi
    if rm -- "$f"; then
        removed=$((removed + 1)); GONE["$f"]=1
        # Its sidecar is now an orphan, but pass 2 owns sidecar removal --
        # doing it here too would mean dry run and --apply measure different
        # sets and the forecast would stop matching the outcome.
    else
        echo "      FAILED to remove (permissions?)" >&2
        failed=$((failed + 1))
    fi
done < <(find "${DROP_DIRS[@]}" -xdev -type f ! -name '._*' ! -name '.DS_Store' -print0 2>/dev/null)

# --- pass 2: orphaned macOS sidecars --------------------------------------
# This is the ONE pass that selects on a name rather than on an inode, so it
# is deliberately narrow. An AppleDouble sidecar `._X` carries only resource
# -fork/xattr metadata for a sibling file `X`; with `X` gone it describes
# nothing and cannot be the sole copy of any media. It is removed ONLY when
# its exact counterpart `X` (same directory, name minus the `._` prefix) does
# not exist. `._X` is never consulted to decide anything about `X`, and the
# comparison is an exact string built from the sidecar's own name — no glob,
# no substring. A sidecar whose counterpart still exists is left alone here;
# it is removed in pass 1 only alongside the real file it belongs to.
orphans=0
while IFS= read -r -d '' s; do
    base="${s##*/._}"; dir="${s%/*}"
    # Still belongs to a real file that is staying -- leave it. A counterpart
    # in GONE is treated as absent: under --apply it already is, and under dry
    # run it would be, which is what makes the two counts agree.
    if [ -e "$dir/$base" ] && [ -z "${GONE[$dir/$base]:-}" ]; then
        continue
    fi
    orphans=$((orphans + 1))
    [ "$APPLY" = 1 ] && rm -f -- "$s"
done < <(find "${DROP_DIRS[@]}" -xdev -type f -name '._*' -print0 2>/dev/null)

# --- pass 3: .DS_Store ----------------------------------------------------
# Finder directory metadata. Carries no file payload; regenerated freely.
dsc=0
while IFS= read -r -d '' s; do
    dsc=$((dsc + 1)); [ "$APPLY" = 1 ] && rm -f -- "$s"
done < <(find "${DROP_DIRS[@]}" -xdev -type f \( -name '.DS_Store' -o -name '._.DS_Store' \) -print0 2>/dev/null)

echo
if [ "$APPLY" = 1 ]; then
    echo "drop-clean: removed $removed file(s), $orphans orphaned sidecar(s), $dsc .DS_Store; kept $kept unimported; $failed failure(s)"
else
    echo "drop-clean: WOULD remove $removed file(s), $orphans sidecar(s) left orphaned by those removals, $dsc .DS_Store; would keep $kept unimported"
fi
[ "$failed" -eq 0 ]
