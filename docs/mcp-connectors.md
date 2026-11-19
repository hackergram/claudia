# Connecting MCP servers to the container

Claude Code running inside the [container environment](container-env.md) can
use **remote MCP servers that sign in with OAuth** — the kind a Claude Desktop
config reaches through `npx mcp-remote <url> <callback-port> ...`. This guide
walks through adding one, signing in, enabling it in Claude Code, and running
it.

Claude Desktop and claude.ai can't run in a container; they keep using their
own config on the host. This guide covers Claude Code (`claude`) in the
container.

## How it works

```
Claude Code ──stdio──> mcp-remote ──HTTPS + OAuth token──> remote MCP server
 (container)           (container)
                           │ reads / refreshes tokens
                           ▼
              /xpal-auth/mcp-remote  =  $XPAL_HOST_AUTH/mcp-remote on the host
```

- The image ships a pinned `mcp-remote`, which proxies Claude Code's stdio to
  the remote server and handles OAuth.
- Tokens live in the auth mount, like every other credential: on the host,
  never in the image, and kept across rebuilds.
- Signing in is the one step that needs a browser. `containerconf/mcp-login.sh`
  does it in a throwaway container:

```
host browser ─> localhost:<callback-port> ─(published, 127.0.0.1 only)─>
  container :<callback-port + 1> ─socat─> 127.0.0.1:<callback-port>  (mcp-remote)
```

mcp-remote only listens on the container's loopback, which a published port
can't reach, so a small relay forwards the redirect. The redirect URI the
OAuth server knows (`http://localhost:<callback-port>/...`) is the same as on a
desktop install. The reasoning is in
[ADR-010](decisions/ADR-010-container-mcp-oauth-relay.md).

## Before you start

- The container environment is set up: `containerconf/setup.sh` has run, and
  Podman is installed (on macOS, `podman machine start` must be running).
- The image includes `mcp-remote`. If your image predates this guide, rebuild
  it: `cd containerconf && ./build.sh` (accept the offer to recreate the
  day-to-day container).
- You know the server's details: its URL, its callback port, and any OAuth
  client info. The easiest source is an existing Claude Desktop entry
  (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS).

## 1. Describe the server

Create `$XPAL_HOST_AUTH/mcp/servers.json` (default: `~/xpal-auth/mcp/servers.json`).
It uses the same `{"mcpServers": {...}}` shape as a Claude Desktop config, so
you can paste an entry across:

```bash
mkdir -p ~/xpal-auth/mcp
$EDITOR ~/xpal-auth/mcp/servers.json
```

```json
{
  "mcpServers": {
    "my-server": {
      "command": "mcp-remote",
      "args": [
        "https://mcp.example.com/mcp",
        "3334",
        "--callback-path", "/callback",
        "--static-oauth-client-info", "{\"client_id\": \"your-client-id\"}"
      ]
    }
  }
}
```

The rules are mcp-remote's own:

- The **first** mcp-remote argument is the server URL. Only `--header` and
  `--header-file` pairs may come before it.
- The **second** argument is the callback port, if the entry gives one. If it
  doesn't, `mcp-login` uses the port mcp-remote derives from the URL (worked
  out by mcp-remote's own code), so Desktop entries without a port work as
  they are. A pre-registered OAuth client usually fixes the port: keep the one
  the provider gave you.
- An `env` block applies to both the sign-in and Claude Code.
- The name (`my-server`) is what you pass to `mcp-login.sh`, and what Claude
  Code will call the server.
- Keep the file in the auth folder, not in a repo: OAuth client info can
  include secrets.

How you write the entry decides where mcp-remote comes from:

| Entry | Runs | Trade-off |
|---|---|---|
| `"command": "mcp-remote"`, args from the URL on | the copy baked into the image | nothing downloaded at launch; a version change means a rebuild |
| `"command": "npx"`, args `"-y", "mcp-remote@<version>", <url>, ...` (a pasted Desktop entry) | npx fetches it at runtime | version change = edit this file; the first launch in each new container downloads it |

A host path to `npx` and any `PATH` override from a Desktop entry are dropped
automatically. Pin the version with npx (`mcp-remote@0.15.1`, not bare
`mcp-remote`).

## 2. Sign in

```bash
cd containerconf
./mcp-login.sh my-server
```

What happens:

1. A throwaway container starts with only the callback port published, on
   `127.0.0.1`.
