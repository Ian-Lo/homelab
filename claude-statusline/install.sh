#!/bin/bash
# Installs this checkout's Claude Code statusline into one or more local
# config profiles, or verifies (--check) that what is installed still matches
# the checkout.
#
# This directory is the source of truth. `~/.claude/statusline.sh` is a
# deployed artefact, not the master — edit the file here, commit, then re-run
# this script on each host. Same pattern as media-stack's install-on-host.sh.
#
# Usage:
#   ./install.sh [--check] [--all-profiles] [config-dir ...]
#
#   (no args)        install into ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
#   --all-profiles   install into every $HOME/.claude* directory that holds a
#                    settings.json (commonly two: .claude and .claude-jp)
#   config-dir ...   install into exactly these directories
#   --check          verify instead of installing; exits non-zero on drift
#
# Examples:
#   ./install.sh --all-profiles          # every profile on this machine
#   ./install.sh                         # just the default profile
#   ./install.sh --check --all-profiles  # did anything drift?
#
# Installs for the invoking user only. If Claude Code runs there as another
# user, run it again as that user — ~/.claude resolves per-account.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES=(statusline.sh hooks/caveman-statusline.sh)

# The install stages each file as "<dest>.tmp.$$" before renaming it into
# place. `set -e` can abort between the two, so clear the stray on any exit —
# a leftover executable in a config profile is exactly the sort of clutter
# that later reads as something still in use.
STAGED=""
cleanup_staged() { [ -n "$STAGED" ] && rm -f "$STAGED"; return 0; }
trap cleanup_staged EXIT

CHECK=0
ALL_PROFILES=0
TARGETS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --check)         CHECK=1 ;;
        --all-profiles)  ALL_PROFILES=1 ;;
        -h|--help)       sed -n '2,28p' "$0"; exit 0 ;;
        -*)              echo "ERROR: unknown option $1" >&2; exit 2 ;;
        *)               TARGETS+=("$1") ;;
    esac
    shift
done

# jq is a hard requirement, not a nicety: every field of the statusLine payload
# is parsed with it, and the merge below rewrites settings.json. Without it the
# statusline still exits 0 but prints an empty line — a silent failure that
# reads as "the install didn't work". awk does the arithmetic for both usage
# bars. git supplies hash-object for --check and the branch segment at runtime.
missing=""
for c in jq awk git; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
    echo "ERROR: missing required commands:$missing" >&2
    exit 1
fi

