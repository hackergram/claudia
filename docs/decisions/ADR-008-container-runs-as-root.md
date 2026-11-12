# ADR-008: The dev container runs as root by default; `coder` is an opt-in fallback

**Status:** Accepted — supersedes the "non-root `coder` user" part of ADR-004

## Context

ADR-004 and the original Containerfile ran the container only as a non-root
`coder` user, whose UID was tied to the host user (`HOST_UID`, default 501) and
mapped with `--userns=keep-id` so the bind-mounted folders were writable.

That design has a cost that matters for how the container is actually used: with
no root and no `sudo`, nothing can be installed at runtime — no `apt`, no system
packages, no services. A large part of the value of a dev container on a
managed host is exactly that: trying software that cannot be installed on the
host itself. Several projects mounted under `/xpal-src` also assume root (one
installer refuses to run unless `EUID` is 0) or assume `apt` works.

A cross-repo review (issue #23) found what actually depends on the user model:

- `HOME` and `PATH` were hard-coded to `/home/coder`; under root, `uv`,
  `ipython` and `claudia` would land in `/root/.local/bin`, off `PATH`, and the
  commit hook would silently write `Model: unknown`.
- `entrypoint.sh` checked for ophio under `~/.local`; ophio's installer targets
  `/usr/local` as root, so the check was always false and ophio reinstalled on
  every start.
- Some projects default their data dir to `$HOME/xpal-data`, which is
  container-local, not the `/xpal-data` mount.
- Nothing in the scanned repos refuses to run as root. One thing external to
  them might: Claude Code's permission-bypass mode is reported to refuse root.
  This has not been verified against the pinned version.

## Decision

- **The image runs as root by default.** No `USER` line; `HOME` follows the
  running user instead of being forced.
- **Drop `HOST_UID`, `XPAL_HOST_UID` and `--userns=keep-id` from the default
  path.** Under *rootless* Podman, container root maps to the host user, so the
  mounts are writable and files created in them are owned by the host user —
  with no UID plumbing at all.
- **Keep a `coder` user in the image as an opt-in fallback** for tools that
  refuse root. UID is fixed (`CODER_UID`, default 1000), not host-derived.
  `XPAL_AS_CODER=1` makes the run scripts add `--user coder
  --userns=keep-id:uid=1000,gid=1000`, which maps the host user onto coder's
  fixed UID so the mounts stay writable. It applies at container creation.
- Fix the assumptions above: `PATH` includes `/root/.local/bin`; `entrypoint.sh`
  mirrors ophio's prefix rule (`/usr/local` as root, `~/.local` otherwise);
  `XPAL_DATA=/xpal-data` is set in the image; git `safe.directory '*'` is set in
  the container-only gitconfig; `claudia` is installed from the mounted source at
  start.

## Consequences

- `apt`, system installs and root-only installers now work inside the container.
  They are still provisional — anything not promoted into the Containerfile is
  lost when the container is recreated (see "Tracking hand-installed
  dependencies" in the README).
- **Rootless only.** Dropping `keep-id` is clean only on rootless Podman. Under
  rootful Docker or rootful Podman, container root is real host root: files
  created in the mounts are root-owned on the host and need `sudo` to remove.
  The run scripts do not detect this. Do not use this setup with a rootful
  runtime.
- Root inside a rootless container is not host root, but it is also not a
  security boundary for a hostile workload: the mounts (including
  `/xpal-auth`, which holds credentials) are writable by it.
- The `coder` mode is thinner than the root mode: `uv`, Python and `ipython` are
  installed under root's home, which `coder` cannot traverse. `coder` gets the
  system-level tools (Node, the npm CLIs, git, `gh`, `rg`, `jq`). Making the uv
  toolchain system-wide is a possible follow-up if coder mode needs Python.
- `--userns=keep-id:uid=,gid=` is a Podman feature; it has not been exercised in
  this change (see ADR-009 for the build-verification caveat). Existing `.env`
  files may still contain `XPAL_HOST_UID`; it is ignored.
- Existing containers are unaffected until recreated (`./build.sh` offers to).
  A container created before this change keeps its old user and flags.
