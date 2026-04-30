# franky-do — Slack agent bot · Design Specification (v1)

> A Slack bot that turns franky into a thread-aware coding agent for any
> Slack workspace. Sibling project; depends on `franky.sdk`. Listens
> via Slack Socket Mode (no public endpoint required), drives one
> stateful `franky.agent.Agent` per Slack thread, streams responses
> back into the same thread with throttled message edits.

---

## §0 Status

| Phase | Scope | Status |
|---|---|---|
| 0 | Project skeleton; `build.zig.zon` declares `franky` (path) + `websocket.zig` (URL) dependencies; `franky-do --version` smoke imports both | ✅ |
| 1 | Slack Web API client: `apps.connections.open` / `auth.test` / `chat.postMessage` / `chat.update`; CLI smoke posts a hello to a channel | ✅ |
| 2 | Slack Socket Mode: open WSS via Web API, connect via `websocket.Client`, log every received event, ACK envelopes | ✅ |
| 3 | Wire `app_mention` events to a `franky.agent.Agent` (single turn, no streaming yet); post the assistant reply via `chat.postMessage` | ✅ |
| 4 | Throttled streaming via `chat.update`; per-thread session map (`thread_ts` → ULID); built-in tools (read/write/edit/ls/find/grep) enabled | ✅ |
| 5 | Session persistence on disk (`franky.coding.session`); `/franky-do reset <thread>` slash command; multi-workspace auth | ✅ |
| 6 | `franky-do run` loop — Socket Mode WSS connect via `websocket.zig`, dispatch `app_mention` + `slash_commands` envelopes to the bot, `--all` parallel-workspace mode | ✅ |
| 7 | **Reactions-as-control** — `reaction_added` events route to abort / retry; bot users react with ❌ to abort an in-flight turn or ↩️ to re-run the last prompt in a thread; reactions on either the user mention OR the bot reply resolve back to the thread via a bounded LRU `reply_anchors` cache | ✅ |
| 8 | **Cost / token dashboards** — `franky-do stats` CLI walks `$FRANKY_DO_HOME/sessions/*` and emits a Markdown table (ulid · model · input · output · cost) with hardcoded Anthropic pricing; `/franky-do stats` slash command posts the workspace summary inside Slack | ✅ |
| 9+ | Bash inside a sandbox container; threads-of-threads / message-shortcut entry points; OAuth install flow; per-thread workspace isolation | ❌ |

The deliberate cut at v0.1 is **Phase 5**: a bot that any Slack workspace
can install, run end-to-end, hold a multi-turn conversation per thread,
use the safe coding tools, and survive process restarts. Bash and
heavyweight features wait until the foundation is proven.

### v0.2.x line — verified end-to-end (2026-04-28)

The v0.2.x patches (v0.2.1-v0.2.3) closed a chain of bugs surfaced
during first real-workspace testing with gemma4 via Ollama:

- **v0.2.1** — Socket Mode envelope parser was hand-rolled and matched
  the wrong nested `type` field; replaced with proper JSON parse.
- **v0.2.2** — `StreamSubscriber` flipped `done = true` on the first
  `turn_end`, causing the timer thread to exit before tool-using
  turns produced their text reply. Plain-text reply policy adopted
  (mrkdwn translation deferred to §16.2).
- **v0.2.3** — `stream_options.timeouts` was never populated, so
  `FRANKY_FIRST_BYTE_TIMEOUT_MS` and siblings had no effect. New
  `resolveTimeoutsFromEnv` plumbs the four canonical env vars
  through both run paths.

Plus a real bug fix in **franky core v1.21.0** (`Agent.workerFn`
deadlock on tool-heavy turns >128 events; now `agentLoop` runs on a
dedicated thread and the worker drains concurrently — capacity bumped
128→4096). franky-do depends on franky as a path-dependency, so it
picks the fix up automatically.

Confirmed working: `@`-mentions in channels, multi-turn tool-using
conversations (find → read → summarize), markdown plain-text rendering
in Slack, `FRANKY_*_TIMEOUT_MS` overrides honored. v0.4 work in
`v0.4-design.md` builds on this verified baseline.

---

## §1 Vision

franky already has six modes that drive the same agent loop: `print`,
`interactive`, `proxy` (web UI), `rpc`, plus the embedded SDK and the
soon-to-come Slack one. They're all consumers of the same
`franky.agent.Agent`. Every new mode that lands has the same shape:

1. A **transport** — how the user types and sees output.
2. A **session-binding strategy** — how persistent state attaches to a
   user and survives restarts.
3. **Identity glue** between the transport's notion of "user" and
   franky's `Agent` instances.

`franky-do` is the Slack instance of that pattern. The transport is
Slack's Socket Mode + Web API. The session-binding strategy is **one
franky session per Slack thread (`thread_ts`)** — Slack's UI already
groups context by thread, so we lean on that affordance rather than
inventing a new one. Identity glue is workspace-scoped: each
`(team_id, thread_ts)` pair maps to exactly one franky session ULID.

The bot is intentionally not a "ChatOps" framework. It does one thing
— give a Slack workspace access to a real coding agent, with full
tool use over a sandboxed file tree, scoped per thread. Everything
else (status checks, deploy commands, reaction-driven flows) is
deferred or out of scope.

---

## §2 Layering

```
┌────────────────────────────────────────────────────────────┐
│  franky-do — Slack adapter, session map, throttler         │
├────────────────────────────────────────────────────────────┤
│  websocket.zig — WSS client (vendored as build dep)        │
├────────────────────────────────────────────────────────────┤
│  franky.sdk → franky.{ai, agent, coding}                   │
└────────────────────────────────────────────────────────────┘
```

Hard rules:

- **`franky-do` imports `franky` only through `franky.sdk`.** No
  reaching past the facade into `franky.coding.modes.*` or
  `franky.agent.loop.*` directly. If `franky-do` needs something the
  SDK doesn't expose, that's a bug to fix in `franky.sdk`, not a
  layering violation to introduce here.
- **No `franky-do` code lives in `franky/`.** The franky binary, its
  CI, its versioning, and its release cadence are independent.
- **One-way deps.** `franky` does not, and never will, know that
  `franky-do` exists.

The point of these rules: prove that the v1.5.4 `franky.sdk` facade
is actually fit for downstream consumption. If we have to crack the
facade to ship the bot, the facade is wrong.

---

## §3 Slack Socket Mode protocol

Reference: <https://api.slack.com/apis/socket-mode>. Summary of what
`franky-do` needs to implement:

### §3.1 Token model

Two tokens, both required:

- **App-Level Token** (`xapp-...`) — has the `connections:write`
  scope. Used **once per WSS lifecycle** to call
  `apps.connections.open` and obtain the temporary WSS URL.
- **Bot Token** (`xoxb-...`) — has scopes like `app_mentions:read`,
  `chat:write`, `im:history`, etc. Used for **all Web API calls**
  while the bot is running.

Both tokens are scoped to a single Slack workspace. Multi-workspace
support (Phase 5) means storing one `(xapp, xoxb)` pair per
installed workspace.

### §3.2 Connection lifecycle

```
                      ┌── apps.connections.open (HTTPS, App-Level Token)
                      │   → returns wss://wss-primary.slack.com/link/?ticket=…
                      ▼
   ┌──────────────────────────────────────────────────┐
   │  websocket.Client.handshake(WSS URL)             │
   │  ↓                                               │
   │  read loop:                                      │
   │    serverMessage(JSON) → dispatch by `type`      │
   │      ├ "hello" → log, ignore                     │
   │      ├ "events_api" → ack(envelope_id), enqueue  │
   │      ├ "slash_commands" → ack(envelope_id), …    │
   │      ├ "interactive" → ack(envelope_id), …       │
   │      └ "disconnect" → close, reconnect           │
   │    clientPing → auto pong (websocket.zig handles)│
   └──────────────────────────────────────────────────┘
                      │
                      ▼
                 reconnect on EOF, error, or "disconnect" type
```

### §3.3 Acknowledgement contract

Every event Slack sends carries an `envelope_id`. The bot **MUST**
reply with the matching envelope id within 3 seconds, or Slack
considers the event un-delivered and retries:

```json
// inbound
{"type":"events_api","envelope_id":"abc-123","payload":{...}}
// outbound (over the same WSS)
{"envelope_id":"abc-123"}
```

The agent loop runs **after** the ACK. We do not block the ACK on
agent work — Slack's 3-second budget is not enough for a model
round-trip. The flow is:

```
on serverMessage(json):
  parse → envelope
  client.write(JSON.stringify({envelope_id}))   // synchronous, < 1ms
  enqueue envelope.payload onto the work queue   // returns immediately
```

The work queue is a single `franky.ai.channel.Channel` of
`SlackJob` events, drained by a worker pool. The drain dispatches
to the right handler based on the event subtype.

### §3.4 Reconnect semantics

- **Slack-initiated**: the `disconnect` message has a `reason`
  (`warning` = reconnect soon; `refresh_requested` = reconnect now).
  Either way: close the WS, sleep a short backoff, call
  `apps.connections.open` again, reconnect.
- **Network-initiated**: read loop returns with an error. Same flow
  as Slack-initiated.
- **Backoff**: 250 ms → 500 ms → 1 s → 2 s → 5 s, capped at 5 s, with
  a small jitter. Resets on a successful `hello` after reconnect.

In-flight envelope IDs queued *before* the disconnect have already
been ACK'd from Slack's perspective; their work continues. New
inbound events go through the new WS.

### §3.5 Event subtypes we care about (v0.1)

