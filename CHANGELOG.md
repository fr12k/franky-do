# Changelog

## [0.5.4] — 2026-04-29 — Fix prompt-timeout thread leak

A real-world DebugAllocator run reported 9 leaks across 3
resolved permission prompts:

- 3× `TimeoutArgs` heap allocation
- 3× duped `channel` string
- 3× duped `prompt_ts` string

All from `slack/prompts.zig:handleRequest` → `timeoutMain`.
The pattern: `timeoutMain` correctly frees its args via `defer`
on exit — but the function body called `sleepMs(args.timeout_ms)`,
which is the **default 600_000 ms (10 minutes)**. Any prompt
the user resolved via ✅/❌ click resolved the prompt
immediately; its timeout thread kept sleeping for the full 10
minutes regardless. Process exit before that deadline left the
thread parked in `nanosleep`, never reaching its `defer` —
hence the leaked args. The other proxy-related leaks reported
in the same DebugAllocator output are the documented v1.29.4
trade-off (Proxy struct has no destructor; ~100 bytes per HTTP
call, fixed at v2.x), not new bugs.

### Fix

Replace `sleepMs` with an interruptible wait on a shared
wakeup signal:

- New `Orchestrator.cancel: std.Io.Event` (initial state
  `.unset`).
- New `Orchestrator.timeout_threads: std.ArrayList(std.Thread)`
  — joinable handles instead of detached threads, so we can
  actually wait for cleanup at shutdown.
- `TimeoutArgs.cancel: *std.Io.Event` — borrowed pointer to
  the orchestrator's event.
- `timeoutMain` now `args.cancel.waitTimeout(io, .{ .duration =
  ... })` instead of `sleepMs`. Both branches (timeout fired
  vs. canceled) fall through to `tryTimeoutResolve`, which
  was already a no-op for resolved prompts.
- `Orchestrator.stop()` calls `cancel.set(io)` to wake all
  parked threads, then joins them and frees the tracking
  list — so each thread's `defer` runs to completion before
  process exit.

The (now-unused) `sleepMs` helper was removed.

### Drive-by

`stream.zig` and `bot.zig` tests were searching for lowercase
`"in:"` / `"out:"` / `"turns:"` in the usage-summary post body,
but the format string had been edited externally to use capital
labels (`"Token in: N · Token out: M · Turns: K"`). Updated
the assertions to match. **117/117 tests pass.**

### Caveat — process-exit cleanup is best-effort

The DebugAllocator runs at process exit, after `Orchestrator`
deinit. If a future change moves the orchestrator out of the
deinit chain (e.g. a forced shutdown path), parked timeout
threads would leak again. The current shape is safe because
every `handleAppMention` instantiates one orchestrator and
defers `stop` + `deinit` on every exit path.

## [0.5.3] — 2026-04-29 — `/diagnostics` shows provider + model

Pairs with **franky v1.29.6**. The `/diagnostics` report header
now includes the configured provider and model, so anyone
reading a Slack thread's diagnostics output knows immediately
which provider's quirks to suspect (Gemini's thinking-budget
exhaustion vs OpenAI's tool-call shape vs Anthropic's stop
reasons).

### Change

- `bot.zig`'s `runDiagnosticsReaction` now sets
  `Options.provider = self.cfg.model_provider` and
  `Options.model = self.cfg.model_id` when constructing the
  diagnostics options. Both are static for the bot lifetime
  (one provider + one model id pinned per `cmdRun`
  invocation).
- Bumps the franky compat floor to **v1.29.6** for the new
  `Options.provider` / `Options.model` fields.

### Sample header (after this change)

```
=== franky diagnostics ===
mode:        franky-do
session:     01KQFWZ1J248NMNHFK0GAEAB5H
provider:    google
model:       gemini-2.5-pro
trace dir:   /home/agent/.franky-do/log-trace
reducer dir: workspaces/T01FJ263RD1/sessions/01KQFWZ1J248NMNHFK0GAEAB5H
transcript:  54 assistant turns / 109 messages
```

### Bundled franky-side improvements (v1.29.6)

The franky bump ALSO sharpens the per-tool-error hints, which
were being mis-followed by gemini-2.5-pro:

- `edit_no_match` now explicitly tells the model **DO NOT
  widen `old`** (the existing hint said "read the file
  again" and Gemini was reading that as "widen with more
  context" — making it worse on every retry).
- `edit_ambiguous` is the OPPOSITE recovery — widen `old`
  with surrounding context until uniquely matching. Now has
  its own dedicated hint instead of falling through to the
  generic one.
- `write_exists` points at `overwrite: true` AND suggests
  the `edit` tool as an alternative.
- `invalid_args` points at the error message body (which
  always names the bad/missing field).

These show up in `/diagnostics` output the next time the bot
hits one of those errors. See franky's `[v1.29.6]` row for
the full diagnosis.

## [0.5.2] — 2026-04-29 — End-of-run usage summary in Slack

After every `@`-mention completes, franky-do now posts one
trailing bubble of the form `_in: 5400 · out: 1100 · turns: 4_`
so the user can see the LLM cost at a glance without leaving
Slack. No cache_read counts, no dollar figures — just the three
numbers that matter for skimming.

### How it's computed

- `total_input` / `total_output` are summed from
  `Message.usage.{input,output}` on every
  `message_end{role=.assistant}`. The provider parser
  populates `usage` for the assistant turn; tool_result rows
  are synthesized locally and don't carry LLM-side counts, so
  they're skipped naturally.
- `turn_count` increments on every `turn_start` agent-loop
  event — that's once per model round-trip, so a 1-tool run
  reports `turns: 2` (assistant text + tool call, then
  assistant final response), matching operator intuition.
- The summary post fires from `bot.zig` after
  `agent.waitForIdle`, BEFORE the reply-anchor drain — so the
  summary bubble's `ts` also lands in `posted_ts` and gets
  anchored, meaning users can react `:x:` / `:mag:` on it
  too if they want.
- No-op when `turn_count == 0` (e.g. setup error before
  `agent.prompt`). Cleanly silent on those.

### Why no cache_read or cost

The user explicitly asked for in/out/turns only. Cache reads
clutter short-turn summaries and the dollar figure depends on
`pricing.lookup(model_id)` returning a value (not every model
is in the table). The `franky-do stats` subcommand still
covers cost when you want it, including across persisted
sessions.

### Tests

Two new tests in `src/subscribers/stream.zig`:

- `flushUsageSummary posts in/out/turns totals after a multi-turn run`
  — fires `turn_start` + `message_end{usage:{input,output}}`
  twice, asserts `total_input=2000`, `total_output=590`,
  `turn_count=2`. Calls `flushUsageSummary()`, asserts a third
  post landed with body containing `in: 2000`, `out: 590`,
  `turns: 2`, AND no `cache` / `$` substring.
- `flushUsageSummary is a no-op when no turn ran` — bare
  subscriber, no events, summary call ⇒ zero posts.

The bot.zig integration test (`Bot.handleAppMention: end-to-end
posts assistant text per message_end`) updated to expect 2
chat.postMessage calls (answer + summary) instead of 1, and
asserts the summary contains `turns: 1` for a single-turn run.

### Drive-by

Fixed two pre-existing breakages from your file reorg that
landed alongside this work:

- Duplicate `franky_do_slack` struct (one at the top of
  `main.zig` pointing at the new `slack/api.zig` /
  `slack/socket.zig` paths, one further down still pointing
  at the deleted `slack/web_api.zig` / `slack/socket_mode.zig`).
  Dropped the stale one.
- Two unused locals (`prompts_enabled`, `ask_all`) in
  `cmdRun` shadowing the same names that `setupAndRunBot`
  recomputes from the same flags. Replaced with a comment
  noting where the resolution actually happens.

**117/117 tests passing** (was 115; +2).

## [0.5.1] — 2026-04-29 — Enable `bash` tool (gated by Slack prompts)

`bash` was deliberately disabled in the v0.1 cut pending a real
sandbox (§6.4 of the spec listed Docker-per-call, bubblewrap,
and workspace ACLs as the candidate approaches). v0.5.1 enables
it without those, on the basis that the v0.4.4 Slack permission
prompt — Block Kit ✅/❌ on every call, with the actual command
in the prompt body — is sufficient gating for the trusted-Slack-
workspace deployment shape franky-do targets today.

### Changes

- `src/main.zig` tool registry now includes
  `franky.coding.tools.bash.tool()` (the no-state factory).
  No `SessionBashState` is wired today — cwd does not persist
  across calls, and spill files land in
  `/tmp/franky-bash-<call_id>.log`. Per-session state is a
  follow-up.
- Bumps the franky compat floor to **v1.29.5** for the
  `.git/` hard-skip in `ls` / `find` (without it, an LLM-
  driven `ls -R` from repo root floods context with git
  object hashes).
- `franky-do.md` §6.3 row for `bash` flips from ❌ disabled to
  ✅ enabled with a one-line summary of the safety story.
  §6.4 prose rewritten as the "current bash safety model"
  rather than the "why bash is disabled" rationale.

### Safety notes

- `prompts_enabled=true` is the default; only operators in
  trusted Slack workspaces should run with `--no-prompts` /
  `FRANKY_DO_PROMPTS=0`. With prompts off, bash auto-executes.
- The "always allow" button on a bash prompt is keyed on the
  **verb fingerprint** (`rm`, `git`, `find`, etc. — see
  `permissions.fingerprintBash`), not the full command. One
  click of "always allow rm" silences future `rm -rf /` prompts
  too. Treat that button as a per-verb gate.
- Bot's UID bounds reachability. Run as a dedicated unprivileged
  UID with no rights outside the workspace dir.

### Other

- Restored `default_model_id` constant and `resolvePromptsEnabled`
  function in `main.zig` — both had been deleted alongside an
  unrelated `resolveModelId` cleanup but still had live callers
  (compile errors at the same time as this v0.5.1 work).
  `default_model_id = "claude-sonnet-4-5"` matches the prior value.

## [0.5.0] — 2026-04-29 — postMessage-only flow (no placeholder, no chat.update)

The four iterations of v0.4.12-v0.4.14 fixing the chronological-
order bug all kept the underlying assumption: a single
placeholder bubble that gets streamed into via `chat.update`
(plus, eventually, swapped to a fresh bubble per turn). Each
attempt was structurally complex — timer thread, mutex,
throttling, swap state machine, idempotency flag, post-run
cleanup — and the user kept seeing edge cases where the
placeholder mutated visibly during the run. After the
v0.4.14 ship the user requested a clean break: drop the
update path entirely.

### New contract

- **No placeholder.** The 💭 reaction on the user's `@`-mention
  (added by `ReactionsSubscriber`) is the "still working"
  indicator until the first response arrives.
- **No `chat.update` from the streaming path.** Every assistant
  response becomes its own `chat.postMessage` at
  `message_end{role=.assistant}`. (`chat.update` survives in
  `web_api.zig` only because the v0.4.4 permission-prompt
  button-disabling flow still uses it — orthogonal concern.)
- **No timer thread, no mutex, no throttling.** `onEvent` runs
  on the agent's worker thread (single-threaded by
  construction) and calls Slack synchronously inside the event
  handler. One post per assistant message ⇒ no rate-limit risk.

### Per-message lifecycle (replaces v0.4.x throttled streaming)

```
message_start{role=.assistant}  → accumulated.clear()
message_update.text             → accumulated.append(delta)
message_end{role=.assistant}    →
    if accumulated.len > overflow_threshold: files.uploadV2()
    else if accumulated.len > 0:              chat.postMessage()
    accumulated.clear()
agent_error                     →
    flushAssistantMessage()   // partial text first, if any
    chat.postMessage(errorReplyText(code, message))
```

Tool-only assistant messages (no text deltas) produce no post.
Tool-result messages (`role == .tool_result`) are ignored
entirely.

### Removed

| Field / function | Reason |
|---|---|
| `_thinking…_` placeholder post | Redundant with 💭 reaction |
| `chat.update` from streaming path | Whole point of the rewrite |
| Throttle (`update_min_interval_ms`, `poll_ms`) | Not needed for one-post-per-message |
| Timer thread + `start()`/`stop()` | No throttle = no timer |
| Mutex | onEvent is single-threaded |
| `dirty` / `done` / `last_update_ms` / `rate_limit_paused_until_ms` | Throttle plumbing |
| `reply_ts` field + ownership rules | No persistent message to keep updating |
| Swap machinery (`maybeSwapForNewTurn` / `tryPostNewBubble` / `expect_new_turn_swap` / `assistant_message_count` / `swap_count`) | Posts ARE turns now |
| `overflowed_to_file` flag | Was about "this in-place message already spilled" — per-message posts don't have that state |
| `spillToFile` preamble dance | Long messages just `files.uploadV2` directly |
| `rate-limited` pause logic | Failed posts logged + dropped; next post is independent |
| `BotError.PostMessageFailed` | Was thrown only from the placeholder post site |

### Kept

- `errorReplyText` + `last_error_code` / `last_error_message`
  — composing the error envelope is unchanged.
- Long-reply file upload (`files.uploadV2`) — per-post
  threshold check; on failure falls back to truncated
  inline post with scope-hint footer (the v0.4.10 work).
- `recordReplyAnchor` — the subscriber records each
  successful post's `ts` into `posted_ts`; `bot.zig` drains
  it after `agent.waitForIdle` so reactions on bot-posted
  bubbles still resolve back to the thread.
- 💭/✅/❌ via `ReactionsSubscriber` — completely
  untouched, still attached to the `@`-mention message.

### Test coverage

Six tests, all in `src/stream_subscriber.zig`:

- `errorReplyText: empty_response gets the targeted thinking-budget phrasing`
- `errorReplyText: generic code surfaces tag + message`
- `StreamSubscriber: posts one chat.postMessage per assistant message_end`
  — drives 2 assistant messages + 1 tool_result message_start;
  asserts `post_count=2`, `posted_ts` has 2 entries (`POSTED-1`,
  `POSTED-2`), each post body contains its own message's text
  and the `thread_ts`, and no chat.update fired.
- `StreamSubscriber: tool-only assistant message (no text) does NOT post`
- `StreamSubscriber: agent_error posts a composed error reply`
- `StreamSubscriber: partial text + agent_error → two posts (text then error)`
  — asserts the partial text is preserved as its own bubble
  before the error envelope.

`bot.zig` integration test (`Bot.handleAppMention: end-to-end
posts assistant text per message_end`) updated to assert
exactly one `chat.postMessage` and zero `chat.update` calls
during a single-turn run.

### Trade-offs you asked about

