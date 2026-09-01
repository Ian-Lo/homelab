#!/bin/bash
# Claude Code statusLine wrapper.
# Emits: model display name | account | cwd basename | git branch (if any) | context-usage % | caveman badge (if present)
# Degrades silently — no stray separators, no errors — when a segment is unavailable
# (e.g. no git repo, or the user-level caveman badge script is not installed).
# Env var CLAUDE_STATUSLINE_CONTEXT_WINDOW overrides the context window size used for the
# usage % calculation; unset, it uses whatever Claude Code itself reports for the active
# model (context_window.context_window_size — already correct for expanded-context modes).

set -u

INPUT=$(cat)

# Debug disabled (was: log all fields Claude Code sends to /tmp/statusline-input.jsonl)

MODEL=$(printf '%s' "$INPUT" | jq -r '.model.display_name // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.workspace.current_dir // .cwd // empty' 2>/dev/null)
RATE_LIMIT=$(printf '%s' "$INPUT" | jq -r '.rate_limits.five_hour.used_percentage // empty' 2>/dev/null)
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)

# This session's active account/profile, derived from the same env var Claude Code itself
# uses to pick a config dir (defaults to ~/.claude when unset) — so one statusline script
# installed into several profiles self-identifies correctly in each.
#
# The default profile is labelled "default", not "main": the account segment sits two
# places left of the git branch segment, and "main" is the most common branch name there
# is, so the default profile on a main branch rendered "main | <repo> | main" — the same
# word twice, with nothing to say which was which.
ACCOUNT=$(basename "${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
ACCOUNT="${ACCOUNT#.}"
[ "$ACCOUNT" = "claude" ] && ACCOUNT="default"

# Claude Code computes context_window.context_window_size itself from the active model,
# so it's already correct for expanded-context modes — no need to guess from model id.
CONTEXT_WINDOW_SIZE=$(printf '%s' "$INPUT" | jq -r '.context_window.context_window_size // empty' 2>/dev/null)
CONTEXT_WINDOW="${CLAUDE_STATUSLINE_CONTEXT_WINDOW:-$CONTEXT_WINDOW_SIZE}"
TOTAL_INPUT=$(printf '%s' "$INPUT" | jq -r '.context_window.total_input_tokens // 0' 2>/dev/null)
TOTAL_OUTPUT=$(printf '%s' "$INPUT" | jq -r '.context_window.total_output_tokens // 0' 2>/dev/null)
TOTAL_USED=$((TOTAL_INPUT + TOTAL_OUTPUT))

SEGMENTS=()

[ -n "$MODEL" ] && SEGMENTS+=("$MODEL")
[ -n "$ACCOUNT" ] && SEGMENTS+=("$ACCOUNT")

# Real user prompts sent this session — excludes tool-result turns (also
# role "user" in the transcript) and injected system-reminder turns
# (isMeta true), so this counts what the user actually typed.
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  PROMPT_COUNT=$(jq -s '[.[]
    | select(.type == "user")
    | select(.isMeta != true)
    | select(
        (.message.content | type) == "string"
        or (
          (.message.content | type) == "array"
          and ([.message.content[].type] | index("tool_result") == null)
        )
      )] | length' "$TRANSCRIPT_PATH" 2>/dev/null)
  [ -n "$PROMPT_COUNT" ] && [ "$PROMPT_COUNT" != "null" ] && SEGMENTS+=("${PROMPT_COUNT} prompts")
fi

if [ -n "$CWD" ]; then
  SEGMENTS+=("$(basename "$CWD")")
  BRANCH=$(git -C "$CWD" --no-optional-locks branch --show-current 2>/dev/null)
  [ -n "$BRANCH" ] && SEGMENTS+=("$BRANCH")
fi

USAGE_PCT=""
if [ -n "$TOTAL_USED" ] && [ "$TOTAL_USED" -gt 0 ] && [ -n "$CONTEXT_WINDOW" ] && [ "$CONTEXT_WINDOW" -gt 0 ]; then
  USAGE_PCT=$(awk "BEGIN { printf \"%.0f\", 100 * $TOTAL_USED / $CONTEXT_WINDOW }")
fi

if [ -n "$USAGE_PCT" ]; then
  # Format tokens: 1000+ as "1k", 1000000+ as "1M"
  format_tokens() {
    local n=$1
    if [ "$n" -ge 1000000 ]; then
      awk "BEGIN { printf \"%.1fM\", $n / 1000000 }" | sed 's/\.0M/M/'
    elif [ "$n" -ge 1000 ]; then
      awk "BEGIN { printf \"%.0fk\", $n / 1000 }"
    else
      echo "$n"
    fi
  }
  USED_FMT=$(format_tokens "$TOTAL_USED")
  WINDOW_FMT=$(format_tokens "$CONTEXT_WINDOW")
  # Color token usage: green <50%, yellow 50-80%, red >80%
  if [ "$USAGE_PCT" -lt 50 ]; then
    COLOR=$'\033[38;5;46m'   # Green
  elif [ "$USAGE_PCT" -lt 80 ]; then
    COLOR=$'\033[38;5;226m'  # Yellow
  else
    COLOR=$'\033[38;5;196m'  # Red
  fi
  RESET=$'\033[0m'
  SEGMENTS+=("${COLOR}${USED_FMT}/${WINDOW_FMT} (${USAGE_PCT}%)${RESET}")
fi

# Build rate limit bar if available
RATE_LIMIT_BAR=""
if [ -n "$RATE_LIMIT" ]; then
  # Round to a whole percent once, up front, and clamp to 0-100. Everything
  # below is bash integer arithmetic, which aborts on a fractional value
  # ("37.5: syntax error: invalid arithmetic operator"). awk also keeps this
  # free of bc: bc is absent from minimal Linux images, and its absence used
  # to silently force the red branch at every usage level.
  RATE_PCT=$(printf '%s' "$RATE_LIMIT" |
    awk '{ v = $0 + 0; if (v < 0) v = 0; if (v > 100) v = 100; printf "%.0f", v }' 2>/dev/null)
  if [ -n "$RATE_PCT" ]; then
    # Color by usage: green <50%, yellow 50-80%, red >80%
    if [ "$RATE_PCT" -lt 50 ]; then
      COLOR=$'\033[38;5;46m'  # Green
    elif [ "$RATE_PCT" -lt 80 ]; then
      COLOR=$'\033[38;5;226m'  # Yellow
    else
      COLOR=$'\033[38;5;196m'  # Red
    fi
    RESET=$'\033[0m'
    # 10-block bar (█ = 10%, ▉ = 9%, ▊ = 8%, etc.)
    BLOCKS=$((RATE_PCT / 10))
    PARTIAL=$((RATE_PCT % 10))
    BAR=""
    for ((i=0; i<BLOCKS; i++)); do
      BAR="${BAR}█"
    done
    GLYPH=""
    case $PARTIAL in
      9) GLYPH="▉" ;;
      8) GLYPH="▊" ;;
      7) GLYPH="▋" ;;
      6) GLYPH="▌" ;;
      5) GLYPH="▍" ;;
      4) GLYPH="▎" ;;
      3) GLYPH="▏" ;;
      *) ;;
    esac
    CELLS=$BLOCKS
    if [ -n "$GLYPH" ]; then
      BAR="${BAR}${GLYPH}"
      CELLS=$((CELLS + 1))
    fi
    # Pad to 10 cells. Count cells arithmetically rather than with ${#BAR}:
    # outside a UTF-8 locale that length is bytes, and each glyph is three.
    while [ "$CELLS" -lt 10 ]; do
      BAR="${BAR}░"
      CELLS=$((CELLS + 1))
    done
    RATE_LIMIT_BAR="${COLOR}${BAR}${RESET} ${RATE_PCT}%"
  fi