| Subtype | Source | What we do |
|---|---|---|
| `events_api` / `app_mention` | User `@`-mentioned the bot | Open or reuse session for `(team_id, thread_ts ?? message_ts)`; call `Agent.prompt(text)` |
| `events_api` / `message.im` | DM to the bot | Treat as one-on-one thread keyed by `(team_id, channel_id)` |
| `events_api` / `reaction_added` | User reacted to a message in a known thread | Phase 7 — `❌` aborts the in-flight turn; `↩️` re-runs the last user prompt. See §18 |
| `slash_commands` | `/franky-do reset` / `/franky-do help` / `/franky-do stats` | Reset / help / token dashboard |
| `interactive` | Button clicks | Out of scope for v0.1 |

Everything else is logged at debug level and dropped — we do not
listen for `message.channels` (no implicit listening; mention required).

---

## §4 Slack Web API surface

Reference: <https://api.slack.com/methods>. All calls are
`POST application/json` with the bot token in `Authorization: Bearer`
header. We reuse `franky.ai.http.fetchWithRetryAndTimeoutsAndHooks`
— v1.8.0 per-phase timeouts already cover us.

Endpoints used in v0.1:

| Method | When | Why |
|---|---|---|
| `apps.connections.open` | Once at startup, again on reconnect | Get WSS URL |
| `auth.test` | Once at startup | Verify bot token, capture `team_id` + `bot_user_id` (used for `@`-mention regex) |
| `chat.postMessage` | First reply in a turn | Posts the initial assistant bubble |
| `chat.update` | Subsequent streaming deltas, throttled per §7 | Updates the same `ts` with the accumulated text |
| `chat.postMessage` (continued) | Per tool call | Tools render as a separate threaded message: `🔧 read README.md → 1.3k bytes` |

Endpoints **explicitly out of v0.1**:
`conversations.replies` (we don't import prior thread context into
new sessions — fresh agent per thread, clean transcript), `files.upload`,
reactions, modals, scheduled messages.

### §4.1 Rate limit handling

Slack rate limits hit hard:

- `chat.postMessage` / `chat.update`: **Tier 4** ≈ 1 req / sec /
  channel.
- Many other methods: **Tier 3** ≈ 50 req / minute.
- 429 responses include a `Retry-After` header.

The `franky.ai.http` retry path already honors `Retry-After` (§F.1).
For `chat.update` specifically, the bot's own throttler (§7) keeps
the per-channel rate under the limit by design — 429s should be a
backstop, not a normal occurrence.

### §4.2 Errors as data

Slack's REST returns 200 OK even for application errors; the JSON
body has `{"ok": false, "error": "rate_limited"}`. The bot wraps
every Web API call in a helper that classifies `ok=false` as an
error event in the agent stream, mirroring the §F.2 tool/agent
error split franky already uses.

---

## §5 Session model

The core mapping:

```
(team_id, thread_ts)  →  franky session ULID
```

For DMs: `(team_id, "im_" ++ channel_id)` is treated as a
permanent thread.

### §5.1 In-memory map

A `std.StringHashMap([]const u8)` keyed by `team_id || ":" || thread_ts`
maps to the session ULID. The map is owned by the `Bot` struct;
its mutex serializes access (multi-thread because the work queue
has multiple drain workers).

### §5.2 Session creation

On first event for a thread:

1. Mint a new ULID via `franky.coding.session.mintUlid`.
2. Materialize `franky.coding.session.SessionHeader` with:
   - `id` = new ULID
   - `provider` / `model` / `api` / `thinking_level` from CLI / config
   - `title` = first 80 chars of the user's prompt (Slack-style truncation)
3. Save to `$FRANKY_DO_HOME/sessions/<ulid>/{session.json, transcript.json}`
   via `franky.coding.session.save`.
4. Store the mapping `(team_id, thread_ts) → ulid` and persist it
   via `bindings.json` in `$FRANKY_DO_HOME` (atomic tempfile + rename,
   same pattern as franky's session writes).

### §5.3 Session reuse

On subsequent events for the same `(team_id, thread_ts)`:

1. Look up ULID in the map.
2. Load via `franky.coding.session.load`.
3. Return a fresh `franky.agent.Agent` configured with that
   transcript.

### §5.4 Session reset

`/franky-do reset <thread>` (Phase 5) deletes the
`(team_id, thread_ts)` binding and the on-disk session dir, then
posts a system message into the thread acknowledging the reset.
The next `@`-mention in that thread starts fresh.

### §5.5 Workspace data layout

```
$FRANKY_DO_HOME/                    (default: ~/.franky-do)
├── workspaces/
│   ├── T0123456/
│   │   ├── auth.json               (xapp-, xoxb-, decoded scopes)
│   │   └── bindings.json           ({ "thread_ts": "ulid", ... })
│   └── T0654321/
│       └── ...
└── sessions/
    ├── 01JXYZABC.../
    │   ├── session.json
    │   └── transcript.json
    └── ...
```

`workspaces/<team_id>/auth.json` is **mode 0600**. ULID is enough
entropy that we don't namespace `sessions/` by team — collisions are
astronomically unlikely.

---

## §6 Agent driver

Per Slack message that requires a model round-trip:

```
on app_mention(payload):
  text = payload.event.text                          // "@franky-do hello"
  text = strip_bot_mention(text, bot_user_id)        // "hello"
  thread_ts = payload.event.thread_ts ?? payload.event.ts
  ulid = sessionMap.getOrCreate(team_id, thread_ts)
  agent = loadOrCreateAgent(ulid)
  reply_ts = chat.postMessage(channel, thread_ts, "_thinking…_")
  agent.subscribe(SlackStreamSubscriber{ channel, reply_ts })
  agent.prompt(text)                                  // returns immediately
  // worker thread runs the loop; subscriber edits reply_ts as deltas arrive
```

### §6.1 Agent lifecycle

A naive design would create a new `Agent` instance per Slack
message and discard it after. That breaks the §H.4 invariant —
`Agent` owns the worker thread + cancel token, and we need
`prompt()` to *append* to the same transcript across calls.

Better: keep an `AgentCache` keyed by ULID. First message for a
thread instantiates the `Agent`; subsequent messages reuse it.
Eviction is LRU bounded by `agent_cache_size` (default 16) — when
evicted, the agent is `deinit`'d cleanly (it has already persisted
its transcript).

When a thread's `Agent` is evicted and a new message arrives, we
re-load the transcript from disk and instantiate a fresh `Agent` —
identical observable behavior, slight reload cost.

### §6.2 Concurrency

Two layers of concurrency:

1. **Across threads**: the work-queue worker pool dispatches Slack
   events to handlers. N=4 by default — supports 4 concurrent
   Slack threads talking to the bot at once.
2. **Within a thread**: `franky.agent.Agent`'s own worker thread
   runs the loop sequentially. A second `prompt()` to the same
   `Agent` enqueues behind the first.

If a user sends **two messages back-to-back in the same thread**,
both queue against the same `Agent`. The second is responded to
after the first's loop terminates. We do **not** abort the first
turn on a second message — interrupting the model mid-sentence
makes for confusing transcripts. Users wanting to abort should
use the planned `/franky-do abort <thread>` (Phase 6).

### §6.3 Tools

The seven `franky.coding.tools` registered with each `Agent`:

| Tool | Phase 4 status | Notes |
|---|---|---|
| `read` | ✅ enabled | Same guards as franky's print mode (binary refusal, 256 KiB cap) |
| `write` | ✅ enabled | Atomic, refuses to clobber by default |
| `edit` | ✅ enabled | Atomic multi-edit |
| `ls` | ✅ enabled | Tree view, gitignore-aware |
| `find` | ✅ enabled | Glob |
| `grep` | ✅ enabled | Regex / literal |
| `bash` | ✅ enabled (v0.5.1) | Stateless `bash.tool()`. **Sole safety layer is the v0.4.4 Slack permission prompt** — `prompts_enabled=true` (default) gates every call behind a Block Kit ✅/❌. The full sandbox roadmap (§6.4) is still future work |

All tools operate against `$FRANKY_DO_WORKSPACE` (default:
`$FRANKY_DO_HOME/workspace`), **not** the host's home or the
bot's CWD. The workspace is a per-bot-instance directory; users
sharing a Slack workspace also share the bot's filesystem.
Per-thread filesystem isolation is post-1.0.

### §6.4 Bash and sandboxing

**v0.5.1 status: bash is enabled** (`franky.coding.tools.bash.tool()`,
no per-session state, no workspace check). The sole safety layer
is the v0.4.4 Slack permission prompt — every call surfaces a
Block Kit message with the actual command in `cmd` and ✅/❌
buttons; nothing executes until an operator clicks ✅.

What that means in practice:

