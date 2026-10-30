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

## 2026-10-29 — container root default + pinning (ADR-008, ADR-009)

- **A new committed file can be silently gitignored.** The repo's `.gitignore` has `*.env`
  (to catch `.env.<machine>` files), which also matched the new `containerconf/versions.env`.
  `git status` just didn't list it — a build on another machine would have failed for a
  missing file. Caught with `git check-ignore -v`; fixed with a narrow `!containerconf/versions.env`.
  Check `git status --ignored` for any new file that is meant to be committed.
- **`oh-my-zsh` has no release tags, and its installer can only clone a branch.** Pinning it
  means fetching an exact commit yourself (`git fetch --depth 1 origin <sha>`) and starting from
  `templates/zshrc.zsh-template`. `uv` and `gh`, by contrast, have versioned installer URLs / release
  assets with published checksums.
- **ophio's installer picks its prefix by user** (`/usr/local` as root, `~/.local` otherwise), so any
  "already installed?" check in `entrypoint.sh` has to mirror that rule or it reinstalls on every
  start. Changing the container user silently changes where tools land (`HOME`, `PATH`).
- **Cached layers hide "latest".** Unpinned `curl | sh` and `npm install -g` layers are frozen by the
  build cache, so the installed versions depended on build history and the running image had
  drifted from the Containerfile (a CLI in the file was missing from the image, and a second
  Claude Code install sat at a different version). Pinning plus `/etc/xpal-versions` makes drift visible.
- **`scripts/scrub-public.sh` already fails on `main`** (12 critical hits at the start of this change,
  before any edit) — see the PR for the before/after count. The repo is public, so this needs its own
  cleanup; it is not part of the container change.
- **Found while sweeping `/xpal-src`, not fixed here (other repos):** `bigaitaskindex`
  (`model/observed.py:35`, `model/index.py:133`) builds its ledger path from `Path.home()/.claude`,
  ignoring `CLAUDE_CONFIG_DIR`, so in the container it reads/writes the wrong place for both users.
  `xetrapal3` scripts default `XPAL_DATA` to `$HOME/xpal-data`; the image now sets `XPAL_DATA=/xpal-data`.
  Several scripts with shebangs are committed as mode 644 (e.g. `mojogoat/goatctl.sh`,
  `xetrapal3/scripts/start_local.sh`) and `mojogoat/startmojogoat.sh` is 755 with no shebang.
- **No container runtime was available** where this was implemented. Shell logic, argument plumbing
  (against a stub runtime), the `gh` download/checksum/extract steps, the oh-my-zsh commit fetch and the
  upstream URLs/digest were checked; the image build itself was not. First build on a real host is the test.
