#!/usr/bin/env bash
# Opens an SSH tunnel to hermes-agent's API port. The container publishes
# 127.0.0.1:8642 on the Docker host only (see docker-compose.yml) -- assume
# nothing else is backstopping that, so the loopback-only publish IS the
# access control. This tunnel is the intended way to reach it remotely.
#
# Run from the client machine:
#   ./tunnel.sh <host> [port]
# Then in another shell:
#   curl -H "Authorization: Bearer $HERMES_API_KEY" \
#     http://127.0.0.1:8642/v1/chat/completions -d '{"messages":[...]}'
set -euo pipefail

# No default host: a tunnel that silently points somewhere is worse than one
# that refuses to start. SSH_USER falls back to ssh's own config/default.
HOST=${1:?usage: $0 <host> [port]   (SSH_USER=<user> to override the ssh user)}
PORT=${2:-8642}

exec ssh -N -L "${PORT}:127.0.0.1:${PORT}" "${SSH_USER:+${SSH_USER}@}${HOST}"
