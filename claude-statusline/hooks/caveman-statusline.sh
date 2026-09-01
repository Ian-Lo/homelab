#!/bin/bash
# caveman — statusline badge script for Claude Code
# Reads the caveman mode flag file and outputs a colored badge.
#
# Usage in ~/.claude/settings.json:
#   "statusLine": { "type": "command", "command": "bash /path/to/caveman-statusline.sh" }
#
# Plugin users: Claude will offer to set this up on first session.
# Standalone users: install.sh wires this automatically.

FLAG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active"
OWNER="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-active-session"

# Refuse symlinks — a local attacker could point the flag at ~/.ssh/id_rsa and
# have the statusline render its bytes (including ANSI escape sequences) to
# the terminal every keystroke.
[ -L "$FLAG" ] && exit 0
[ ! -f "$FLAG" ] && exit 0

# The flag is a single file shared by every session pointed at this config
# dir — on its own it says nothing about which session activated caveman.
# Without this check, any session sharing the config dir renders [CAVEMAN]
# the instant ANY session activates it, including sessions that never ran
# /caveman and sessions that already ended (there's no SessionEnd hook to
# clear the flag). The activation hooks (caveman-activate.js,
# caveman-mode-tracker.js) write their session_id to a companion file,
# .caveman-active-session, every time they write or clear the flag. Compare
# it against THIS session's own id, read from the same statusline JSON
# statusline.sh already piped in on stdin. Fail closed: no owner file, no
# session_id on stdin, or a mismatch all mean "render nothing" — never fall
# back to the old global behavior this replaces.
INPUT=$(cat)
SELF_SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SELF_SESSION" ] && exit 0
[ -L "$OWNER" ] && exit 0
[ ! -f "$OWNER" ] && exit 0
OWNER_SESSION=$(head -c 128 "$OWNER" 2>/dev/null | tr -d '\n\r')
[ "$OWNER_SESSION" != "$SELF_SESSION" ] && exit 0

# Hard-cap the read at 64 bytes and strip anything outside [a-z0-9-] — blocks
# terminal-escape injection and OSC hyperlink spoofing via the flag contents.
MODE=$(head -c 64 "$FLAG" 2>/dev/null | tr -d '\n\r' | tr '[:upper:]' '[:lower:]')
MODE=$(printf '%s' "$MODE" | tr -cd 'a-z0-9-')

# Whitelist. Anything else → render nothing rather than echo attacker bytes.
case "$MODE" in
  off|lite|full|ultra|wenyan-lite|wenyan|wenyan-full|wenyan-ultra|commit|review|compress) ;;
  *) exit 0 ;;
esac

if [ -z "$MODE" ] || [ "$MODE" = "full" ]; then
  printf '\033[38;5;172m[CAVEMAN]\033[0m'
else
  SUFFIX=$(printf '%s' "$MODE" | tr '[:lower:]' '[:upper:]')
  printf '\033[38;5;172m[CAVEMAN:%s]\033[0m' "$SUFFIX"
fi

# Savings suffix: on by default. Opt out via CAVEMAN_STATUSLINE_SAVINGS=0.
# Reads a pre-rendered string written by caveman-stats.js so we don't shell out
# to node on every keystroke. Refuses symlinks and strips control bytes —
# same hardening as the flag file (a local attacker could plant a file with
# ANSI escape codes otherwise). Until /caveman-stats has run at least once,
# the suffix file is absent and nothing is rendered — so the default is safe
# for fresh installs (no fake number, no crash).
if [ "${CAVEMAN_STATUSLINE_SAVINGS:-1}" != "0" ]; then
  SAVINGS_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.caveman-statusline-suffix"
  if [ -f "$SAVINGS_FILE" ] && [ ! -L "$SAVINGS_FILE" ]; then
    SAVINGS=$(head -c 64 "$SAVINGS_FILE" 2>/dev/null | tr -d '\000-\037')
    [ -n "$SAVINGS" ] && printf ' \033[38;5;172m%s\033[0m' "$SAVINGS"
  fi
fi
