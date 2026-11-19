#!/usr/bin/env bash
# mcp-login — sign in to a remote OAuth MCP server from INSIDE the container,
# then register it with Claude Code. Installed at /usr/local/bin/mcp-login.
#
# Normally launched from the host by containerconf/mcp-login.sh, which starts a
# throwaway container with the OAuth callback port published. User guide:
# docs/mcp-connectors.md.
#
#   mcp-login NAME                        sign in if needed, list tools, register
#   mcp-login --print-callback-port NAME  print NAME's callback port and exit
#
# Environment:
#   MCP_SERVERS_FILE      server definitions (default /xpal-auth/mcp/servers.json)
#   MCP_LOGIN_TIMEOUT     seconds to wait for the browser sign-in (default 600)
#   MCP_LOGIN_RELAY_PORT  relay port (default callback port + 1)
#
# Server definitions live in /xpal-auth/mcp/servers.json (host:
# $XPAL_HOST_AUTH/mcp/servers.json), in the same {"mcpServers": {...}} shape a
# Claude Desktop config uses, so an entry can be pasted across unchanged.
# Entries must run mcp-remote, and the form decides where it comes from:
#   "command": "mcp-remote"                    the copy baked into the image
#   "command": "npx", args "-y mcp-remote@X"   fetched by npx at runtime
# (A host path to npx, e.g. ~/node/bin/npx, counts as npx.) The callback port
# is whichever port mcp-remote itself will use: the second positional argument
# if given, otherwise the one mcp-remote derives from the server URL.
#
# Why a relay: mcp-remote's OAuth callback server listens on 127.0.0.1 only
# (hard-coded in mcp-remote, no flag to change it). A published container port
# delivers traffic to the container's network interface, not its loopback, so
# the browser's post-login redirect would never arrive. socat listens on all
# interfaces at RELAY_PORT and forwards to 127.0.0.1:CALLBACK_PORT; the host
# publishes CALLBACK_PORT -> RELAY_PORT. The redirect URI the OAuth server has
# registered (http://localhost:<callback port>/<path>) therefore stays the same
# as on a desktop install.

set -euo pipefail

SERVERS_FILE="${MCP_SERVERS_FILE:-/xpal-auth/mcp/servers.json}"
LOGIN_TIMEOUT="${MCP_LOGIN_TIMEOUT:-600}"

usage() {
  echo "Usage: mcp-login NAME" >&2
  echo "       mcp-login --print-callback-port NAME" >&2
  echo "NAME is a key under \"mcpServers\" in $SERVERS_FILE." >&2
}

# Reads one server entry and prints, by mode:
#   port   — the callback port mcp-remote will listen on
#   client — the command that runs mcp-remote-client with the entry's args and
#            env, NUL-separated (npx -p <pkg> ... for npx entries)
#   claude — the entry normalized for `claude mcp add-json`: same launcher
#            (bare `npx`, not a host path), any PATH override dropped — in a
#            desktop config it points at host paths.
# node is always present here (mcp-remote needs it), so it does the JSON work.
# (This is a single-quoted shell string: the JS must not contain apostrophes.)
PARSER='
const [file, name, mode] = process.argv.slice(1);
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const fail = (msg) => { process.stderr.write(`mcp-login: ${msg}\n`); process.exit(2); };
let doc;
try { doc = JSON.parse(fs.readFileSync(file, "utf8")); }
catch (e) { fail(`cannot read ${file}: ${e.message}`); }
const servers = (doc && doc.mcpServers) || {};
const def = servers[name];
if (!def) fail(`no server "${name}" in ${file} (found: ${Object.keys(servers).join(", ") || "none"})`);
const cmd = String(def.command || "").split("/").pop();
const args = (def.args || []).map(String);
// via "npx":       fetch mcp-remote at runtime, like a Claude Desktop config
// via "installed": use the copy baked into the image (any other launcher too)
let rest, via = "installed", pkg = "";
if (cmd === "mcp-remote") {
  rest = args;
} else {
  const i = args.findIndex((a) => /^mcp-remote(@.+)?$/.test(a));
  if (i === -1) fail(`"${name}" does not run mcp-remote; mcp-login only handles mcp-remote servers`);
  rest = args.slice(i + 1);
  if (cmd === "npx") { via = "npx"; pkg = args[i]; }
}
// mcp-remote drops every "--header V" and "--header-file V" pair before it
// reads its positional arguments, so those pairs may come before the URL.
const pos = [];
for (let i = 0; i < rest.length; i++) {
  if ((rest[i] === "--header" || rest[i] === "--header-file") && i < rest.length - 1) { i++; continue; }
  pos.push(rest[i]);
}
if (!/^https?:\/\//.test(pos[0] || ""))
  fail(`"${name}": the server URL must be the first mcp-remote argument (only --header/--header-file pairs may precede it)`);
// The entry env, minus PATH. Sign-in and the registered server both get it.
const env = { ...(def.env || {}) };
delete env.PATH;
const envArgs = Object.entries(env).map(([k, v]) => {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(k)) fail(`"${name}": env name ${JSON.stringify(k)} is not a valid variable name`);
  return `${k}=${v}`;
});
if ([...rest, ...envArgs].some((a) => a.includes("\0"))) fail(`"${name}": args and env values cannot contain NUL`);
const nul = (list) => list.map((a) => `${a}\0`).join("");