- `prompts_enabled=true` is the **default** (`--no-prompts` /
  `FRANKY_DO_PROMPTS=0` flips it off — don't, with bash enabled).
- The "always allow" button on a bash prompt is fingerprint-keyed
  on the **verb** (e.g. `rm`, `git`, `find`). Clicking it once for
  `rm -rf /tmp/scratch` silences future prompts for `rm`-anything,
  including `rm -rf /`. Treat that button as a per-verb gate, not
  a per-command one.
- The bot's UID is what bounds reachability. `rm -rf $HOME` is
  bot-UID-scoped damage; `rm -rf /etc` requires root. Run the bot
  as a dedicated UID with no rights outside the workspace dir
  ("Workspace ACL hardening" below) for a real safety floor.
- Spill files land in `/tmp/franky-bash-<call_id>.log` (no
  per-session `bash_state` is wired today; v1.27.x's session-dir
  spill is a follow-up — see v2 roadmap).

The full sandbox roadmap is still open. Shortlist:

- **Docker per call**: spin up a container per `bash` invocation with
  a read-only mount of the workspace and `--rm`. Heavy but bulletproof.
- **bubblewrap / firejail / chroot**: lighter, Linux-only, requires
  the bot to run with appropriate capabilities.
- **Workspace ACL hardening**: simplest — give the bot a UID with no
  rights outside the workspace dir. Mitigates `rm -rf /`-class issues
  but doesn't stop network egress.

The decision belongs to whoever's running the bot in production.
A future minor will ship one of these (most likely the Docker or
ACL variant) as the default. Until then: keep the Slack prompt
on, run the bot as an unprivileged UID, and don't click "always
allow" on bash prompts unless you really mean it.

---

## §7 Streaming + throttling

Agent events fire at ~50/sec (text deltas). Slack's
`chat.update` rate limit is ~1/sec/channel. We need a coalescer.

### §7.1 Stream subscriber shape

```zig
const SlackStreamSubscriber = struct {
    bot: *Bot,
    channel: []const u8,
    reply_ts: []const u8,
    accumulated: std.ArrayList(u8),
    last_update_ms: i64,
    update_min_interval_ms: u32 = 750,   // throttle floor
    pending_dirty: bool,                  // unflushed delta since last update
};
```

`subscribe` is called from §6's per-thread agent driver. Its
`onEvent` receives every `franky.agent.types.AgentEvent`:

- `text` deltas → append to `accumulated`, mark dirty, attempt update
- `thinking` deltas → render as Slack quote prefix (`> _thinking:_ …`),
  same throttle path
- `tool_execution_start` → post a separate threaded message
  (`🔧 read README.md`)
- `tool_execution_end` → update that tool message with the result preview
- `turn_end` → final update with full text + flush
- `agent_error` → reply with an error block

### §7.2 Throttle timer

A single per-thread timer thread (or the bot's shared work pool)
ticks at `update_min_interval_ms`. On each tick, if the subscriber
is `pending_dirty`, it issues a `chat.update` with `accumulated`
and clears the dirty flag. Multiple deltas between ticks coalesce
into one update — the user sees the full current state, not 50
intermediate ones.

`turn_end` forces an immediate flush regardless of timing — the
user should see the completed message without an extra second of
delay.

### §7.3 Slack message size cap

Slack limits a single message to 40,000 characters. Long agent
responses are split: when `accumulated.len > 39_000`, the
subscriber flushes the current message, posts a fresh
continuation message in the thread, and switches to that as the
new `reply_ts`. The model sees no difference; the user sees
multiple messages.

### §7.4 Markdown / mrkdwn

Slack uses **mrkdwn**, a subset of Markdown with subtle
differences (`*bold*` not `**bold**`, no real headings, code
fences use triple backticks, etc.). We do **not** transform model
output to mrkdwn in v0.1 — the model is told via system prompt to
prefer Slack-friendly formatting. A mrkdwn translator can come
later if mismatches prove painful.

System-prompt addendum injected for franky-do:

> _You are responding inside a Slack thread. Use single-asterisk
> `*bold*` and triple-backtick code fences. Avoid headings._

---

## §8 Tool surface (recap)

See §6.3. All seven franky tools are registered; `bash` is a
disabled stub in v0.1.

**Workspace path safety**: tools resolve relative paths against
`$FRANKY_DO_WORKSPACE` and refuse absolute paths or `..` escapes
that leave the workspace root. The same `franky.coding.path_safety`
helpers franky's own modes use.

---

## §9 Auth and multi-workspace

### §9.1 Single-workspace mode (v0.1 default)

Tokens come from environment variables:

- `SLACK_APP_TOKEN` — `xapp-...`
- `SLACK_BOT_TOKEN` — `xoxb-...`

`franky-do run` without flags reads both and runs against one
workspace. This matches the typical "I just want to run a bot for
my team" deploy shape.

### §9.2 Multi-workspace mode (Phase 5)

`franky-do install --workspace T0123456 --xapp ... --xoxb ...`
adds a workspace entry to `$FRANKY_DO_HOME/workspaces/T0123456/auth.json`.

`franky-do run` without `--workspace` enumerates all installed
workspaces and opens one Socket Mode connection per workspace,
each running concurrently.

Slack's OAuth install flow (the `/oauth/v2/access` redirect dance)
is **not** in v0.1. Tokens are obtained manually from the Slack
app config UI. OAuth-based install is Phase 5+.

### §9.3 Token storage

`auth.json` is mode 0600, plaintext. Encryption-at-rest uses the
host's keyring is post-1.0 — for now, file permissions are the
trust boundary, matching how franky's `auth.json` for OAuth tokens
already works.

---

## §10 Configuration

### §10.1 CLI

```
franky-do run                                   # one workspace from env
franky-do run --workspace T0123456              # one specific installed workspace
franky-do run --workspace T... --model <id>     # override the model id (any provider)
franky-do run --all                             # every installed workspace
franky-do install --workspace T... --xapp ... --xoxb ...
franky-do uninstall --workspace T0123456
franky-do list                                  # show installed workspaces
franky-do --version
franky-do --help
```

### §10.2 Config file

Optional `$FRANKY_DO_HOME/config.json`:

```json
{
  "model": "claude-sonnet-4-6",
  "thinking_level": "medium",
  "agent_cache_size": 16,
  "update_min_interval_ms": 750,
  "workspace_dir": "/srv/franky-do/workspace",
  "log_level": "info"
}
```

CLI flags override config-file values; config-file values override
defaults.

### §10.3 Env vars

| Var | Purpose |
|---|---|
| `SLACK_APP_TOKEN` | App-level token (xapp-) |
| `SLACK_BOT_TOKEN` | Bot token (xoxb-) |
| `FRANKY_DO_HOME` | Data dir (default: `~/.franky-do`) |
| `FRANKY_DO_WORKSPACE` | Tool workspace root (default: `$FRANKY_DO_HOME/workspace`) |
| `FRANKY_DO_LOG` | Log level (`error` / `warn` / `info` / `debug` / `trace`); off by default |
| `FRANKY_DO_LOG_FILE` | Redirect log output from stderr to a path |
| `FRANKY_DO_PROFILE` | v0.3.5+ — Profile name (settings.json catalog or built-ins like `gemini` / `groq` / `cerebras` / `ollama`). Resolves provider + model + auth in one shot via franky's profile system |
| `FRANKY_DO_MODEL` | Override the profile's model (default: `claude-sonnet-4-5`); per-run flag `--model <id>` wins. Pre-v0.3.5 this was Anthropic-only |
| `FRANKY_CONNECT_TIMEOUT_MS` | HTTP connect timeout (default 10000ms) |
| `FRANKY_UPLOAD_TIMEOUT_MS` | HTTP request-upload timeout (default 30000ms) |
| `FRANKY_FIRST_BYTE_TIMEOUT_MS` | HTTP first-byte timeout (default 30000ms). Bump for slow Ollama / Cloudflare cold starts; `300000` is reasonable for local Ollama under thinking workloads |
| `FRANKY_EVENT_GAP_TIMEOUT_MS` | SSE inter-event gap timeout (default 30000ms) |
| `FRANKY_DO_AGENT_CACHE_SIZE` | Hard cap on in-memory Agents (default 16). v0.3.1+ |
| `FRANKY_DO_IDLE_EVICTION_MS` | Evict in-memory Agents idle for longer than this (default 1_800_000 = 30min). v0.3.1+ |
| `FRANKY_DO_SWEEPER_INTERVAL_MS` | Idle-sweep cadence (default 300_000 = 5min). v0.3.1+ |
| `ANTHROPIC_API_KEY` | Forwarded to franky for the model call |
| `CLAUDE_CODE_OAUTH_TOKEN` | Forwarded to franky |

The four `FRANKY_*_TIMEOUT_MS` env vars share names with franky's CLI
(franky-do reads them via the same resolver shape, so a single
deployment can set them once at the parent-env level). Resolved
values are info-logged at startup so operators can confirm the env
took effect: `INFO franky-do timeouts connect=10000ms upload=30000ms
first_byte=300000ms event_gap=30000ms`.

---

## §11 Errors and reconnection

Same posture as franky proper: errors flow through streams, raises
are reserved for OOM and programmer errors.

### §11.1 Slack disconnect

WSS read loop returns `error.EndOfStream` or
`error.ConnectionResetByPeer` → close the client, run §3.4
reconnect with backoff, log at `info`. Per-thread agents continue
running; their stream subscribers buffer to memory until the
reconnect completes, then flush via `chat.update` on the new
connection.

### §11.2 Slack 5xx / network

Web API returns 5xx → `franky.ai.http`'s retry path handles it
(§F.1). 429 honors `Retry-After`. After exhausting retries the
bot logs the failure and posts an error message in the thread.

### §11.3 Agent errors

`agent_error` flows through the stream subscriber as a Slack
message:

> ⚠️ The model returned an error: `rate_limited` — try again in 30s.

We do **not** silently retry on agent errors. Slack users see the
problem and can decide.

### §11.4 Token / scope misconfig

`auth.test` at startup verifies the bot token. Missing scopes
(`app_mentions:read`, `chat:write`) → log a clear error to stderr
and exit non-zero. The bot does not start in a half-broken state.

---

## §12 Security model

The bot is a **multiplier of franky's tool capabilities** to anyone
who can `@`-mention it in the workspace. Threat model:

- Slack workspace members are **partially trusted**. They can:
  - Read any file in `$FRANKY_DO_WORKSPACE` (via `read`/`grep`/`find`/`ls`).
  - Write/edit any file in `$FRANKY_DO_WORKSPACE` (via `write`/`edit`).
  - **Not** run shell commands (bash disabled in v0.1).
  - **Not** access anything outside the workspace dir (path-safety guards).
- Slack workspace **admins** are fully trusted. They install the bot
  and provision its tokens.

What the bot does NOT do in v0.1:

- Per-user permission scoping. Anyone in the workspace gets full
  tool access. Slack thread visibility is the only ACL.
- Audit logging of tool calls. The transcript files are the audit log.
- Encrypted-at-rest token storage. File-mode 0600 is the boundary.
- DLP / content scanning of model output. Don't put secrets into
  files the bot can read.

These are documented in the README's "Limits and risks" section so
operators don't deploy under false assumptions.

---

## §13 Project structure

```
franky-do/
├── franky-do.md                    (this file)
├── README.md                       (operator-facing quickstart)
├── CHANGELOG.md
├── build.zig
├── build.zig.zon                   (franky path dep + websocket.zig URL dep)
└── src/
    ├── main.zig                    (CLI entry; subcommand dispatch)
    ├── cli.zig                     (flag parsing)
    ├── config.zig                  (config-file loader + defaults)
    ├── auth.zig                    (workspace auth.json round-trip)
    ├── slack/
    │   ├── web_api.zig             (auth.test, chat.postMessage, chat.update,
    │   │                            apps.connections.open; wraps franky.ai.http)
    │   ├── socket_mode.zig         (websocket.Client wrapper, ack pump,
    │   │                            reconnect/backoff loop)
    │   ├── events.zig              (parsed event union: app_mention, im, slash, …)
    │   └── mrkdwn.zig              (later: markdown→mrkdwn shim if needed)
    ├── bot.zig                     (top-level Bot struct, work queue, drain pool)
    ├── session_map.zig             ((team, thread) ↔ ULID, persistent JSON)
    ├── agent_cache.zig             (LRU of franky.agent.Agent keyed by ULID)
    ├── stream_subscriber.zig       (the §7 throttler + chat.update emitter)
    └── tools.zig                   (registers franky tools, swaps bash for stub)
```

Single binary (`franky-do`); subcommands routed by argv[1].

---

## §14 Phase plan / status (detail)

### Phase 0 — skeleton

Scope:

- `build.zig.zon` declaring two deps:
  - `franky` as a path dep (`../franky`)
  - `websocket.zig` as a URL dep (pinned to a git commit hash)
- `build.zig` wiring both into a single `franky-do` executable
- `src/main.zig` smoke: parses `--version`, prints
  `franky-do <ver> (franky <ver>, websocket.zig <ver>)`, returns
- All subsequent phases gated on this building clean

Deliverable: `zig build` produces `zig-out/bin/franky-do`;
`./zig-out/bin/franky-do --version` succeeds.

### Phase 1 — Web API client

Scope:

- `src/slack/web_api.zig` exposing typed wrappers over four endpoints:
  `auth.test`, `apps.connections.open`, `chat.postMessage`, `chat.update`
- Reuses `franky.ai.http.fetchWithRetryAndTimeoutsAndHooks` for HTTP
- Smoke CLI: `franky-do _smoke postmsg --channel C... --text "hello"`
- Unit tests against a mock loopback server (same pattern as
  franky's §G.4 phase tests)

Deliverable: `franky-do _smoke postmsg ...` posts a message to a
real Slack channel.

### Phase 2 — Socket Mode

Scope:

- `src/slack/socket_mode.zig` wrapping `websocket.Client`:
  - `connect()`: calls `apps.connections.open`, opens WSS, runs
    handshake with the ticket query string
  - Background read loop via `client.readLoopInNewThread`
  - `serverMessage(data)`: parses JSON, dispatches by `type`,
    sends ACK envelope synchronously
  - `disconnect` handling + reconnect with backoff (§3.4)
- `src/slack/events.zig`: typed event union
- Smoke: `franky-do _smoke listen` connects and logs every event;
  `@`-mention the bot in Slack, see the event in stderr

Deliverable: full Socket Mode round-trip working; bot stays
connected through Slack-initiated reconnects.

### Phase 3 — single-turn bot

Scope:

- `src/agent_cache.zig`: keyed `franky.agent.Agent` instances
- `src/session_map.zig`: in-memory map; persistence deferred to
  Phase 5
- `src/bot.zig`: top-level struct holding socket-mode, agent-cache,
  session-map, web-api
- For each `app_mention`:
  - Resolve thread → ULID
  - Get/create agent
  - `agent.prompt(text)`
  - Synchronous `agent.waitForIdle()`
  - `chat.postMessage` the final assistant text
- No streaming yet; whole response posts at once

Deliverable: bot answers `@`-mentions in any channel it's been
invited to; tools (read/write/edit/ls/find/grep) work; bash is
the stub.

### Phase 4 — streaming + throttling

Scope:

- `src/stream_subscriber.zig`: §7 throttler + `chat.update` emitter
- Replace Phase 3's `waitForIdle` + `chat.postMessage`-after with:
  1. Post initial `_thinking…_` placeholder
  2. Subscribe stream subscriber to the agent
  3. Return; agent loop drives updates until `turn_end`
- Tool calls render as separate threaded messages
- 40k-char split (§7.3)

Deliverable: live streaming responses in Slack with smooth
throttling (no rate-limit 429s under nominal load).

### Phase 5 — persistence + multi-workspace

Scope:

- `src/auth.zig`: `auth.json` round-trip per workspace
- `franky-do install` / `uninstall` / `list` subcommands
- `franky-do run --all` opens N Socket Mode connections in parallel
- `session_map.zig`: persist to `bindings.json` per workspace
- `franky-do reset <thread>` slash command (requires the slash command
  to be configured in the Slack app — operator instruction)

Deliverable: bot survives restart with full session history;
multi-team install works.

### Phase 6+ — bash, OAuth, dashboards

Out of v0.1 scope. Documented separately when we get there.

---

## §15 Testing strategy

### §15.1 Unit tests

- `web_api.zig`: faux loopback server (same `bindLoopback` pattern
  franky uses); each endpoint test posts a known body, asserts the
  request shape (headers, JSON), returns a canned response,
  asserts the parsed result.
- `events.zig`: parse a corpus of real Slack event JSON payloads
  (anonymized) into typed events; assert dispatch.
- `session_map.zig`: round-trip mappings through `bindings.json`.
- `stream_subscriber.zig`: drive synthetic agent events through
  the throttler; assert the number of `chat.update` calls is
  bounded by `(turn_duration / update_min_interval_ms) + 1`.

### §15.2 Integration tests

- `slack_socket_mode_loopback_test.zig`: stand up a mini WSS server
  using `websocket.zig`'s server side, make `franky-do` connect to
  it as a client, exchange a scripted Slack-shape envelope flow,
  verify ACKs match, verify reconnect on close.
- `bot_end_to_end_test.zig`: same WSS loopback + faux LLM provider
  + faux Web API. Send a fake `app_mention`, drive the agent to
  completion, assert the resulting `chat.postMessage` body.

No live-Slack tests in CI. Manual smoke against a real workspace
is the operator's responsibility (and well-documented in README).

### §15.3 What we explicitly do NOT test

- Slack's own rate limits (we trust their docs).
- WSS protocol correctness (`websocket.zig` has 31 of its own tests
  against the protocol).
- Network partitions of arbitrary shape (the spec'd backoff is
  what we ship; pathological cases are out of scope).

---

## §16 Open questions / deferred

- **Slash command security**: `/franky-do reset <thread>` lets
  anyone in the workspace nuke any thread's session. Should we
  scope to thread participants? Phase 5+ decision.
- **Long-running tools**: a `read` of a 256 KiB file is bounded;
  a future `bash` running `cargo build` is not. Tool-output
  streaming via threaded messages is more complex than the
  agent-message streaming and warrants its own design pass.
- **Reactions as control surface**: ❌ to abort, ↩️ to retry,
  ✏️ to edit-and-resend? Tempting; defer until Phase 6+ when we
  have a stable text-only baseline.
- **OAuth install flow**: requires `franky-do` to expose an HTTPS
  endpoint or a CLI-paste flow. Defer until Phase 5+.
- **Log retention**: `franky-do` runs for weeks; logs grow. Add a
  rotating file handler or just expect operator to wire stderr to
  syslog / journald? Operator's call.
- **DM dispatch**: `bot.dispatchSlackEvent` only routes
  `app_mention` (and `reaction_added`) events. `message` events
  with `channel_type: "im"` (DMs) are received but dropped.
  Manifest already subscribes to `message.im`. Phase X follow-up:
  add a `message`/`im` arm that routes to the same
  `mentionWorker` path (≈30 LOC).

### §16.1 Profile system reuse — shipped in v0.3.5

**v0.3.5 status: shipped.** `FRANKY_DO_PROFILE` selects a
profile (settings.json catalog or built-in like `gemini`,
`groq`, `cerebras`, `cloudflare-llama`, etc.); franky's
`profiles.applyProfile` + `print.resolveProviderIo` chain
resolves provider + model + api_key + auth_token + base_url +
context_window + max_output + capabilities in one shot. All
five mode providers (`anthropic-messages`,
`openai-chat-completions`, `openai-compatible-gateway`,
`google-gemini`) are registered in the bot's registry; the
agent dispatches by api_tag.

Precedence for model selection: `--model` CLI flag (cmdRun
only) > `FRANKY_DO_MODEL` env > `FRANKY_DO_PROFILE` →
`profile.model` > built-in default `claude-sonnet-4-5`.

**Pre-v0.3.5 state (kept for back-compat).** Without
`FRANKY_DO_PROFILE` set, `print.resolveProviderIo` falls back
to its standard precedence: `ANTHROPIC_API_KEY` /
`CLAUDE_CODE_OAUTH_TOKEN` env vars → auth.json → no creds. So
existing v0.3.4 invocations keep working unchanged.

**What v0.3.5 ships:** the recommended Option A from the
v0.3 roadmap — `profiles.applyProfile` + `print.resolveProviderIo`
in `cmdRun` and `runForInstalledWorkspace`, all five mode
providers registered in the bot registry, three new optional
`bot.Config` fields (`model_context_window` / `model_max_output`
/ `model_capabilities`) propagated from the resolved
`ProviderInfo`. CLI `--model` flag wins over `FRANKY_DO_MODEL`
env wins over `FRANKY_DO_PROFILE` → profile.model wins over
default — same precedence franky CLI uses.

**Per-workspace profile** (originally an open question for
v0.3): deferred to v0.4. v0.3.5's `--all` path uses one
`FRANKY_DO_PROFILE` for every workspace it spawns. If real
operators want per-workspace profiles (so `T01` uses
`claude-sonnet-4-5` while `T02` uses `gemini`), the
`auth.json` shape would gain a `profile` field and
`runForInstalledWorkspace` would read it. ~30 LOC follow-up
when demand surfaces.

### §16.2 Markdown reply formatting — v0.4 roadmap

**State (v0.2.1).** The system prompt instructs the model to reply
in **plain text** — no markdown headings, no asterisks for bold,
no underscores for italic, no bullet markers. Triple-backtick code
fences are allowed (Slack renders them).

**Why plain text.** Slack's mrkdwn dialect overlaps with standard
markdown but is not a subset:

| Slack mrkdwn | Standard markdown | Renders in Slack? |
|---|---|---|
| `*bold*` | `**bold**` | only the single-asterisk form renders |
| `_italic_` | `*italic*` | only underscores render |
| `### Heading` | (same) | shows as literal `###` |
| `[text](url)` | (same) | shows as literal `[text](url)`; Slack uses `<url\|text>` |
| `* bullet` | (same) | shows as inline `*`, no list rendering |
| `\`\`\`code\`\`\`` | (same) | works |
| `` `inline` `` | (same) | works |

Earlier versions tried prompt-engineering the model into producing
mrkdwn (`Use *bold* (single asterisks). Avoid headings — Slack
doesn't render them.`). Weak open-source models (gemma4 via
Ollama, observed in v0.2.1 testing) ignore those instructions and
emit standard markdown anyway, which Slack renders as literal
punctuation. Plain text always renders correctly regardless of
how well the model follows formatting instructions.

**Goal (v0.4).** Let the model produce standard markdown freely;
**translate to mrkdwn server-side** before posting via
`chat.postMessage` / `chat.update`. This restores light visual
structure (bullets, bold, links) when the model produces it well,
without depending on the model's mrkdwn fluency.

**Translation rules (rough sketch — refine when implementing):**

- `**X**` → `*X*` (de-double asterisks)
- `__X__` → `*X*`
- `*X*` (single, italic) → `_X_` (preserve italic intent)
- `### X` / `## X` / `# X` → `*X*` (treat headings as bold)
- `* item` / `- item` → `• item` (use bullet glyph)
- `1. item` / `2. item` → `1. item` (Slack handles numbered lists)
- `[text](url)` → `<url|text>`
- `<https://...>` → `<https://...>` (passthrough)
- Triple-backtick fences passthrough as-is.
- Inside fenced blocks, **no translation** (preserve code).

**Open design points for v0.4:**

1. **Where the translator lives.** Two reasonable homes:
   - In `stream_subscriber.zig`'s `issueUpdate` — translate the
     accumulated buffer just before each `chat.update`.
     Per-update cost is small (matched-text scan), but every
     update re-translates everything.
   - On a finalize step before `sub.stop()` — translate once at
     end of turn, do a single final `chat.update` with the
     translated text.
   The first preserves streaming look-and-feel; the second is
   cheaper but loses progressive rendering. Probably the first.
2. **Edge cases.** A line beginning with `* ` could be either an
   italic marker mid-sentence (rare) or a bullet (common); the
   translator needs context (line-start position) to disambiguate.
3. **Code-fence detection.** Backtick-fenced regions are sacred
   (no translation inside). Need a tiny state machine for ` ``` `
   open/close.
4. **Tables.** Standard markdown tables don't render in Slack at
   all. Should the translator strip the `|` / `---` separators
   and emit a plain-text version? Or pass through verbatim?
   **Recommendation:** strip; tables-in-Slack are unreadable.
5. **Inline links.** `<url|text>` requires the URL to be safe
   (no unescaped `<` `>` `|` in either side). If a model emits
   a URL with one of those characters, the translator must
   percent-encode it or fall back to plain `text (url)`.

**Estimated effort:** ~80-150 LOC + tests. The translator is
mostly pure text manipulation; tests can be table-driven (input
markdown → expected mrkdwn).

**Why not yet.** Plain text works today. Slack-formatting fidelity
is a polish item, not a blocker. v0.3 should land profile reuse
first (more universal value); v0.4 picks up the translator once
operators ask for richer formatting.

---

## §17 Versioning

`franky-do`'s version is independent from franky's. Version policy:

- v0.x: pre-stable, breaking changes allowed in minor bumps.
- v1.0: ships when phases 0–5 are complete and the bot has been
  running in at least one production workspace for two weeks
  without operator intervention.

The `franky` dependency is pinned in `build.zig.zon` to a specific
revision — bumping franky in `franky-do` is a deliberate change,
not an implicit one.

### Compatibility window

The current cut (`v0.5.1`) requires franky **v1.29.5** for the
`.git/` hard-skip in `ls`/`find` (otherwise a recursive ls or
broad-glob find from a repo root floods the LLM context with git
object hashes). It also still requires the
proxy-UAF fix (any operator running behind `HTTPS_PROXY` will
segfault on franky ≤ v1.29.3 — see CHANGELOG `[0.4.8]` /
franky's `[v1.29.4]` for the diagnosis).

Every franky release in the v1.27.x – v1.29.x window is additive
on the SDK boundary (`franky.sdk` / `franky.ai` / `franky.agent` /
`franky.coding`); franky-do consumes no signature that changed
during that range, so any franky build in that window works.
Specifically:

- **v1.27.x** (truncate.zig, bash spill, grep/read line caps,
  session-dir spill in proxy/rpc) — invisible to franky-do
  because it doesn't drive the modes that surface those.
- **v1.28.x** (subagent firewall + final_text cap, max_subs
  bump) — likewise invisible; franky-do exposes `subagent` to
  Slack users but the cap is provider-side and read-only.
- **v1.29.x** (Diagnostics + trace_id + empty_response +
  reducer dumps, plus `/diagnostics` slash) — additive
  `Message.diagnostics` field, additive `StreamEvent.diagnostic`
  variant (consumed by Reducer, never propagates into
  `AgentEvent` so franky-do's exhaustive switches stay safe),
  additive `errors.Code.empty_response` (logged via `@tagName`
  so it surfaces in Slack stderr without code changes), additive
  `loop.Config.reducer_dump_dir` and `Agent.Config.reducer_dump_dir`
  (defaults to `null` — current `Bot.ensureAgent` literal works
  unchanged).

v0.4.2's only behavioral change: the StreamSubscriber now
**captures** `agent_error{code, message}` and the `message_end`'s
`diagnostics.trace_id`, then composes a Slack reply on the
final flush when accumulated text is empty. See §19 below.

v0.4.3 adds the `--ask-all` / `FRANKY_DO_ASK_ALL` knob (§20)
that flips `franky.coding.permissions.Store.ask_all = true`,
demoting `read`/`ls`/`find`/`grep` from "auto-allow" to "ask".
No franky-core changes were needed — the knob already existed
on the Store from franky's own `--ask-tools all`; we just
exposed it.

---

## §20 Slack-side error rendering (v0.4.2)

When the agent loop emits `agent_error` mid-run, the bot needs
to leave the operator with something more actionable than a ❌
reaction over a forever-stuck `_thinking…_` placeholder. v0.4.2
rewires the StreamSubscriber to compose a real reply text on
the final flush.

### Capture phase

The subscriber gains three optional fields:

| Field | Lifetime | Source |
|---|---|---|
| `last_error_code: ?ai.errors.Code` | run-scoped | `agent_error` event |
| `last_error_message: ?[]u8` | run-scoped, owned | duped from `agent_error.message` |
| `last_trace_id: ?[]u8` | run-scoped, owned | duped from `message_end.diagnostics.trace_id` |

`onEvent` populates `last_error_*` whenever an `agent_error`
fires (last-write-wins; in practice the loop emits exactly one).
It populates `last_trace_id` on every `message_end` (last-write-
wins so the most recent assistant turn's trace is the one
surfaced).

### Render phase

A new `errorReplyText(allocator, code, message, trace_id) ![]u8`
helper composes the Slack message:

- **`code == .empty_response`** → targeted phrasing pointing at
  thinking budget + profile-switch escape hatch.
- **any other code** → generic envelope `provider returned an
  error: <code> — <message>`.
- **trailing footer** when `trace_id` is non-null:
  `\n_trace: <trace_id>_` (italic, monospaced trace id is
  fine via plain Slack-mrkdwn).

### Final flush logic

The timer-loop's terminal flush, before posting, checks:

```
if (accumulated.items.len == 0 and last_error_code != null) {
    accumulated.appendSlice(errorReplyText(...));
}
```

This means happy-path runs are completely unaffected — text
streams in, gets flushed normally, no error path runs.
Only failed runs that produced zero text pick up the new
behavior. Runs that produced *partial* text plus an error
preserve the partial text and skip the error-render (the
operator already has something to read; the ❌ reaction
remains the failure indicator).

### Why subscriber-local

Composition of the error reply could live in `bot.zig`'s
`handleAppMention` instead. Keeping it in the subscriber:

- The subscriber already owns the Slack `chat.update` path; no
  extra `web_api` call needed.
- The subscriber has the lifetime that matches the run (started
  before `agent.prompt`, stopped after `waitForIdle`).
- It avoids a second `chat.update` race against the timer's
  final flush.

The bot still owns the placeholder + final reaction-marking;
only the *body* of an error reply moves to the subscriber.

---

## §18 Reactions-as-control (Phase 7)

A second control surface alongside `@`-mentions and slash commands.
The bot subscribes to `reaction_added` events; two reactions act
on the thread the reacted-to message belongs to:

| Reaction | Slack name | Effect |
|---|---|---|
| ❌ | `x` | Abort the in-flight agent turn for the thread (fires `Agent.abort`). No-op if the agent is idle. |
| ↩️ | `leftwards_arrow_with_hook` | Re-run the last user prompt in the thread (looks up the agent, walks the transcript backwards to the most recent `.user` message, calls `Agent.prompt` with that text). |

Out of scope for v0.1: ✏️ edit-and-resend (needs a Slack modal), 🗑️ delete-session (slash command already covers it).

### §18.1 Event shape

Slack delivers reactions in this shape:

```json
{
  "type": "event_callback",
  "event": {
    "type": "reaction_added",
    "user": "U_REACTOR",
    "reaction": "x",
    "item": {
      "type": "message",
      "channel": "C_CHANNEL",
      "ts": "1700000000.000200"
    },
    "item_user": "U_BOT_OR_USER",
    "event_ts": "1700000001.000300"
  }
}
```

### §18.2 Thread resolution

The reacted-to message's `item.ts` may be either the user's
mention or the bot's reply. Either way, we look up the active
session for the thread:

1. If `(team_id, item.ts)` is a known thread anchor in
   `session_map`, use it directly.
2. Otherwise, treat `item.ts` as a `thread_ts` candidate — same
   lookup. The bot's reply usually lives inside the thread it's
   answering, so the `thread_ts` of the reacted message would be
   the user's mention `ts`. Slack doesn't include `thread_ts` on
   `reaction_added` events directly, so we fall back to `item.ts`
   and tolerate the lookup miss.

If neither matches, the reaction is logged at debug level and
dropped — not every reaction in a channel concerns us.

### §18.3 Scopes + event subscription

`TESTING.md` Step 3 OAuth scopes gain `reactions:read`. Step 4
event subscriptions gain `reaction_added`. Existing installs need
to re-authorize after adding the scope (Slack admin UI: *Install
App → Reinstall to Workspace*).

### §18.4 Audit

Every reaction-driven action posts a small system message in the
thread (`✋ aborted by @U_REACTOR` / `↩️ retrying last prompt`) so
participants see what happened. Doing it silently would be
confusing — the thread state changed without an apparent cause.

---

## §19 Cost / token dashboards (Phase 8)

Token usage already lives on every assistant message
(`franky.agent.loop.Transcript.messages[i].usage = { input, output, cache_read, cache_creation }`).
Phase 8 surfaces it.

### §19.1 `franky-do stats` CLI

```
franky-do stats                 # all installed workspaces, per-thread breakdown
franky-do stats --workspace T0  # one workspace
franky-do stats --total         # workspace totals only (no per-thread rows)
franky-do stats --json          # machine-readable
```

Walks `$FRANKY_DO_HOME/sessions/*/transcript.json`, sums input +
output tokens per session, joins via each workspace's
`bindings.json` to map back to `(team, thread_ts)`. Renders a
Markdown-style table to stdout:

```
team_id        thread_ts                input    output     cost
T0123456       1700000000.000200       12,300     2,150   $0.064
T0123456       1700000050.000600        4,500     1,200   $0.024
T0123456       (TOTAL)                 16,800     3,350   $0.088
```

Cost uses a hardcoded pricing table — see §19.3 — and falls back
to "n/a" for unknown model ids.

### §19.2 `/franky-do stats` slash command

In-Slack visibility. Posts a Markdown summary into the slash
command's invoking channel:

```
*franky-do stats — workspace T0123456*
> 7 threads, 142.3k input / 28.5k output tokens
> Total est. cost: $0.74
> Most active: <thread link> (45.1k tokens)
```

Per-thread rows are *not* emitted by default to avoid spamming
channels with long tables; the operator can pipe `franky-do
stats` into a file and share that.

### §19.3 Pricing table

Hardcoded in `src/pricing.zig`. Per-million-token pricing for
Anthropic models the bot is likely to use:

| Model id pattern | Input ($/MTok) | Output ($/MTok) |
|---|---|---|
| `claude-opus-4-*` | 15.00 | 75.00 |
| `claude-sonnet-4-*` | 3.00 | 15.00 |
| `claude-haiku-4-*` | 1.00 | 5.00 |

Falls back to the empty entry (cost = "n/a") on no match. Pricing
will drift; the table is meant to be edited as needed. OpenAI and
Google entries are post-Phase-8.

### §19.4 What we don't track

- Cache discounts (the `usage.cache_read` field is summed in but
  not priced separately — assume the simple flat input/output rate).
- Per-user attribution. Slack `user` is on the *prompt*, not on
  every message; multi-user threads don't preserve who-asked-what
  beyond the transcript text.
- Real-time spend caps. If you need that, watch `franky-do stats
  --json` from cron and act on it.

---

## §21 Permission overlay knobs (v0.4.3)

The default `franky.coding.permissions.Store` policy
auto-allows `read`/`ls`/`find`/`grep` and prompts only for
`write`/`edit`/`bash`. Some operators want a "prompt for
everything" mode — useful when running franky-do against an
untrusted Slack channel or during a security review.

### `--ask-all` / `FRANKY_DO_ASK_ALL`

v0.4.3 exposes a single bit on the Store:

| Surface | Wins over | Effect |
|---|---|---|
| `--ask-all` flag | env var | sets `Store.ask_all = true` |
| `FRANKY_DO_ASK_ALL=1` (or `=true`) | nothing | sets `Store.ask_all = true` |
| (neither set) | n/a | preserves default-auto_allow behavior |

When on, the read-family tools demote to "ask" and surface the
same yellow Slack prompt with the same ✅/⏩/❌/🚫 reaction
UX as `write`/`edit` already do. `always_allow` entries (and
the ⏩ reaction) still take precedence — flipping a tool to
"always allow" once silences subsequent prompts for that tool
just like before.

The flag is local to `franky-do run` (single-workspace mode);
the multi-workspace `--all` path honors only the env var since
it has no per-workspace flag surface.

### What's not exposed yet

The CSV-driven equivalents — `--allow-tools <csv>`,
`--deny-tools <csv>`, `--ask-tools <csv>` — remain post-1.0
follow-ups. They map cleanly onto the same `Store` API
(`addToolEntry(.allow|.deny|.ask, name)`); the v0.4.3 cut just
ships the all-or-nothing knob since that's the most common
operator request and it's a one-line wire.

### Startup confirmation

Both `cmdRun` and `cmdRunAll` now log an `ask_all=…` field on
the permission-store-ready line so a quick run confirms the
state without grepping `permissions.json`:

```
permissions store ready remember=yes ask_all=yes path=/home/agent/.franky-do/permissions.json
```

`yes` = read-family tools will prompt. `no` = default behavior.

### `--http-trace-dir` / `FRANKY_DO_HTTP_TRACE_DIR` (v0.4.7)

Mirror of franky CLI's flag — when set, every provider HTTP
call dumps the full request + response to a file at
`<dir>/<unix_ms>-<seq>-<provider>.txt`. Required for
post-mortem on the v1.29.0 `empty_response` failures (Gemini
returning `STOP` with thinking tokens but no content tokens),
and the `Message.diagnostics.trace_id` field on saved
messages points at the exact filename so the `:mag:`-reaction
diagnostics report shows the path inline.

| Surface | Wins over | Effect |
|---|---|---|
| `--http-trace-dir <DIR>` flag | env var | `stream_options.http_trace_dir = <DIR>` |
| `FRANKY_DO_HTTP_TRACE_DIR=<DIR>` | nothing | same |
| (neither set) | n/a | tracing disabled |

The flag is local to `franky-do run` (single-workspace mode);
the multi-workspace `--all` path honors only the env var
(same precedence pattern as `--ask-all`).

Startup confirmation:

```
[info] franky-do http_trace dir=/Users/.../.franky-do/log-trace
```

(falls to debug level when null)

---

## §22.5 Long-reply file-attachment fallback (v0.3.8 + v0.4.10 fix)

When a streamed reply accumulates past `cfg.overflow_threshold_bytes`
(default 3500), Slack's `chat.update` rejects it with `msg_too_long`
or silently truncates. v0.3.8 added the file-attachment fallback:
the bot updates the placeholder with a `_reply too long for chat —
full content in the attached file ↓_` preamble and uploads the
full text via Slack's 3-step `files.uploadV2`:

1. `files.getUploadURLExternal` → `{upload_url, file_id}`
2. `POST <upload_url>` (multipart/form-data with the bytes)
3. `files.completeUploadExternal` → finalizes + posts file in
   thread

### v0.4.10 — `files:write` scope + defensive fallback

Real-user incident:

```
+607183 INFO  reply size 4296B exceeds threshold 3500B → switching to file attachment
+607880 WARN  files.uploadV2 failed: SlackApiError slack_error=invalid_arguments bytes=4296
```

User saw the preamble but no file attachment. Two root causes,
both produce Slack's deceptively generic `invalid_arguments`:

1. **Missing `files:write` OAuth scope** — `slack-app-manifest.yaml`
   pre-v0.4.10 listed `chat:write`, `reactions:write`, etc. but not
   `files:write`. v0.4.10 adds it. **App reinstall required
   when upgrading from v0.4.9 or earlier** — Slack doesn't grant
   new scopes on existing tokens.
2. **Bot not invited to the channel** — `app_mentions:read` lets
   the bot *receive* mentions but not *upload files* into a
   channel it hasn't been invited to. Operator fix:
   `/invite @franky-do` per channel.

### Defensive fallback (v0.4.10)

When upload still fails (after the install is corrected), or
during the transition while operators are reinstalling, the
bot now does NOT leave the user with just the preamble.
`uploadOverflow`'s catch arm invokes a new
`fallbackToTruncatedInline(content, slack_err)` that posts the
first ~3000B inline as a `chat.update` with a clear
self-explanatory footer:

```
…<reply content, capped at 3000 chars>…

_…truncated (1296B more). File attachment failed:
`invalid_arguments` — check `files:write` scope and
`/invite @franky-do` in this channel._
```

Best-effort: the fallback `chat.update` doesn't need
`files:write` scope, so it succeeds when the upload fails for
scope-related reasons. The `overflowed_to_file = true` flag
that `uploadOverflow` already set blocks subsequent flushes
from racing the fallback.

### Operator runbook for reinstall

When upgrading from v0.4.9 or earlier:

1. Pull v0.4.10 + rebuild.
2. Push the updated `slack-app-manifest.yaml` via the Slack
   app dashboard's "Manifest" tab (Settings → App Manifest).
3. Reinstall the app to your workspace (required for the new
   `files:write` scope).
4. `/invite @franky-do` in each channel where you use the
   bot (one-time per channel; existing tokens stay valid for
   already-granted scopes — only the new one needs the
   reinstall).
5. Restart the bot process.

Verification: have the agent produce a long reply (`@franky-do
explain the architecture in detail`); it should land as a
`reply.txt` attachment in the thread instead of the inline
preamble + truncated-tail fallback.

---

## §22 Permission-prompt UI: Block Kit buttons (v0.4.4)

The reaction-driven prompt UI from v0.3.3 (✅ ⏩ ❌ 🚫 emoji
seeds + counter pips) is gone. v0.4.4 replaces it with four
interactive Block Kit buttons. Single-click resolution, no
emoji legend, no ambiguity about which user clicked, and the
buttons disable themselves once the choice has been made.

### Wire format

`chat.postMessage` body now carries a `blocks` array:

```jsonc
[
  // Header
  {
    "type": "section",
    "text": {
      "type": "mrkdwn",
      "text": ":warning: *Permission required*\nThe agent wants to call `find`"
    }
  },
  // Args preview (capped at 1024 chars; over-long → "…(truncated)")
  {
    "type": "section",
    "text": {
      "type": "mrkdwn",
      "text": "```\n{\"pattern\":\"**/*.markdown\"}\n```"
    }
  },
  // Action row
  {
    "type": "actions",
    "block_id": "perm_actions",
    "elements": [
      { "type": "button", "text": {"type":"plain_text","text":"Allow Once"},   "value":"allow_once",   "action_id":"perm:gcall-0:allow_once" },
      { "type": "button", "text": {"type":"plain_text","text":"Always Allow"}, "value":"always_allow", "action_id":"perm:gcall-0:always_allow", "style":"primary" },
      { "type": "button", "text": {"type":"plain_text","text":"Deny Once"},    "value":"deny_once",    "action_id":"perm:gcall-0:deny_once" },
      { "type": "button", "text": {"type":"plain_text","text":"Always Deny"},  "value":"always_deny",  "action_id":"perm:gcall-0:always_deny",  "style":"danger" }
    ]
  }
]
```

The fallback `text` field still ships (`Permission required:
<tool> — open in Slack to allow or deny.`); Slack uses it for
notifications, screen-readers, and clients that don't render
blocks.

### Action ID format

`perm:<call_id>:<resolution>`

The `block_actions` payload returns the same `action_id` we
attached to the button. `slack_prompts.parseActionId(action_id)`
splits it back into a `(call_id, Resolution)` tuple so
`Bot.dispatchInteractive` can route directly to the existing
`prompts.tryReactionResolve` path. No second lookup needed.

### Socket Mode wiring

Slack delivers `block_actions` payloads via the existing Socket
Mode WSS connection as `interactive` envelopes. franky-do's
socket-mode dispatch table grew a new arm:

```zig
.events_api    => bot.dispatchSlackEvent(...)
.slash_commands => bot.dispatchSlashCommand(...)
.interactive   => bot.dispatchInteractive(...)   // v0.4.4
```

`Bot.dispatchInteractive` parses the envelope (typed:
`InteractiveEnvelope` with just the fields we route on), pulls
`payload.actions[0]`, calls `parseActionId`, then drives the
existing atomic-resolution path through
`prompts.tryReactionResolve(channel, message_ts, user_id,
resolution)`.

### Post-resolution `chat.update`

Once resolved, the bot rewrites the prompt message to disable
further interaction:

- Same first two section blocks (header + args).
- Action row replaced with a single `context` block:
  `:white_check_mark: Always allowed — chosen by <@U…>`
  (emoji + label varies by resolution).

This requires the entry to carry `tool_name` + `args_json`
beyond the request lifetime, so `prompts_state.PromptEntry`
gained both fields (owned dups, freed alongside the entry).
The `ReactionOutcome.resolved` variant surfaces them as owned
slices for the caller's `chat.update` — a single
`prompts.tryReactionResolve` call returns everything the
update needs.

### Why buttons, not radio buttons

The original design draft used `radio_buttons` inside an `input`
block. That UX is two clicks (pick + Submit) and shows a
"required" submit button with no per-choice styling. Plain
buttons fire `block_actions` immediately on click and let each
choice carry its own `style` ("primary" green for the always-
allow, "danger" red for always-deny) which preserves the
v0.3.x emoji-color intuition.

### Interaction with other reactions

- `:x:` reactions on a *prompt message* still short-circuit so
  they don't fall through to `Bot.abortThread`. The handler
  ignores them at debug level (the buttons are authoritative).
- `:x:` and `↩️` (`leftwards_arrow_with_hook`) reactions on
  *non-prompt* messages still drive abort/retry as before.
- The bot no longer seeds any reactions on the prompt message
  — Slack delivers no `reaction_added` events back to us for
  prompts.

### What didn't change

- `prompts.tryReactionResolve` keeps its name even though the
  caller is now buttons, not reactions. The function's
  implementation only takes a pre-decoded `Resolution`; the
  reaction-vs-button distinction is purely upstream. Renaming
  would mean churning every test that drives this path; the
  comments in v0.4.4 reflect the new semantics.
- Timeout auto-deny still fires at `FRANKY_DO_PROMPT_TIMEOUT_MS`
  (default 10 min) and posts the same `:hourglass_flowing_sand:
  no response — denied; ask again to retry` message.
- `--ask-all` and `FRANKY_DO_ASK_ALL` (v0.4.3) are unchanged;
  they still demote read-family tools to "ask" and the buttons
  surface for those calls just like for write/edit/bash.

### Slack app manifest

`slack-app-manifest.yaml` already declares
`features.interactivity.is_enabled: true` (carried over from
v0.3.x for the slash-commands feature). Existing installs work
without any manifest edits. New installs use the same manifest
shape.

---

## §23 In-thread diagnostics via `:mag:` reaction (v0.4.5)

Slack platform constraint: developer slash commands cannot be
invoked from inside threads. Only specific Slack-built-in
commands like `/giphy` are exempt; everything else (including
the franky-do `/franky-do …` family) only fires from top-level
channel input. This has been the case since 2018, surfaced in
both the official Slack Developer docs and a long-running
public feature request on @SlackHQ.

v0.4.5 works around the constraint with a reaction trigger,
piggybacking on the existing `reaction_added` Events API
subscription that the bot already has scoped (no new OAuth
scopes; no manifest edits).

### The trigger

React `:mag:` (🔍) on the original `@`-mention OR on any of the
bot's replies in the thread. Either resolves the same way
(`Bot.resolveReactionThread` walks the reply-anchor cache for
bot-message reactions; the original-mention case resolves
directly).

### Behavior

1. `Bot.dispatchReaction` now recognizes three reactions:
   `:x:` → abort, `:leftwards_arrow_with_hook:` → retry,
   `:mag:` → diagnostics. The first two are unchanged; the
   third routes to `runDiagnosticsReaction(team_id, channel,
   thread_ts, reactor, ulid)`.
2. The handler computes the team's session-parent dir
   (`<home>/workspaces/<team>/sessions/`) and calls
   `franky.coding.session.load(parent, ulid)` to read the
   persisted `session.json` + `transcript.json` for that
   thread.
3. Calls `franky.coding.diagnostics.runAndPersist(...)` with:
   - `transcript = loaded.transcript.messages.items`
   - `http_trace_dir` = whatever `--http-trace-dir` resolved
     to at startup (passed through `cfg.stream_options`)
   - `session_dir` = full `<parent>/<ulid>` so the analyzer's
     reducer-dump pointer hints render correctly
   - `session_label` = the ulid
   - `mode_name = "franky-do"`
   - `persist_opts = { franky_home: ~/.franky-do, session_id:
     ulid, timestamp_ms: now }`
4. Posts the rendered report as a thread reply via
   `chat.postMessage` with `thread_ts` set. Body shape:

   ```
   ```                                <-- fenced code block (preserves whitespace + monospaces)
   === franky diagnostics ===         <-- analyzer header
   mode:        franky-do
   session:     01JXYZ…
   trace dir:   /tmp/franky-trace      <-- if --http-trace-dir is set
   reducer dir: <home>/workspaces/T0/sessions/01JXYZ
   transcript:  4 assistant turns / 9 messages

   Per-turn:
     #1  ts=...  stop=stop  blocks=text:1  parts=2 cand=12 …
     #2  ts=...  stop=tool_use  blocks=text:1,toolCall:1  …
     ...

   Summary: 0 anomaly across 4 turns
   (all turns clean)
   Reference: docs/reference/diagnostics.md
   ```
   _saved: /Users/.../.franky-do/diagnostics/01JXYZ/1777498943846.txt_
   ```

   Code fence + italic footer give Slack-mrkdwn a clean
   single-pane render. The persisted-path footer lets
   operators `cat` the file later (the report is preserved
   verbatim on disk).

### Source-of-truth selection (v0.4.6 fix)

**v0.4.5 originally read disk-only.** That was wrong:
franky-do persists sessions only on **hibernation eviction**
(per v0.3.1), not after every turn. A live, recently-active
thread never has a `transcript.json` on disk, so `session.load`
returned `SessionNotFound` and the empty-state message fired
even when there was clearly an active session. **v0.4.6
fixes this** by selecting the source based on agent-cache
state:

| State | Source | Rationale |
|---|---|---|
| Cached + idle | live `agent.transcript.messages.items` | Worker is joined between turns (`Agent.waitForIdle`); slice read is consistent |
| Cached + streaming (`agent.is_streaming.load(.acquire)`) | (refuse) | Mid-turn — in-memory races with worker appends, disk would be stale |
| Not cached | `franky.coding.session.load` from disk | Hibernated session — eviction wrote `transcript.json` atomically |
| Neither | (empty-state message) | Thread has no persisted session yet |

The mid-turn refusal posts a small italic message:
> `_agent is mid-turn; react :mag: again after the run finishes_`

The not-cached + not-on-disk case keeps the original v0.4.5
empty-state message:
> `_no persisted session for this thread (yet); mention me to
> start one and try the :mag: reaction again_`

The source-agnostic body lives in
`runDiagnosticsForTranscript(team_id, channel, thread_ts,
ulid, transcript: []const ai.types.Message)` so both branches
share one renderer/post pipeline.

### Empty-state path

`session.load` fails when the thread has no persisted session
yet (typically: an operator clicks `:mag:` on a non-bot message
or before mentioning the bot in this thread). The handler
catches the error and posts a friendly italic message instead
of failing silently:

> `_no persisted session for this thread (yet); mention me to
> start one and try the :mag: reaction again_`

### Where the report file lives

`~/.franky-do/diagnostics/<ulid>/<unix_ms>.txt`

- `<ulid>` is the thread's session id (same one the
  workspaces-dir already uses).
- `<unix_ms>` is wall-clock at click time. Each click writes
  a fresh file rather than overwriting; clicking `:mag:` on
  the same thread three times yields three timestamped files.
- Best-effort: a write failure surfaces in the report's
  footer (`_saved skipped: ..._`) but doesn't fail the
  command.

### What the reply does NOT do

- Does NOT enter the agent's transcript. The reply is a
  bot-side `chat.postMessage` exactly like the existing
  `/franky-do stats` reply. The model never sees it; the next
  `@`-mention's context is unaffected.
- Does NOT abort, retry, or otherwise mutate the agent. Pure
  read.
- Does NOT consume the reaction. Slack still records the
  `:mag:` on the message; later operators can scan a thread
  for `:mag:` reactions to find prior diagnostic clicks.

### `/franky-do help` updated

Help output now lists all three reactions plus a single-line
explanation of why slash commands aren't available in threads,
so operators discover the `:mag:` trigger from the same place
they discover `:x:` (abort) and `:leftwards_arrow_with_hook:`
(retry).

### Why not Block Kit shortcuts (modals)?

Considered. Pros: works in threads via the "shortcuts" UI in
the message-overflow menu. Cons: requires a new manifest
shortcut declaration, requires users to discover the
shortcut menu (`+` icon in some clients, three-dot menu in
others), and triggers a modal flow that's overkill for a
read-only report. Reactions are zero-discovery for any
operator who already knows about `:x:` (abort) — they're an
in-bounds extension of the same interaction model. Shortcuts
remain a sensible v1.0 addition.

---

## §24 postMessage-only flow (v0.5.0)

Up to v0.4.x, every turn of a multi-turn run streamed into a
single Slack bubble — a placeholder posted at `@`-mention
time, repeatedly mutated via `chat.update`. Slack orders
messages by *post* timestamp (not edit timestamp), so the
answer ended up at the placeholder's slot — ABOVE all the
tool-permission prompts that fired between turns. Four
iterations in v0.4.12-v0.4.14 tried to fix this without
giving up the throttled-update model:

| Iteration | Trigger for "new bubble" | Why it didn't satisfy |
|---|---|---|
| v0.4.12 #1 | `message_end{stop_reason=tool_use}` | Gemini returns `STOP`, never `tool_use` → no-op |
| v0.4.12 #2 | post-run repost | Placeholder still mutates DURING the run |
| v0.4.13 | `tool_execution_end` | Doesn't split adjacent assistant messages |
| v0.4.14 | assistant `message_start` past the first | Works, but the swap state machine is still complex (timer thread + mutex + flag + idempotency + HTTP-inside-onEvent + ownership rules for `reply_ts`) |

After v0.4.14 shipped the user requested a clean break: drop
the entire update path. v0.5.0 is the result.

### The new contract

- **No placeholder post.** The 💭 reaction on the user's
  `@`-mention is the "still working" indicator until the
  first response arrives.
- **No `chat.update` from the streaming path.** Every assistant
  response becomes a fresh `chat.postMessage` at
  `message_end{role=.assistant}`. (`web_api.zig.chatUpdate`
  survives because the §11 permission-prompt button-disabling
  flow still uses it; that's an unrelated concern.)
- **No timer thread, no mutex, no throttling.** `onEvent` runs
  on the agent's worker thread (single-threaded) and calls
  Slack synchronously. One post per assistant message ⇒ no
  rate-limit risk; no need to coalesce.

### Per-message lifecycle

```
message_start{role=.assistant}  → accumulated.clear()
message_update.text             → accumulated.append(delta)
message_end{role=.assistant}    →
    if accumulated.len > overflow_threshold (3500): files.uploadV2()
    else if accumulated.len > 0:                    chat.postMessage()
    accumulated.clear()
