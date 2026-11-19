# ADR-010: Remote OAuth MCP servers in the container via mcp-remote and a sign-in relay

**Status:** Accepted

(Numbered 010 because ADR-008 and ADR-009 are taken by the open container
PR #27: run-as-root and toolchain pinning.)

## Context

Teams already use remote MCP servers from Claude Desktop through `mcp-remote`
(`npx mcp-remote <url> <callback-port> --static-oauth-client-info ...`), and
want Claude Code in the container (`containerconf/`) to use the same servers.
Running the proxy in the container is easy. Signing in is not:

- The OAuth authorization-code flow redirects the user's **host** browser to
  `http://localhost:<callback-port>/<path>`. With a static (pre-registered)
  OAuth client, that redirect URI is fixed by the server-side client
  registration, so the port and host can't be changed per machine.
- `mcp-remote` (0.15.1) binds its callback server to `127.0.0.1` only. It is
  hard-coded, with no flag. A published container port delivers traffic to the
  container's network interface, not its loopback. Verified on Podman 6.2
  (macOS, libkrun, rootless, netavark + pasta): a loopback-bound server answers
  inside the container but gives the host an empty reply through a published
  port.
- The device grant (`--device-code`) would avoid the callback entirely. But
  whether it works depends on the OAuth client: Keycloak, for example,
  advertises the grant realm-wide yet enables it per client, and pre-registered
  clients commonly have it off.
- Ports on the long-lived day-to-day container are fixed at creation. Keeping
  a callback port permanently published there would also block other host
  apps (e.g. Claude Desktop's own mcp-remote) from binding it when they need
  to sign in.

## Decision

1. **Ship mcp-remote in the image, pinned** (`ARG MCP_REMOTE_VERSION`), plus
   `socat`. Point `MCP_REMOTE_CONFIG_DIR` at `/xpal-auth/mcp-remote`, so tokens
   live in the auth mount like every other credential. An empty
   `MCP_REMOTE_VERSION` skips the preinstall for npx-only setups.
2. **Server definitions on the host, outside git:** `$XPAL_HOST_AUTH/mcp/servers.json`,
   in Claude Desktop's `{"mcpServers": {...}}` shape so entries paste across.
   Both forms are honored: `"command": "mcp-remote"` runs the baked copy, and
   an `npx` entry keeps fetching its pinned version at runtime.
3. **Sign in through a throwaway container** (`containerconf/mcp-login.sh <name>`)
   that publishes only `127.0.0.1:<callback-port>` → container
   `<callback-port + 1>`, where `socat` relays to `127.0.0.1:<callback-port>`.
   The redirect URI is unchanged from a desktop install. The in-image helper
   (`mcp-login`) parses the definition, runs `mcp-remote-client` with the same
   args and env (same token-cache key), and registers the server with Claude
   Code at user scope (`claude mcp add-json --scope user`), replacing the
   registration when the entry changed and checking the config file
   afterwards (`add-json` exits 0 even when it can't write).
   The callback port is the entry's second argument or, when there is none,
   the port mcp-remote derives from the URL, computed by calling mcp-remote's
   own argument parser rather than a copy of its hash. That is also why the
   host asks the image for the port (one extra container start, ~0.2 s)
   instead of parsing `servers.json` itself: only the image has mcp-remote,
   and the host has no guaranteed JSON parser.
4. **No callback port on the day-to-day container.** It only consumes tokens:
   Claude Code launches mcp-remote, which refreshes tokens without a callback.
   When a refresh token finally expires, re-run `mcp-login.sh`.
5. **Shared SELinux label (`:z`) on the auth mount** in the sign-in and run
   scripts. A private label (`:Z`) on a throwaway sign-in container would cut
   a running day-to-day container off from its credentials.

## Consequences

- Works with any authorization-code OAuth server and a pre-registered client,
  without server-side changes. A device-code-enabled client can add
  `--device-code` and skip the relay.
- Tokens are portable: the cache filename is an md5 of the server URL (plus
  resource/headers/params when given), so host and container installs with the
  same args share one cache key.
- Deriving a missing port relies on mcp-remote's package layout (`client.js`
  importing `parseCommandLineArgs` from a chunk). If that changes, mcp-login
  asks for an explicit port instead of guessing.
- The relay depends on mcp-remote's loopback-only bind. If a future
  mcp-remote adds a bind-address option, the relay can be dropped. The pin
  keeps this from changing unnoticed.
- The scripts inherit the container env's Podman assumptions
  (`--userns=keep-id`, `container exists`). They aren't Docker-compatible as
  written.
- OpenCode is not wired up automatically; its config isn't in `/xpal-auth` yet.
