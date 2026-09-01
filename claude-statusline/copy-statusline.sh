#!/bin/bash
# Syncs the statusline to a remote host by pulling this repo there and running
# install.sh — it no longer scp's anything.
#
# An earlier version copied one machine's live ~/.claude/statusline.sh to the target
# and merged the settings key remotely. That made that machine's mutable copy the
# de-facto master: it had no history, no review, and no way to tell whether
# the two hosts had diverged. This directory is now the source of truth, so
# both hosts install the same committed blob and `install.sh --check` measures
# each of them against it.
#
# Commit and push your changes first — this pulls, it does not upload.
#
# Usage:
#   ./copy-statusline.sh <host> <ssh-user> [remote-checkout]
#
# Example:
#   ./copy-statusline.sh myserver.example youruser      # checkout at ~/homelab
#   ./copy-statusline.sh somehost me ~/Git/homelab
#
# Installs for the named user only. Claude Code resolves ~/.claude per-account,
# so another account on the same host needs its own run.
set -euo pipefail

HOST="${1:?usage: $0 <host> <ssh-user> [remote-checkout]}"
SSH_USER="${2:?usage: $0 <host> <ssh-user> [remote-checkout]}"
REMOTE_CHECKOUT="${3:-\$HOME/homelab}"

TARGET="${SSH_USER}@${HOST}"

# Warn rather than block: the remote pulls from the push remote, so anything
# uncommitted or unpushed here simply will not arrive, and that is a confusing
# way to discover a change did not take.
if [ -n "$(git -C "$(dirname "${BASH_SOURCE[0]}")" status --porcelain -- . 2>/dev/null)" ]; then
    echo "WARNING: uncommitted changes in claude-statusline/ — the remote pulls" >&2
    echo "         from the push remote, so those will not be installed." >&2
fi

echo "==> Pulling and installing on $HOST"
ssh "$TARGET" bash -s -- "$REMOTE_CHECKOUT" <<'REMOTE'
set -euo pipefail
checkout=$(eval echo "$1")

[ -d "$checkout/.git" ] || {
    echo "ERROR: $checkout is not a git checkout." >&2
    echo "Clone this repo there first, or pass the right path as the" >&2
    echo "third argument." >&2
    exit 1
}

cd "$checkout"
git pull --ff-only
exec ./claude-statusline/install.sh
REMOTE

echo
echo "==> Verifying no drift on $HOST"
ssh "$TARGET" bash -s -- "$REMOTE_CHECKOUT" <<'REMOTE'
set -euo pipefail
cd "$(eval echo "$1")"
exec ./claude-statusline/install.sh --check
REMOTE