// The port mcp-remote will listen on, by its own rule: the second positional
// argument when parseInt reads it as non-zero; otherwise a port derived from a
// hash of the URL and several options. The derivation runs mcp-remote own
// parser, from the same package that will run, rather than a copy of the hash.
function derivedPort() {
  const where = "add the callback port as the second mcp-remote argument instead";
  let bin;
  try {
    bin = execFileSync(via === "npx" ? "npx" : "sh",
      via === "npx" ? ["-y", "-p", pkg, "-c", "command -v mcp-remote-client"] : ["-c", "command -v mcp-remote-client"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"],
        env: { ...process.env, npm_config_update_notifier: "false" } }).trim();
  } catch { fail(`"${name}" gives no callback port, and mcp-remote is not available to derive one; ${where}`); }
  const dist = path.dirname(fs.realpathSync(bin));
  const client = fs.readFileSync(path.join(dist, "client.js"), "utf8");
  const imp = [...client.matchAll(/import\s*\{([^}]*)\}\s*from\s*"(\.\/[^"]+)"/g)]
    .find((m) => /\bparseCommandLineArgs\b/.test(m[1]));
  if (!imp) fail(`this mcp-remote version does not expose its argument parser; ${where}`);
  const chunk = require("url").pathToFileURL(path.join(dist, imp[2])).href;
  // A child process keeps mcp-remote logging and exit calls out of this one,
  // and an empty config dir keeps the lookup away from cached registrations.
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mcp-login-"));
  try {
    return parseInt(execFileSync(process.execPath, ["--input-type=module", "-e",
      "const [u, ...a] = process.argv.slice(1); const { parseCommandLineArgs } = await import(u);" +
      " process.stdout.write(String((await parseCommandLineArgs(a, \"\")).callbackPort));",
      chunk, ...rest],
      { encoding: "utf8", env: { ...process.env, ...env, MCP_REMOTE_CONFIG_DIR: tmp }, stdio: ["ignore", "pipe", "pipe"] }), 10);
  } catch (e) {
    fail(`mcp-remote could not read the arguments of "${name}":\n${String(e.stderr || e.message).trim()}`);
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

switch (mode) {
  case "port": {
    const port = (pos[1] ? parseInt(pos[1]) : 0) || derivedPort();
    if (!Number.isInteger(port) || port < 1 || port > 65535) fail(`"${name}": callback port ${port} is outside 1-65535`);
    process.stdout.write(`${port}\n`);
    break;
  }
  case "client": {
    if (via === "npx" && !/^mcp-remote@\d/.test(pkg))
      process.stderr.write(`mcp-login: warning: "${name}" runs ${pkg} unpinned; pin it (mcp-remote@<version>) so the version cannot change under you\n`);
    const launcher = via === "npx"
      ? ["npx", "-y", "-p", pkg, "mcp-remote-client", ...rest]
      : ["mcp-remote-client", ...rest];
    process.stdout.write(nul(envArgs.length > 0 ? ["env", ...envArgs, ...launcher] : launcher));
    break;
  }
  case "claude": {
    const out = via === "npx"
      ? { type: "stdio", command: "npx", args: ["-y", pkg, ...rest] }
      : { type: "stdio", command: "mcp-remote", args: rest };
    if (envArgs.length > 0) out.env = env;
    process.stdout.write(`${JSON.stringify(out)}\n`);
    break;
  }
  default:
    fail(`internal: unknown mode ${mode}`);
}
'

# Compares NAME's user-scope Claude Code entry with the wanted one and prints
# "absent", "same", or "differs" followed by the current entry on a 2nd line.
# User-scope servers live under "mcpServers" in $CLAUDE_CONFIG_DIR/.claude.json.
REGISTERED='
const [file, name, wanted] = process.argv.slice(1);
const fs = require("fs");
let cfg = {};
if (fs.existsSync(file)) {
  try { cfg = JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (e) { process.stderr.write(`mcp-login: cannot read ${file}: ${e.message}\n`); process.exit(2); }
}
const have = cfg.mcpServers && cfg.mcpServers[name];
const norm = (d) => JSON.stringify([d.type || "stdio", d.command, d.args || [], Object.entries(d.env || {}).sort()]);
if (!have) process.stdout.write("absent\n");
else if (norm(have) === norm(JSON.parse(wanted))) process.stdout.write("same\n");
else process.stdout.write(`differs\n${JSON.stringify(have)}\n`);
'

PRINT_PORT=0
if [ "${1:-}" = "--print-callback-port" ]; then
  PRINT_PORT=1
  shift
fi
NAME="${1:-}"
if [ -z "$NAME" ] || [ "${NAME#-}" != "$NAME" ]; then
  usage
  exit 2
fi

if [ ! -f "$SERVERS_FILE" ]; then
  echo "mcp-login: $SERVERS_FILE not found." >&2
  echo "Create it on the host at \$XPAL_HOST_AUTH/mcp/servers.json" >&2
  echo "(shape: containerconf/mcp-servers.example.json)." >&2
  exit 1
fi
case "$LOGIN_TIMEOUT" in
  ''|*[!0-9]*|0)
    echo "mcp-login: MCP_LOGIN_TIMEOUT must be a positive number of seconds." >&2
    exit 2
    ;;
esac

parse() { node -e "$PARSER" "$SERVERS_FILE" "$NAME" "$1"; }

CALLBACK_PORT="$(parse port)"
if [ "$PRINT_PORT" = "1" ]; then
  echo "$CALLBACK_PORT"
  exit 0
fi

WORK="$(mktemp -d)"
RELAY_PID=""
HOLD_PID=""
cleanup() {
  if [ -n "$HOLD_PID" ]; then kill "$HOLD_PID" 2>/dev/null || true; fi
  if [ -n "$RELAY_PID" ]; then kill "$RELAY_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Through a file, not `mapfile < <(parse client)`: a failed parse then stops
# the script here (set -e) instead of leaving an empty command behind.
parse client >"$WORK/client"
mapfile -d '' -t CLIENT_CMD <"$WORK/client"
CLAUDE_JSON="$(parse claude)"

# --- Callback relay (see header) -------------------------------------------
if [ "$CALLBACK_PORT" -lt 65535 ]; then
  RELAY_PORT="${MCP_LOGIN_RELAY_PORT:-$((CALLBACK_PORT + 1))}"
else
  RELAY_PORT="${MCP_LOGIN_RELAY_PORT:-$((CALLBACK_PORT - 1))}"
fi
socat "TCP-LISTEN:${RELAY_PORT},fork,reuseaddr" "TCP:127.0.0.1:${CALLBACK_PORT}" &
RELAY_PID=$!

# True once something is LISTENing on port $1. Reads the kernel socket tables
# instead of connecting: a test connection would make socat dial the callback
# port, where nothing listens yet.
listening() {
  local hex files=()
  hex="$(printf ':%04X' "$1")"
  for f in /proc/net/tcp /proc/net/tcp6; do
    if [ -r "$f" ]; then files+=("$f"); fi
  done
  awk -v p="$hex" '$4 == "0A" && substr($2, length($2) - 4) == p { found = 1 }
                   END { exit !found }' "${files[@]}"
}
for _ in $(seq 50); do
  if listening "$RELAY_PORT" || ! kill -0 "$RELAY_PID" 2>/dev/null; then break; fi
  sleep 0.1
done
if ! listening "$RELAY_PORT"; then
  echo "mcp-login: the callback relay is not listening on port $RELAY_PORT." >&2
  exit 1
fi

cat <<EOF
== Signing in to "$NAME" ==
mcp-remote prints an authorization URL below. Open it in a browser on your
host and sign in. The OAuth server then redirects the browser to
http://localhost:${CALLBACK_PORT}/... on the host, which mcp-login.sh published
into this container. Tokens are stored under ${MCP_REMOTE_CONFIG_DIR:-~/.mcp-auth}.
If valid tokens already exist, no URL appears — it just connects and lists tools.
("Could not open a browser automatically" is expected in a container.)
Gives up after ${LOGIN_TIMEOUT}s; Ctrl-C cancels.

EOF

# Once connected, mcp-remote-client lists the tools and exits by itself. But
# it also exits (status 0) on stdin EOF, which would cut the listing short, so
# its stdin is a pipe nobody writes to. The holder is killed right after.
exec 3< <(exec sleep infinity)
HOLD_PID=$!
# --foreground keeps the client in this process group, so Ctrl-C reaches it;
# the INT trap keeps this script alive to report the cancel.
set +e
trap 'true' INT
timeout --foreground -k 10 "$LOGIN_TIMEOUT" "${CLIENT_CMD[@]}" <&3
STATUS=$?
trap - INT
set -e
exec 3<&-
kill "$HOLD_PID" 2>/dev/null || true
HOLD_PID=""
case "$STATUS" in
  0) ;;
  124|137)
    echo "mcp-login: gave up after ${LOGIN_TIMEOUT}s waiting for \"$NAME\" to sign in and connect." >&2
    echo "Run it again; MCP_LOGIN_TIMEOUT=<seconds> allows longer." >&2
    exit 1
    ;;
  130)
    echo "mcp-login: cancelled; \"$NAME\" was not registered." >&2
    exit 130
    ;;
  *)
    echo "mcp-login: sign-in or connection to \"$NAME\" failed (status $STATUS; see output above)." >&2
    exit 1
    ;;
