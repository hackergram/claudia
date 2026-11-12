#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# Rebuild the container image from the Containerfile.
#
# After a Containerfile change the ritual is: rebuild -> rm -> recreate the
# named container. Ephemeral runs (run-ephemeral.sh) pick up the new image
# automatically, so only the day-to-day named container needs a manual refresh.

IMAGE="$XPAL_IMAGE"
CONTAINER="$XPAL_CONTAINER"

# Toolchain pins (versions.env, sourced by config.sh) become build args. A name
# missing from versions.env fails here, not as an obscure error mid-build.
BUILD_ARGS=()
for name in DEBIAN_IMAGE NODE_MAJOR CLAUDE_CODE_VERSION OPENCODE_VERSION \
            GH_VERSION UV_VERSION PYTHON_VERSION IPYTHON_VERSION \
            OH_MY_ZSH_REF CODER_UID; do
  BUILD_ARGS+=( --build-arg "$name=${!name:?$name is not set — check versions.env}" )
done

# Extra flags pass straight through, e.g. `./build.sh --no-cache` to pick up
# fresh apt packages (cached layers keep the packages from the last build).
echo "Building $IMAGE from Containerfile..."
"$XPAL_RUNTIME" build "${BUILD_ARGS[@]}" "$@" -t "$IMAGE" "$SCRIPT_DIR"

# Show what the build actually contains (written into the image by the
# Containerfile), so a rebuild never changes versions unnoticed.
echo
echo "Installed versions (/etc/xpal-versions):"
"$XPAL_RUNTIME" run --rm --entrypoint cat "$IMAGE" /etc/xpal-versions || \
  echo "(could not read /etc/xpal-versions from $IMAGE)"

# If the day-to-day named container exists, offer to recreate it so it picks
# up the freshly built image (a container is pinned to the image as it was at
# creation — rebuilding the image does NOT update an existing container).
if "$XPAL_RUNTIME" container exists "$CONTAINER"; then
  echo
  echo "The day-to-day container '$CONTAINER' is running the OLD image."
  read -r -p "Remove and recreate it from the new image? [y/N] " reply
  case "$reply" in
    [yY]|[yY][eE][sS])
      "$XPAL_RUNTIME" rm -f "$CONTAINER"
      echo "Removed '$CONTAINER'. Recreate it with:  ./run-daily.sh"
      echo "(Reminder: anything hand-installed in the old container is gone —"
      echo " make sure keepers were promoted into the Containerfile first.)"
      ;;
    *)
      echo "Left '$CONTAINER' as-is. It will keep running the old image until"
      echo "you remove and recreate it."
      ;;
  esac
fi

echo "Done."