fi

OUT=""
for seg in ${SEGMENTS[@]+"${SEGMENTS[@]}"}; do
  if [ -z "$OUT" ]; then
    OUT="$seg"
  else
    OUT="$OUT | $seg"
  fi
done

if [ -n "$RATE_LIMIT_BAR" ]; then
  if [ -z "$OUT" ]; then
    OUT="$RATE_LIMIT_BAR"
  else
    OUT="$OUT | $RATE_LIMIT_BAR"
  fi
fi

# Resolve the caveman badge script. USER-LEVEL PATHS ONLY, in this order:
#   1. this profile's config dir  — per-account override (e.g. ~/.claude-jp/hooks)
#   2. ~/.claude/hooks           — the shared install, and the fallback for a
#                                   profile that has no hooks/ of its own
# Silently emits no badge if neither is present.
#
# A project-relative candidate ($CLAUDE_PROJECT_DIR/.claude/hooks/...) was
# deliberately removed: this wrapper execs whatever it finds on every render —
# roughly every keystroke — with no prompt, so any cloned repo shipping an
# executable of that name would get arbitrary code execution straight from
# `git clone`. Claude Code's own hook-approval gate covers .claude/settings.json
# hooks, NOT a path our wrapper execs itself. Search order cannot fix that: a
# project copy still runs whenever the user-level one is absent, which is
# exactly the state of a fresh host. Do not re-add it, and do not add an env
# var to opt back in — a repo can set env vars via direnv or shell hooks.
#
# Each candidate must also be a regular file, not a symlink, owned by the
# invoking user, and executable — same guard shape the badge script applies to
# its own flag file.
CAVEMAN_SCRIPT=""
for _cm_candidate in \
  "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/caveman-statusline.sh" \
  "$HOME/.claude/hooks/caveman-statusline.sh"; do
  if [ -f "$_cm_candidate" ] && [ ! -L "$_cm_candidate" ] \
     && [ -O "$_cm_candidate" ] && [ -x "$_cm_candidate" ]; then
    CAVEMAN_SCRIPT="$_cm_candidate"
    break
  fi
done
if [ -n "$CAVEMAN_SCRIPT" ]; then
  BADGE=$(printf '%s' "$INPUT" | "$CAVEMAN_SCRIPT" 2>/dev/null)
  if [ -n "$BADGE" ]; then
    if [ -z "$OUT" ]; then
      OUT="$BADGE"
    else
      OUT="$OUT | $BADGE"
    fi
  fi
fi

printf '%s' "$OUT"
