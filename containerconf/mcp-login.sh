#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# --- Remote MCP sign-in -----------------------------------------------------
# OAuth sign-in for a remote MCP server reached through mcp-remote (e.g. one
# copied from a Claude Desktop config). Run once, and again whenever the
# server's refresh token expires or its entry in servers.json changes.
#
#   ./mcp-login.sh NAME     NAME = a key under "mcpServers" in
#                           $XPAL_HOST_AUTH/mcp/servers.json
#   MCP_LOGIN_TIMEOUT=900 ./mcp-login.sh NAME   allow longer than 600 s
#
# Starts a throwaway container that publishes ONLY the server's OAuth callback
# port, on host loopback, so the browser's post-login redirect reaches
# mcp-remote inside the container (via a relay — see mcp-login-container.sh).
# Tokens land in $XPAL_HOST_AUTH/mcp-remote, which the day-to-day containers
# mount as well, so they use the tokens without being recreated.
#
# Why not sign in from the day-to-day container: its ports are fixed at
# creation, and keeping the callback port published there would stop other
# apps on this machine (e.g. Claude Desktop's own mcp-remote) from binding it
# when they need to sign in.

NAME="${1:-}"
if [ -z "$NAME" ] || [ "${NAME#-}" != "$NAME" ]; then
  echo "Usage: $0 NAME   (a server name from \$XPAL_HOST_AUTH/mcp/servers.json)" >&2
  exit 2
fi

if [ ! -f "$XPAL_HOST_AUTH/mcp/servers.json" ]; then
  echo "No $XPAL_HOST_AUTH/mcp/servers.json yet." >&2
  echo "Create it from containerconf/mcp-servers.example.json — same shape as the" >&2
  echo "\"mcpServers\" block of a Claude Desktop config." >&2
  exit 1
fi

if ! "$XPAL_RUNTIME" image inspect "$XPAL_IMAGE" >/dev/null 2>&1; then
  echo "No image '$XPAL_IMAGE' yet. Build it first: ./build.sh" >&2
  exit 1
fi

# The auth folder is mounted with a shared SELinux label (:z), not a private
# one (:Z): a day-to-day container may be running with the same folder, and a
# private relabel for this throwaway container would cut it off from its
# credentials. Without SELinux the label is a no-op.
AUTH_VOLUME="$XPAL_HOST_AUTH:/xpal-auth"

# --- 1. Callback port --------------------------------------------------------
# Asked of the image, because when an entry gives no port, mcp-login derives
# it with mcp-remote's own code, which only exists there. The lookup is kept
# light: no entrypoint, read-only mount. Exit codes tell a runtime failure
# apart from a problem with the entry.
set +e
PORT="$("$XPAL_RUNTIME" run --rm --userns=keep-id --entrypoint mcp-login \
  -v "$AUTH_VOLUME:ro,z" "$XPAL_IMAGE" --print-callback-port "$NAME")"
STATUS=$?
set -e
case "$STATUS" in
  0) ;;
  125|126)
    echo "$XPAL_RUNTIME could not start the port-lookup container (its error is above)." >&2
    exit 1
    ;;
  127)
    echo "Image '$XPAL_IMAGE' has no mcp-login helper (it predates MCP support)." >&2
    echo "Rebuild it: ./build.sh" >&2
    exit 1
    ;;
  *)
    echo "Could not get a callback port for '$NAME' (the reason is above)." >&2
    exit 1
    ;;
esac
case "$PORT" in
  ''|*[!0-9]*)
    echo "Unexpected callback port '$PORT' for '$NAME'." >&2
    exit 1
    ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "Callback port $PORT for '$NAME' is outside 1-65535." >&2
  exit 1
fi
# The relay's port inside the container: any port other than the callback's.
if [ "$PORT" -lt 65535 ]; then
  RELAY_PORT=$((PORT + 1))
else
  RELAY_PORT=$((PORT - 1))
fi

# --- 2. Is the port free? ----------------------------------------------------
# A readable early warning only. The real check is the runtime binding the
# port below: if anything takes it in the meantime, that bind fails with
# "address already in use". ::1 is probed too because a browser may try
# localhost over IPv6 first and would then reach whatever listens there.
for ADDR in 127.0.0.1 ::1; do
  if (exec 3<>"/dev/tcp/$ADDR/$PORT") 2>/dev/null; then
    echo "Port $PORT is already in use on this machine ($ADDR)." >&2
    echo "Another mcp-remote (e.g. Claude Desktop's) may be mid sign-in — finish or" >&2
    echo "quit it, then retry." >&2
    exit 1
  fi
done

# --- 3. Sign in ---------------------------------------------------------------
# Allocate a TTY only when there is one (works from scripts and agents too;
# the in-container helper feeds the client's stdin itself).
TTY_ARGS=( -i )
if [ -t 0 ] && [ -t 1 ]; then
  TTY_ARGS=( -it )
fi
ENV_ARGS=( -e "MCP_LOGIN_RELAY_PORT=$RELAY_PORT" )
if [ -n "${MCP_LOGIN_TIMEOUT:-}" ]; then
  ENV_ARGS+=( -e "MCP_LOGIN_TIMEOUT=$MCP_LOGIN_TIMEOUT" )
fi

echo "Publishing host 127.0.0.1:$PORT -> container relay :$RELAY_PORT for the sign-in."
exec "$XPAL_RUNTIME" run "${TTY_ARGS[@]}" --rm \
  --userns=keep-id \
  -p "127.0.0.1:$PORT:$RELAY_PORT" \
  "${ENV_ARGS[@]}" \
  -v "$AUTH_VOLUME:z" \
  "$XPAL_IMAGE" mcp-login "$NAME"