if [ ${#TARGETS[@]} -eq 0 ]; then
    if [ "$ALL_PROFILES" -eq 1 ]; then
        for d in "$HOME"/.claude*; do
            [ -d "$d" ] && [ -f "$d/settings.json" ] && TARGETS+=("$d")
        done
        [ ${#TARGETS[@]} -eq 0 ] && {
            echo "ERROR: --all-profiles found no \$HOME/.claude* directory with a settings.json" >&2
            exit 1
        }
    else
        TARGETS+=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
    fi
fi

for f in "${FILES[@]}"; do
    [ -f "$SRC_DIR/$f" ] || { echo "ERROR: $SRC_DIR/$f missing from the checkout" >&2; exit 1; }
done

# The statusLine command a given profile should carry. $HOME is left
# unexpanded inside the JSON string on purpose — the shell that runs the
# command expands it, so one entry works whatever the account's username is.
expected_command() {
    local dir="$1" rel
    case "$dir" in
        "$HOME"/*) rel="\$HOME/${dir#"$HOME"/}" ;;
        *)         rel="$dir" ;;
    esac
    printf 'bash "%s/statusline.sh"' "$rel"
}

# True when settings.json already invokes THIS profile's statusline.
#
# Compares the file the command resolves to, not the literal string. macOS is
# case-insensitive, so a hand-written "$HOME/.claude-jp/statusline.sh" already
# addresses the real ".claude-JP" directory — rewriting settings.json to
# change only the case would be churn, and on a case-sensitive filesystem
# (ext4, say) the two forms genuinely differ and `-ef` reports it. `-ef`
# also collapses any symlink or ".." in either path to one device+inode test.
statusline_command_ok() {
    local dir="$1" got path
    [ -f "$dir/settings.json" ] || return 1
    got=$(jq -r '.statusLine.command // ""' "$dir/settings.json" 2>/dev/null || echo "")
    [ -n "$got" ] || return 1

    # Expected form: bash "<some-dir>/statusline.sh" — pull out the quoted path.
    case "$got" in
        *'"'*'"'*) path=${got#*\"}; path=${path%\"*} ;;
        *)         return 1 ;;
    esac
    path=${path/#\$HOME/$HOME}

    [ -e "$path" ] || return 1
    [ "$path" -ef "$dir/statusline.sh" ]
}

# The badge script used to be installed at the profile root rather than under
# hooks/. The current resolver never looks there, so a leftover is inert — but
# an executable sitting in ~/.claude reads as "still in use" to the next person
# who finds it. Warn; do not delete. Removing a file the operator placed is
# their call, and a warning that survives every --check is enough pressure.
warn_stale_badge() {
    local dir="$1" stale="$1/caveman-statusline.sh"
    [ -e "$stale" ] || return 0
    echo "  NOTE: stale $stale (pre-hooks/ location, no longer read)"
    echo "        remove it by hand: rm $stale"
}

# --------------------------------------------------------------------------
# check
# --------------------------------------------------------------------------
# Compare against the checkout's blob hash rather than against the other
# host's live file: both hosts then measure the same identity, and neither
# host's mutable copy becomes an accidental master.
check_one() {
    local dir="$1" rc=0 f dest want got

    [ -d "$dir" ] || { echo "  DRIFT: $dir does not exist"; return 1; }

    for f in "${FILES[@]}"; do
        dest="$dir/$f"
        want=$(git hash-object "$SRC_DIR/$f")

        if [ ! -e "$dest" ]; then
            echo "  DRIFT: $f not installed"
            rc=1
            continue
        fi
        # A symlink is drift, not sharing. statusline.sh is what settings.json
        # execs and hooks/caveman-statusline.sh is what statusline.sh execs, so
        # both sit on an exec path — a link there is a redirection point, and
        # the whole reason the badge resolver was hardened. Report the target
        # so an intentional legacy symlink is obvious rather than cryptic.
        if [ -L "$dest" ]; then
            echo "  DRIFT: $f is a symlink to $(readlink -f "$dest" 2>/dev/null || readlink "$dest")"
            echo "         (re-run without --check to replace it with a real file)"
            rc=1
            continue
        fi
        [ -O "$dest" ] || { echo "  DRIFT: $f is not owned by $(id -un)"; rc=1; }
        [ -x "$dest" ] || { echo "  DRIFT: $f is not executable"; rc=1; }

        got=$(git hash-object "$dest")
        if [ "$got" != "$want" ]; then
            echo "  DRIFT: $f content differs from the checkout"
            echo "         installed $got"
            echo "         checkout  $want"
            rc=1
        fi
    done

    if [ ! -f "$dir/settings.json" ]; then
        echo "  DRIFT: settings.json missing"
        rc=1
    elif ! statusline_command_ok "$dir"; then
        got=$(jq -r '.statusLine.command // ""' "$dir/settings.json" 2>/dev/null || echo "")
        echo "  DRIFT: settings.json statusLine.command does not invoke this profile"
        echo "         is   ${got:-<unset>}"
        echo "         want $(expected_command "$dir")"
        rc=1
    fi

    [ "$rc" -eq 0 ] && echo "  ok"
    warn_stale_badge "$dir"
    return "$rc"
}

# --------------------------------------------------------------------------
# install
# --------------------------------------------------------------------------
install_one() {
    local dir="$1" f dest backup want

    mkdir -p "$dir/hooks"

    for f in "${FILES[@]}"; do
        dest="$dir/$f"

        # Keep one timestamped copy whenever we are about to overwrite content
        # that differs from the checkout — a host may carry a local edit, and
        # without this the first run of the wrapper destroys it silently.
        # Identical content is not backed up: re-running the install would
        # otherwise litter the profile with copies of the same bytes.
        if [ -f "$dest" ] && [ ! -L "$dest" ] \
           && [ "$(git hash-object "$dest")" != "$(git hash-object "$SRC_DIR/$f")" ]; then
            backup="$dest.bak-$(date +%Y%m%d%H%M%S)"
            cp "$dest" "$backup"
            echo "    backed up the previous $f as $(basename "$backup")"
        fi

        # Replace a symlink with a real file rather than writing through it:
        # `cp` onto a symlink follows it and silently updates whatever it
        # points at. ~/.claude-JP/statusline.sh was such a link to
        # ~/.claude/statusline.sh; per-profile real files also let --check
        # compare every profile against the checkout with no readlink special
        # case.
        if [ -L "$dest" ]; then
            echo "    replacing symlink $f -> $(readlink "$dest")"
            rm -f "$dest"
        fi

        # Stage then rename, rather than cp'ing onto the live file. Both of
        # these sit on an exec path that fires on every statusline render —
        # roughly every keystroke — so a plain `cp` has a window in which the
        # file on disk is truncated or half-written, and a render landing in
        # that window execs a partial script. `mv` within one directory is an
        # atomic rename, so a render sees either the old file or the new one.
        # chmod the staged copy before the rename so the file is never briefly
        # live without its mode.
        STAGED="$dest.tmp.$$"
        cp "$SRC_DIR/$f" "$STAGED"
        chmod 755 "$STAGED"
        mv -f "$STAGED" "$dest"
        STAGED=""
        echo "    installed $f"
    done

    [ -f "$dir/settings.json" ] || echo '{}' > "$dir/settings.json"

    want=$(expected_command "$dir")
    if statusline_command_ok "$dir"; then
        echo "    settings.json already invokes this profile's statusline"
    else
        backup="$dir/settings.json.bak-$(date +%Y%m%d%H%M%S)"
        cp "$dir/settings.json" "$backup"
        # Merge the one key rather than copying the file: settings.json also
        # holds permissions, model and account-specific state that must not be
        # transplanted between hosts or profiles.
        jq --arg cmd "$want" '.statusLine = {type: "command", command: $cmd}' \
            "$dir/settings.json" > "$dir/settings.json.new"
        mv "$dir/settings.json.new" "$dir/settings.json"
        echo "    settings.json merged (previous saved as $(basename "$backup"))"
    fi

    warn_stale_badge "$dir"
}

# --------------------------------------------------------------------------

RC=0
for dir in "${TARGETS[@]}"; do
    if [ "$CHECK" -eq 1 ]; then
        echo "==> Checking $dir"
        check_one "$dir" || RC=1
    else
        echo "==> Installing into $dir"
        install_one "$dir"
    fi
done

if [ "$CHECK" -eq 1 ]; then
    echo
    if [ "$RC" -eq 0 ]; then
        echo "No drift: every profile matches $SRC_DIR."
    else
        echo "Drift found. Re-run without --check to reinstall from the checkout,"
        echo "or commit the local change here if the installed copy is the one you want."
    fi
    exit "$RC"
fi

# Render once so a broken install fails here rather than in the user's status
# bar. The statusline exits 0 on unparseable input, so empty output is the
# failure signal.
echo
echo "==> Verifying"
for dir in "${TARGETS[@]}"; do
    out=$(printf '{"model":{"display_name":"Opus 5"},"workspace":{"current_dir":"%s"},"context_window":{"context_window_size":200000,"total_input_tokens":5000,"total_output_tokens":100},"rate_limits":{"five_hour":{"used_percentage":42}}}' "$HOME" \
        | CLAUDE_CONFIG_DIR="$dir" bash "$dir/statusline.sh" 2>/dev/null)
    if [ -z "$out" ]; then
        echo "ERROR: $dir rendered nothing — check that jq works: echo {} | jq ." >&2
        exit 1
    fi
    echo "    $(basename "$dir"): $out"
done

echo
echo "==> Done. Restart Claude Code to pick it up."
echo "    The caveman badge appears only when \$CLAUDE_CONFIG_DIR/.caveman-active"
echo "    exists; without it the badge segment is silently omitted."
