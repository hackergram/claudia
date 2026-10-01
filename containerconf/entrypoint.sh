#!/usr/bin/env bash
set -e

# Runtime initialization.
#
# These directories live INSIDE the /xpal-auth bind mount, so they can only be
# created after the mount exists — i.e. now, at container start. Creating them
# at build time would be pointless: the runtime mount masks anything the image
# baked into this path.
mkdir -p /xpal-auth/claude /xpal-auth/git /xpal-auth/npm

# Point git's credential store at the mounted auth dir (idempotent — safe to
# run on every start). Writes to $GIT_CONFIG_GLOBAL, which lives in the mount,
# so it persists across rebuilds.
git config --global credential.helper "store --file=/xpal-auth/git/git-credentials"

# Install ophio (host-Chrome automation) from the mounted source.
#
# This happens at start rather than in the Containerfile because the ophio
# repo is private and an image build has no credentials — but by now
# /xpal-src is mounted, so the source is right here. Costs a checksum on a
# normal start; only reinstalls when the source actually changed or the
# container was recreated (~/.local is image state, not a mount).
#
# Never fatal: a missing source or an offline npm must not stop the shell.
install_ophio() {
  src="${OPHIO_SRC:-}"
  if [ -z "$src" ]; then
    for candidate in /xpal-src/*/ophio; do
      if [ -f "$candidate/install.sh" ]; then src="$candidate"; break; fi
    done
  fi
  [ -n "$src" ] && [ -f "$src/install.sh" ] || return 0

  stamp="$HOME/.local/lib/ophio/.src-stamp"
  current="$(cat "$src/ophio.py" "$src/driver/"*.mjs "$src/driver/package.json" 2>/dev/null | cksum)"
  if [ -x "$HOME/.local/bin/ophio" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$current" ]; then
    return 0
  fi

  echo "entrypoint: installing ophio from $src ..."
  if "$src/install.sh" >/tmp/ophio-install.log 2>&1; then
    printf '%s' "$current" >"$stamp"
    echo "entrypoint: ophio ready — run 'ophio doctor' to check the host Chrome."
  else
    echo "entrypoint: ophio install failed; see /tmp/ophio-install.log. Continuing." >&2
  fi
}
install_ophio

# Hand off to whatever CMD was given (zsh, by default).
exec "$@"