esac

# --- Register with Claude Code (user scope -> $CLAUDE_CONFIG_DIR, persisted) --
# servers.json is the source of truth: add NAME if missing, replace it if its
# definition changed, leave it alone if it already matches. A registration
# only counts once Claude Code's config file shows it: `claude mcp add-json`
# prints "Added" and exits 0 even when it cannot write that file.
echo
if ! command -v claude >/dev/null 2>&1; then
  echo "claude is not on PATH; skipped Claude Code registration."
  exit 0
fi
CLAUDE_USER_CONFIG="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
registered() { node -e "$REGISTERED" "$CLAUDE_USER_CONFIG" "$NAME" "$1"; }
REG="$(registered "$CLAUDE_JSON")"
STATE="${REG%%$'\n'*}"
OLD_JSON=""
case "$STATE" in
  same)
    echo "\"$NAME\" is already registered with Claude Code with this definition."
    ;;
  absent|differs)
    if [ "$STATE" = differs ]; then
      OLD_JSON="${REG#*$'\n'}"
      echo "\"$NAME\" is registered with a different definition; replacing it with the one in servers.json."
      if ! claude mcp remove --scope user "$NAME"; then
        echo "mcp-login: could not remove the old \"$NAME\" registration (see error above)." >&2
        exit 1
      fi
    fi
    if ! claude mcp add-json --scope user "$NAME" "$CLAUDE_JSON" ||
       [ "$(registered "$CLAUDE_JSON")" != same ]; then
      echo "mcp-login: registering \"$NAME\" with Claude Code failed: $CLAUDE_USER_CONFIG" >&2
      echo "does not hold the new definition. Check that the folder is writable." >&2
      if [ -n "$OLD_JSON" ]; then
        if claude mcp add-json --scope user "$NAME" "$OLD_JSON" >/dev/null 2>&1 &&
           [ "$(registered "$OLD_JSON")" = same ]; then
          echo "The previous definition was restored." >&2
        else
          echo "Restoring the previous definition failed too; \"$NAME\" may be unregistered." >&2
        fi
      fi
      exit 1
    fi
    if [ "$STATE" = differs ]; then
      echo "Updated \"$NAME\" in Claude Code (user scope)."
    else
      echo "Registered \"$NAME\" with Claude Code (user scope)."
    fi
    ;;
  *)
    echo "mcp-login: unexpected registration state: $REG" >&2
    exit 1
    ;;
esac
echo "Done. In the day-to-day container, start a new claude session (or /mcp -> reconnect)."
