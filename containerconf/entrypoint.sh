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

# The bind-mounted repos are owned by the host user. Under rootless Podman that
# looks like the running user, but under rootful Docker (or a --user override)
# git refuses them as "dubious ownership". This gitconfig lives in the
# container-only auth mount, so trusting every directory here is contained.
if ! git config --global --get-all safe.directory | grep -qx '\*'; then
  git config --global --add safe.directory '*'
fi

# Install ophio (host-Chrome automation) from the mounted source.
#
# This happens at start rather than in the Containerfile because the ophio
# repo is private and an image build has no credentials — but by now
# /xpal-src is mounted, so the source is right here. Costs a checksum on a
# normal start; only reinstalls when the source actually changed or the
# container was recreated (the install prefix is image state, not a mount).
#
# ophio's install.sh picks its prefix by user: /usr/local as root, ~/.local
# otherwise. Mirror that rule here, or the "already installed" check below
# looks in the wrong place and reinstalls on every start.
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

  if [ "$(id -u)" = "0" ]; then prefix="/usr/local"; else prefix="$HOME/.local"; fi
  stamp="$prefix/lib/ophio/.src-stamp"
  log="/tmp/ophio-install-$(id -u).log"
  current="$(cat "$src/ophio.py" "$src/driver/"*.mjs "$src/driver/package.json" 2>/dev/null | cksum)"
  if [ -x "$prefix/bin/ophio" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$current" ]; then
    return 0
  fi

  echo "entrypoint: installing ophio from $src ..."
  if "$src/install.sh" >"$log" 2>&1; then
    printf '%s' "$current" >"$stamp"
    echo "entrypoint: ophio ready — run 'ophio doctor' to check the host Chrome."
  else
    echo "entrypoint: ophio install failed; see $log. Continuing." >&2
  fi
}
install_ophio

# Install claudia (editable, from the mounted source) so the prepare-commit-msg
# hook can record the Model: trailer — without it the hook silently writes
# "Model: unknown". Skipped if claudia is already on PATH or no checkout is
# mounted. Needs network once (uv builds the project); never fatal.
install_claudia() {
  command -v claudia >/dev/null 2>&1 && return 0
  command -v uv >/dev/null 2>&1 || return 0
  for candidate in /xpal-src/*/claudia; do
    if [ -f "$candidate/pyproject.toml" ] && [ -f "$candidate/claudia.py" ]; then
      echo "entrypoint: installing claudia from $candidate ..."
      if uv tool install --editable "$candidate" >"/tmp/claudia-install-$(id -u).log" 2>&1; then
        echo "entrypoint: claudia ready."
      else
        echo "entrypoint: claudia install failed; see /tmp/claudia-install-$(id -u).log. Continuing." >&2
      fi
      return 0
    fi
  done
}
install_claudia

# Hand off to whatever CMD was given (zsh, by default).
exec "$@"
