#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# --- Day-to-day + remote track ---------------------------------------------
# A long-lived, named container like run-daily.sh, but also binds an OPTIONAL
# synced folder (default mount point /xpal-data-remote). Separate from the plain
# day-to-day container because mounts are fixed at container creation — a
# container with a remote mount can't be the same container as one without.
#
# Usage:
#   ./run-daily-remote.sh [REMOTE_DIR] [options]
#
# Options (all optional; each overrides the .env / default value):
#   -n, --name NAME       container name        (default: $XPAL_CONTAINER_REMOTE)
#   -r, --remote DIR      host folder to mount   (same as the positional arg;
#                         else $XPAL_REMOTE, else $XPAL_HOST_REMOTE_DIR)
#   -m, --mount PATH      mount point inside the container
#                         (default: /xpal-data-remote)
#   -p, --ports "LIST"    space-separated host:container ports, e.g.
#                         "5002:5001 8002:8001"; use "" for no published ports
#                         (default: $XPAL_PORTS)
#   -h, --help            show this help
#
# Examples:
#   First container:   ./run-daily-remote.sh "/path/to/ProjectA"
#   Second container:  ./run-daily-remote.sh -n xpal-dev-remote2 \
#                        -r "/path/to/ProjectB" -m /xpal-data-remote2 \
#                        -p "5002:5001 8002:8001 8081:8080"
#
#   Re-enter later:     $XPAL_RUNTIME start -ai <name>
#   Extra shell into:   $XPAL_RUNTIME exec -it <name> zsh
#   Refresh after a rebuild:  rm it manually, then re-run this script
#     (build.sh only offers to refresh the plain day-to-day container)
#
# NOTE: the remote path, mount point and ports are only bound at CREATION time.
# Once the container exists, re-running this script just starts and attaches to
# it — passing different options has no effect until you remove and recreate it.
# Two running containers can't publish the same host port: give each its own.
#
# Prerequisite: the folder must already exist on this filesystem (e.g. a
# SharePoint library synced locally by the OneDrive/SharePoint sync client).

usage() { sed -n '/^# Usage:/,/^# Prerequisite/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed '$d'; }

IMAGE="$XPAL_IMAGE"
CONTAINER="$XPAL_CONTAINER_REMOTE"
REMOTE_DIR="${XPAL_REMOTE:-${XPAL_HOST_REMOTE_DIR:-}}"
REMOTE_MOUNT="/xpal-data-remote"
PORTS="$XPAL_PORTS"

POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    -n|--name)   [ $# -ge 2 ] || { echo "Error: $1 needs a value" >&2; exit 2; }; CONTAINER="$2"; shift 2 ;;
    -r|--remote) [ $# -ge 2 ] || { echo "Error: $1 needs a value" >&2; exit 2; }; REMOTE_DIR="$2"; shift 2 ;;
    -m|--mount)  [ $# -ge 2 ] || { echo "Error: $1 needs a value" >&2; exit 2; }; REMOTE_MOUNT="$2"; shift 2 ;;
    -p|--ports)  [ $# -ge 2 ] || { echo "Error: $1 needs a value" >&2; exit 2; }; PORTS="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    --)          shift; POSITIONAL+=( "$@" ); break ;;
    -*)          echo "Error: unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)           POSITIONAL+=( "$1" ); shift ;;
  esac
done

# Back-compat: a bare first argument is the remote host folder.
if [ "${#POSITIONAL[@]}" -gt 1 ]; then
  echo "Error: too many positional arguments (expected at most one REMOTE_DIR)" >&2
  exit 2
fi
if [ "${#POSITIONAL[@]}" -eq 1 ]; then
  REMOTE_DIR="${POSITIONAL[0]}"
fi

case "$REMOTE_MOUNT" in
  /*) ;;
  *) echo "Error: --mount must be an absolute path inside the container: $REMOTE_MOUNT" >&2; exit 2 ;;
esac

# If it already exists, don't create a second one — restart and attach instead.
if "$XPAL_RUNTIME" container exists "$CONTAINER"; then
  echo "Container '$CONTAINER' already exists — starting and attaching."
  echo "(Remote mount, ports and name were fixed at creation — see script header.)"
  exec "$XPAL_RUNTIME" start -ai "$CONTAINER"
fi

# Rebuild the -p args from the (possibly overridden) port list.
PORT_ARGS=()
for p in $PORTS; do
  PORT_ARGS+=( -p "$p" )
done

MOUNTS=(
  -v "$XPAL_HOST_SRC":/xpal-src:Z
  -v "$XPAL_HOST_DATA":/xpal-data:Z
  -v "$XPAL_HOST_AUTH":/xpal-auth:Z
)

if [ -n "$REMOTE_DIR" ]; then
  if [ ! -d "$REMOTE_DIR" ]; then
    echo "Error: remote folder does not exist: $REMOTE_DIR" >&2
    echo "(Is the library synced and available offline?)" >&2
    exit 1
  fi
  MOUNTS+=( -v "$REMOTE_DIR":"$REMOTE_MOUNT":Z )
  echo "Remote: $REMOTE_DIR -> $REMOTE_MOUNT"
else
  echo "No remote folder mounted."
fi

echo "Creating day-to-day+remote container '$CONTAINER'..."
exec "$XPAL_RUNTIME" run -it --name "$CONTAINER" \
  ${USER_ARGS[@]+"${USER_ARGS[@]}"} \
  ${PORT_ARGS[@]+"${PORT_ARGS[@]}"} \
  "${MOUNTS[@]}" \
  "$IMAGE"
