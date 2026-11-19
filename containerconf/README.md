# xpal-claudia — containerized Claude Code + OpenCode

A minimal, containerized
[Claude Code](https://docs.claude.com/en/docs/claude-code/overview) +
[OpenCode](https://opencode.ai) environment on Debian slim. Runs as a non-root
user, uses zsh + oh-my-zsh, and keeps all credentials in a mounted host folder
(never in the image). Both agents are on PATH — `claude` or `opencode`,
whichever you want to work in for a given session.

The **Containerfile is the source of truth.** The image is rebuilt from it; you
never `podman commit` a running container into your build chain. Both run modes
below start from the same freshly built image.

Everything machine-specific — host folders, UID, runtime, ports, names — comes
from `containerconf/.env`, generated once by `./setup.sh` (see below). The
scripts never hardcode your paths.

## Get started

```bash
cd containerconf
./setup.sh        # guided wizard — answers are written to containerconf/.env
./build.sh        # build the image from the Containerfile
./run-daily.sh    # create and enter the day-to-day container
```

`./setup.sh` prompts for each setting with a sensible default (host folders
default to `~/xpal-src`, `~/xpal-data`, `~/xpal-auth`; UID defaults to your
`id -u`; runtime auto-detects podman → docker). It creates the folders and
writes the config. Re-run it any time to change paths, ports, or names — the
next container you create picks them up. `.env` is machine-specific and
gitignored; never commit it. See `.env.example` for the full key list.

For unattended setup: `XPAL_HOST_SRC="$HOME/code" ./setup.sh --yes`.

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

`--userns=keep-id` (set in both run scripts) maps the container's `coder` user
to your host user so it can read/write the bind-mounted host folders under
rootless Podman. Without it you'll get permission errors on the mounts.

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
- **Remote MCP servers** — `MCP_REMOTE_CONFIG_DIR=/xpal-auth/mcp-remote` holds
  mcp-remote's OAuth tokens; server definitions live in
  `/xpal-auth/mcp/servers.json`. See [Remote MCP servers](#remote-mcp-servers-oauth-via-mcp-remote).

For SSH-based git, add a fourth mount onto the standard path, e.g.
`-v ~/xpal-auth/ssh:/home/coder/.ssh:Z`.

**Never commit credentials.** The `.gitignore` excludes common secret files;
credentials live in the mounted host folder, not the repo or the image.

## Remote MCP servers (OAuth via mcp-remote)

> Step-by-step user guide: `docs/mcp-connectors.md`. Design rationale:
> `docs/decisions/ADR-010-container-mcp-oauth-relay.md`.

Claude Code in the container can use remote MCP servers that sign in with
OAuth — the kind a Claude Desktop config reaches through
`npx mcp-remote <url> <callback-port> ...`. The image ships `mcp-remote`
(pinned via `MCP_REMOTE_VERSION` in the Containerfile) and keeps its tokens in
`/xpal-auth/mcp-remote`, so like every other credential they live on the host
and survive rebuilds.

**1. Describe the server** in `$XPAL_HOST_AUTH/mcp/servers.json`. It uses the
same `{"mcpServers": {...}}` shape as a Claude Desktop config, so an entry can
be pasted across unchanged — a host path to `npx` and any host `PATH` override
are normalized away, and an entry without a callback port uses the one
mcp-remote derives from its URL. See `mcp-servers.example.json` for the shape. The file stays on the host, outside git: it can carry OAuth client
details.

```bash
mkdir -p "$XPAL_HOST_AUTH/mcp" && $EDITOR "$XPAL_HOST_AUTH/mcp/servers.json"
```

How the entry is written decides where mcp-remote comes from:

| Entry | mcp-remote comes from | Trade-off |
|---|---|---|
| `"command": "mcp-remote"` | the copy baked into the image | no network or download at launch; changing version = rebuild |
| `"command": "npx"`, args `"-y", "mcp-remote@<version>", ...` (a pasted Desktop entry) | fetched by npx at runtime into `~/.npm/_npx` | version change = edit `servers.json` only; first launch in each new container downloads it (needs npm registry access, slower first start) |

`npx` ships with Node.js, so it is always available — nothing to install.
Pin the version (`mcp-remote@0.15.1`, not bare `mcp-remote`); `mcp-login` warns
if you don't. If every entry uses npx, set `MCP_REMOTE_VERSION` empty in the
Containerfile to drop the preinstall. After editing an entry (switching forms
included), re-run `./mcp-login.sh <name>`: it replaces the registration.

**2. Sign in once** (if the image predates this section, `./build.sh` first):

```bash
./mcp-login.sh <name>        # <name> = a key under "mcpServers"
```

This starts a throwaway container that publishes only that server's callback
port, on host loopback. mcp-remote prints an authorization URL — open it in a
browser on the host and sign in. The OAuth server redirects the browser to
`http://localhost:<callback-port>/...`, which reaches mcp-remote inside the
container. The tokens are written to `$XPAL_HOST_AUTH/mcp-remote`, the
connection is tested (the server's tools are listed), and the server is
registered with Claude Code at user scope (stored in `$CLAUDE_CONFIG_DIR`, so
it persists too), or its registration is updated if the entry changed. The
sign-in gives up after 10 minutes (`MCP_LOGIN_TIMEOUT=<seconds>` to change).

**3. Use it.** In the day-to-day container, start `claude`; `/mcp` lists the
server. Claude Code launches `mcp-remote` itself, which reads the shared tokens
and refreshes them silently. No recreate is needed — the day-to-day container
mounts the same `/xpal-auth`. (An existing day-to-day container does need one
recreate after the rebuild in step 2, to get `mcp-remote` and
`MCP_REMOTE_CONFIG_DIR`.)

When the refresh token eventually expires, the server shows as failed in
`/mcp`: re-run `./mcp-login.sh <name>`, then reconnect from `/mcp`.

**Why a relay.** mcp-remote's OAuth callback server binds `127.0.0.1` only
(hard-coded), and a published container port delivers traffic to the
container's network interface, not its loopback — publishing the port alone
never delivers the redirect. `mcp-login` runs `socat` on callback-port + 1 (all
interfaces) forwarding to `127.0.0.1:<callback-port>`, and `mcp-login.sh`
publishes host `<callback-port>` to container `<callback-port + 1>`. The
redirect URI the OAuth server has registered is unchanged.

**Why a separate container.** The day-to-day container's ports are fixed at
creation, and keeping the callback port published there would stop other apps
on the host (e.g. Claude Desktop's own mcp-remote) from binding it when they
need to sign in.

If a server's OAuth client allows the device grant, adding `--device-code` to
its args skips the callback entirely. Many clients have it disabled even when
the authorization server advertises it.

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
- `mcp-remote` (pinned) and `socat`, plus the `mcp-login` helper — remote
  OAuth MCP servers, see above
- Python toolchain: `uv` (owns Python — no apt python3), a uv-managed CPython
  exposed as `python`/`python3`, and `ipython` as a uv tool
- A non-root `coder` user

## Requirements

Claude Code officially supports Debian 10+, needs Node.js 18+, and 4 GB+ RAM.
See the [advanced setup docs](https://code.claude.com/docs/en/setup).