2. mcp-remote prints **"Please authorize this client by visiting: https://…"**.
   Open that URL in a browser on the host and sign in. ("Could not open a
   browser automatically" is expected in a container.)
3. The browser is redirected back into the container, and mcp-remote stores
   the tokens in `$XPAL_HOST_AUTH/mcp-remote`.
4. It connects, lists the server's tools, and registers the server with Claude
   Code, or updates the registration if the entry in `servers.json` changed.

It ends with one of:

```
Registered "my-server" with Claude Code (user scope).
Updated "my-server" in Claude Code (user scope).
"my-server" is already registered with Claude Code with this definition.
```

If valid tokens already exist, no URL appears; it just connects. So
`mcp-login.sh` doubles as a connection check.

It waits up to 10 minutes for the browser sign-in; set `MCP_LOGIN_TIMEOUT`
(seconds) to allow longer. Ctrl-C cancels without registering anything.

## 3. Enable it in Claude Code

`mcp-login.sh` registers the server at **user scope**. The config lives in
`$CLAUDE_CONFIG_DIR` (`/xpal-auth/claude`), so it is available in every
project and survives rebuilds. Check it without opening a session:

```bash
podman exec xpal-dev claude mcp list     # if the day-to-day container is running
# otherwise, a throwaway container with just the auth folder:
podman run --rm --userns=keep-id -v ~/xpal-auth:/xpal-auth:z xpal-claudia claude mcp list
# my-server: mcp-remote https://mcp.example.com/mcp 3334 ... - ✔ Connected
```

Mount the auth folder with `:z` (shared label), not `:Z`. On SELinux hosts,
`:Z` relabels it privately for the new container and cuts a running
day-to-day container off from its credentials.

Other ways to manage it, all inside the container:

| Want to | Do |
|---|---|
| Turn it off for now, keep config | `/mcp` in a Claude session → select the server → disable |
| Register by hand (no sign-in run) | `claude mcp add-json --scope user my-server '{"type":"stdio","command":"mcp-remote","args":[...]}'` |
| Apply an edit to `servers.json` | `./mcp-login.sh my-server`: it replaces the registration when the entry changed |
| Remove it | `claude mcp remove --scope user my-server`; optionally delete its tokens in `$XPAL_HOST_AUTH/mcp-remote/` |

## 4. Run it

```bash
cd containerconf
./run-daily.sh          # or re-enter: podman start -ai xpal-dev
claude                  # first time only: log in to Claude Code
```

In the session:

- `/mcp` lists the server as connected.
- Its tools appear as `mcp__my-server__<tool>`. Ask for something that needs
  them, for example "use my-server to tell me who I'm signed in as". Claude
  Code asks permission the first time each tool runs.
- To skip the permission prompt for tools you trust, allow them in settings
  (for example `"permissions": {"allow": ["mcp__my-server__whoami"]}`), or use
  `/permissions`.

Claude Code launches mcp-remote for each session, and mcp-remote refreshes the
access token silently.

## Keeping it working

- **Refresh-token expiry.** Eventually (server policy, often weeks) the refresh
  token expires and the server shows as failed in `/mcp`. Run
  `./mcp-login.sh my-server` again, then reconnect from `/mcp`. You don't need
  to restart or recreate the day-to-day container — it shares the auth mount.
- **Args are part of the token key.** mcp-remote keys its token cache on the
  server URL, plus `--resource`, headers and authorize params when given.
  Changing any of those needs a fresh sign-in; switching between the
  `mcp-remote` and `npx` forms does not.
- **Several servers.** Add more entries under `mcpServers`. Each server's
  callback port is whatever its OAuth client was registered with. Sign in to
  them one at a time.
- **Port clash.** `mcp-login.sh` refuses to start if the callback port is busy
  on the host (on `127.0.0.1` or `::1`) — usually another mcp-remote (for
  example Claude Desktop's) partway through its own sign-in. Finish or quit
  that one first. If something grabs the port just after that check, Podman
  fails with `address already in use`; the cause is the same.
- **Upgrading mcp-remote.** Bump `MCP_REMOTE_VERSION` in the Containerfile and
  run `./build.sh` (or edit the version in an npx entry).

## Security notes

- Tokens and server definitions stay in `$XPAL_HOST_AUTH`, which is never
  copied into the image or committed. Don't put `servers.json` in a repo.
- The callback port is published only on `127.0.0.1`, and only for the length
  of a sign-in. The day-to-day container never publishes it.
- mcp-remote is pinned, so the code handling your tokens only changes when
  someone changes the pin.
- A server's tools act with your account's permissions. Review what a tool
  does before allowing it without a prompt, especially tools that write or
  submit data.

## Not covered (yet)

- **OpenCode.** It isn't registered automatically. It can use the same tokens
  if you add a `local` MCP entry that runs `mcp-remote` with the same args, but
  OpenCode's config isn't kept in `/xpal-auth` yet.
- **Device-code sign-in.** If the server's OAuth client allows the device
  grant, adding `--device-code` to the args removes the need for the callback
  and relay. Many clients have it turned off.

Problems? See [troubleshooting.md](troubleshooting.md#remote-mcp-sign-in-browser-cant-reach-the-redirect).
