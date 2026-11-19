# Lessons learned

## 2026-05-12 — Initial build

- **JSONL schema**: Every Claude Code assistant turn in `~/.claude/projects/**/*.jsonl`
  carries a `message.usage` object with full token breakdown including cache split. The
  `type: "assistant"` field identifies these entries. Filter out `model: "<synthetic>"` —
  those appear in internal tool-use plumbing and carry no real usage data.

- **Cache tokens dominate**: For heavy Claude Code use, `cache_read_input_tokens` is
  typically 50-100× larger than `output_tokens`. Over 3 weeks: 282M cache reads vs 3.3M
  output tokens. Pricing matters: cache reads at $0.30/MTok vs output at $15/MTok means
  the cache is saving very significant cost.

- **Output tokens drive energy**: Despite cache reads being the largest token count,
  energy consumption is dominated by output tokens (0.39 J each) because each output
  token requires a full autoregressive forward pass. Cache reads are ~0.02 J each.

- **Admin API requires Admin key**: The `/v1/organizations/usage_report/messages` endpoint
  rejects regular user API keys (`sk-ant-api...`) with a 403. It requires an Admin key
  (`sk-ant-admin...`) provisioned at console.anthropic.com → Settings → Admin API Keys.
  Org admin role required to create these.

- **API field for cache writes**: In the Admin API response, cache creation is split into
  `cache_creation.ephemeral_1h_input_tokens` and `cache_creation.ephemeral_5m_input_tokens`.
  The local JSONL rolls these into a single `cache_creation_input_tokens` field. Sum both
  API fields to match the local figure.

- **Anthropic has no per-token environmental data**: No official Anthropic figure exists
  for energy per token. The best public source is TokenPowerBench (arxiv 2512.03024) at
  0.39 J/output token on H100 hardware. Water and carbon are derived from this via
  industry-average data-center WUE and US grid intensity.

## 2026-08-22 — `Model:` trailer (ADR-007)

- **No env var reliably names the running model.** `ANTHROPIC_MODEL`/`CLAUDE_MODEL` are
  override *inputs*, not the effective model echoed back — unset in a normal session even
  though a specific model is definitely running. Had to read it from the agent's own
  session log instead of trusting the environment, unlike agent identity (ADR-005), which
  genuinely is a stable env marker.
- **Claude Code JSONL filenames are the session id** (`<sessionId>.jsonl`), so looking up
  "the model for *this* session" via `CLAUDE_CODE_SESSION_ID` is a direct glob, not a scan
  of `read_claude_sessions()`'s full history — much cheaper for something that runs on
  every commit.
- **OpenCode's `session.model` column is polymorphic**: sometimes a plain string, sometimes
  a JSON blob `{"id", "providerID"}`. `_opencode_session_record` already handled this for
  `claudia index`; the new `--current-model` path needed the same parsing (`_opencode_model_id`)
  or it would've printed the raw JSON blob into commit trailers.
- **`claude_dir()` was silently broken in this project's own container setup**: it checked
  only `CLAUDIA_CLAUDE_DIR`, never `CLAUDE_CONFIG_DIR` (the var `docs/container-env.md`
  documents this container as actually setting, to `/xpal-auth/claude`). Every claudia
  command — not just the new one — was reading an empty default `~/.claude` and reporting
  "No matching usage data found." the whole time. Found only because `--current-model`
  returned `unknown` when the live JSONL clearly had the data. Worth periodically sanity
  checking claudia's own commands actually see data in whatever environment they're
  supposedly supported in, rather than trusting that passing tests means it works live.

## 2026-11-17 — Remote MCP (mcp-remote) inside the container

- **mcp-remote's OAuth callback is loopback-only.** 0.15.1 hard-codes
  `app.listen(port, "127.0.0.1")` with no flag to change it, and a published
  container port delivers to the container's interface, not its loopback — so
  `-p <port>:<port>` alone never delivers the browser redirect. Fix: socat on
  port+1 (all interfaces) → `127.0.0.1:<port>`, publish host `<port>` →
  container `<port+1>`; the registered redirect URI is unchanged.
- **Verified the relay is required, not just theoretically.** Podman 6.2 on
  macOS (libkrun VM, rootless, netavark + pasta): a server bound to
  `127.0.0.1` in the container answers inside (HTTP 200) but the published
  port gives the host an empty reply (curl exit 52). Through the socat relay
  the same path works, and a full `mcp-login` sign-in completed.
- **Token cache is portable between host and container.** File is
  `$MCP_REMOTE_CONFIG_DIR/mcp-remote-v1/<md5>_tokens.json`, md5 over the server
  URL (+ `--resource`, headers, authorize params, client-metadata URL, token
  endpoint if given). Same args → same file; changing any of those forces a new
  sign-in.
- **Keycloak advertises the device grant realm-wide but enables it per
  client.** `device_authorization_endpoint` in the realm metadata proves
  nothing; POST `client_id=<id>` to it — `unauthorized_client` means
  `--device-code` won't work for that client.
- **`mcp-remote-client` quits on stdin EOF.** It treats stdin `end` like
  SIGINT: shuts down with exit 0 right after connecting, before the tools list
  arrives. Run it with a TTY (`-it`) or with stdin held open, or a "passing"
  smoke test proves only that it connected.
- **The callback server starts lazily** (only when a sign-in is needed), and
  `waitForAuthCode` has no timeout; `--auth-timeout` (30 s) only bounds the
  long-poll and the post-callback token exchange.

## 2026-11-19 — PR #28 review follow-ups (mcp-login)

- **`claude mcp add-json` exits 0 when it can't write.** With an unwritable
  `$CLAUDE_CONFIG_DIR` it still prints "Added stdio MCP server ..." and exits
  0, writing nothing. Check the config file afterwards (user scope:
  `mcpServers` in `$CLAUDE_CONFIG_DIR/.claude.json`).
- **mcp-remote 0.15.1 derives a missing callback port deterministically:**
  `3335 + parseInt(md5(url|resource|params|headers|...)[0:4], 16) % 45816`,
  no free-port search. Its parser also removes `--header`/`--header-file`
  pairs before reading the URL and port, so those may precede the URL. Without
  static client info it deletes a cached registration whose redirect URI
  doesn't match, so the sign-in must use the exact port the runtime will.
  `parseCommandLineArgs` is exported from the bundled chunk that `client.js`
  imports, so mcp-login calls it instead of copying the hash.
- **`mcp-remote-client` exits by itself** after listing tools and resources
  ("Exiting OK..."). Its SIGINT and stdin-end handlers are installed only
  after connecting, and both exit 0; before connecting, Ctrl-C kills it
  (status 130).
- **`timeout --foreground` is needed for Ctrl-C.** Without it, `timeout` moves
  to its own process group, so a terminal Ctrl-C never reaches the client.
- **`:Z` on a shared host folder is a trap on SELinux hosts.** It relabels the
  folder privately for the newest container, cutting off any running
  container that mounts it. Use `:z` for folders several containers share.
- **Podman exit codes for a throwaway container:** 125 for runtime errors such
  as a bad mount, 127 for a missing command, and 126 also for attach-phase
  failures (a busy published port gave 126 on Podman 6.2 for macOS). A
  `podman run --rm` start costs ~0.2 s on that machine.