agent_error                     →
    flushAssistantMessage()  // partial text first, if any
    chat.postMessage(errorReplyText(code, message))
```

Tool-only assistant messages (no text deltas) produce no post.
Tool-result messages (`role == .tool_result`) are ignored
entirely.

### Subscriber state (`StreamSubscriber`)

```
allocator, io, api, channel, thread_ts, cfg
accumulated: ArrayList(u8)              // per-message text buffer
last_error_code, last_error_message     // composed in errorReplyText
post_count: atomic u32                  // tests inspect
posted_ts: ArrayList([]u8)              // drained by bot.zig for anchors
```

That's it. No `reply_ts`, no `dirty`, no `done`, no swap
counters, no flags. About 350 lines of Zig (vs ~1300 at
v0.4.14) including five tests.

### Bot side (`bot.zig`)

Inside `handleAppMention`:

```
var sub = stream_sub_mod.StreamSubscriber.init(...);  // cannot fail
defer sub.deinit();
const sub_id = try agent.subscribe(...);
defer agent.unsubscribe(sub_id);

try agent.prompt(text);
agent.waitForIdle();

// Drain posted bubbles into the reply-anchor cache so
// reactions on bot replies still resolve to the thread.
for (sub.posted_ts.items) |ts| {
    self.recordReplyAnchor(team_id, ts, thread_ts) catch {};
}
```

No `start()`/`stop()`. No placeholder post. No `BotError.PostMessageFailed`.

### Synchronous-HTTP-inside-onEvent

`flushAssistantMessage` blocks the agent's worker thread for
one HTTP round-trip (~200-500 ms) per assistant message. The
agent's event channel buffers events while we're inside
`onEvent`, so back-pressure is bounded — the worker doesn't
progress until the subscriber returns.

For long replies that take the file-upload path, the worker
blocks for ~1.5-3s (3 round-trips for `files.uploadV2`).
That's tolerable: long replies are the minority case, and
the user already perceives the model latency as the
dominant wait.

### Failure modes

- **`chat.postMessage` fails** → log warn, drop the post,
  next assistant message starts fresh. The 💭/❌ reaction
  is the user's only signal that *something* happened.
- **`files.uploadV2` fails** → fall back to truncated inline
  `chat.postMessage` with a footer pointing at the most
  likely fix (missing `files:write` scope or bot not in
  channel). Same as v0.4.10's `fallbackToTruncatedInline`,
  carried forward.
- **`agent_error` before any `message_end`** → the partial
  text in `accumulated` is flushed as one bubble, then the
  composed error envelope as a second bubble.

### What stays unchanged

- **Status reactions** (👀/💭/✅/❌) on the `@`-mention.
  Still attached by `ReactionsSubscriber` to
  `user_message_ts`; v0.5.0 doesn't touch this path.
- **Reply anchor cache.** Now keyed on each posted bubble's
  ts (the subscriber's `posted_ts` list, drained by
  `bot.zig` after `waitForIdle`). Step 1 of
  `resolveReactionThread` (react on the `@`-mention) is the
  always-works fallback.
- **Permission prompts** (§Phase 2). Wholly separate code
  path; still uses `chat.update` to disable buttons after
  a click.
- **Long-reply file-attachment fallback** (§22.5). Now
  applied per-message at post time instead of mid-stream.
- **Compatibility window.** Now requires franky **v1.29.5** for
  the `.git/` hard-skip in `ls`/`find`, on top of v1.29.4's
  proxy-UAF fix and the `Message.diagnostics` field (currently
  unused in v0.5.x but kept by `web_api.zig` for the
  `--http-trace-dir` plumbing).

### Cost: no partial visibility

The visible UX trade-off: with Gemini taking 5-30s to start
emitting text (its `thinkingBudget` consumed first), the
user sees nothing in the thread except the 💭 reaction
during that window. The 💭 was always the authoritative
"still working" signal — it's why we add it. v0.5.0 just
makes it the *only* signal during pre-emit.

For users who want to see streaming progress, the answer is
to use a faster model (`/franky-do model anthropic`) or
lower the thinking budget — the same answer that applied
under v0.4.x's throttled-stream model, since 750 ms
throttle plus 5-30s pre-emit produced the same long quiet
window anyway.