- **No partial visibility during a turn.** With Gemini taking
  5-30s to start emitting text, the user sees only the 💭
  reaction during that window. The 💭 was always the
  authoritative "still working" signal (it's why we add it).
- **Ordering is automatic.** Each post lands in the thread at
  `now()`, after any tool prompts that came before it. The
  whole reverse-chronological-order class of bug from v0.4.12
  is gone by construction.

## [0.4.14] — 2026-04-29 — Per-turn split via assistant `message_start`

v0.4.13's `tool_execution_end` trigger was correct but
indirect: it only fired the swap when a tool call sat between
two assistant messages. The user's actual ask was simpler —
**every** LLM response should be its own Slack bubble, full
stop. Restructured around the cleaner invariant.

### Trigger change

The swap now arms on every assistant `message_start` past the
first, instead of every `tool_execution_end`:

| | v0.4.13 | v0.4.14 |
|---|---|---|
| Counter | `tool_execution_count` | `assistant_message_count` |
| Increments on | `.tool_execution_end` | `.message_start` (only when `role == .assistant`) |
| Arms `expect_new_turn_swap` when | always (per tool_execution_end) | `assistant_message_count > 1` |

Functionally equivalent for the common case (tool calls
between turns), but correct for the edge case where two
assistant messages appear back-to-back without a tool result
in between (provider retry, refusal continuation, etc.).
Conceptually it's also a better mental model: "each LLM
response gets its own bubble" maps directly to "each
assistant message_start past the first mints a new bubble".

`message_start` is dispatched-on for `role == .assistant`
only — the agent loop also emits `message_start` for
synthesized `tool_result` messages (`franky/src/agent/loop.zig:545`),
which must NOT bump the counter.

### Dropped surface

- `tool_execution_count` field — was only consumed by the
  v0.4.13 parallel-tools idempotency test, which is no longer
  meaningful (one `message_start` per assistant message
  regardless of tool count, so idempotency is structural).
- `tally_server.update_bodies` — leftover instrumentation
  from the v0.4.12 attempt-1 tests; written and freed but
  never read by any assertion. Removed along with the
  matching deinit + dupe.

The swap mechanic itself (`maybeSwapForNewTurn` +
`tryPostNewBubble`) is unchanged — same chat.update-then-
chat.postMessage pair, same ownership rules, same fallback to
streaming-into-old-bubble on HTTP failure.

### Test coverage (3 swap tests, replacing v0.4.13's 3)

- `second assistant message_start + text_delta swaps to a new bubble` —
  fires `.message_start{.assistant}` + text + `.message_start{.tool_result}`
  + `.message_start{.assistant}` + text. Asserts
  `assistant_message_count=2`, `swap_count=1`, `post_count=1`,
  new bubble body contains the second message's first delta,
  final `chat.update` targets the new ts with second
  message's content only.
- `single-message reply does NOT trigger a swap` — sanity
  check: one `message_start{.assistant}` ⇒ no swap.
- `tool_result message_start does NOT count as an assistant message` —
  regression guard for the role filter.

### bot.zig

No call-site changes. Only the trailing comment near
`agent.waitForIdle` was updated to reference the new trigger.

## [0.4.13] — 2026-04-29 — Per-turn split via `tool_execution_end` (provider-agnostic)

v0.4.12's post-run repost wasn't enough: the placeholder still
mutated with multi-turn text during the run (every
`chat.update` fired by the throttled timer), so the user saw
the answer evolve in the FIRST message at the top of the
thread, with tool prompts below — the very ordering they were
trying to escape. The repost helped at the END of the run but
the in-flight UX was still confusing.

**Per-turn split, take 2.** Each LLM response (turn) now
becomes its own Slack `chat.postMessage` bubble, in
chronological order between the tool prompts. The mechanism is
the same as the originally-attempted v0.4.12 (swap on first
text_delta of a new turn) but with a **provider-agnostic
trigger**: `tool_execution_end` (an agent-loop event) instead
of `message_end{stop_reason=tool_use}` (a provider-specific
detail that Gemini doesn't emit).

### What fires the swap

`StreamSubscriber.onEvent`'s `.tool_execution_end` arm now
sets `expect_new_turn_swap = true` (under the mutex). The flag
is idempotent: parallel-tool runs that emit 3
`tool_execution_end` events before the next text_delta still
cause exactly ONE swap — the second and third sets are no-ops.

The first text_delta after the flag is set runs
`maybeSwapForNewTurn(t.delta)`, which under-the-mutex:

1. Snapshots `accumulated` and `reply_ts`. Clears the flag.
2. Outside the mutex, `chat.update` the OLD reply_ts with the
   snapshot (final-flushes the previous turn's bubble at its
   true terminal text).
3. `chat.postMessage` a fresh bubble in `thread_ts` using
   `t.delta` as the initial body (so we don't need an
   immediate follow-up `chat.update` AND so Slack's
   "empty text" rejection doesn't apply).
4. Re-takes the mutex; swaps `reply_ts` (frees old, stores
   new), resets `accumulated` to `[t.delta]`, sets
   `dirty=false`. Also clears `overflowed_to_file`
   so a previous turn's file-attachment fallback doesn't gate
   the new bubble's updates.

`maybeSwapForNewTurn` returns `true` on a successful swap;
the caller in `onEvent.text` short-circuits its normal append
path so `t.delta` isn't double-appended.

### Why `tool_execution_end` and not `message_end{tool_use}`

The agent loop's `tool_execution_end` event fires regardless of
how the LLM provider expressed the tool call:

| Provider | `finishReason` / `stop_reason` for tool turns | Emits `tool_execution_end`? |
|---|---|---|
| Anthropic | `stop_reason=tool_use` | Yes |
| OpenAI | `finish_reason=tool_calls` | Yes |
| **Gemini** | **`finishReason=STOP`** (only `functionCall` parts signal the call) | **Yes** |

The first attempt at v0.4.12 tried to detect turn boundaries
via `message_end.stop_reason == .tool_use`, which Gemini's
`mapFinishReason` never produces. It was a no-op for the
bot's primary provider; the user observed identical
v0.4.11 behavior.

`tool_execution_end` is the agent-loop's own event — it fires
AFTER the tool has completed, before the next assistant
message_start, regardless of provider. Single source of truth.

### Failure modes

- **Old-bubble `chat.update` fails** → log warn + continue.
  The user's previous bubble retains whatever the throttled
  `chat.update` flushed last (≤750 ms staleness). The new
  bubble still appears below the tool prompts.
- **New-bubble `chat.postMessage` fails** →
  `maybeSwapForNewTurn` returns `false`. The caller's normal
  append path runs: `t.delta` is appended to the OLD
  `accumulated`, so this turn keeps streaming to the old
  bubble (v0.4.11 behavior, only for THIS turn).
  `expect_new_turn_swap` is already cleared (we committed in
  step 1), so the next delta won't re-attempt.
- **Allocator failures** in either dupe → bail early, same
  fallback as above.

### Ownership change

`StreamSubscriber.reply_ts` is now `[]u8` (subscriber-owned,
freed on `deinit`) instead of `[]const u8` (caller-borrowed).
The swap path needs to rewrite this slice across turns, so it
can't be a borrowed pointer. `init` and `initInThread` now
return `!StreamSubscriber` so they can `dupe` the input.
`bot.zig`'s call site updated to `try`.

### bot.zig simplification

The post-run repost (`sub.repostFinalIfToolUsed()`) added in
the previous v0.4.12 cut is gone — every turn is in its own
bubble by the time `waitForIdle` returns, no post-run cleanup
needed. The explicit `sub.stop()` before the repost is also
gone (back to the deferred-only pattern).

### Test coverage

- `tool_execution_end + text_delta swaps to a new bubble` —
  drives a 2-turn run, asserts `swap_count=1`, `post_count=1`,
  the new bubble's body contains turn 2's first delta + the
  thread_ts, and the final `chat.update` lands on the new
  ts with turn 2 content only (turn 1 is gone — it was
  finalized to the old ts).
- `single-turn reply (no tool calls) does NOT trigger a swap` —
  sanity check: no tool ⇒ no swap, `reply_ts` stays at the
  original placeholder.
- `parallel tools (multiple tool_execution_end before next text) → still ONE swap` —
  edge case: 3 parallel tools emit 3 `tool_execution_end`
  events before the next text_delta. Asserts
  `tool_execution_count=3` AND `swap_count=1` (the flag's
  idempotency).

### Why the previous v0.4.12 (post-run repost) was rejected

After shipping it, the user observed the "thinking message"
still updating throughout the run with each new turn's text.
The repost only fixed the END state — the live experience
during the run still showed the answer evolving at the top
of the thread, in confusing position. Per-turn split fixes
the live experience too: each turn's bubble is born below
the tool prompts that came before it, and stays there.

## [0.4.12] — 2026-04-29 — Repost final answer below tool prompts

Pre-fix, in any multi-turn run with tool calls the bot's reply
ended up in the **wrong chronological position**. The
`@`-mention placeholder (posted at run start) was repeatedly
mutated via `chat.update` as the agent streamed text — but
Slack orders messages by *post* timestamp, not edit timestamp.
Result: after 3 tool calls, the user saw

```
Franky-Do  11:22:08 — [final multi-turn narration]   (edited)
:warning: Permission required  ls
:white_check_mark: Allowed once
:warning: Permission required  read build.zig
:white_check_mark: Allowed once
:warning: Permission required  read src/main.zig
:white_check_mark: Allowed once
```

The "answer" appeared at 11:22:08 (the placeholder timestamp)
even though it was generated *after* the last tool call at
11:22:18 — confusing, because the user reads top-to-bottom
expecting causal order.

**An earlier v0.4.12 attempt** (split-per-turn, swap on
`message_end{stop_reason=tool_use}`) was reverted: it was a no-op
for Gemini, the most common provider for this bot. Gemini's API
returns `finishReason=STOP` even for tool-call turns (the
presence of `functionCall` parts is the only signal), so
franky's `mapFinishReason` never produced `.tool_use` and the
swap never triggered. Anthropic does emit `stop_reason=tool_use`
correctly, but designing around one provider's behavior wasn't
the right move.

**The replacement: post-run repost.** A single, provider-
agnostic counter (`tool_execution_count`, incremented on every
`tool_execution_end` agent event) drives the new behavior:

1. The bot still streams text into the placeholder via
   `chat.update` during the run — gives live progress feedback.
2. After `agent.waitForIdle()` returns, the bot calls
   `sub.stop()` to join the timer thread (idempotent), then
   `sub.repostFinalIfToolUsed()`.
3. If `tool_execution_count > 0` AND `accumulated.len > 0`,
   the subscriber:
   - **`chat.postMessage`** the full accumulated text as a
     fresh bubble in the same thread. Slack timestamps it
     `now`, so it lands chronologically below all tool prompts.
   - **`chat.update`** the placeholder to a brief
     `_…full reply below ↓_` pointer so the user isn't left
     with two copies of the same content.

No-op when no tool ran (single-turn replies are already in the
right place — the placeholder is the only reply in the thread)
or when accumulated is empty (error paths where
`errorReplyText` already composed a targeted message into the
placeholder).

**Failure paths degrade gracefully.**

- `chat.postMessage` fails → log warn + return error. The
  placeholder still has the full streamed text, so the user
  loses nothing — just the chronological ordering, which is
  the v0.4.11 behavior they were already tolerating.
- Pointer `chat.update` fails after a successful repost → log
  warn but don't propagate. The user sees both the placeholder
  (with the full streamed text) AND the fresh bubble (with the
  same text). Mild duplication, but the answer is in the
  correct position. The user can still read the conversation.
- `errorFlagged()` short-circuits the repost in `bot.zig`:
  failed runs already had the error envelope composed into the
  placeholder by `errorReplyText` (v0.4.2), and reposting an
  error message below the tool prompts would be redundant +
  confusing.

**Why this beats the original split-per-turn idea.**

- **Provider-agnostic.** `tool_execution_end` is an agent-loop
  event, fires regardless of how the provider canonicalizes
  `stop_reason`. Works for Gemini, Anthropic, OpenAI, and
  every future provider with no per-provider tweaks.
- **Single bubble per run.** The user sees ONE final answer
  in the conversation, not N bubbles for N turns. Slack
  threads with 3-5 multi-turn replies + tool prompts get
  busy fast; one consolidated bubble at the bottom keeps
  the thread skimmable.
- **Cheaper.** One extra `chat.postMessage` + one `chat.update`
  per multi-turn run, total. The split-per-turn design issued
  one extra `chat.postMessage` PER turn, so a 4-turn run was
  3 extra round-trips — and held the agent worker thread
  inside `onEvent` for each.
- **No mutex / ownership churn.** `reply_ts` is back to
  `[]const u8` (caller-borrowed); `init` / `initInThread`
  back to non-fallible.

**Implementation notes.**

- `repostFinalIfToolUsed` runs on the bot's main thread
  AFTER `sub.stop()` joins the timer — no concurrent
  `chat.update` can race the `chat.postMessage`.
- Snapshots `accumulated` under the mutex despite the
  timer being joined, for consistency with the rest of the
  file's locking discipline.
- Bot.zig's existing `defer sub.stop()` becomes a no-op for
  the success path (`stop()` is idempotent — second call
  short-circuits on `timer_thread == null`); error/early-
  return paths still use the deferred stop as their cleanup.

**Test coverage.** `TallyServer` already tracks per-method
counters and bodies (added speculatively in the earlier
v0.4.12 attempt; kept). Three new tests:

- `repostFinalIfToolUsed: posts fresh bubble + replaces placeholder when tools ran`
  — drives a synthetic 2-tool run, asserts `post_count==1`
  with the FULL accumulated text in the body, plus a
  `chat.update` carrying `full reply below` for the
  placeholder pointer.
- `repostFinalIfToolUsed: no-op when no tools ran` — sanity
  check that single-turn replies don't pay the repost cost.
- `repostFinalIfToolUsed: no-op when accumulated buffer is empty`
  — error-path scenario where the placeholder already has
  the targeted error envelope.

## [0.4.11] — 2026-04-30 — Slack HTTP tracing + `response_metadata.messages` on errors

Pre-fix, `--http-trace-dir` only captured LLM provider traffic
(Gemini/Anthropic/OpenAI). Slack web_api calls (`chat.postMessage`,
`chat.update`, `files.uploadV2`'s 3 steps, `reactions.add`,
etc.) were invisible — operators chasing a Slack-side
`invalid_arguments` had nothing to grep.

**Two fixes that compound:**

1. **Slack HTTP tracing.** `web_api.Client` gained a
   `http_trace_dir: ?[]const u8` field. When set, every
   `callMethod` invocation AND the presigned-URL upload (step 2)
   write a full trace via `franky.ai.http.writeTraceFile` —
   same convention + same directory as the LLM-provider
   traces. Filename `provider` field is `slack-<method>` (e.g.
   `slack-files.completeUploadExternal`) for callMethod and
   `slack-files-upload-presigned` for step 2, so a single
   `ls /tmp/franky-trace` shows everything interleaved by
   timestamp. Wired in both `cmdRun` (flag + env) and
   `cmdRunAll` (env-only) via the existing
   `resolveHttpTraceDirFromEnv` resolver.
2. **`response_metadata.messages` parsing.** Slack's generic
   error codes (especially `invalid_arguments`) usually come
   with an array of specific `messages` like
   `[ERROR] not_in_channel` or
   `[ERROR] missing required field 'files'`. Pre-fix, the
   typed response struct didn't include this field, so the
   info was thrown away. v0.4.11's new
   `captureResponseMetadataMessages(body)` re-parses the raw
   body on the failure path (using a transient
   `ArenaAllocator`) and joins the array entries with `; ` into
   a new `last_slack_error_detail` field. Cheap on success
   (only fires when `ok=false`).

**Surfaced where it matters most.** The `files.uploadV2 failed`
warn log now reads:

```
WARN files.uploadV2 failed: SlackApiError slack_error=invalid_arguments
     detail=[ERROR] not_in_channel bytes=4296
```

— actionable in one line.

The truncate-fallback footer in Slack also includes the detail
when present, so the operator sees the specific reason in
Slack itself without consulting the trace files.

**No new tests** — both additions are diagnostic surfaces, not
behavior changes. **115 tests passing total** (unchanged from
v0.4.10).

**Filename convention reminder:**

| Trace file prefix | What's in it |
|---|---|
| `<ts>-<seq>-google-gemini.txt` | Gemini provider |
| `<ts>-<seq>-slack-chat.update.txt` | Slack `chat.update` |
| `<ts>-<seq>-slack-files.completeUploadExternal.txt` | Slack file-upload step 3 (the one that's been failing for you) |

Recipe for the failing call:

```sh
ls -lt $TRACE/*-slack-files.completeUploadExternal.txt | head -3 \
  | xargs -I{} sh -c 'echo "=== {} ==="; awk "/^--- response body ---$/{r=1;next} r" "{}"'
```

## [0.4.10] — 2026-04-30 — Add `files:write` scope + truncate-fallback on long-reply upload failure

Real-user bug — a 4296-byte assistant reply (over the 3500B
inline-update threshold) triggered the file-attachment fallback,
which then failed:

```
+607183 INFO  reply size 4296B exceeds threshold 3500B → switching to file attachment
+607880 WARN  files.uploadV2 failed: SlackApiError slack_error=invalid_arguments bytes=4296
+607924 DEBUG handle step=exit
```

User saw the `_reply too long for chat — full content in the
attached file ↓_` preamble and **no file attachment** — empty
result.

**Two root causes**, both produce Slack's deceptively generic
`invalid_arguments`:

1. **Missing `files:write` OAuth scope.** v0.3.8's manifest
   added the file-upload code paths but never added the scope.
   Without it, `files.completeUploadExternal` rejects with
   `invalid_arguments` (rather than the more obvious
   `missing_scope` / `not_allowed_token_type`). Fixed by adding
   `files:write` to `slack-app-manifest.yaml`. **App reinstall
   required when upgrading from v0.4.9 or earlier** — Slack
   doesn't grant new scopes on existing tokens automatically.
2. **Bot not invited to the channel.** Even with `files:write`,
   `files.completeUploadExternal` requires the bot to be a member
   of the target channel. `app_mentions:read` lets the bot
   *receive* mentions but not *upload* into a channel it hasn't
   been invited to. Fix: `/invite @franky-do` in the channel.

**Defensive fallback when upload still fails.** Pre-fix, an
upload error left the user with just the preamble. v0.4.10's
`fallbackToTruncatedInline` posts the first ~3000B of content
inline as a `chat.update` with a clear footer:

```
…<reply content, capped at 3000 chars>…

_…truncated (1296B more). File attachment failed:
`invalid_arguments` — check `files:write` scope and
`/invite @franky-do` in this channel._
```

So even when the install is broken, the operator (a) sees the
core of the answer and (b) gets a self-explanatory hint about
what to fix. Best-effort: if the fallback `chat.update` ALSO
fails (rare — the same scope/membership story doesn't apply to
chat.update), it logs at warn and gives up.

**Code shape:** `uploadOverflow`'s catch arm now invokes
`fallbackToTruncatedInline(content, slack_err)` before
propagating the error. The `overflowed_to_file = true` flag
that `uploadOverflow` already set blocks subsequent flushes
from racing the fallback's `chat.update`.

**No new tests** — the failure mode is OAuth-scoped (missing
`files:write` returns `invalid_arguments` over the wire); the
unit-test surface for the body builder doesn't simulate
Slack's response-side behavior, and the fallback path is a
~30-LOC composition over already-tested `chat.update` and
`std.fmt.allocPrint`. **115 tests passing total** (unchanged).

**Operator action when upgrading from v0.4.9 or earlier:**

1. Pull v0.4.10 + rebuild (`zig build`).
2. Update the Slack app's OAuth scopes — push the new manifest
   (`slack-app-manifest.yaml`) via the Slack app dashboard's
   "Manifest" tab.
3. **Reinstall the app to your workspace** (required for the
   new `files:write` scope to take effect). Existing tokens
   stay valid for already-granted scopes; only `files:write`
   needs the reinstall.
4. In each channel where you use the bot, `/invite @franky-do`
   if you haven't already (one-time per channel).
5. Restart the bot process so it picks up the new binary.

## [0.4.9] — 2026-04-30 — Drop redundant "allowed by" status post after button click

The post-resolution flow used to do two things on a successful
button click:

1. `chat.update` the prompt message → action row swapped for a
   context block: `:white_check_mark: Allowed once — chosen by <@user>`.
2. `chat.postMessage` a separate thread reply: `✓ allowed by <@user>`.

Both messages stacked in the thread, conveying the same info.
Visual noise — confirmed by user screenshot. The second post is
a leftover from the v0.3.3 reaction-driven UX where the prompt
message itself didn't update on resolve; v0.4.4's in-place
block-update made it redundant.

**Fix.** Removed the `postPromptStatus` call from
`Bot.dispatchInteractive`'s `.resolved` branch and dropped the
function (no other callers). The post-resolution thread now
shows only the in-place updated prompt message:

```
:warning: *Permission required*
The agent wants to call `ls`
```{"recursive":true}```
:white_check_mark: Allowed once — chosen by <@U…>
```

Sub-effects:
- ❌ / 🚫 (deny) variants likewise drop the redundant `✗ denied
  by` post — the resolved-block context line carries the same
  info.
- ⏩ (always-allow) and 🚫 (always-deny) — the persisted
  `permissions.json` write is unaffected; the user-visible
  message is just less repetitive.

**No new tests** — the change is a removal; existing
button-click tests in `slack_prompts.zig` still cover the
resolved-blocks shape, and the dropped `postPromptStatus` had
no test coverage. **115 tests passing total** (unchanged).

## [0.4.8] — 2026-04-30 — Bump franky → v1.29.4 to fix proxy use-after-free segfault

Real-user crash when running franky-do behind `HTTPS_PROXY`
(Squid via `gateway.docker.internal:3128`):

```
+81186 INFO  http ca-bundle extended trust store with FRANKY_CA_BUNDLE=/etc/ssl/certs/proxy-ca.pem
Segmentation fault at address 0xffff936e0040
/Users/.../franky/src/ai/vendored/http_client.zig:1737:23 in connect (franky-do)
    if (proxy.host.eql(host) and proxy.port == port and proxy.protocol == protocol) {
                      ^
... in request (franky-do)
... in fetchPhased (franky-do)
```

Diagnosed as a **use-after-free in franky's
`setupClientFromEnv`**: the function created a function-scoped
`ArenaAllocator`, passed it to `client.initDefaultProxies`,
and `defer`'d the arena's `deinit` — but the vendored Zig
Client's `http_proxy` / `https_proxy` fields hold pointers
INTO that arena and are documented to need memory that
outlives the client. Arena died on `setupClientFromEnv`
return; pointers dangled; next request's `connect()` deref'd
freed memory.

Fault address `0xffff936e0040` matched the high-bit user-space
UAF pattern that v1.28.1's spec row had already corrected the
v1.26.6 framing on. Single-call test runs worked because the
GeneralPurposeAllocator hadn't recycled the freed page yet;
the crash hit reliably once a second concurrent HTTP call
(franky-do has many — `chat.update` from the StreamSubscriber
timer thread, `reactions.add` from the ReactionsSubscriber,
the bot's own placeholder post) reused the freed memory.

**Fix lives in franky core (v1.29.4).** franky-do v0.4.8
just bumps the dep — no franky-do source changes needed
beyond the version string. The proxy memory now allocates
on the caller's long-lived allocator and leaks ~100 bytes
per HTTP call (acceptable for bot workloads; restart cycles
handle accumulation).

**No new tests** — the test allocator's per-test reset
masks the UAF (which is why v0.4.7's CI didn't catch it).
Pinning a regression for this requires a dedicated
test-with-proxy harness, deferred to v2.x. **115 tests
passing** (unchanged from v0.4.7).

## [0.4.7] — 2026-04-30 — `--http-trace-dir` / `FRANKY_DO_HTTP_TRACE_DIR` actually wired

Pre-fix, franky-do silently dropped `--http-trace-dir`: the
flag wasn't in `cmdRun`'s argv loop, and `stream_opts.http_trace_dir`
was never assigned. Operators trying to capture the raw
provider request/response (e.g. for the `empty_response`
agent-error class added in franky v1.29.0) saw the
`/diagnostics` report's "trace dir" line render as
`<unset — pass --http-trace-dir to capture>` no matter what
they passed. The `:mag:` Slack-side report was equally blind.

**Fix.** Two opt-in surfaces, CLI flag wins:

```sh
# Per-run flag (highest priority)
franky-do run --workspace T01… --http-trace-dir ~/.franky-do/log-trace

# Env var (when --http-trace-dir is absent)
FRANKY_DO_HTTP_TRACE_DIR=~/.franky-do/log-trace franky-do run --workspace T01…
```

The `--all` (multi-workspace) command path honors the env var
since it has no per-workspace flag surface.

When set, every provider HTTP call writes a trace file to
`<dir>/<unix_ms>-<seq>-<provider>.txt` (full request body +
full response body, no truncation — see franky v1.16.1's
`http.writeTraceFile`). Each saved assistant message's
`Message.diagnostics.trace_id` field points at the matching
filename stem so `/diagnostics` reports + `:mag:` reactions
can show the exact path to grep.

**Startup logs** confirm the wiring:

```
[info] franky-do http_trace dir=/Users/.../.franky-do/log-trace
```

If the trace dir resolves to null, the line drops to debug
level.

**+4 tests** for the resolver's precedence rules (default null,
flag wins over env, env used when flag null, empty
flag+env → null). **115 tests passing total** (was 111; +4).

## [0.4.6] — 2026-04-30 — Fix `:mag:` falling through to "no persisted session" for live threads

The v0.4.5 ship picked the wrong source-of-truth for the
diagnostics transcript. Real-user incident — operator hit
`empty_response` on a live thread, reacted `:mag:` to
investigate, got back `_no persisted session for this thread
(yet)…_` even though there was clearly an active session.

**Root cause:** v0.4.5 read the transcript exclusively from
disk via `franky.coding.session.load`. franky-do's persistence
model writes only on **hibernation eviction** (per v0.3.1),
not after every turn — so a live, recently-active thread
never has a `transcript.json` on disk. `session.load` returned
`error.SessionNotFound`, and the empty-state path fired.

**Fix.** `runDiagnosticsReaction` now picks the source by
agent-cache state:

1. **Cached + idle** → read `agent.transcript.messages.items`
   directly. Safe between turns: `Agent.waitForIdle`'s join
   guarantees the worker isn't appending.
2. **Cached + streaming** (`agent.is_streaming.load(.acquire)`)
   → post `_agent is mid-turn; react :mag: again after the
   run finishes_`. Reading the in-memory slice mid-turn would
   race; reading from disk would be stale.
3. **Not cached** → `session.load` from disk (the hibernated
   case still works).
4. **Neither** → friendly empty-state (the v0.4.5 message,
   now reserved for the genuinely-empty case).

Source-agnostic body extracted to
`runDiagnosticsForTranscript(transcript: []const ai.types.Message)`
so the live + disk paths share one renderer/post block.
Added a `postSimpleThreadReply` helper since both empty-state
arms now post a friendly italic message.

**No new tests** — the unique fix is the source-selection
branch, which is straightforward composition over already-
tested pieces (`agents.get`, `is_streaming.load`,
`session.load`, `diagnostics.runAndPersist`). The
end-to-end safety net is the same as v0.4.5: build passes,
existing reaction-routing tests cover dispatch, analyzer
tests cover the report generation. **111 tests passing
total** (unchanged).

Spec §23 updated to document the source-selection rule. The
"why disk-load and not in-memory" rationale from v0.4.5 was
wrong about franky-do's persistence model; the corrected
explanation is now in the v0.4.6 footnote.

## [0.4.5] — 2026-04-30 — `:mag:` reaction → diagnostics report in-thread

Slack disallows developer slash commands inside threads (only
built-ins like `/giphy` are exempt; see Slack's "implementing
slash commands" docs). v0.4.5 works around that with a third
reaction trigger alongside `:x:` (abort) and
`:leftwards_arrow_with_hook:` (retry):

> React `:mag:` 🔍 on the original `@`-mention OR any bot
> reply in the thread to get a per-turn diagnostics report
> posted as a thread reply.

**Behavior:**

1. Reaction lands → `Bot.dispatchReaction` recognizes `:mag:`
   alongside the existing two and routes to a new
   `runDiagnosticsReaction(team_id, channel, thread_ts,
   reactor, ulid)`.
2. Resolves the team's `<home>/workspaces/<team>/sessions/`
   parent dir, calls `franky.coding.session.load(parent, ulid)`
   to read the persisted transcript (NOT the live in-memory
   transcript — that races against the worker's appends).
3. Calls `franky.coding.diagnostics.runAndPersist` with
   `franky_home = ~/.franky-do`, `session_id = ulid`,
   `mode_name = "franky-do"`, `session_dir = <full path>` (so
   reducer-dump pointers light up correctly).
4. Posts the rendered report as a thread reply, fenced in a
   `\`\`\`` block so Slack monospaces it; appends a
   `_saved: <path>_` italic footer with the persisted-file
   path so operators can `cat` it later.
5. The reply rides `chat.postMessage` and never enters the
   agent's transcript — model context for the next mention is
   unaffected.

**File path:**
`~/.franky-do/diagnostics/<ulid>/<unix_ms>.txt` (one file per
click; reading the same session via `:mag:` again creates a
new timestamped file rather than overwriting).

**Why disk-load and not the live transcript.** The live
agent's `transcript.messages.items` slice is reallocated as
the worker thread appends. A read from another thread can
race with `ArrayList.append` and see a torn header → segfault
or stale data. Disk-load is consistent at session-save
boundaries (`session.zig` writes are atomic via
tempfile+rename), and it costs one JSON parse — cheap. The
trade-off: the report shows turns up to the most recent
session-save, not the in-flight turn. That's fine for the
common case (operator investigates a turn that already
finished).

**Friendly empty-state path.** If `session.load` fails
(typically: thread has no persisted session yet — the user
hasn't mentioned the bot in this thread), the bot replies in
the thread:

> _no persisted session for this thread (yet); mention me to
> start one and try the :mag: reaction again_

Catches the operator-clicks-too-early case without surfacing
a stack trace.

**`/franky-do help` updated** to list all three reaction
triggers (`:x:` / `:leftwards_arrow_with_hook:` / `:mag:`)
plus a one-line note explaining why slash commands aren't
available in threads.

**Why reactions over slash commands inside the thread.**
Researched: Slack's slash-command platform explicitly excludes
threads (per Slack Developer docs and persistent
[since-2018-and-still-open user requests on
@SlackHQ](https://x.com/SlackHQ/status/977264888392413186)).
The official guidance is "use shortcuts or app actions
instead." Reactions piggyback on the existing
`reaction_added` Events API subscription that franky-do
already has scoped, so no new OAuth scopes or manifest edits
are required.

**No new tests added** — the implementation composes
already-tested pieces (`session.load` from franky core's
session tests, `diagnostics.runAndPersist` from v1.29.x's
analyzer + persist tests, and `dispatchReaction`'s routing
fan-out which is already covered by the unknown-reaction-
emoji-dropped test). The unique v0.4.5 surface is the new
`runDiagnosticsReaction` method which is straight composition.
**111 tests passing total** (unchanged from v0.4.4).

## [0.4.4] — 2026-04-30 — Block Kit buttons for permission prompts (replaces reactions)

The reaction-based permission UX (✅ ⏩ ❌ 🚫 on the prompt
message, four counter pips, "react to resolve" legend) is gone.
v0.4.4 replaces it with **four interactive Block Kit buttons** —
one click per decision, single-press, with the right styling
per choice.

**Wire-format change.** Permission prompts now post via
`chat.postMessage` with a `blocks` array:

- `section` block: `:warning: *Permission required*\nThe agent wants to call \`<tool>\``
- `section` block: a fenced code block carrying the tool args (capped at 1024 chars; over-long args land with `…(truncated)`)
- `actions` block: four `button` elements with `action_id =
  perm:<call_id>:<resolution>` and `style: primary` /
  `style: danger` on the always-* variants

When a user clicks, Slack delivers a Socket Mode `interactive`
envelope (we already had a connection — `block_actions` rides
the same WSS). New `Bot.dispatchInteractive` parses the
envelope, extracts `payload.actions[0].action_id`, decodes back
to `(call_id, resolution)`, and feeds the existing
`prompts.tryReactionResolve` resolution path. After the
resolution lands, `chat.update` swaps the action row for a
context block (`:white_check_mark: Always allowed — chosen by <@user>`)
so the prompt visibly disables itself.

**Why buttons, not radio buttons.** The user's draft used a
`radio_buttons` element inside an `input` block, but that needs
a separate Submit interaction — 2 clicks per decision. Plain
buttons fire `block_actions` immediately on click and let each
choice carry its own `style` ("Always Allow" green, "Always
Deny" red), which matches the reaction-era visual semantics.

**Reactions on prompt messages are still ignored** so an `:x:`
reaction on a permission prompt doesn't fall through to
`abortThread` and wrongly terminate the run. The dispatch path
just consumes the reaction and logs it.

**`prompts_state.PromptEntry` schema change.** The entry now
holds `tool_name` and `args_json` (owned dups). Both feed the
post-resolution `chat.update` so the resolved prompt keeps the
same header + args view. `ReactionOutcome.resolved` surfaces
both as owned slices.

**Removed:** `prompts_state.decodeReaction`, the four
`reactionsAdd` seed calls in `slack_prompts.handleRequest`, and
the legacy `formatPromptText` text builder.

**Added:**
- `slack_web_api.ChatPostMessageArgs.blocks_json` and
  `ChatUpdateArgs.blocks_json` — raw-JSON blocks pass-through.
  Caller produces well-formed JSON; we just pipe it into the
  request body.
- `slack_prompts.buildPromptBlocks(allocator, tool_name,
  args_json, call_id) ![]u8` — emits the JSON-stringified
  blocks array.
- `slack_prompts.buildResolvedBlocks(allocator, tool_name,
  args_json, user_id, resolution) ![]u8` — same shape minus the
  action row, plus the "chosen by" context line.
- `slack_prompts.parseActionId("perm:<call_id>:<resolution>") ?ParsedAction`
  — round-trip the `action_id` payload back into a `(call_id,
  Resolution)` tuple.
- `Bot.dispatchInteractive(raw_json) !void` — Socket Mode entry
  point for `interactive` envelopes. Routed in main.zig's
  socket-mode dispatch table alongside `events_api` and
  `slash_commands`.
- `bot.InteractiveEnvelope` struct typed for the fields we route
  on (`payload.type`, `payload.user.id`,
  `payload.container.{channel_id,message_ts}`,
  `payload.actions[].action_id`).

**Tests updated.** `formatPromptText` and `decodeReaction` tests
removed (the functions are gone). `+6` new tests in
slack_prompts.zig (block builder structural validity, JSON
escaping, args-truncation, resolved-blocks rendering, action_id
parser positive + negative cases). `tryReactionResolve happy
path` now also asserts the `tool_name_owned` / `args_json_owned`
fields on the resolved outcome.

**111 tests passing total** (was 108; +3 net after deletions).

**Slack app manifest.** Existing installs need to enable Socket
Mode's "Interactivity" toggle (under "Interactivity & Shortcuts"
in the Slack app dashboard). The bot's connection scope already
includes the relevant subscription; no new OAuth scopes
required since `block_actions` rides the existing app-level
token. `slack-app-manifest.yaml` updated to set the
`interactivity` flag explicitly.

## [0.4.3] — 2026-04-29 — `--ask-all` / `FRANKY_DO_ASK_ALL` to demote auto-allow tools to ask

Closes the v0.3.2 "post-1.0 follow-up" comment in
`initPermissionStore` — operators now have a way to make Slack
prompt for *every* tool call, including the read-family ones
(`read`/`ls`/`find`/`grep`) that the default
`franky.coding.permissions` policy auto-allows.

The franky core support already existed via
`Store.ask_all: bool` (mirrored from franky CLI's
`--ask-tools all` reserved sentinel); v0.4.3 just exposes the
knob.

**Two opt-in surfaces, CLI flag wins:**

```sh
# Per-run flag (highest priority)
franky-do run --workspace T01… --ask-all

# Env var (when --ask-all is absent)
FRANKY_DO_ASK_ALL=1 franky-do run --workspace T01…
FRANKY_DO_ASK_ALL=true franky-do run --workspace T01…
```

The `--all` (multi-workspace) command path also honors the env
var since it has no per-workspace flag surface.

**Effect when on:** every `read`/`ls`/`find`/`grep` call surfaces
a yellow Slack prompt with the same ✅/⏩/❌/🚫 reaction UX
that `write`/`edit` already use. `always_allow` entries (and the
⏩ "always allow" reaction) still take precedence — flipping a
tool to "always" once silences subsequent prompts for that tool
just like before.

**What's NOT in this cut.** The CSV-driven equivalents
(`--ask-tools <csv>` for narrowing to a subset, `--allow-tools`
/ `--deny-tools` for static policy) remain post-1.0 follow-ups.
v0.4.3 ships the all-or-nothing shape because that's the most
common operator request and it's a one-bit knob.

**Startup logs grow an `ask_all=…` field** so a quick
`franky-do run` confirms the state without digging:

```
permissions store ready remember=yes ask_all=yes path=/home/agent/.franky-do/permissions.json
```

Tests for the resolver's precedence rules (default off, env=1,
env=true, env=anything-else, --ask-all flag wins over env=0).
**108 tests passing total** (was 103; +5).

## [0.4.2] — 2026-04-29 — Targeted Slack reply for `empty_response` + trace_id footer on errors

Companion to franky **v1.29.3**. The franky v1.29.x line shipped
the diagnostics-everywhere bundle (`Message.diagnostics` +
`empty_response` error code + reducer dumps + trace_id plumbing)
plus a `/diagnostics` slash command available in interactive and
proxy modes. franky-do v0.4.2 picks up two of those signals on
the Slack side without changing its public API:

1. **Targeted reply for `empty_response`.** Pre-fix, when Gemini
   thought-but-emitted-nothing (or any other provider closed
   cleanly with zero content), the bot painted ❌ but the Slack
   thread held no explanation of *why* — just a forever-stuck
   `_thinking…_` placeholder if no text had streamed yet.
   v0.4.2 captures the `agent_error{code, message}` on the
   subscriber, and on the final flush — when accumulated text is
   empty AND an error fired — composes a Slack-friendly message.
   `empty_response` gets a custom phrasing pointing at the
   thinking-budget knob and the profile-switch escape hatch:

   > *Provider returned no output (likely thinking-budget
   > exhaustion). Try a different profile (`/franky-do model …`),
   > raise `--thinking` budget, or retry once.*

   Other codes get a generic envelope (`provider returned an
   error: <code> — <message>`) using the same path.

2. **trace_id footer on errors.** When the assistant message
   ended with `Message.diagnostics.trace_id` populated AND we
   captured an agent_error during the run, the error reply now
   ends with a small footer: `_trace: <trace_id>_`. Operators
   running with `--http-trace-dir` can grep the matching trace
   file directly without having to dig through the saved
   transcript first.

Both behaviors are subscriber-local in `stream_subscriber.zig`;
no API surface change, no new env vars, no Slack-side message
shape change for the happy path. The placeholder still posts
unchanged; only failed runs pick up the new text. Tests added
for the `empty_response` rendering path (`captures empty_response
+ flushes a targeted reply`), the generic-error path (`generic
agent_error code surfaces in flushed reply text`), and the
trace_id footer (`appends trace_id footer when message_end
diagnostics present`).

This release also bumps the documented compatibility window in
`franky-do.md` to franky **v1.27.x – v1.29.x** — every release
between v1.26.0 (the v0.4.1 baseline) and v1.29.3 was additive
on the SDK boundary, so franky-do v0.4.1 already worked against
all of them; v0.4.2 just makes the documentation honest.

## [0.4.1] — 2026-04-29 — Vendored Zig `http.Client` patch for HTTPS-via-proxy

Companion to franky **v1.26.0** which vendors `std.http.Client`
with [Zig PR #23365](https://github.com/ziglang/zig/pull/23365)
applied so requests to HTTPS origins through `HTTPS_PROXY`
perform a TLS handshake on the established CONNECT tunnel
instead of sending the body as plaintext. Without that patch,
Squid (and Docker Sandboxes' MITM proxy) reject every outbound
LLM and Slack request with `Host header does not match CONNECT
request` even when the operator has wired `FRANKY_CA_BUNDLE`
correctly per v0.4.0. v0.4.1 just swaps `web_api.zig`'s direct
`std.http.Client` references for `franky.ai.http.Client`,
which now points at the vendored copy. No behavioral change
for non-proxy traffic.

## [0.4.0] — 2026-04-29 — `FRANKY_CA_BUNDLE` propagation (TLS trust store extension)

Companion to franky **v1.25.0** which added `FRANKY_CA_BUNDLE`
to extend Zig's TLS trust store at runtime. franky-do already
forwarded `environ_map` to the LLM providers (v0.3.6) and to
the Slack web_api (v0.3.9), so the new env var flows through
both paths automatically. v0.4.0 just bumps the version + adopts
franky's new `setupClientFromEnv` helper in
`web_api.callMethod` and `web_api.uploadFileToPresignedUrl`,
replacing the inline `initDefaultProxies` calls — this gives
the Slack-side HTTP calls the same proxy + CA-bundle treatment
as the LLM providers.

### Why it was needed

Docker Desktop / Claude Code Sandboxes ship a TLS-intercepting
proxy whose CA cert (`Docker Sandboxes Proxy CA`) lives as a
separate file in `/etc/ssl/certs/proxy-ca.pem`, not appended to
`/etc/ssl/certs/ca-certificates.crt`. curl walks the directory
(`CApath`); Zig stops at the first bundle file. So Zig never
sees the proxy CA and TLS verification fails on every outbound
request.

### How to use

```sh
FRANKY_CA_BUNDLE=/etc/ssl/certs/proxy-ca.pem \
  http_proxy=http://gateway.docker.internal:3128 \
  https_proxy=http://gateway.docker.internal:3128 \
  no_proxy=localhost,127.0.0.1,::1,gateway.docker.internal \
  GEMINI_API_KEY=$KEY FRANKY_DO_PROFILE=gemini \
  ./zig-out/bin/franky-do run --workspace T01...
```

You'll see the new log line on startup:
`info http ca-bundle extended trust store with FRANKY_CA_BUNDLE=...`

Both LLM and Slack HTTPS now succeed through the MITM proxy.

### Tests

98/98 — no test count change. The env-var path can't be
exercised in a unit test without a real cert file; structural
correctness comes from franky's provider tests +
`web_api.callMethod` already going through the same shared
helper.

### Migration notes

- Drop-in. Existing v0.3.9 invocations without `FRANKY_CA_BUNDLE`
  set behave identically — the extension only fires when the
  env var is present.
- Requires franky **v1.25.0+** (the upstream change ships the
  helper).

## [0.3.9] — 2026-04-28 — Slack web_api honors HTTP_PROXY / HTTPS_PROXY / NO_PROXY

Closes a corp-network gap. The 5 LLM providers (anthropic,
openai_chat, openai_responses, google_gemini, google_vertex)
already initialized `std.http.Client` proxies from
`stream_options.environ_map` via
`std.http.Client.initDefaultProxies`. franky-do's Slack
`web_api.Client` did not — its `callMethod` and the v0.3.8
`uploadFileToPresignedUrl` constructed `std.http.Client` raw,
bypassing any HTTP_PROXY/HTTPS_PROXY/NO_PROXY env. On networks
that route ALL outbound traffic through a corp proxy (e.g.
`http_proxy=http://gateway.docker.internal:3128`), the bot
could talk to the LLM but couldn't post replies.

### What shipped

- New `web_api.Client.environ_map: ?*std.process.Environ.Map`
  field. Set once at startup from `init.environ_map` (the
  post-applyProfile view, same one the LLM providers use).
- Both fetch paths (`callMethod` for /api/* and
  `uploadFileToPresignedUrl` for the files.uploadV2 step-2
  presigned URL) now check the field and call
  `initDefaultProxies(arena, env_map)` on the local
  `std.http.Client` before fetching. Same shape as the
  provider streamFns. On allocation failure of the proxy
  arena → returns `HttpFailed` with `last_http_error` set, so
  failures are debuggable.
- Wired in both `cmdRun` and `runForInstalledWorkspace` after
  `Client.init`: one line `api.environ_map = environ_map;`
  per call site.

### Env vars honored

Standard pair, both cases:
- `HTTP_PROXY` / `http_proxy` — for plain-HTTP requests.
- `HTTPS_PROXY` / `https_proxy` — for HTTPS (slack.com is
  always HTTPS so this is the load-bearing one).
- `NO_PROXY` / `no_proxy` — comma-separated host suffixes that
  bypass the proxy. Hosts like `localhost,127.0.0.1,::1,gateway.docker.internal`
  do what you'd expect.

### Tests

98/98 — no test count change. Adding a real proxy-route test
requires a SOCKS/HTTP proxy fixture which doesn't fit the
existing FauxSlackServer pattern; structural correctness is
covered by the existing tests + the same proxy-init pattern is
already exercised in franky's provider tests.

### Migration notes

- Drop-in. Existing v0.3.8 invocations without proxy env vars
  set behave identically — `initDefaultProxies` is a no-op
  when the env doesn't carry proxy vars.

## [0.3.8] — 2026-04-28 — Slack rate-limit + long-reply file fallback

Three changes that together respect Slack's API quotas + fix
the v0.3.7 `chat.update failed: SlackApiError` user issue.
Driven by https://docs.slack.dev/apis/web-api/rate-limits/.

### What shipped

**1. Honor `ratelimited` in `stream_subscriber`.** When Slack
returns `ok: false, error: "ratelimited"` from chat.update, the
subscriber now sets a 30-second pause window
(`rate_limit_paused_until_ms`) and the timer-loop checks it
before every flush. The "is_done but still owes a flush in the
pause window" case keeps the loop alive (don't lose the final
content). 30 s is conservative — the franky http transport
doesn't currently expose the `Retry-After` header so we use a
fixed default; v1.x franky-side work is queued to plumb the
header through, after which we'll honor the actual value.

**2. Long replies become file attachments.** Slack's hard
`text` limit is 40k chars but block-rendering quirks make
~3500 chars the safe upper bound for plain-text chat.update.
v0.3.8 adds the modern `files.uploadV2` 3-step flow
(`files.getUploadURLExternal` → multipart POST to presigned
URL → `files.completeUploadExternal`) and a high-level
`uploadTextToThread` orchestrator. When the streamed reply
exceeds `overflow_threshold_bytes` (default 3500), the
subscriber:
  1. chat.update's the placeholder with a one-line preamble:
     `_reply too long for chat — full content in the attached
     file ↓_`
  2. Uploads the FULL content as `reply.txt` in the same
     thread.
  3. Marks `overflowed_to_file = true` so subsequent flush
     ticks become no-ops (no double-update of the placeholder).
The threshold + `thread_ts` are wired through
`StreamSubscriber.initInThread` (a sibling factory to the
existing `init`); legacy callers using `init()` skip the
overflow path.

**3. System-prompt nudge.** The bot's system prompt now tells
the LLM: `"Keep replies under ~3000 chars. Long outputs become
a file attachment automatically; preface them with a 1-2
sentence summary so the user knows what's in the file."` Soft
constraint that works on cooperative models (Sonnet, Gemini-Pro)
to reduce how often the file-attachment path fires in the
first place. Both the inline default in `bot.Config` and the
explicit override in `main.zig` updated.

### New web_api surface

- `Client.filesGetUploadURLExternal(.{filename, length})` —
  step 1, returns `{upload_url, file_id}`.
- `Client.uploadFileToPresignedUrl(upload_url, filename, content)`
  — step 2, raw multipart POST to the Slack-internal presigned
  URL. Bypasses `callMethod` because the URL isn't an /api/
  endpoint; uses the same shared http transport.
- `Client.filesCompleteUploadExternal(.{files, channel_id,
  thread_ts, initial_comment})` — step 3, finalizes + posts.
- `Client.uploadTextToThread(.{...})` — high-level
  orchestrator that runs all three.

Multipart body is built by a new internal `buildMultipartFile`
helper with a wall-clock-keyed boundary
(`makeMultipartBoundary`) so concurrent uploads don't collide.

### Tests

98/98 (was 95; +3): `buildFilesGetUploadURLBody`,
`buildFilesCompleteUploadBody`, `buildMultipartFile`. Loopback-
server end-to-end tests for the full 3-step flow are deferred
— the multipart middle step is on a non-Slack URL that the
existing FauxSlackServer doesn't yet handle.

### Migration notes

- **Existing v0.3.7 invocations keep working unchanged.** The
  overflow path is opt-in: only fires when `thread_ts` is wired
  via `initInThread`. `bot.handleAppMention` switched to that
  variant; one-off / test callers using the legacy `init()`
  fall back to inline chat.update.
- **`chat.update` over the threshold no longer happens.** If
  you see `chat.update` log lines with bytes > 3500, that means
  the file-attachment path didn't fire (likely because of an
  upload failure higher up — check the warn log).

## [0.3.7] — 2026-04-28 — surface Slack error code on chat.update failure

Diagnostic-only fix. The `chat.update` warn log was printing
just the Zig error name (`SlackApiError`) without the actual
Slack error code (`msg_too_long` / `not_in_channel` /
`cant_update_message` / `edit_window_closed` / `rate_limited`,
etc.) — making it impossible to tell from logs WHY a chat.update
failed. The error code IS captured on `web_api.Client.last_slack_error`
but the subscriber wasn't reading it.

`stream_subscriber.issueUpdate` now logs both the Zig error AND
`api.last_slack_error` on failure: `chat.update failed: SlackApiError
slack_error=<code> bytes=<n>`. Rebuild + reproduce to see what
Slack actually returns.

## [0.3.6] — 2026-04-28 — profile `env: {}` block reaches all knobs

Hot-fix on top of v0.3.5. A profile body like
`{"provider": "google-gemini", "model": "gemini-2.5-pro",
"env": {"FRANKY_FIRST_BYTE_TIMEOUT_MS": "1200000"}}` correctly
overlays its `env: {}` into `environ_map` via `applyProfile`, but
franky-do's helpers — `resolveTimeoutsFromEnv`,
`resolveHibernationKnobs`, `resolvePromptTimeoutMs`,
`resolvePromptsEnabled`, `resolveRememberPermissions` — read from
the immutable `environ` (POSIX block) rather than the mutated
`environ_map`. Result: a Gemini run with a 20-min timeout in the
profile timed out at the default 30 s.

**Fix:** all five resolvers + their `parseEnvU32`/`parseEnvU64`
helpers now take `*const std.process.Environ.Map` and call
`environ_map.get(key)`. `initPermissionStore` updated alongside
since it called `resolveRememberPermissions`. Both
`cmdRun` and `runForInstalledWorkspace` now uniformly route
through the post-profile `environ_map` for everything that
should be profile-overridable.

`environ` (POSIX) is still used for things that shouldn't be
profile-overridable: `FRANKY_DO_HOME`, Slack-token env vars,
the slash-command flag parser, etc.

### Tests

95/95 — no test count change (the resolvers were structurally
covered; the change is type-narrowing the source-of-truth).

## [0.3.5] — 2026-04-28 — `FRANKY_DO_PROFILE` multi-provider dispatch

v0.3.4 and earlier hardcoded `model_provider = "anthropic"` and
`model_api = "anthropic-messages"` at the two `Bot.init` call
sites in `cmdRun` and `runForInstalledWorkspace`. Setting
`FRANKY_DO_MODEL=gemini-2.5-pro` therefore dispatched to the
Anthropic provider with a Gemini model id, and Anthropic
returned `model not found`. v0.3.5 routes through franky's
profile system instead — the same `applyProfile` →
`resolveProviderIo` chain franky's print mode runs at startup.

### What shipped

- **Profile-driven provider resolution.** New env
  `FRANKY_DO_PROFILE` selects a profile name (settings.json or
  built-in catalog like `gemini`, `groq`, `cerebras`, etc.).
  `franky.coding.profiles.applyProfile(&sub_cfg, ...)` overlays
  the profile's `provider` / `model` / `api_key_env` /
  `auth_token_env` / `base_url`; `print.resolveProviderIo`
  returns a `ProviderInfo` with the resolved
  `{model_id, provider_name, api_tag, api_key, auth_token,
  base_url, context_window, max_output, capabilities}`.
- **All five mode providers registered in the bot's registry**:
  `anthropic-messages`, `openai-chat-completions`,
  `openai-compatible-gateway`, `google-gemini` (faux excluded
  — no use case in franky-do). The `Agent` class then dispatches
  through whichever `api_tag` the resolver picked.
- **`Bot.Config` extended** with three new optional fields:
  `model_context_window`, `model_max_output`, `model_capabilities`.
  Defaults match v0.3.4 behavior (1M context, 64k max output —
  Anthropic territory) so callers that don't fill them in keep
  working. v0.3.5 main.zig populates them from
  `provider_info.{context_window, max_output, capabilities}` so
  Gemini's 2M-window vs Sonnet's 200k-window distinction
  actually reaches the Agent.
- **Precedence for model selection:** `--model` CLI flag (cmdRun
  only) > `FRANKY_DO_MODEL` env > `FRANKY_DO_PROFILE` →
  `profile.model` > built-in default `claude-sonnet-4-5`. CLI
  beats env beats profile beats default — same shape franky's
  print mode uses.
- **`environ_map` plumbed** through `cmdRun` and
  `runAll` → `WorkspaceWorkerArgs` → `runForInstalledWorkspace`.
  Required for `applyProfile`'s `${VAR}` interpolation in profile
  bodies and for `stream_options.environ_map` (which providers
  use for proxy detection via `initDefaultProxies`).
- **Anthropic-only credential pre-check removed.**
  `print.resolveProviderIo` runs the per-provider credential
  resolution chain (env > auth.json) and exits with a
  provider-specific message ("openai provider requires …") on
  missing creds. franky-do no longer hard-fails when only Gemini
  creds are set.

### Try it

```sh
GEMINI_API_KEY=$KEY FRANKY_DO_PROFILE=gemini ./zig-out/bin/franky-do run --workspace T01...
```

…or override the profile's default model:

```sh
GEMINI_API_KEY=$KEY \
  FRANKY_DO_PROFILE=gemini \
  FRANKY_DO_MODEL=gemini-2.5-flash \
  ./zig-out/bin/franky-do run --workspace T01...
```

…or use any other provider whose profile is in your
settings.json (`groq`, `cerebras`, custom `ollama-deepseek`,
etc.). Run `franky --list-profiles` to see what's available.

### Migration notes

- **Back-compat preserved.** Existing invocations without
  `FRANKY_DO_PROFILE` keep using Anthropic (the default model
  resolves to `claude-sonnet-4-5` and `print.resolveProviderIo`
  picks Anthropic when `ANTHROPIC_API_KEY` /
  `CLAUDE_CODE_OAUTH_TOKEN` are present in env).
- **`FRANKY_DO_MODEL` semantics shifted slightly.** It used to
  be "the Anthropic model id". Now it's "the model id, regardless
  of provider — overrides the profile's default". Setting it
  alone (no profile) still hits Anthropic (the default-provider
  resolution); pair it with `FRANKY_DO_PROFILE` to cross
  providers.

### Tests

95/95 — no test count change. The model-id default test was
updated to assert v0.3.5; structural tests cover the existing
shape that survives this refactor.

## [0.3.4] — 2026-04-28 — single-emoji status indicator

Revises the v0.3.0 emoji-trail behavior (design §A.3.4) to keep
**only the latest state** on the user's `@`-mention. So at any
moment the message shows exactly one of `👀` / `💭` / `✅` /
`❌` — the bot's *current* status, not a history.

### Why the change

The v0.3.0 "leave the trail" decision optimized for one API call
per state and pitched the trail as a useful audit signal. In
practice the trail is more confusing than helpful: a returning
user sees `👀 💭 ✅` and has to read three emojis to figure out
"is it done?". The mobile-client animation argument (the original
A.2 rationale) only works when there's a single reaction
transitioning — three static reactions is just clutter. The
transcript itself + the placeholder reply already provide the
audit log; the reactions are a *live status* indicator.

### What shipped

- **`slack/web_api.zig`**: new `reactionsRemove(.{ channel,
  timestamp, name })` wrapping `reactions.remove`. Body shape is
  identical to `reactions.add`. Returns `{ ok, error }` like
  every other web-API helper.

- **`reactions_subscriber.zig`** rewritten as a state machine.
  - Internal `State` enum (`none` / `eyes` / `thought_balloon` /
    `white_check_mark` / `x`) replaces the four idempotency
    booleans.
  - `transition(new_state)` is the single mutation point. Held
    under `state_mutex` for the read-prior + commit-new step;
    released BEFORE the network calls so HTTP latency doesn't
    block concurrent callers.
  - Order: add new emoji **first**, then remove the prior. If
    `reactions.remove` 429s the user briefly sees two emojis —
    better than the reverse failure mode (no emoji at all).
  - `no_reaction` errors from `reactions.remove` are demoted to
    debug — means it was already removed (race / manual cleanup).
  - `agent_error` still flags `is_error_state` non-mutating;
    `markFinal(.error_state)` does the actual transition to ❌.
  - Tests: `markReceived` idempotency, full add+remove sequence
    in correct order, agent_error → ❌ transition, 429 doesn't
    panic.

- **`v0.4-design.md`** §A.3.4 updated with the revised decision
  + rationale + implementation note. Original "leave the trail"
  text preserved as the proposal so future readers see what was
  swapped.

### API budget impact

v0.3.0 issued 3 reactions.add calls per mention (👀 + 💭 + ✅).
v0.3.4 issues 4 calls (3 add + ~3 remove, since `none → eyes`
has no prior to remove). Roughly 2× the API cost per mention but
still well under Slack's Tier 3 budget (~50/min/workspace). On
agent_error the budget rises by 1 (extra add+remove for the
final state).

If `reactions.remove` rate-limits, the new state still landed
(add fires first); the user sees a brief stale emoji until the
next transition's remove succeeds.

### Tests

95/95 (no test count change — replaced 4 v0.3.0 tests with 4
state-machine tests of equivalent shape, expanded to verify the
remove ordering).

### Migration notes

- No new Slack scopes — `reactions:write` already required for
  v0.3.0's `reactions.add`. Same scope covers `reactions.remove`.
- Operators who *liked* the historical trail behavior have no
  knob to keep it. If demand surfaces, a `FRANKY_DO_REACTION_TRAIL=1`
  env opt-in is straightforward to add (one `if` in `transition`)
  but isn't shipping today.

## [0.3.3] — 2026-04-28 — Slack permission prompt UI (v0.4 design Feature B, Phase 2)

Phase 2 of Feature B — what v0.3.2 set the stage for. The
foundation (workspace-wide `permissions.Store` + per-Agent
`SessionGates` via `Agent.tool_gate`) was already in place; this
release adds the actual interactive surface: a Slack-thread
prompt for each gated tool call, four tap-to-react resolution
emojis, owner-only resolution, a per-prompt timeout, and the
race-safe wiring that lets short-lived prompters coexist with the
long-lived per-Agent gates without use-after-free.

### What shipped

- **`prompts_state.zig`** extended with `tryReactionResolve` and
  `tryTimeoutResolve` — atomic "lookup + win the resolution race
  + call `prompter.resolve` + remove entry" all under the map
  mutex. This is the cornerstone of safe lifetimes: any code that
  derefs `entry.prompter` does so under the same mutex that
  `Orchestrator.stop` takes when scrubbing leftover entries
  before deinit'ing the prompter. Stale reactors / late timers
  cleanly see `not_found` instead of crashing.
  - New `decodeReaction(name) → ?Resolution` for the four
    supported emojis: `white_check_mark`/✅ → `allow_once`,
    `fast_forward`/⏩ → `always_allow`, `x`/❌ → `deny_once`,
    `no_entry_sign`/🚫 → `always_deny`.
  - 6 tests total (round-trip, missing-key, decoder coverage,
    happy path, user_mismatch, already_resolved race).

- **`slack_prompts.zig`** (new module) — `Orchestrator`,
  per-mention permission-prompt machinery:
  - Owns a heap-allocated `PermissionPrompter` + a dedicated
    64-event `AgentChannel` (separate from the agent's internal
    channel — only `tool_permission_request` events flow here,
    so the rest of the agent's stream is unaffected).
  - Drain thread reads each request, posts a Slack message with
    the formatted "agent wants to call `<tool>(<args>)`" body
    and four seed reactions, registers the prompt in the
    bot-level `prompts_state.Map`, and spawns a per-prompt
    detached timeout thread (default 600_000ms = 10 min per
    design B.3.3).
  - `start` / `stop` / `deinit` lifecycle. `stop` is idempotent
    and force-scrubs orphan map entries via `tryTimeoutResolve`
    BEFORE deinit'ing the prompter, so a slow concurrent
    reactor can't dereference a freed prompter pointer.
  - Argument truncation at 1024 chars to keep prompt messages
    readable.

- **`bot.Bot`** — three new fields:
  - `prompts: prompts_state.Map` — bot-wide map of pending
    Slack prompts.
  - `bot_user_id: []u8` — owned-duped at `setBotUserId`. Used
    by `dispatchReaction` to skip the bot's own seed reactions
    on prompt messages (without this guard, our own `:x:` seed
    would self-trigger the abort path).
  - `prompt_timeout_ms: u64` — env-overridable
    (`FRANKY_DO_PROMPT_TIMEOUT_MS`).

- **`bot.handleAppMention`** — added the orchestrator setup +
  teardown around the existing `agent.prompt` /
  `agent.waitForIdle` flow. Guards against the (unlikely)
  concurrent-mention-on-same-session case by only setting
  `gates.prompter` if it's currently null, and only nulling
  back its own pointer at teardown if we own it (concurrent
  mention's `agent.prompt` errors with `AgentBusy` and bails
  out cleanly without disturbing the active prompter).

- **`bot.dispatchReaction`** rewired:
  - Prompt-message reactions take precedence over abort/retry
    via new `tryRoutePromptReaction`. Without this, a user
    reacting `:x:` ("deny once") to a permission prompt would
    wrongly trigger `abortThread` (`x` is also our abort
    emoji); same for the bot's own seed `:x:`.
  - Skips reactions where `user == bot_user_id` for prompt
    messages (the four seed reactions we add).
  - Owner-only resolution per design B.3.4: a non-owner
    reaction is logged at `info` and ignored.
  - On accepted resolution, posts a `✓ allowed by <@user>` /
    `✗ denied by <@user>` status reply in the original thread.

- **`MentionWorkerArgs`** + dispatch path — added
  `mentioner_user_id` plumbing so `handleAppMention` can pass
  the owner id to the orchestrator. Retry path uses the
  reactor's user_id (the user who tapped `↩️`).

- **`main.zig`** —
  - New env: `FRANKY_DO_PROMPT_TIMEOUT_MS` (default 600_000).
  - Both bot init paths now set `bot.bot_user_id` after
    `auth.test` and write `prompt_timeout_ms`.
  - New module re-export: `pub const slack_prompts = …`.

### Race-safety highlights

The lifetimes nest like:

```
bot (process)
└── Store (process)
    └── Agent (per-thread, lifetime = cache entry)
        └── SessionGates (per-Agent, heap-allocated, stable addr)
            └── prompter (per-mention!) ← changes during the
                Agent's life
```

The interesting one is `prompter`: it points at a `PermissionPrompter`
that lives on the orchestrator's heap allocation, which only
exists for the duration of *one* `handleAppMention` call. That's
shorter than the Agent it's attached to. The map entries point
at the same prompter and are populated/cleared on a separate
thread (the orchestrator's drain thread) from the resolver
(reaction handler on the bot's read thread) and from the timer
(detached per-prompt). Three threads, one short-lived prompter,
several arbitrarily-stale references in flight at any moment.

The serialization point is `prompts_state.Map.mutex` — the only
place any thread is allowed to dereference `entry.prompter`.
`Orchestrator.stop` scrubs all the map entries it owns under the
same mutex, then deinit's the prompter once it knows nothing
else can reach it. Stale reactors / late timers see
`.not_found` and no-op.

### Tests

95/95 (was 89; +6 from `prompts_state` and `slack_prompts`):
- `Map: put + get + remove round-trip` (existing)
- `Map: missing key returns null without error` (existing)
- `decodeReaction maps the four supported emojis`
- `tryReactionResolve happy path: allow_once resolves prompter and removes entry`
- `tryReactionResolve user_mismatch returns expected_user_id and leaves entry`
- `tryReactionResolve already_resolved returns without erroring`
- `formatPromptText: includes tool name and args`
- `formatPromptText: truncates over-long args`

The four B.5 design tests are partially covered: happy path /
always-allow promotion / timeout (functionally exercised via
`tryTimeoutResolve` in stop's scrub path) / stale reaction. A
full end-to-end test that runs the entire orchestrator + drain
thread + Slack loopback server is a v0.3.4 follow-up — the
machinery to do that exists (see existing `bot.zig`
loopback-server tests) but is out of scope for this cut.

### Migration notes

- **Default behavior change vs v0.3.2:** with the prompter now
  wired, `write` / `edit` calls that previously fell through to
  the "permission gate active" refusal will now post a Slack
  prompt and wait. Operators want this; users see a new
  in-thread interaction.
- **Slack manifest:** no new scopes (already had
  `reactions:read` from Phase 7 and `reactions:write` from
  v0.3.0).
- **Performance:** Slack rate-limits `reactions.add` at Tier 3
  (~50/min/workspace). A workflow that triggers many gated
  calls per turn could hit this; per design B.3.2.3 we
  warn-and-skip on 429 rather than retrying.

### Deferred to v0.3.4

- Full e2e orchestrator test with loopback Slack server +
  `tool_permission_request` event injection.
- `--allow-tools` / `--deny-tools` / `--ask-tools` CLI flags
  (mirror of franky's overlay).
- Re-enabling `bash` once we've operationally proven the prompt
  flow (per design B.3.6 — bash deferred to v0.5).

## [0.3.2] — 2026-04-28 — permission overlay foundation (v0.4 design Feature B, Phase 1)

Third of three v0.4-design cuts — but split into two phases. **This
release is Phase 1 only**: the permission-overlay scaffolding
(franky's `permissions.Store` + per-Agent `SessionGates` wired via
the v1.22.0 `Agent.tool_gate` hook). **Phase 2** (the actual Slack
prompt UI — emoji-reaction approve/deny on a posted message) defers
to v0.3.3.

With Phase 1 in place, when `prompts_enabled` is on the bot owns a
workspace-wide `permissions.Store` and every Agent gets gates
pointing at it. Without a `PermissionPrompter` (Phase 2 territory),
calls that aren't pre-allowed currently fall through to franky's
"permission gate active — use --yes / --allow-tools" refusal — same
behavior as franky-core in `--prompts` mode without an interactive
TTY. Built-ins `read` / `ls` / `find` / `grep` are auto-allowed
(franky's default policy); `write` / `edit` / `bash` are gated.

This release is therefore *safe to deploy* (gates exist, persist
across restarts via `permissions.json`) and *not yet useful* for
end-users wanting interactive approval — that arrives in v0.3.3.
The split was chosen over a single big cut because (a) the
plumbing is already worth merging on its own, (b) the Slack
prompt UX has design questions (timeout, owner-only re-auth,
prompt vs response thread placement) better answered against a
shipping foundation than a paper design.

### What shipped

- **`agent_cache.Cache` extended** with an optional `gates:
  ?*permissions_mod.SessionGates` field on both `Entry` and
  `Victim`. `tryPut` signature gained `gates` (nullable);
  `popAll` / `popIdleOlderThan` / `popLeastRecentlyUsedLocked`
  carry it through to Victims; `freeVictim` calls
  `gates.deinit()` + frees the heap allocation. New accessor
  `entryGates(ulid) → ?*SessionGates` for Phase 2 use (the
  reaction handler will need to find the prompter on a session
  to call `resolve` on).

- **`bot.Bot`** gained two fields:
  - `prompts_enabled: bool = true` — gate the entire feature
    with one switch.
  - `permission_store: ?*permissions_mod.Store = null` —
    workspace-wide, lifetime owned by `cmdRun` /
    `runForInstalledWorkspace`.
  - `agentGates(ulid) → ?*SessionGates` accessor (Phase 2).

- **`bot.ensureAgent`** allocates a per-Agent `SessionGates` on
  the heap when `prompts_enabled` and `permission_store` are
  both set, then assigns `agent.tool_gate = .{ userdata = gates,
  before_tool_call = SessionGates.beforeToolCall, role_denied =
  SessionGates.roleDenied }` before publishing the agent into
  the cache. With `gates.prompter == null` (Phase 2 territory)
  the gate falls through to the standard refusal path. Cache
  victim cleanup deinits + frees the gates.

- **`prompts_state.zig`** (new module, **unused in Phase 1**) —
  the bot-level `(channel, prompt_ts) → PromptEntry` map that
  Phase 2 will populate when posting "agent wants to call X"
  Slack messages. Map / put / get / remove + 2 round-trip
  tests. Wiring it lives in v0.3.3.

- **`main.zig`** (`cmdRun` + `runForInstalledWorkspace`):
  - New `--no-prompts` CLI flag (cmdRun only; `--all` falls
    through to env).
  - New env vars: `FRANKY_DO_PROMPTS=0` to disable;
    `FRANKY_DO_REMEMBER_PERMISSIONS=0` to opt out of disk
    persistence (default: persist to
    `$FRANKY_DO_HOME/permissions.json`).
  - `resolvePromptsEnabled` / `resolveRememberPermissions` /
    `initPermissionStore` / `freePermissionStore` helpers.
  - Both bot init paths now allocate a workspace-wide `Store`
    when prompts are on, and `defer freePermissionStore` it.

- **public re-export**: `pub const prompts_state =
  @import("prompts_state.zig");` from `main.zig` (so tests can
  reach it; Phase 2 callers will too).

### Why this is opt-out, not opt-in

Mirroring franky-core's `--prompts` default-on policy: the upgrade
shouldn't silently start auto-approving destructive tool calls
that would have been gated under Phase 2. Today that means
`write` / `edit` / `bash` will refuse without a Phase-2 prompter
or an explicit `--allow-tools` (TBD). Operators wanting the v0.3.1
"yolo" experience set `FRANKY_DO_PROMPTS=0`.

### Migration notes

- **Adopters running v0.3.1 in production**: rolling forward to
  v0.3.2 *without* setting `FRANKY_DO_PROMPTS=0` will start
  refusing `write` / `edit` / `bash`. Until v0.3.3 ships, the
  pragmatic option is `FRANKY_DO_PROMPTS=0` in the env.
- **Adopters who want to start collecting `permissions.json`
  state today**: leave the default. Built-in read tools work; the
  permissions store will start empty and stay empty (no prompter
  to record "always-allow" decisions yet) but the file path is
  reserved.

### Tests

89/89 (was 87 before this cut: +2 from `prompts_state.zig`'s
round-trip and missing-key tests).

### Deferred to v0.3.3 (Phase 2 — Slack prompt UI)

- Per-mention `PermissionPrompter` (one prompter per mention
  worker) + `permission_channel` for `tool_permission_request`
  events draining off the Agent's stream.
- "agent wants to call `<tool>` with `<args>` — react ✅ / ❌"
  Slack messages, owner-only resolution (B.3.4), 10-minute
  per-prompt timeout thread, reaction routing in
  `dispatchReaction`.
- `--allow-tools` / `--deny-tools` / `--ask-tools` CLI flags
  (mirror of franky's `--prompts`/`--allow-tools` overlay) so
  ops can pre-allow well-known calls without per-prompt clicks.

## [0.3.1] — 2026-04-28 — session hibernation (v0.4 design Feature C)

Second of three v0.4-design cuts. Closes the long-standing Phase 5
gap that `agent_cache.zig` had flagged since day one — bounded
in-memory cache + idle eviction + lazy disk reload — so a returning
user picks up days/weeks later with full thread context. Designed
in `v0.4-design.md` §C.

### What shipped

- **`agent_cache.Cache` extended**:
  - `Entry { agent, session_dir, last_access_ms }` per ULID
    (atomic timestamp so the sweeper reads without taking the
    cache mutex).
  - `cap` field, default 16 (`FRANKY_DO_AGENT_CACHE_SIZE` env
    override).
  - `tryPut` enforces `cap`; on overflow returns the LRU entry
    as a `Victim` for the bot to persist + free.
  - `popIdleOlderThan(ms)` returns Victims past the idle
    threshold for the sweeper.
  - `popAll()` drains the cache for graceful-shutdown
    persistence.
  - `freeVictim(v, deinit_agent)` centralizes the
    victim-cleanup path.

- **`agent_hibernate.zig`** (new module):
  - `persist(allocator, io, session_dir, agent, model_id, …)` —
    drives `franky.coding.session.save` (writes `session.json` +
    `transcript.json`) and a sibling `franky_do.json` carrying
    franky-do-specific metadata (currently just
    `last_active_ms`; v0.3.2+ will add per-thread cwd when
    `bash` is re-enabled).
  - `load(allocator, io, parent_dir, ulid, cfg) → Agent` —
    initializes a fresh Agent with `cfg`, replaces its empty
    transcript with the loaded one, returns ready for
    `subscribe` + `prompt`. Returns `error.SessionNotFound`
    cleanly if no transcript on disk (clean cache miss);
    `error.HibernateIoFailed` for actual corruption / IO
    failure (caller logs + mints fresh).
  - **Compaction-on-reload deferred to v0.3.1.1.** The current
    cut emits a warn-level log when a rehydrated transcript
    exceeds 80% of a conservative 200_000-token window
    (`compaction.shouldTrigger == .soft`). Actually running
    `coding/compaction.run` requires a `branching.Tree` plus an
    LLM round-trip — both real but worth their own milestone.
    Worst case today: `context_overflow` on the next turn,
    which the user can `/franky-do reset` past.

- **`bot.ensureAgent`** rewritten:
  - Fast path: `cache.get` (no rehydrate mutex held).
  - Slow path: under new `bot.rehydrate_mutex` (double-checked),
    attempt `agent_hibernate.load` from disk; fall back to
    minting fresh on `SessionNotFound` (or after warning on
    `HibernateIoFailed`).
  - Signature gained a `team_id` parameter so the session_dir
    can be computed correctly under
    `<home>/workspaces/<team_id>/sessions/<ulid>`.
  - `tryPut` may evict an LRU Victim — `bot.persistAndFreeVictim`
    handles persist-then-free.

- **Sweeper thread** (in `main.zig`):
  - Spawned per `cmdRun` / per `runForInstalledWorkspace`.
  - Wakes every `FRANKY_DO_SWEEPER_INTERVAL_MS` (default 5min);
    pops idle entries older than `FRANKY_DO_IDLE_EVICTION_MS`
    (default 30min); persists each, drops.
  - 100ms-slice interruptible sleep so SIGTERM responds within
    100ms instead of waiting up to 5 minutes for the next wake.

- **Graceful shutdown**: `bot.deinit` now drains `cache.popAll`
  and persists every in-flight Agent before tearing down. Ctrl-C
  no longer evaporates active conversations.

### Configuration matrix

| Env var | Default | Purpose |
|---|---|---|
| `FRANKY_DO_AGENT_CACHE_SIZE` | `16` | Hard cap on in-memory Agents |
| `FRANKY_DO_IDLE_EVICTION_MS` | `1_800_000` (30 min) | Evict if no activity for this long |
| `FRANKY_DO_SWEEPER_INTERVAL_MS` | `300_000` (5 min) | Sweeper wake cadence |

All three info-logged at startup so operators see the active
configuration:

```
INFO franky-do hibernation cache_size=16 idle_eviction_ms=1800000 sweeper_interval_ms=300000
```

### Tests (+3 → 87)

- `Cache: get/tryPut round-trip and last-access touch` —
  basic semantics + LRU timestamp update on `get`.
- `Cache: cap-driven LRU eviction returns oldest as Victim` —
  cap = 2, third insert evicts LRU; touch refreshes recency.
- `Cache: popIdleOlderThan returns stale entries` — sweeper
  primitive; entries past the cutoff land in the Victim slice,
  fresh entries stay.
- `Cache: drop returns Victim without persistence concerns` —
  the `/franky-do reset` path's clean-eviction primitive.
- `persist + load: fresh agent round-trips transcript through
  disk` — end-to-end round-trip through
  `franky.coding.session.save/load` + `franky_do.json`.
- `load: missing transcript.json returns SessionNotFound` —
  the clean-cache-miss case.

### Files changed

- `src/agent_cache.zig` — Cache rewritten around `Entry +
  Victim`; LRU + idle + popAll + freeVictim. New
  `TestAgentFixture` for clean test resource ownership.
- `src/agent_hibernate.zig` — new module + 2 round-trip tests.
- `src/bot.zig` — `rehydrate_mutex` field;
  `ensureAgent(team_id, ulid)` rewritten with double-check +
  rehydrate; new `persistAndFreeVictim` helper; `deinit` now
  drains cache via `popAll` and persists.
- `src/main.zig` — `HibernationKnobs` + `resolveHibernationKnobs`;
  `SweeperArgs` + `sweeperMain` + `nanoSleepInterruptible`;
  spawned in both `cmdRun` and `runForInstalledWorkspace`;
  startup info-log of the three env vars; version
  0.3.0 → 0.3.1.

### Try it

```sh
FRANKY_DO_LOG=info \
FRANKY_DO_MODEL=gemma4:latest \
FRANKY_DO_AGENT_CACHE_SIZE=4 \
FRANKY_DO_IDLE_EVICTION_MS=60000 \
FRANKY_DO_SWEEPER_INTERVAL_MS=15000 \
FRANKY_FIRST_BYTE_TIMEOUT_MS=600000 \
CLAUDE_CODE_OAUTH_TOKEN=<real-token> \
./zig-out/bin/franky-do run --workspace T01FJ263RD1
```

Mention the bot in five different threads. After ~15s of
inactivity in the first thread, you'll see:

```
INFO franky-do sweeper evicted+persisted 1 idle session(s)
```

Returning to that thread an hour later and posting again, the
`hibernate` log line shows the rehydration:

```
INFO franky-do hibernate rehydrated ulid=... messages=12
```

Stop the bot with Ctrl-C; you'll see remaining cache entries
flush:

```
DEBUG franky-do hibernate evicted+persisted ulid=...
```

### Known limitations / deferred to v0.3.1.1

- **Compaction-on-reload** is detected (warn log) but not
  executed. Next turn on a >80%-of-window transcript may hit
  `context_overflow`.
- **Per-thread cwd** isn't yet serialized into `franky_do.json`
  (the bot's `bash` tool stays disabled, so cwd doesn't carry
  meaningful state). v0.3.2+ when bash is re-enabled.
- **Multi-process safety**: two `franky-do run --workspace T...`
  processes hitting the same disk session would conflict on
  rehydrate. The `bindings.json` flock pattern from session_map
  could be lifted here; deferred until anyone runs duplicate
  instances on purpose.

## [0.3.0] — 2026-04-28 — emoji status indicators (v0.4 design Feature A)

First of three v0.4-design cuts. Adds **reactions on the user's
`@`-mention message** so the bot's state is visible without
scrolling: 👀 (mention received) → 💭 (agent working) → ✅ (done) /
❌ (error). Designed in `v0.4-design.md` §A.

### What shipped

- **Web API extension** — new `Client.reactionsAdd(.{ channel,
  timestamp, name })` wraps Slack's `reactions.add` endpoint;
  same-shape `ApiError` + JSON-parsed response as the existing
  `chat.postMessage` / `chat.update`.
- **`ReactionsSubscriber`** (new `src/reactions_subscriber.zig`) —
  registers as a second `franky.agent.Agent.subscribe` callback.
  Tracks per-mention idempotency via atomic flags so multi-turn
  flows don't post the same emoji twice. Bot-level lifecycle:
  - `markReceived()` — fires 👀 synchronously when handleAppMention
    enters.
  - `onEvent(.turn_start)` — fires 💭 once across all turns.
  - `onEvent(.agent_error)` — flips `is_error_state`; bot reads
    via `errorFlagged()` after `waitForIdle`.
  - `markFinal(.success | .error_state)` — fires ✅ or ❌; the
    bot calls this once after `waitForIdle()` returns.
- **Buffered (effectively dropped) `🔧` per A.3.3** — per-tool
  reactions would race Slack's Tier-3 50/min/workspace rate limit
  on long agent runs. We trade per-tool granularity for a
  constant 3-API-calls-per-mention budget. Streamed `chat.update`
  text is the per-tool feedback channel.
- **Trail left in place per A.3.4** — `👀 + 💭 + ✅` stays as a
  visible audit trail; we don't issue `reactions.remove` calls.
- **429 graceful degradation per A.3.3** — rate-limited responses
  log at warn and skip; no retries, no failures. The
  user-visible degradation is "reactions stop appearing,"
  never "the bot fails."
- **`MentionWorkerArgs.user_message_ts`** — new field carrying
  the user's mention `ts` (distinct from `thread_ts` for
  top-level mentions). `bot.dispatchSlackEvent` populates from
  `ev.ts`; `retryThread` uses `thread_ts` as a fallback (the
  thread root is the original mention for top-level threads).

### Slack workspace migration

The manifest gained the **`reactions:write` OAuth scope**.
Operators upgrading from v0.2.x must reinstall the app to their
workspace and refresh the bot token. See `TESTING.md` §"Migrating
from v0.2.x to v0.3.0" for the click-path.

### Tests (+5 → 84)

- `buildReactionsAddBody: basic shape` — round-trips the new
  endpoint's body through the JSON builder.
- `ReactionsSubscriber: markReceived → 👀 fires once even on
  repeat calls` — idempotency.
- `ReactionsSubscriber: turn_start → 💭, markFinal(.success) → ✅
  in source order` — multi-turn dedup.
- `ReactionsSubscriber: agent_error then markFinal(.error_state)
  fires ❌` — error path; covers the
  `is_error_state` / `posted_terminal` interaction.
- `ReactionsSubscriber: 429 from Slack does not panic` — rate
  limit handling; assert no crash and subsequent calls still
  attempt.
- (Updated) `Bot.handleAppMention: end-to-end posts placeholder
  then streams updates` — assertions extended to also verify
  `eyes` + `thought_balloon` + `white_check_mark` reactions
  landed.

### Files changed

- `src/slack/web_api.zig` — `ReactionsAdd{Args,Response}` +
  `reactionsAdd()` + `buildReactionsAddBody()` + 1 test.
- `src/reactions_subscriber.zig` — new module + 4 tests.
- `src/main.zig` — `pub const reactions_subscriber` export;
  version bump 0.2.3 → 0.3.0; matching test fixture update.
- `src/bot.zig` — import `reactions_sub_mod`;
  `MentionWorkerArgs.user_message_ts` field plus dupes/frees;
  `handleAppMention` signature gains `user_message_ts`; the
  retry path passes `thread_ts` as a fallback; the e2e test
  asserts the new emoji reactions.
- `slack-app-manifest.yaml` — `reactions:write` scope added with
  inline migration note.
- `franky-do.md` §0 — already notes the v0.2.x verification;
  no further status change here. The v0.4-design pointer stays.

### Try it

```sh
FRANKY_DO_LOG=info \
FRANKY_DO_MODEL=gemma4:latest \
FRANKY_FIRST_BYTE_TIMEOUT_MS=600000 \
CLAUDE_CODE_OAUTH_TOKEN=<real-token> \
./zig-out/bin/franky-do run --workspace T01FJ263RD1
```

`@`-mention the bot in a channel. Within ~1s you should see 👀
appear on your message, then 💭 once the agent starts. After the
final turn completes, ✅ joins the trail. If anything errors mid-
run, ❌ replaces the would-be ✅.

If reactions don't appear: confirm the app was reinstalled after
the manifest change (the v0.2.x bot token doesn't carry the new
scope).

## [0.2.3] — 2026-04-28 — read FRANKY_*_TIMEOUT_MS env vars

`stream_options.timeouts` was never populated, so the HTTP
transport silently used its hardcoded 30 s defaults. Operators
who tried `FRANKY_FIRST_BYTE_TIMEOUT_MS=300000` to wait out a
slow Ollama under heavy thinking workload saw the var get
ignored and the model time out at 30 s as before.

### What shipped

New `resolveTimeoutsFromEnv` helper that mirrors franky's
`print.resolveTimeoutsFromMap` shape for the env-var fallback
path, reading the four canonical vars:

- `FRANKY_CONNECT_TIMEOUT_MS` (default 10000)
- `FRANKY_UPLOAD_TIMEOUT_MS` (default 30000)
- `FRANKY_FIRST_BYTE_TIMEOUT_MS` (default 30000)
- `FRANKY_EVENT_GAP_TIMEOUT_MS` (default 30000)

Wired into `stream_options.timeouts` in both `cmdRun` (single
workspace) and `runForInstalledWorkspace` (the `--all` worker).
Resolved values are info-logged at startup so operators can
confirm:

```
INFO franky-do timeouts connect=10000ms upload=30000ms first_byte=300000ms event_gap=30000ms
```

### Files changed

- `src/main.zig` — `resolveTimeoutsFromEnv` helper; both
  stream_opts assignment sites populate `.timeouts`; usage
  banner + the `Environment` table both list the four vars
  with defaults.
- `franky-do.md` §10.3 — env table extended; brief note on
  why the names match franky's (single-env-set deployments).
- `src/main.zig` version bump 0.2.2 → 0.2.3 (also updates the
  `phase 0: our own version constant is set` test fixture).

## [0.2.2] — 2026-04-28 — plain-text reply policy + premature-shutdown bug fix

Two issues uncovered while testing tool-using turns end-to-end with
gemma4 on Ollama.

### Bug fix — subscriber shutdown on the first `turn_end`

`StreamSubscriber.onEvent` was treating `turn_end` as the
"conversation is over" signal and flipping `done = true`. But
franky's agent loop runs **multiple turns** when the model
returns `tool_use` — it pushes a `turn_end` after each iteration,
then continues with the next turn that consumes the tool result
and produces text. The subscriber's timer thread saw the first
`turn_end`, exited after a final flush of the (empty) buffer,
and the second turn's text deltas accumulated locally but never
reached Slack.

Fix: `turn_end` is now logged at debug but does *not* flip
`done`. The bot's `defer sub.stop()` (which fires after
`agent.waitForIdle()` returns and the worker thread has
joined — i.e., all turns truly done) is the canonical
conversation-end signal. `agent_error` still flips `done`
immediately because it is genuinely terminal.

This was the first bug surfaced by v0.2.1's diagnostic logging.
Without `FRANKY_DO_LOG=trace`, it would have looked like
"some replies just don't make it to Slack" with no obvious
cause.

### Reply formatting — plain text only

The system prompt previously instructed the model to use Slack's
mrkdwn dialect (`*bold*` single asterisks, no headings). Weak
open-source models like gemma4 ignore those instructions and
emit standard markdown (`**bold**`, `### heading`) anyway, which
Slack renders as literal punctuation. Switching to a plain-text
policy guarantees correct rendering regardless of how well the
model follows formatting instructions:

```
You are franky-do, a coding assistant in a Slack thread.
Reply in plain text. Do not use markdown headings, asterisks
for bold, underscores for italic, or bullet markers — Slack's
mrkdwn dialect renders them inconsistently. Use blank lines
to separate paragraphs. Triple-backtick code fences are OK
(Slack renders them).
```

A v0.4 follow-up will introduce server-side standard-markdown→
mrkdwn translation so we can let the model produce richer output
and translate before posting. Full design captured in
`franky-do.md` §16.2.

### New diagnostic logging (composes with v0.2.1's)

- **Tool surface audit** — at startup, info-log the registered
  tool names + count: `tools count=6 names=[read,write,edit,ls,find,grep]`.
  Confirms what the bot has wired without grepping source.
- **Per-step `handle` lifecycle** — every `dispatchSlackEvent`
  worker logs at debug: `step=enter`, `step=session_resolved`,
  `step=agent_ready`, `step=agent.prompt`, `step=waitForIdle`,
  `step=idle accumulated_bytes=N updates=M`, `step=exit`.
- **`chat.postMessage` / `chat.update` send + response** — both
  endpoints now log at debug before the call and after, with the
  `ts` echoed back. Failures log at warn with the error name.
- **Stream-event visibility** — `StreamSubscriber.onEvent` now
  logs every `AgentEvent` kind (trace), with `text_delta` /
  `thinking_delta` / `toolcall_args` byte counts. Critically,
  `tool_execution_start` and `tool_execution_end` log at info
  with the tool name + call_id + result.is_error so a stalled
  tool call is visible without enabling trace.

### Files changed

- `src/main.zig` — tool-list audit log; new plain-text system
  prompt; comment block explaining the Option-A vs Option-B
  trade-off + pointer to the spec.
- `src/bot.zig` — handleAppMention step logging;
  chat.postMessage send/response logging; default
  `Config.system_prompt` updated to match the plain-text
  policy.
- `src/stream_subscriber.zig` — drop the `turn_end → done=true`
  bug; per-event-kind trace logging; tool_execution_start/end
  surfaced at info; chat.update send/response logging.
- `franky-do.md` — new §16.2 "Markdown reply formatting — v0.4
  roadmap" with the full Option B design (translation rules,
  edge cases, where the translator lives).

## [0.2.1] — 2026-04-28 — diagnostics + model override + Socket Mode parser fix

Three follow-ups uncovered while standing up franky-do for the
first time in a real workspace.

### Bug fix — Socket Mode envelope parser

`parseInboundEvent` was finding the wrong `type` field. Slack's
real envelopes order `payload` *before* the outer `type` field;
the hand-rolled `findStringField` did `std.mem.indexOf` and
returned the first match — which was the inner
`payload.event.type` (`"message"` / `"app_mention"`) rather than
the outer `"events_api"`. Result: every real Slack event got
tagged as `EventType.unknown` and dropped silently. The bot
*looked* connected but no event ever reached the dispatcher.

Fix: replaced the hand-rolled parser with `std.json.parseFromSlice`
(arena-scoped, `ignore_unknown_fields = true`). Hot-path concerns
in the original comment were overblown — Slack message rates
don't justify hand-rolling JSON parsers.

+4 tests:
- `parseInboundEvent: events_api with payload BEFORE outer type`
  reproduces the real Slack ordering.
- `parseInboundEvent: app_mention payload with payload-first
  ordering` covers the @-mention shape.
- `parseInboundEvent: malformed JSON → unknown` confirms the new
  parser doesn't crash on garbage.
- (`buildAckMessage` and the existing happy-path tests now pass
  with the allocator-taking signature; tests updated to pass
  `testing.allocator`.)

API change: `parseInboundEvent` now takes an allocator as its
first argument. The only non-test caller is `Handler.serverMessage`
which has access to `self.sm.allocator`.

### New — diagnostic logging via `franky.ai.log`

Set `FRANKY_DO_LOG=info|debug|trace` to opt in (off by default).
Optionally set `FRANKY_DO_LOG_FILE=<path>` to redirect from
stderr.

- `info` — connect status, dispatch summary, mention worker
  outcomes (success / error name).
- `debug` — every inbound socket-mode event with type +
  envelope_id + bytes; dispatch decisions including dropped
  events with the reason.
- `trace` — full raw JSON of every inbound payload (useful when
  diagnosing schema issues like the Socket Mode parser bug
  above).

Reuses the leveled logger from `franky.ai.log` — same level
parsing + sink redirection as `franky --log-level`. Several
previously-silent `catch {}` paths in the dispatch flow now
log the swallowed error at `warn`.

### New — model override

`--model <id>` flag (per-run, in `cmdRun`) and `FRANKY_DO_MODEL`
env var (works for `run` and `run --all`) override the previously-
hardcoded `claude-sonnet-4-6`. Default is now `claude-sonnet-4-5`
(broader subscription compatibility under
`CLAUDE_CODE_OAUTH_TOKEN`).

Precedence: `--model` flag > `FRANKY_DO_MODEL` env >
`default_model_id`. Per-run logs the resolved id at `info` so
operators see what's active.

This is a stop-gap. v0.3 will replace the env-only model selection
with a full reuse of franky's profile system (`franky.coding.profiles`,
shipped in franky v1.17.0) — see `franky-do.md` §16.1 for the
roadmap. With profiles, `--profile <name>` resolves provider +
model + base_url + api_key_env in one shot using franky's
existing built-in catalog (`cloudflare-llama`, `groq`, `cerebras`,
`openrouter`, `ollama`, `lm-studio`, …) plus any user-defined
entries in `~/.franky/settings.json`.

### Files changed

- `src/slack/socket_mode.zig` — `parseInboundEvent` rewritten
  to use `std.json.parseFromSlice`; signature now takes an
  allocator. `findTopLevelEnvelopeId` retained as a small
  string helper for the borrow-into-raw-JSON envelope id.
  +4 tests; 75 → 79.
- `src/main.zig` — `initLogging` + `resolveModelId` helpers;
  `--model` + `FRANKY_DO_MODEL` parsing; logging hooks at
  inbound-event dispatch + connect/run error paths.
- `src/bot.zig` — `dispatchSlackEvent` logs every parsed event +
  dispatch decision; `mentionWorker` logs success / `handleAppMention`
  failure at info / warn.
- `franky-do.md` — `--model` documented in §10.1; new env vars
  in §10.3; new §16.1 "Profile system reuse — v0.3 roadmap"
  with the full integration design.

### Known issue

DM dispatch — `bot.dispatchSlackEvent` only routes `app_mention`
and `reaction_added`. `message` events with `channel_type: "im"`
(the DM-to-bot path) are received and logged-as-dropped. Manifest
already subscribes to `message.im`. Fix is small (~30 LOC) but
deferred to its own commit. Documented in §16.

## [0.2.0-phase-8] — 2026-04-25 — reactions + cost dashboards

Two operator-visible additions on top of the v0.1.0 baseline.

### Phase 7 — reactions-as-control

- New `reaction_added` event subtype on `EventsApiEnvelope`;
  `Bot.dispatchSlackEvent` routes it to a dedicated path. Two
  reactions are wired (everything else drops at debug):
  - `:x:` (❌) → `Agent.abort()` on the thread's live agent.
  - `:leftwards_arrow_with_hook:` (↩️) → abort + replay the
    last user prompt through the existing `mentionWorker`
    pipeline (so subscriber + chat.postMessage flow stays
    identical to a fresh `@`-mention).
- `Bot.recordReplyAnchor` cache: `(team_id, reply_ts) →
  thread_ts`, bounded LRU with 1024 slots. Populated whenever
  the bot posts a reply, consulted by `resolveReactionThread`
  so reactions on the bot's *reply* (the natural target) map
  back to the thread without an extra `conversations.replies`
  round-trip.
- Audit lines posted in-thread on every action — `✋ aborted
  by <@user>` / `↩️ retrying last prompt (requested by
  <@user>)` — so silent state changes don't surprise other
  thread participants.
- New scope: `reactions:read`. Existing installs need to
  reinstall the app to pick it up. `TESTING.md` updated with
  the new scope row, the new event subscription, and Test E.

### Phase 8 — cost / token dashboards

- New `franky-do stats` CLI subcommand. Walks
  `$FRANKY_DO_HOME/sessions/*`, parses each `session.json` for
  the model id and each `transcript.json` for `usage.input` /
  `usage.output`, sums per session, applies prices from
  `src/pricing.zig`, and prints a Markdown table:
  `ulid · model · input · output · cost`. Sessions whose model
  doesn't match a pricing-table prefix show `n/a` cost; the
  totals row excludes them and a footer notes the gap.
- `pricing.zig` ships v0.1 entries for `claude-{opus,sonnet,
  haiku}-4`, `claude-3-5-{sonnet,haiku}`, `claude-3-opus`.
  Longest-prefix match resolves version suffixes. `lookup`
  returns null on unknown ids; `estimate` returns null too.
- New `/franky-do stats` slash subcommand posts the workspace
  aggregate (`{N} sessions, {input}/{output} tokens, total est.
  cost: ${cost}`) into the slash command's invoking thread.
  Per-session detail stays in the CLI — channels stay readable.
- Bot.Config gains an optional `home_dir` so the slash handler
  can find session data; missing → command degrades to a
  one-line `_stats unavailable…_` message.

### Test surface

- 67 → 76 unit tests. New: `EventsApiEnvelope` parses
  `reaction_added`, `recordReplyAnchor` round-trip + LRU
  semantics, unknown-emoji drop, `pricing.lookup` matrix,
  `pricing.estimate` math, `stats.render` empty / known-model
  / unknown-model.
- `TESTING.md` Tests E and F cover the new operator paths.

### Files changed
`src/bot.zig`, `src/main.zig`, `src/pricing.zig` (new),
`src/stats.zig` (new), `franky-do.md` (§3.5 + §18 + §19),
`TESTING.md` (Step 3, 4, Tests E + F), `CHANGELOG.md`.

## [0.1.0-phase-6] — 2026-04-24 — `run` loop wired end-to-end

The piece that turns franky-do from "every component tested in
isolation" into a runnable bot. `franky-do run` now opens a real
Slack Socket Mode connection, dispatches `app_mention` events to
the agent, and routes `slash_commands` to a `/franky-do reset` /
`/franky-do help` handler. `--all` mode runs every installed
workspace in parallel.

### Surface

```
franky-do run                          # one workspace from env
franky-do run --workspace T0123456     # one specific installed workspace
franky-do run --all                    # every installed workspace in parallel
```

Environment:
- `SLACK_APP_TOKEN` + `SLACK_BOT_TOKEN` — when no `--workspace`
- `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` — LLM creds

### What landed

- **WSS connect in `socket_mode.zig`** — `connect()` parses the
  WSS URL, builds a `ws.Client` with `tls=true`, runs the
  handshake. `run()` blocks on `client.readLoop`. `close()`
  joins. Heap-allocated client + handler pair owned by the
  SocketMode.
- **Dispatcher in `bot.zig`** — `dispatchSlackEvent` parses the
  `events_api` envelope, extracts `team_id` / `channel` /
  `thread_ts` / `text`, strips the `<@UBOT>` prefix, spawns a
  detached worker that runs `handleAppMention`. A new wait-group
  counter (`Bot.in_flight`) blocks `Bot.deinit` until every
  worker has exited — a real correctness fix surfaced by the
  test suite.
- **Slash command handler** — `dispatchSlashCommand` for the
  `slash_commands` envelope. `reset` drops the session for the
  thread and posts a confirmation; `help` prints the command
  list; unknown subcommands echo a usage hint.
- **`franky.agent.Agent` Config gained `stream_options`** — the
  one franky-side change needed to wire real providers. The
  Agent now forwards the caller's `StreamOptions` (api_key /
  auth_token / environ_map / hooks) to every `agentLoop` call.
  Backward-compatible: default `.{}` behaves exactly as before.
  franky's 687-test suite still passes.
- **`runAll` / `runForInstalledWorkspace`** — multi-workspace
  parallelism. One thread per installed workspace, each owning
  its own api Client / Bot / SocketMode. Anthropic registry is
  shared since it's stateless after registration.
- **`stripMentionPrefix`** — peels Slack's `<@UBOT>` /
  `<@UBOT|name>` mention prefix off so the model sees a clean
  prompt. Six unit tests covering shapes Slack actually sends.

### Tests

61 → 63 passing. New:
- 2 slash-command tests (reset + help) using the loopback Slack
  server, asserting both side effects (session drop) and the
  resulting `chat.postMessage` body shape.

WSS-handshake-against-real-Slack remains a manual smoke step
(documented in README); CI doesn't cover it.

### Known gaps deferred to v0.2+

- Reconnect on socket-mode disconnect — currently the read loop
  just exits cleanly. The `run` returns; in `--all` mode that
  workspace's thread exits while others keep running. Polish
  for v0.2.
- Bash sandboxing — Phase 7 per spec §6.4.
- 40k-character message-split — defined in §7.3, not implemented.

## [0.1.0-phase-5] — 2026-04-24 — Persistence + multi-workspace CLI

Ships the storage half of franky-do v0.1: workspace tokens and
per-thread session bindings persist to disk, with a CLI surface
(`install` / `uninstall` / `list`) for managing them.

### What's new

- **`src/auth.zig`** — `auth.json` round-trip per workspace.
  Atomic-write pattern (tempfile + rename) mirroring franky's
  session.zig. `read` / `write` / `list` / `uninstall` operations.
- **`src/session_map.zig` persistence** — `persistToDisk` /
  `loadFromDisk` for `bindings.json`. JSON object of
  `{"<thread_ts>": "<ulid>"}`. Per-team scoped — saving T1's
  bindings doesn't bleed T2's into the file.
- **CLI subcommands** in `src/main.zig`:
  - `franky-do install --workspace T... --xapp xapp-... --xoxb xoxb-... [--name "Acme"]`
  - `franky-do uninstall --workspace T...`
  - `franky-do list`
  - All resolve `$FRANKY_DO_HOME` (default `$HOME/.franky-do`).
- End-to-end CLI smoke verified: install creates the auth.json,
  list shows it, uninstall removes the dir.

### Tests

54 / 54 passing (was 45). New test cases:
- 7 auth round-trip / list / uninstall / validation tests
- 2 session-map persistence round-trip tests

### Deferred to Phase 6

The actual `franky-do run` loop — wiring socket-mode to the bot
to a real Slack workspace — is the remaining piece. All
components (`socket_mode`, `bot`, `stream_subscriber`,
`session_map`, `auth`) are built and tested; Phase 6 just
assembles them in `main.zig`'s `run` handler. The `--all`
multi-workspace runtime and the `/franky-do reset` slash command
both depend on the run loop and move with it.

## [0.1.0-phase-4] — 2026-04-24 — Streaming + throttled chat.update

`stream_subscriber.zig` coalesces 50 Hz agent text deltas into
~1 Hz `chat.update` calls so the bot stays under Slack's rate
limit. Per-turn timer thread; final unconditional flush on
`turn_end`. Bot's `handleAppMention` now posts a placeholder
via `chat.postMessage` then streams updates against that `ts`.

45 / 45 tests passing (was 44). New: end-to-end test with
50 synthesized text deltas → asserts the throttler issues a
small handful of updates rather than 50.

## [0.1.0-phase-3] — 2026-04-24 — Single-turn agent driver

`session_map`, `agent_cache`, and `bot` modules. Per-message
flow: resolve thread → ULID via session map, get/create
`franky.agent.Agent` via cache, prompt + waitForIdle,
`chat.postMessage` the accumulated text. Tools registered (none
of the seven enabled yet — Phase 4 turns them on).

44 / 44 tests passing (was 32). New: end-to-end test using the
faux LLM provider + a faux Slack server proving the whole
pipeline lands the right text in the right channel.

## [0.1.0-phase-2] — 2026-04-24 — Slack Socket Mode primitives

`socket_mode.zig` carries the WSS URL parser, ACK builder,
inbound-event tagged union, and `SocketMode.refreshWssUrl`
which calls `apps.connections.open`. Reconnect semantics
documented; actual reconnect loop ships with the run-loop
wiring in Phase 6.

32 / 32 tests passing (was 15). New: 13 socket_mode tests
covering URL parser edge cases, ACK roundtrip, event-type
detection, and the apps.connections.open round-trip via a
loopback HTTP server.

## [0.1.0-phase-1] — 2026-04-24 — Slack Web API client

`web_api.zig` with typed wrappers for four endpoints:
`auth.test`, `apps.connections.open`, `chat.postMessage`,
`chat.update`. Reuses
`franky.ai.http.fetchWithRetryAndTimeoutsAndHooks` so we
inherit franky's v1.8.0 per-phase HTTP timeouts +
§F.1 retry policy.

15 / 15 tests passing (was 4). New: 11 tests covering each
endpoint's payload shape, response parsing, error path,
and authorization-header behavior. Tests stand up a loopback
HTTP server and assert request shape end-to-end.

## [0.1.0-phase-0] — 2026-04-24 — Project skeleton

Lays the foundation: the build composes `franky` (path dep) + the
`websocket.zig` library (URL-pinned URL dep) into a single
`franky-do` executable with a working `--version` / `--help`
surface and four smoke tests proving both dependency seams hold.

### What works

- `zig build` produces `zig-out/bin/franky-do`.
- `franky-do --version` prints `franky-do 0.1.0 (franky 1.8.0, websocket.zig vendored)`.
- `franky-do --help` prints the placeholder usage.
- `zig build test` runs 4 phase-0 smoke tests, all passing.
- The franky SDK facade is accessible: `franky.sdk.Agent`,
  `franky.sdk.Transcript`, `franky.sdk.Registry`,
  `franky.sdk.Channel` all reference cleanly at compile time.
- The websocket library imports cleanly: `ws.Client` references.

### What doesn't work yet

Everything else. `franky-do run` is a stub that prints "Phase 0:
`run` is a stub" and exits.

### Notes

- `build.zig.zon` pins `websocket.zig` to commit
  `d823a7d8cb3e43b3789208ae499bfe1d077de8ee` (master, 2026-04-25).
  31/31 of websocket.zig's own tests pass on Zig
  `0.17.0-dev.87+9b177a7d2`, our pinned toolchain.
- Required a one-line change to franky's `build.zig`:
  `b.createModule(...)` → `b.addModule("franky", ...)` so the
  module is visible to dependent builds. Verified franky's own
  687-test suite still passes after the change.
