# xpal-claudia — containerized Claude Code + OpenCode

A minimal, containerized
[Claude Code](https://docs.claude.com/en/docs/claude-code/overview) +
[OpenCode](https://opencode.ai) environment on Debian slim. Runs as root by
default (under rootless Podman that is *your* host user — see ADR-008) with an
opt-in non-root `coder` fallback, uses zsh + oh-my-zsh, and keeps all
credentials in a mounted host folder (never in the image). Both agents are on PATH — `claude` or `opencode`,
whichever you want to work in for a given session.

The **Containerfile is the source of truth.** The image is rebuilt from it; you
never `podman commit` a running container into your build chain. Both run modes
below start from the same freshly built image.

Everything machine-specific — host folders, runtime, ports, names — comes
from `containerconf/.env`, generated once by `./setup.sh` (see below). The
scripts never hardcode your paths.

## After a Podman upgrade (or whenever containers must be recreated)

Containers are tied to the Podman that created them, so a major upgrade can
leave existing ones unusable. Your **host folders are untouched** (`xpal-src`,
`xpal-data`, `xpal-auth` — code, data, and credentials all live there). What is
lost is anything that lived only inside the old container: hand-installed
packages and `/tmp`. Run these **on the host**, from `containerconf/`:

```bash
# 1. Is Podman healthy? On macOS the machine may need starting (or re-creating
#    if the upgrade replaced it).
podman --version
podman machine list                 # want one machine, "Currently running"
podman machine start                # if it isn't running

# 2. Optional, before you lose it: see what you hand-installed in the old
#    container, so you can promote keepers into the Containerfile.
podman diff xpal-dev                # skip if the container is already gone

# 3. Get the current scripts and pins.
git pull

# 4. Build. Reads versions.env, builds, and prints every installed version.
#    Add --no-cache for fresh Debian packages. If a container named xpal-dev
#    exists it offers to remove it — answer y.
./build.sh

# 5. Remove the remote-track container too, if you use it. build.sh only
#    offers to recreate the plain one.
podman rm -f xpal-dev-remote        # skip if you don't use run-daily-remote.sh

# 6. Create and enter the new container.
./run-daily.sh                      # or ./run-daily-remote.sh "/path/to/remote"
```

No `./setup.sh` needed — your `.env` still works (an old `XPAL_HOST_UID` line in
it is ignored). Re-run `./setup.sh` only if `.env` is missing. If the upgrade
also wiped your images, step 4 simply rebuilds them.

**Check it worked** (inside the new container):

```bash
cat /etc/xpal-versions              # what this build actually contains
id                                  # uid=0(root) — the default
claude --version && claudia --current-model
touch /xpal-data/.owner-check       # then on the HOST: ls -ln ~/xpal-data/.owner-check
```

The file should be owned by **your** host user, not root; delete it afterward.
If it is root-owned you are on a rootful runtime — see "Root, and the `coder`
fallback" below. The first start also installs a few tools from the mounted
`/xpal-src` (needs network once); `claude` will ask you to log in only if
`xpal-auth` was lost.

## Get started

```bash
cd containerconf
./setup.sh        # guided wizard — answers are written to containerconf/.env
./build.sh        # build the image from the Containerfile
./run-daily.sh    # create and enter the day-to-day container
```

`./setup.sh` prompts for each setting with a sensible default (host folders
default to `~/xpal-src`, `~/xpal-data`, `~/xpal-auth`; runtime auto-detects
podman → docker). It creates the folders and writes the config. Re-run it any time to change paths, ports, or names — the
next container you create picks them up. `.env` is machine-specific and
gitignored; never commit it. See `.env.example` for the full key list.

For unattended setup: `XPAL_HOST_SRC="$HOME/code" ./setup.sh --yes`.

An older `.env` may still contain `XPAL_HOST_UID`; it is no longer used and can
be deleted.

## Versions and pinning

Every tool version in the image is pinned in one committed file,
`versions.env` (base image by digest, Node major, Claude Code, OpenCode, `gh`,
`uv`, Python, IPython, oh-my-zsh commit — ADR-009). `./build.sh` reads it,
passes each value to the Containerfile, and **prints the versions actually
installed** when the build finishes (also in the image at `/etc/xpal-versions`;
the full Debian package list is in `/etc/xpal-apt-manifest`).

```bash
./build.sh                          # build exactly what versions.env says
./build.sh --no-cache               # same pins, but refresh Debian packages
CLAUDE_CODE_VERSION=2.2.0 ./build.sh   # try a different version for one build
```

To bump a pin, edit `versions.env`, rebuild, and read the printed list. Always
build with `./build.sh` — a bare `podman build` has no build args and the
Containerfile will stop with a message saying so. Debian packages are
deliberately unpinned: the base-image digest fixes the snapshot they come from.

## Root, and the `coder` fallback

The container runs as **root** by default, so you can `apt-get install`,
install system packages, and run root-only installers inside it. Under
*rootless* Podman, container root is mapped to your host user: the bind mounts
are writable and files created in them are owned by you on the host. Don't use
this with a rootful runtime — there, root in the container is root on the host
and files in the mounts end up root-owned.

Some tools refuse to run as root. For those, the image also has a `coder` user
(fixed UID 1000, not tied to your host UID). Create the container with
`XPAL_AS_CODER=1` to run as it:

```bash
XPAL_AS_CODER=1 ./run-daily.sh      # only applies when the container is created
```

That adds `--user coder --userns=keep-id:uid=1000,gid=1000`, which maps your
host user onto `coder` so the mounts stay writable. `coder` has the system-level
tools (Node, the npm CLIs, git, `gh`, `rg`, `jq`) but not the `uv`-managed
Python, which lives under root's home. To switch, remove the container
(`./cleanup.sh`) and recreate it. For a one-off non-root shell in a root
container, `podman exec -it -u coder xpal-dev zsh` works for anything that
doesn't need to write the mounts.

## Two run tracks

### 1. Day-to-day (long-lived, named, stable mounts)

A persistent container you return to. Mounts are fixed at creation. No remote.

```bash
./run-daily.sh                      # first run creates the day-to-day container
$XPAL_RUNTIME start -ai $XPAL_CONTAINER   # re-enter later
$XPAL_RUNTIME exec -it $XPAL_CONTAINER zsh  # open an extra shell into it
```

(Container and image names come from `containerconf/.env` — defaults are
`xpal-dev` and `xpal-claudia`.)

A container is pinned to the image it was created from. After changing the
Containerfile, run `./build.sh` — it rebuilds and offers to remove + recreate
the day-to-day container so it picks up the new image. (Anything hand-installed
in the old container is lost on recreate — promote keepers to the Containerfile
first.)

### 2. Ephemeral (throwaway, optional per-run SharePoint mount)

A fresh `--rm` container every launch, so it always uses the latest image and
can take a different remote folder each time.

```bash
./run-ephemeral.sh                              # no remote
./run-ephemeral.sh "/path/to/SharePoint/ProjectA"   # mount ProjectA this run
XPAL_REMOTE="/path/to/ProjectB" ./run-ephemeral.sh  # same, via env var
```

The remote is bound at `/xpal-data-remote`.

**SharePoint prerequisite:** the library must be **synced to a local folder**
by the OneDrive/SharePoint sync client — a bind mount can only point at a path
that already exists on this filesystem. On macOS that's usually under
`~/Library/CloudStorage/OneDrive-<org>/...`. If the library is *not* synced
locally, a bind mount can't reach it; you'd need `rclone` inside the container
instead (different setup). If files appear missing inside the container despite
the folder existing, the sync client may be showing online-only placeholders —
set the folder to "always keep on this device."

## Mounts

| Host path (from `.env`)       | Container path      | Purpose               |
|-------------------------------|---------------------|-----------------------|
| `$XPAL_HOST_SRC` (default `~/xpal-src`)  | `/xpal-src`         | code (working dir)    |
| `$XPAL_HOST_DATA` (default `~/xpal-data`) | `/xpal-data`        | local data            |
| `$XPAL_HOST_AUTH` (default `~/xpal-auth`) | `/xpal-auth`        | all credentials       |
| *(per-run, ephemeral only)*   | `/xpal-data-remote` | synced SharePoint     |

Host folders are chosen per machine by `./setup.sh`; the container-side paths
are fixed.

Under rootless Podman, the default (root) user maps to your host user, so the
mounts are readable and writable with no extra flags. In `XPAL_AS_CODER=1` mode
the run scripts add `--userns=keep-id:uid=1000,gid=1000` to do the same for the
`coder` user.

## Ports

The day-to-day container publishes the ports from `$XPAL_PORTS` (default
`5000`, `8000`, `8080`) to the host, so a dev server on those ports is
reachable at `localhost:<port>` on your machine. Under rootless Podman a
container has no host-routable IP, so ports must be published explicitly — you
can't hit the container by IP.

**Servers must bind to `0.0.0.0`, not `127.0.0.1`,** or the published port has
nothing to connect through (e.g. `flask run --host=0.0.0.0`,
`uvicorn --host 0.0.0.0`). Ports are fixed at container creation; changing them
means a rebuild + recreate (`./build.sh`).

## Authentication

All credentials are redirected to `/xpal-auth` via environment variables set in
the Containerfile, so they persist on the host and never enter the image:

- **Claude Code** — `CLAUDE_CONFIG_DIR=/xpal-auth/claude` (holds
  `.credentials.json` etc.). Run `claude` and log in once.
- **git** — `GIT_CONFIG_GLOBAL=/xpal-auth/git/gitconfig`; the entrypoint sets a
  credential helper storing tokens to `/xpal-auth/git/git-credentials`. Set your
  identity once (persists): `git config --global user.name "..."` and
  `user.email "..."`.
- **npm** — `NPM_CONFIG_USERCONFIG=/xpal-auth/npm/npmrc`.

For SSH-based git, add a fourth mount onto the standard path, e.g.
`-v ~/xpal-auth/ssh:/root/.ssh:Z` (`/home/coder/.ssh` in `XPAL_AS_CODER` mode).

**Never commit credentials.** The `.gitignore` excludes common secret files;
credentials live in the mounted host folder, not the repo or the image.

## Tracking hand-installed dependencies

Installs made inside a running container are provisional — they vanish on
rebuild/recreate. To see what diverged from the image before promoting to the
Containerfile:

```bash
podman diff xpal-dev                      # files added/changed vs the image
# inside the container:
grep " install " /var/log/dpkg.log | tail # recently apt-installed packages
npm ls -g --depth=0                        # global npm packages
```

Fold keepers into the Containerfile's `apt-get install` / `npm install -g`
lines, commit, then `./build.sh`.

## Cleanup

```bash
./cleanup.sh
```

Removes the `xpal-dev` container and prunes dangling `<none>` images left behind
by previous builds (each `./build.sh` orphans the prior image). Prompts before
acting; never touches the current image, your host data, or git. Ephemeral
containers use `--rm` and need no cleanup.

## What's inside

- Debian 12 (bookworm) slim base
- Node.js 20 LTS, `git`, `ripgrep`
- zsh + oh-my-zsh (default shell)
- Claude Code (`@anthropic-ai/claude-code`) — run with `claude`
- OpenCode (`opencode-ai`) — run with `opencode`
- Python toolchain: `uv` (owns Python — no apt python3), a uv-managed CPython
  exposed as `python`/`python3`, and `ipython` as a uv tool
- [ophio](https://github.com/hackergram/ophio) — drives the **host's** Chrome
  from inside the container over the DevTools protocol (see below);
  installed at start from `/xpal-src`, not baked into the image
- GitHub CLI (`gh`), `jq`, and an `ssh` client
- [claudia](https://github.com/hackergram/claudia) itself, installed (editable)
  at start from `/xpal-src/*/claudia` so the commit-trailer hook can record the
  model — skipped if no checkout is mounted
- Runs as root by default; a non-root `coder` user is the opt-in fallback
  (see "Root, and the `coder` fallback")

## Browser automation (ophio)

The container has no browser, and installing a headless one rootlessly is a
multi-hour dead end (no root for `apt`, no fonts, no display server). `ophio`
sidesteps that by driving the Chrome already running on your Mac, over CDP via
`host.containers.internal`.

`entrypoint.sh` installs it from `/xpal-src/*/ophio` on container start —
about a second, and skipped entirely (a checksum) when nothing changed. It is
not baked into the image because the ophio repo is private and an image build
has no credentials. Point it elsewhere with `-e OPHIO_SRC=/path/to/ophio`; if
the source is missing the container still starts normally, just without
`ophio`.

`OPHIO_CDP_URL` is pre-set, so the only real step is starting Chrome on the
host with its debug port open:

```bash
# in the container — prints the command to run on the host, and checks it
ophio host-cmd
ophio doctor

# then
ophio open https://example.com
ophio snapshot
ophio close
```

The `--user-data-dir` in the printed command is not optional: without it an
already-running Chrome ignores the flags and never opens the port.

Full docs live in the ophio repo; `ophio doctor` diagnoses each layer
separately when something is wrong, and `/tmp/ophio-install-<uid>.log`
(`-0` as root) has the install output if the CLI is missing entirely.

## Requirements

Claude Code officially supports Debian 10+, needs Node.js 18+, and 4 GB+ RAM.
See the [advanced setup docs](https://code.claude.com/docs/en/setup).
