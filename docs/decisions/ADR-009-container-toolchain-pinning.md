# ADR-009: Pin the container toolchain; record what each build contains

**Status:** Accepted

## Context

The Containerfile pinned almost nothing. The base was a mutable tag
(`debian:bookworm-slim`); Node floated within a major; `uv`, CPython,
`@anthropic-ai/claude-code`, `opencode-ai`, `ipython` and oh-my-zsh all took
whatever was latest on the day of the build, several via `curl | sh`. Nothing
recorded what a build contained. The running image had visibly drifted from the
file (a CLI listed in the Containerfile was absent from the image; two Claude
Code installs at different versions were present).

Because Docker layer caching also freezes unpinned layers until invalidated,
"latest" was not even consistent: the version depended on when each layer was
last built. A forced container recreation (such as a Podman major-version
upgrade) is exactly when everything moves at once, with no way to say what
changed.

A scan of the projects under `/xpal-src` (issue #23) found no hard version
conflicts: Python floor is 3.11 (lowest declared floor elsewhere: 3.10 for
claudia, 3.8 for ophio), Node floor is 20 (set by one project's Playwright
lock), and no project declares an upper bound. There are no `.nvmrc` /
`.python-version` files anywhere, so the image was the only place a version was
decided — implicitly.

## Decision

- **One committed file, `containerconf/versions.env`, holds every pin.**
  `config.sh` sources it; `build.sh` passes each value as a `--build-arg`; the
  Containerfile declares each `ARG` immediately before its use and aborts with a
  clear message if one is missing. Any pin can be overridden for a single build
  via the environment (`CLAUDE_CODE_VERSION=… ./build.sh`).
- **Pinned exactly:** base image (by digest, with the tag kept for readers),
  Claude Code, OpenCode, `uv`, IPython, `gh` (release tarball, checked against
  the release's published checksums), and oh-my-zsh (by commit — it has no
  release tags, and its installer can only clone a branch, so the Containerfile
  fetches the exact commit itself).
- **Pinned to a minor/major:** Python `3.13` (the version best covered by the
  repos' CI matrices, and within every declared range), Node `20`.
- **Deliberately left floating:** Debian apt packages. The base digest fixes the
  Debian snapshot they come from, exact apt pins break when old versions leave
  the mirror, and stable receives only security fixes. Instead, their exact
  versions are recorded (below). Rebuild with `./build.sh --no-cache` to pick
  up newer security fixes within the same snapshot.
- **Record what was built:** the Containerfile writes `/etc/xpal-versions` (tool
  versions) and `/etc/xpal-apt-manifest` (every Debian package and version).
  `build.sh` prints the first after each build.
- `entrypoint.sh` is copied last, so editing it rebuilds one layer instead of
  everything installed above it.

## Consequences

- Rebuilds are reproducible apart from the unpinned apt packages and the
  `curl | bash` NodeSource setup script (only its major is pinned; the script
  itself is not checksummed).
- Pins go stale. Bumping is a deliberate one-line edit plus a rebuild; there is
  no automation yet (a Renovate/Dependabot-style updater is a possible
  follow-up). Security fixes in pinned tools require remembering to bump.
- **Not verified by an image build.** This change was made in an environment
  with no container runtime. What was checked: shell syntax, the `build.sh` /
  `config.sh` / run-script argument plumbing against a stub runtime, the
  Containerfile's guard and `gh` download/checksum/extract logic, the
  oh-my-zsh commit fetch, and that the Debian digest, `uv` versioned installer
  and `gh` assets exist upstream. What was **not** run: `podman build` itself,
  the NodeSource script, `uv python install`, the final version-manifest `RUN`,
  and the `entrypoint.sh` start-up path inside a container. First build on a
  real host should be treated as the test.
- Pinning the base image digest means the Debian security updates released after
  that digest are only picked up when the digest is bumped.
- The ophio and claudia installs at container start are not pinned — they track
  whatever is checked out in the mounted source, by design.

## Alternatives considered

- *Pin everything including apt versions.* Rejected: brittle, and the base
  digest already fixes the snapshot.
- *Leave latest and rely on the cache.* Rejected: the cache makes versions
  depend on build history, and a recreation resets it.
- *Pin in the Containerfile `ARG` defaults only.* Rejected: the values would be
  duplicated or hidden in the file; a separate committed file makes version
  bumps a clean diff and lets `build.sh` print and override them.
