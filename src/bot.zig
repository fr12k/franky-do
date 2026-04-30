//! Top-level Bot — ties Slack Web API + session map + agent cache
//! into the per-message pipeline.
//!
//! `handleAppMention(team_id, channel, thread_ts, text)` resolves a
//! session, ensures an `Agent`, wires the v0.5.0 per-message Slack
//! poster (one `chat.postMessage` per assistant `message_end`),
//! runs the agent to idle, and drains posted-bubble timestamps into
//! the reply-anchor cache so reaction-based controls keep working.
//!
//! Threading: Phase 3 runs the agent's loop synchronously on the
//! caller's thread. Phase 4+ may hand the work off to a worker pool
//! so the Socket Mode read thread stays responsive — at that point
//! the caller's thread is the work-queue drain thread, not the
//! socket read thread.

const std = @import("std");
const franky = @import("franky");
const ai = franky.ai;
const agent_mod = franky.agent;
const at = agent_mod.types;
const web_api = @import("slack/web_api.zig");
const session_map = @import("session_map.zig");
const agent_cache = @import("agent_cache.zig");
const stream_sub_mod = @import("stream_subscriber.zig");
const reactions_sub_mod = @import("reactions_subscriber.zig");
const agent_hibernate_mod = @import("agent_hibernate.zig");
const prompts_state = @import("prompts_state.zig");
const slack_prompts = @import("slack_prompts.zig");
const session_mod = franky.coding.session;
const permissions_mod = franky.coding.permissions;
const stats_mod = @import("stats.zig");

pub const BotError = std.mem.Allocator.Error;

pub const Config = struct {
    model_id: []const u8,
    model_provider: []const u8,
    model_api: []const u8,
    /// v0.3.5 — model-catalog metadata propagated from
    /// `print.resolveProviderIo`. Defaults match v0.3.4
    /// behavior (1M context for Anthropic models) for back-
    /// compat when the caller doesn't fill them in.
    model_context_window: u32 = 1_000_000,
    model_max_output: u32 = 64_000,
    model_capabilities: ai.types.Capabilities = .{ .tool_use = true },
    system_prompt: []const u8 =
    // v0.2.1 — plain text only. See main.zig + franky-do.md §16.2 for
    // the rationale (Slack mrkdwn ↔ standard markdown mismatch).
    // v0.3.8 — added the long-reply-becomes-attachment hint.
    \\You are franky-do, a coding agent in a Slack thread.
    \\Reply in plain text — no markdown headings, asterisks for bold,
    \\underscores for italic, or bullet markers. Use blank lines to
    \\separate paragraphs. Triple-backtick code fences are OK.
    \\
    \\Keep replies under ~3000 chars. Long outputs become a file
    \\attachment automatically; preface them with a 1-2 sentence
    \\summary so the user knows what's in the file.
    ,
    /// Caller-owned. Bot does not deinit.
    registry: *ai.registry.Registry,
    /// Tools to register with each per-thread Agent. Caller-owned.
    tools: []const at.AgentTool = &.{},
    /// Forwarded to every per-thread Agent's `stream_options`.
    /// Carries the auth + transport bits the provider needs
    /// (`api_key`, `auth_token`, `environ_map`, etc.). Caller
    /// owns `environ_map` and any hook userdata.
    stream_options: ai.registry.StreamOptions = .{},
    /// Phase 8 — `$FRANKY_DO_HOME` for the `/franky-do stats`
    /// slash command. Empty disables the stats command (it's a
    /// no-op-with-error-message). Caller-owned.
    home_dir: []const u8 = "",
};

pub const Bot = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api: *web_api.Client,
    cfg: Config,
    sessions: session_map.Map,
    agents: agent_cache.Cache,
    /// PRNG for ULID minting. Seeded from wall-clock at init.
    ulid_prng: std.Random.DefaultPrng,
    /// Number of dispatchSlackEvent workers currently running.
    /// `deinit` busy-waits this to hit 0 before tearing down
    /// shared state — otherwise an in-flight mention worker
    /// would dereference freed agents/sessions/api.
    in_flight: std.atomic.Value(u32) = .init(0),

    /// Phase 7 — reactions-as-control. When the bot posts a
    /// reply, we cache `(team_id || ":" || reply_ts) → thread_ts`
    /// so a `reaction_added` event on the bot's own message can
    /// resolve back to the originating thread. Without this, only
    /// reactions on the user's `@`-mention would be addressable.
    /// Bounded to `reply_anchors_max` LRU slots; oldest evicted
    /// when full so a long-running bot doesn't grow without bound.
    reply_anchors: std.StringHashMapUnmanaged(ReplyAnchor) = .empty,
    reply_anchors_mutex: std.Io.Mutex = .init,
    reply_anchors_seq: u64 = 0,

    /// v0.3.1 — serializes the slow-path `ensureAgent` (rehydrate +
    /// mint + tryPut). Held only on cache miss; cache hits bypass it.
    /// Prevents two concurrent mentions on the same `(team, thread)`
    /// from rehydrating the same session twice.
    rehydrate_mutex: std.Io.Mutex = .init,

    /// v0.3.2 Phase 1 — permission overlay (`v0.4-design.md` §B).
    /// `prompts_enabled` is the resolved opt-out toggle (default
    /// true; `--no-prompts` / `FRANKY_DO_PROMPTS=0` disables).
    /// `permission_store` is bot-shared (workspace-wide
    /// always-allow / always-deny scope per design §B.3.5); each
    /// per-thread Agent gets its own `SessionGates` pointing at
    /// this Store via `tool_gate.userdata`. With no `prompter`
    /// wired (Phase 1), `.ask` decisions fall through to franky's
    /// existing "permission gate active" refusal — operators get
    /// coarse gating via `--allow-tools` / `--deny-tools` /
    /// `--yes` while Phase 2 adds Slack-side prompt UI.
    prompts_enabled: bool = true,
    permission_store: ?*permissions_mod.Store = null,

    /// v0.3.3 — Phase 2. Bot-level map of pending Slack prompts,
    /// keyed by `(channel, prompt_ts)`. Populated by per-mention
    /// `slack_prompts.Orchestrator` drain threads when the agent
    /// emits a `tool_permission_request`; consumed by
    /// `dispatchReaction` when the user reacts on the prompt
    /// message. Lifetime: bot-wide (workspace), entries removed
    /// atomically inside `tryReactionResolve` /
    /// `tryTimeoutResolve`.
    prompts: prompts_state.Map = .{},

    /// v0.3.3 — bot's own Slack user_id, captured once after
    /// `auth.test`. Owned-duped at `setBotUserId`. Used by
    /// `dispatchReaction` to skip our own seed-reactions on
    /// prompt messages (without this, the bot adding `:x:` to its
    /// prompt would trigger the abort routing!).
    bot_user_id: []u8 = "",

    /// v0.3.3 — per-prompt timeout (B.3.3). Default 10 minutes.
    /// `main.zig` reads `FRANKY_DO_PROMPT_TIMEOUT_MS` and writes
    /// here before the read loop starts.
    prompt_timeout_ms: u64 = 600_000,

    pub const reply_anchors_max: usize = 1024;

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        api: *web_api.Client,
        cfg: Config,
    ) Bot {
        const seed: u64 = @bitCast(ai.stream.nowMillis());
        return .{
            .allocator = allocator,
            .io = io,
            .api = api,
            .cfg = cfg,
            .sessions = session_map.Map.init(allocator, io),
            .agents = agent_cache.Cache.init(allocator, io),
            .ulid_prng = std.Random.DefaultPrng.init(seed),
        };
    }

    pub fn deinit(self: *Bot) void {
        // Block until every detached mention worker has exited.
        // Without this, the workers race against `agents.deinit()`
        // freeing the agent they're prompting.
        while (self.in_flight.load(.acquire) > 0) {
            // 1 ms busy-spin is fine — workers are model calls
            // measured in seconds, not microseconds.
        }

        // v0.3.1 — graceful shutdown persistence. Drain the cache,
        // persist each victim's transcript to disk, then free.
        // Without this, in-memory transcripts evaporate on Ctrl-C
        // and a returning user sees fresh context.
        if (self.agents.popAll()) |victims| {
            for (victims) |victim| self.persistAndFreeVictim(victim);
            self.allocator.free(victims);
        } else |e| {
            franky.ai.log.log(.warn, "franky-do", "hibernate", "popAll on shutdown failed: {s}", .{@errorName(e)});
        }

        self.sessions.deinit();
        self.agents.deinit(); // map is empty after popAll; this just frees the map header

        // Free reply-anchors map. We don't hold the mutex here
        // because no other thread can reach Bot once `deinit`
        // returns — see the in_flight wait above for the symmetric
        // worker-side guarantee.
        var ait = self.reply_anchors.iterator();
        while (ait.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.thread_ts);
        }
        self.reply_anchors.deinit(self.allocator);

        // v0.3.3 — drain the prompts map. By the in_flight==0
        // guarantee above, no orchestrator's drain thread is
        // running, so `prompts` only contains stragglers from
        // the now-defunct mention workers (which would be a bug
        // — orchestrator.stop is supposed to scrub them — but
        // be defensive).
        self.prompts.deinit(self.allocator, self.io);

        if (self.bot_user_id.len > 0) self.allocator.free(self.bot_user_id);
    }

    /// v0.3.3 — set after `auth.test` so `dispatchReaction` can
    /// skip the bot's own seed-reactions on prompt messages.
    /// Idempotent: replaces any prior value.
    pub fn setBotUserId(self: *Bot, id: []const u8) !void {
        if (self.bot_user_id.len > 0) self.allocator.free(self.bot_user_id);
        self.bot_user_id = try self.allocator.dupe(u8, id);
    }

    /// Resolve `(team_id, thread_ts) → ULID`, minting a new one if
    /// none exists. Returned slice is owned by `sessions` and stays
    /// valid until the binding is reset or the map is deinit'd.
    pub fn resolveSessionUlid(
        self: *Bot,
        team_id: []const u8,
        thread_ts: []const u8,
    ) ![]const u8 {
        if (self.sessions.get(team_id, thread_ts)) |existing| return existing;

        const now_ms: u64 = @intCast(ai.stream.nowMillis());
        const ulid_obj = session_mod.newUlid(now_ms, self.ulid_prng.random());
        try self.sessions.set(team_id, thread_ts, &ulid_obj.bytes);
        return self.sessions.get(team_id, thread_ts).?;
    }

    /// Get or create the Agent for `ulid`, scoped to `team_id`.
    ///
    /// **Cache hit**: fast path, no rehydrate mutex held.
    ///
    /// **Cache miss**: under `rehydrate_mutex` (double-checked),
    /// try to rehydrate from disk via `agent_hibernate.load`. If
    /// no transcript on disk (or the binding points at a corrupted
    /// session), mint a fresh Agent. Either way, `tryPut` returns
    /// any LRU-evicted Victim — we persist that, deinit, free.
    ///
    /// New agents are initialized with the bot's Config (model,
    /// system prompt, tools, registry).
    pub fn ensureAgent(self: *Bot, team_id: []const u8, ulid: []const u8) !*agent_mod.Agent {
        // Fast path — cache hit doesn't touch the rehydrate mutex.
        if (self.agents.get(ulid)) |a| return a;

        self.rehydrate_mutex.lockUncancelable(self.io);
        defer self.rehydrate_mutex.unlock(self.io);

        // Double-check after acquiring: another worker may have
        // rehydrated this ULID between our miss and the lock.
        if (self.agents.get(ulid)) |a| return a;

        const session_dir = try self.computeSessionDir(team_id, ulid);
        defer self.allocator.free(session_dir);
        const parent_dir = try self.computeSessionsParentDir(team_id);
        defer self.allocator.free(parent_dir);

        const a = try self.allocator.create(agent_mod.Agent);
        errdefer self.allocator.destroy(a);

        // Try rehydrate first; fall back to a fresh Agent on miss.
        // `agent_hibernate.load` returns `error.SessionNotFound` for
        // the no-transcript-on-disk case (a clean miss), and other
        // errors for corruption / IO issues.
        const fresh_cfg = agentInitOptionsFromConfig(&self.cfg);
        const rehydrated_or_null: ?agent_mod.Agent = blk: {
            const loaded = agent_hibernate_mod.load(
                self.allocator,
                self.io,
                parent_dir,
                ulid,
                fresh_cfg,
            ) catch |e| {
                if (e != error.SessionNotFound) {
                    franky.ai.log.log(.warn, "franky-do", "hibernate", "load failed for ulid={s}: {s}", .{
                        ulid, @errorName(e),
                    });
                }
                break :blk null;
            };
            break :blk loaded;
        };
        if (rehydrated_or_null) |loaded| {
            a.* = loaded;
            franky.ai.log.log(.info, "franky-do", "hibernate", "rehydrated ulid={s} messages={d}", .{
                ulid, a.transcript.messages.items.len,
            });
        } else {
            a.* = try agent_mod.Agent.init(self.allocator, self.io, fresh_cfg);
            franky.ai.log.log(.debug, "franky-do", "hibernate", "fresh agent for ulid={s}", .{ulid});
        }
        errdefer a.deinit();

        // v0.3.2 — allocate per-Agent SessionGates when prompts are
        // enabled. The address must be stable for the lifetime of
        // the Agent (the agent loop reads it via `tool_gate.userdata`
        // on every tool call), so heap-allocate. The Store pointer
        // inside is bot-shared.
        var gates_ptr: ?*permissions_mod.SessionGates = null;
        if (self.prompts_enabled and self.permission_store != null) {
            const g = try self.allocator.create(permissions_mod.SessionGates);
            errdefer self.allocator.destroy(g);
            g.* = .{
                .role = null, // franky-do has no role gate today
                .permissions = self.permission_store.?,
                // `.prompter` flips per-mention in `handleAppMention`.
                .prompter = null,
            };
            a.tool_gate = .{
                .userdata = @ptrCast(g),
                .before_tool_call = permissions_mod.SessionGates.beforeToolCall,
                .role_denied = permissions_mod.SessionGates.roleDenied,
            };
            gates_ptr = g;
        }

        const result = try self.agents.tryPut(ulid, a, session_dir, gates_ptr);
        if (result == .evicted) {
            self.persistAndFreeVictim(result.evicted);
        }
        return a;
    }

    /// v0.3.2 — look up the per-Agent `SessionGates`. Phase 2
    /// (v0.3.3) uses this to set `gates.prompter` for the duration
    /// of a single mention. Returns null when prompts are disabled
    /// or no entry exists yet.
    pub fn agentGates(self: *Bot, ulid: []const u8) ?*permissions_mod.SessionGates {
        return self.agents.entryGates(ulid);
    }

    /// Persist a victim's transcript to disk, then deinit + free
    /// its memory. Best-effort: persistence failures log at warn
    /// but don't error — the cache eviction has already happened.
    pub fn persistAndFreeVictim(self: *Bot, victim: agent_cache.Victim) void {
        agent_hibernate_mod.persist(
            self.allocator,
            self.io,
            victim.session_dir,
            victim.agent,
            self.cfg.model_id,
            self.cfg.model_provider,
            self.cfg.model_api,
            self.cfg.system_prompt,
        ) catch |e| franky.ai.log.log(.warn, "franky-do", "hibernate", "persist failed for {s}: {s}", .{
            victim.ulid, @errorName(e),
        });
        franky.ai.log.log(.debug, "franky-do", "hibernate", "evicted+persisted ulid={s}", .{victim.ulid});
        self.agents.freeVictim(victim, true);
    }

    /// `<home_dir>/workspaces/<team_id>/sessions` — the parent of
    /// every session dir for that team. Created on demand by
    /// `agent_hibernate`.
    fn computeSessionsParentDir(self: *Bot, team_id: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{
            self.cfg.home_dir, "workspaces", team_id, "sessions",
        });
    }

    fn computeSessionDir(self: *Bot, team_id: []const u8, ulid: []const u8) ![]u8 {
        return std.fs.path.join(self.allocator, &.{
            self.cfg.home_dir, "workspaces", team_id, "sessions", ulid,
        });
    }

    /// Build the `Agent.Config` from the bot's `cfg`. Used by both
    /// the rehydrate and fresh-mint paths so they share the same
    /// model / tools / registry / stream options.
    fn agentInitOptionsFromConfig(c: *const Config) agent_mod.Agent.Config {
        return .{
            .model = .{
                .id = c.model_id,
                .provider = c.model_provider,
                .api = c.model_api,
                .context_window = c.model_context_window,
                .max_output = c.model_max_output,
                .capabilities = c.model_capabilities,
            },
            .system_prompt = c.system_prompt,
            .tools = c.tools,
            .registry = c.registry,
            .stream_options = c.stream_options,
        };
    }

    /// Phase-4 entry point. Synchronously:
    ///   1. resolve session
    ///   2. ensure agent
    ///   3. wire the per-message Slack poster (no placeholder —
    ///      the 💭 reaction on the user's `@`-mention is the
    ///      "still working" indicator; the subscriber posts a
    ///      fresh `chat.postMessage` per assistant `message_end`)
    ///   4. agent.prompt + waitForIdle
    ///   5. drain the subscriber's posted-ts list into the
    ///      reply-anchor cache so reactions on the bot's reply
    ///      bubbles still resolve back to the thread
    pub fn handleAppMention(
        self: *Bot,
        team_id: []const u8,
        channel: []const u8,
        thread_ts: []const u8,
        text: []const u8,
        user_message_ts: []const u8,
        mentioner_user_id: []const u8,
    ) !void {
        franky.ai.log.log(.debug, "franky-do", "handle", "step=enter team={s} channel={s} thread_ts={s} text_bytes={d} user={s}", .{
            team_id, channel, thread_ts, text.len, mentioner_user_id,
        });

        // v0.3.0 — emoji status indicators on the user's mention.
        // 👀 fires synchronously here (before any agent work). The
        // subscriber lives on this stack frame and joins the agent's
        // event broadcast for 💭; final ✅/❌ comes from the explicit
        // `markFinal` call after `agent.waitForIdle()`.
        var reactions = reactions_sub_mod.ReactionsSubscriber.init(
            self.allocator,
            self.io,
            self.api,
            channel,
            user_message_ts,
        );
        reactions.markReceived();

        const ulid = try self.resolveSessionUlid(team_id, thread_ts);
        franky.ai.log.log(.debug, "franky-do", "handle", "step=session_resolved ulid={s}", .{ulid});
        const agent = try self.ensureAgent(team_id, ulid);
        franky.ai.log.log(.debug, "franky-do", "handle", "step=agent_ready", .{});

        // v0.5.0 — no placeholder. The `StreamSubscriber` posts a
        // fresh `chat.postMessage` per assistant `message_end` (so
        // each LLM response is its own bubble in chronological
        // order between tool prompts). The 💭 reaction on the
        // user's `@`-mention is the "still working" indicator
        // until the first response arrives.
        var sub = stream_sub_mod.StreamSubscriber.init(
            self.allocator,
            self.io,
            self.api,
            channel,
            thread_ts,
            .{},
        );
        defer sub.deinit();

        const sub_id = try agent.subscribe(stream_sub_mod.StreamSubscriber.onEvent, @ptrCast(&sub));
        defer agent.unsubscribe(sub_id);

        // v0.3.0 — second subscriber for the emoji indicators. Fires
        // 💭 on the first turn_start; tracks agent_error so a stale
        // success-call can't paint over.
        const reactions_sub_id = try agent.subscribe(
            reactions_sub_mod.ReactionsSubscriber.onEvent,
            @ptrCast(&reactions),
        );
        defer agent.unsubscribe(reactions_sub_id);

        // v0.3.3 Phase 2 — Slack-side permission prompting. When
        // `prompts_enabled` and the per-Agent gates are wired
        // (Phase 1 setup in `ensureAgent`), allocate a per-mention
        // prompt orchestrator: it owns a permission channel + a
        // `PermissionPrompter`, runs a drain thread that posts
        // Slack messages for each `tool_permission_request`, and
        // routes reactions back through `prompter.resolve`. The
        // `gates.prompter` pointer is patched LIVE for the
        // duration of this mention, then unset before stop.
        var orch_ptr: ?*slack_prompts.Orchestrator = null;
        var owns_gates_prompter = false;
        defer if (orch_ptr) |o| o.deinit();
        if (self.prompts_enabled and self.permission_store != null) {
            if (self.agentGates(ulid)) |gates| {
                orch_ptr = slack_prompts.Orchestrator.init(
                    self.allocator,
                    self.io,
                    self.api,
                    &self.prompts,
                    channel,
                    thread_ts,
                    mentioner_user_id,
                    self.prompt_timeout_ms,
                ) catch |e| blk: {
                    franky.ai.log.log(.warn, "franky-do", "prompts", "orchestrator init failed: {s} (continuing without prompts)", .{@errorName(e)});
                    break :blk null;
                };
                if (orch_ptr) |o| {
                    o.start() catch |e| {
                        franky.ai.log.log(.warn, "franky-do", "prompts", "orchestrator start failed: {s}", .{@errorName(e)});
                    };
                    // Defensive against the (unlikely) case of two
                    // concurrent mentions on the same session — the
                    // second one's `agent.prompt` will error with
                    // AgentBusy, but only AFTER we've overwritten
                    // the first's prompter slot if we don't guard
                    // here. With the guard, the second orchestrator
                    // is a quiet no-op and the first's prompter
                    // stays wired.
                    if (gates.prompter == null) {
                        gates.prompter = &o.prompter;
                        owns_gates_prompter = true;
                    } else {
                        franky.ai.log.log(.warn, "franky-do", "prompts", "gates.prompter already set — concurrent mention on same session? skipping", .{});
                    }
                }
            }
        }
        // Defer the `gates.prompter = null` reset and `orch.stop`
        // so they happen AFTER `waitForIdle` returns. Only null
        // out the gate slot if WE were the owner — otherwise we'd
        // clobber a concurrent mention's wiring.
        defer if (orch_ptr) |o| {
            if (owns_gates_prompter) {
                if (self.agentGates(ulid)) |g| {
                    if (g.prompter == &o.prompter) g.prompter = null;
                }
            }
            o.stop();
        };

        franky.ai.log.log(.debug, "franky-do", "handle", "step=agent.prompt", .{});
        try agent.prompt(text);
        franky.ai.log.log(.debug, "franky-do", "handle", "step=waitForIdle", .{});
        agent.waitForIdle();
        franky.ai.log.log(.debug, "franky-do", "handle", "step=idle posts={d} bubbles_recorded={d}", .{
            sub.post_count.load(.monotonic), sub.posted_ts.items.len,
        });

        // v0.5.0 — drain the subscriber's posted-ts list into the
        // reply-anchor cache. Each successfully-posted bubble
        // becomes a target for `:x:` (abort), `↩️` (retry), and
        // `:mag:` (diagnostics) reactions. Allocator-failures here
        // are non-fatal — the user can still react on the
        // `@`-mention itself (resolveReactionThread step 1).
        for (sub.posted_ts.items) |ts| {
            self.recordReplyAnchor(team_id, ts, thread_ts) catch {};
        }

        // v0.3.0 — fire the terminal reaction. If the agent emitted
        // an `agent_error` during the run, `errorFlagged()` is true
        // and we fire ❌; otherwise ✅.
        if (reactions.errorFlagged()) {
            reactions.markFinal(.error_state);
        } else {
            reactions.markFinal(.success);
        }
        franky.ai.log.log(.debug, "franky-do", "handle", "step=exit", .{});
    }

    /// Phase 6 entry point. Called by the Socket-Mode read thread
    /// for every inbound event AFTER the ACK has been sent. We
    /// route `events_api/app_mention` to a detached worker that
    /// runs `handleAppMention`. Other event types are logged and
    /// dropped in this version.
    ///
    /// `bot_user_id` is captured at startup via `auth.test`; if
    /// non-empty, we strip the `<@U…> ` mention prefix from the
    /// text before passing to the agent.
    pub fn dispatchSlackEvent(
        self: *Bot,
        bot_user_id: []const u8,
        raw_json: []const u8,
    ) !void {
        const parsed = std.json.parseFromSlice(
            EventsApiEnvelope,
            self.allocator,
            raw_json,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |e| {
            franky.ai.log.log(.warn, "franky-do", "events_api", "envelope parse failed: {s}", .{@errorName(e)});
            return;
        };
        defer parsed.deinit();

        const env = parsed.value;
        if (env.payload == null) {
            franky.ai.log.log(.debug, "franky-do", "events_api", "envelope without payload — dropped", .{});
            return;
        }
        const ev = env.payload.?.event orelse {
            franky.ai.log.log(.debug, "franky-do", "events_api", "payload without event — dropped", .{});
            return;
        };

        franky.ai.log.log(.debug, "franky-do", "events_api", "event type={s} channel={s} ts={s} thread_ts={s} text_bytes={d}", .{
            ev.@"type",
            ev.channel,
            ev.ts,
            ev.thread_ts,
            ev.text.len,
        });

        // Phase 7 — reaction_added is its own dispatch path.
        // app_mention falls through to the existing worker spawn.
        if (std.mem.eql(u8, ev.@"type", "reaction_added")) {
            try self.dispatchReaction(env.payload.?.team_id, ev);
            return;
        }
        if (!std.mem.eql(u8, ev.@"type", "app_mention")) {
            franky.ai.log.log(.info, "franky-do", "events_api", "dropped event type={s} (only app_mention + reaction_added are dispatched today; DMs / message events are NOT handled)", .{ev.@"type"});
            return;
        }

        const team_id = env.payload.?.team_id;
        const channel = ev.channel;
        // Slack sets thread_ts on threaded mentions; for top-level
        // mentions we anchor on `ts` so the bot's reply opens a
        // new thread off that message.
        const thread_ts = if (ev.thread_ts.len > 0) ev.thread_ts else ev.ts;
        const stripped = stripMentionPrefix(ev.text, bot_user_id);

        // Make owned copies — the parsed JSON is freed before the
        // worker thread reads them.
        const team_owned = try self.allocator.dupe(u8, team_id);
        errdefer self.allocator.free(team_owned);
        const channel_owned = try self.allocator.dupe(u8, channel);
        errdefer self.allocator.free(channel_owned);
        const thread_owned = try self.allocator.dupe(u8, thread_ts);
        errdefer self.allocator.free(thread_owned);
        const text_owned = try self.allocator.dupe(u8, stripped);
        errdefer self.allocator.free(text_owned);
        const user_ts_owned = try self.allocator.dupe(u8, ev.ts);
        errdefer self.allocator.free(user_ts_owned);
        const mentioner_owned = try self.allocator.dupe(u8, ev.user);
        errdefer self.allocator.free(mentioner_owned);

        const args = try self.allocator.create(MentionWorkerArgs);
        errdefer self.allocator.destroy(args);
        args.* = .{
            .bot = self,
            .team_id = team_owned,
            .channel = channel_owned,
            .thread_ts = thread_owned,
            .text = text_owned,
            .user_message_ts = user_ts_owned,
            .mentioner_user_id = mentioner_owned,
        };

        // Bump in-flight before spawning so deinit blocks correctly
        // even if the worker hasn't started yet.
        _ = self.in_flight.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{}, mentionWorker, .{args}) catch |e| {
            _ = self.in_flight.fetchSub(1, .acq_rel);
            return e;
        };
        t.detach();
    }

    /// Handle a `slash_commands` envelope. Phase 5 implements:
    ///
    ///   /franky-do reset           — drops the session for the
    ///                                CURRENT thread (or DM)
    ///   /franky-do help            — print available commands
    ///
    /// Anything else echoes a usage message. Slash commands run
    /// synchronously on the read thread (they're cheap — no model
    /// call). The reply is posted via `chat.postMessage` ephemeral
    /// to the calling user … actually for v0.1 we use a normal
    /// post so other thread participants see the action.
    pub fn dispatchSlashCommand(
        self: *Bot,
        raw_json: []const u8,
    ) !void {
        const parsed = std.json.parseFromSlice(
            SlashEnvelope,
            self.allocator,
            raw_json,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch return;
        defer parsed.deinit();
        if (parsed.value.payload == null) return;
        const p = parsed.value.payload.?;

        // Use thread_ts if present, else channel_id (DM).
        const thread_anchor = if (p.thread_ts.len > 0) p.thread_ts else p.channel_id;
        const text = std.mem.trim(u8, p.text, " \t\n\r");

        // First word = subcommand.
        const subcmd_end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
        const subcmd = text[0..subcmd_end];

        if (std.mem.eql(u8, subcmd, "reset")) {
            const dropped_session = self.sessions.reset(p.team_id, thread_anchor);
            if (dropped_session) {
                // best-effort: also drop the cached agent. We don't
                // know the ULID directly anymore, but ensureAgent
                // will create a fresh one on next message — leaving
                // the old agent in cache is fine, it just becomes
                // unreachable. Phase 5+ adds proper LRU eviction.
            }
            const reply = if (dropped_session)
                "Session reset. The next mention starts fresh."
            else
                "No session to reset for this thread.";
            var resp = self.api.chatPostMessage(.{
                .channel = p.channel_id,
                .text = reply,
                .thread_ts = thread_anchor,
            }) catch return;
            defer resp.deinit();
            return;
        }

        if (std.mem.eql(u8, subcmd, "help") or subcmd.len == 0) {
            var resp = self.api.chatPostMessage(.{
                .channel = p.channel_id,
                .text =
                \\*franky-do* slash commands:
                \\  `/franky-do reset` — drop the session for the current thread
                \\  `/franky-do stats` — token + cost summary across persisted sessions
                \\  `/franky-do help`  — show this list
                \\
                \\Mention me (`@franky-do`) in any channel to start a conversation.
                \\React to a bot message:
                \\  ❌ `:x:`                          — abort the in-flight run
                \\  ↩️ `:leftwards_arrow_with_hook:`   — retry the last prompt
                \\  🔍 `:mag:`                        — diagnostics report for this thread
                \\  (Slack disallows slash commands inside threads, so reactions are the in-thread surface.)
                ,
                .thread_ts = thread_anchor,
            }) catch return;
            defer resp.deinit();
            return;
        }

        if (std.mem.eql(u8, subcmd, "stats")) {
            self.runStatsSlash(p.channel_id, thread_anchor);
            return;
        }

        // Unknown subcommand — usage hint.
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "Unknown subcommand `{s}`. Try `/franky-do help`.",
            .{subcmd},
        ) catch "Unknown subcommand. Try `/franky-do help`.";
        var resp = self.api.chatPostMessage(.{
            .channel = p.channel_id,
            .text = msg,
            .thread_ts = thread_anchor,
        }) catch return;
        defer resp.deinit();
    }

    // ─── Phase 8 — `/franky-do stats` ─────────────────────────────

    /// Slash-command summary. Posts a one-paragraph aggregate
    /// (no per-session table — that would spam the channel) into
    /// the slash command's invoking thread.
    fn runStatsSlash(self: *Bot, channel: []const u8, thread_anchor: []const u8) void {
        if (self.cfg.home_dir.len == 0) {
            var resp = self.api.chatPostMessage(.{
                .channel = channel,
                .text = "_stats unavailable (bot started without `home_dir` configured)_",
                .thread_ts = thread_anchor,
            }) catch return;
            defer resp.deinit();
            return;
        }

        var agg = stats_mod.collect(self.allocator, self.io, self.cfg.home_dir) catch {
            var resp = self.api.chatPostMessage(.{
                .channel = channel,
                .text = "_stats failed to read sessions on disk_",
                .thread_ts = thread_anchor,
            }) catch return;
            defer resp.deinit();
            return;
        };
        defer agg.deinit(self.allocator);

        const cost_str = if (agg.priced_session_count > 0)
            std.fmt.allocPrint(self.allocator, "${d:.2}", .{agg.total_cost_usd}) catch return
        else
            self.allocator.dupe(u8, "n/a") catch return;
        defer self.allocator.free(cost_str);

        const summary = std.fmt.allocPrint(
            self.allocator,
            \\*franky-do stats*
            \\> {d} session(s), {d} input / {d} output tokens
            \\> Total est. cost: {s}
            \\
            \\Run `franky-do stats` on the host for the per-session breakdown.
        ,
            .{ agg.sessions.len, agg.total_input, agg.total_output, cost_str },
        ) catch return;
        defer self.allocator.free(summary);

        var resp = self.api.chatPostMessage(.{
            .channel = channel,
            .text = summary,
            .thread_ts = thread_anchor,
        }) catch return;
        defer resp.deinit();
    }

    // ─── Phase 7 — reactions-as-control ──────────────────────────

    /// Cache `(team_id, reply_ts) → thread_ts` so a reaction on
    /// the bot's own reply resolves back to the originating
    /// thread. Bounded by `reply_anchors_max` LRU slots.
    /// Called from `handleAppMention` after `chat.postMessage`
    /// returns the reply's `ts`.
    pub fn recordReplyAnchor(
        self: *Bot,
        team_id: []const u8,
        reply_ts: []const u8,
        thread_ts: []const u8,
    ) !void {
        var key_buf: [256]u8 = undefined;
        const key_slice = compositeReplyKey(&key_buf, team_id, reply_ts) catch return;

        self.reply_anchors_mutex.lockUncancelable(self.io);
        defer self.reply_anchors_mutex.unlock(self.io);

        if (self.reply_anchors.fetchRemove(key_slice)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.thread_ts);
        }
        // Bounded LRU: when full, drop the entry with the smallest
        // seq. Linear scan, n ≤ 1024 — fine.
        if (self.reply_anchors.count() >= reply_anchors_max) {
            var min_seq: u64 = std.math.maxInt(u64);
            var victim_key: ?[]const u8 = null;
            var it = self.reply_anchors.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.seq < min_seq) {
                    min_seq = entry.value_ptr.seq;
                    victim_key = entry.key_ptr.*;
                }
            }
            if (victim_key) |k| if (self.reply_anchors.fetchRemove(k)) |old| {
                self.allocator.free(old.key);
                self.allocator.free(old.value.thread_ts);
            };
        }

        const owned_key = try self.allocator.dupe(u8, key_slice);
        errdefer self.allocator.free(owned_key);
        const owned_thread = try self.allocator.dupe(u8, thread_ts);
        errdefer self.allocator.free(owned_thread);

        self.reply_anchors_seq += 1;
        try self.reply_anchors.put(self.allocator, owned_key, .{
            .thread_ts = owned_thread,
            .seq = self.reply_anchors_seq,
        });
    }

    /// Resolve a reacted-message-ts back to a thread. Tries
    /// `(team_id, item.ts)` directly (works when the user reacted
    /// to the original `@`-mention), then falls back to the
    /// `reply_anchors` cache (works when the user reacted to the
    /// bot's reply). Returns the thread_ts owned by the caller —
    /// dupe before the function returns to avoid races.
    fn resolveReactionThread(
        self: *Bot,
        team_id: []const u8,
        item_ts: []const u8,
    ) ?[]u8 {
        // Step 1 — `item.ts` is the thread anchor itself.
        if (self.sessions.get(team_id, item_ts)) |_| {
            return self.allocator.dupe(u8, item_ts) catch null;
        }
        // Step 2 — bot's reply; look up the cached anchor.
        var key_buf: [256]u8 = undefined;
        const key_slice = compositeReplyKey(&key_buf, team_id, item_ts) catch return null;

        self.reply_anchors_mutex.lockUncancelable(self.io);
        defer self.reply_anchors_mutex.unlock(self.io);
        const anchor = self.reply_anchors.get(key_slice) orelse return null;
        return self.allocator.dupe(u8, anchor.thread_ts) catch null;
    }

    /// Top-level entry point for `events_api/reaction_added`. Routes
    /// `❌` (`x`) to abort and `↩️`
    /// (`leftwards_arrow_with_hook`) to retry. Other reactions are
    /// dropped at debug level.
    fn dispatchReaction(self: *Bot, team_id: []const u8, ev: EventsApiEnvelope.Event) !void {
        if (ev.item.ts.len == 0 or ev.item.channel.len == 0) return;

        // v0.3.3 Phase 2 — prompt-message reactions take
        // precedence over abort/retry. Without this, a user
        // reacting `:x:` to a permission prompt would wrongly
        // abort the agent (`x` is also our abort emoji), and our
        // own seed-`:x:` reaction on the prompt would self-abort.
        if (try self.tryRoutePromptReaction(ev)) return;

        const reaction = ev.reaction;
        const action: enum { abort, retry, diagnostics, ignore } = blk: {
            if (std.mem.eql(u8, reaction, "x")) break :blk .abort;
            if (std.mem.eql(u8, reaction, "leftwards_arrow_with_hook")) break :blk .retry;
            // v0.4.5 — :mag: → run diagnostics for the thread's
            // session. Slack disallows slash-command invocation
            // inside threads, so reactions are the only Slack-side
            // surface for in-thread operator actions. Read-only:
            // diagnostics doesn't mutate session state.
            if (std.mem.eql(u8, reaction, "mag")) break :blk .diagnostics;
            break :blk .ignore;
        };
        if (action == .ignore) return;

        const thread_ts = self.resolveReactionThread(team_id, ev.item.ts) orelse return;
        defer self.allocator.free(thread_ts);
        const ulid = self.sessions.get(team_id, thread_ts) orelse return;

        switch (action) {
            .abort => self.abortThread(ev.item.channel, thread_ts, ev.user, ulid),
            .retry => self.retryThread(team_id, ev.item.channel, thread_ts, ev.user, ulid),
            .diagnostics => self.runDiagnosticsReaction(team_id, ev.item.channel, thread_ts, ev.user, ulid),
            .ignore => unreachable,
        }
    }

    /// v0.4.5 — `:mag:` reaction handler.
    ///
    /// Source-of-truth selection (v0.4.5.1 fix — the original
    /// disk-only path missed the live-agent case because franky-do
    /// only persists on hibernation eviction):
    ///
    ///   1. **Cached + idle**  → read `agent.transcript.messages.items`
    ///      directly. Safe because the worker thread is joined
    ///      between turns (`Agent.waitForIdle` blocks `handleAppMention`
    ///      until the worker exits).
    ///   2. **Cached + streaming** → post "agent is busy, react again
    ///      after the run finishes". Reading the in-memory slice
    ///      while the worker appends would race; reading from disk
    ///      would return a stale (or missing) snapshot.
    ///   3. **Not cached** → `franky.coding.session.load` from disk
    ///      (the hibernated case — eviction wrote `transcript.json`
    ///      atomically).
    ///   4. **Neither** → friendly empty-state.
    ///
    /// The Slack reply NEVER appends to the agent transcript —
    /// it's posted via `chat.postMessage`, the same path the stats
    /// and reset commands use, so the next mention's model context
    /// is unaffected.
    fn runDiagnosticsReaction(
        self: *Bot,
        team_id: []const u8,
        channel: []const u8,
        thread_ts: []const u8,
        reactor: []const u8,
        ulid: []const u8,
    ) void {
        franky.ai.log.log(.info, "franky-do", "diagnostics", "reaction trigger reactor={s} ulid={s} channel={s}", .{ reactor, ulid, channel });

        // ── Source 1: live cached agent ──────────────────────────
        if (self.agents.get(ulid)) |a| {
            if (a.is_streaming.load(.acquire)) {
                franky.ai.log.log(.info, "franky-do", "diagnostics", "agent busy ulid={s}; declining", .{ulid});
                postSimpleThreadReply(
                    self,
                    channel,
                    thread_ts,
                    "_agent is mid-turn; react :mag: again after the run finishes_",
                );
                return;
            }
            franky.ai.log.log(.debug, "franky-do", "diagnostics", "using live transcript ulid={s} messages={d}", .{ ulid, a.transcript.messages.items.len });
            self.runDiagnosticsForTranscript(team_id, channel, thread_ts, ulid, a.transcript.messages.items);
            return;
        }

        // ── Source 2: disk-loaded transcript (hibernated case) ──
        const sessions_dir = self.computeSessionsParentDir(team_id) catch |e| {
            franky.ai.log.log(.warn, "franky-do", "diagnostics", "computeSessionsParentDir err: {s}", .{@errorName(e)});
            return;
        };
        defer self.allocator.free(sessions_dir);

        var loaded = franky.coding.session.load(self.allocator, self.io, sessions_dir, ulid) catch |e| {
            franky.ai.log.log(.warn, "franky-do", "diagnostics", "session.load failed ulid={s}: {s}", .{ ulid, @errorName(e) });
            postSimpleThreadReply(
                self,
                channel,
                thread_ts,
                "_no persisted session for this thread (yet); mention me to start one and try the :mag: reaction again_",
            );
            return;
        };
        defer loaded.deinit(self.allocator);
        franky.ai.log.log(.debug, "franky-do", "diagnostics", "using disk transcript ulid={s} messages={d}", .{ ulid, loaded.transcript.messages.items.len });
        self.runDiagnosticsForTranscript(team_id, channel, thread_ts, ulid, loaded.transcript.messages.items);
    }

    /// Source-agnostic body of `runDiagnosticsReaction`. Composes
    /// the analyzer call, persists to `~/.franky-do/diagnostics`,
    /// and posts a fenced thread reply.
    fn runDiagnosticsForTranscript(
        self: *Bot,
        team_id: []const u8,
        channel: []const u8,
        thread_ts: []const u8,
        ulid: []const u8,
        transcript: []const franky.ai.types.Message,
    ) void {
        const sessions_dir = self.computeSessionsParentDir(team_id) catch return;
        defer self.allocator.free(sessions_dir);
        const session_dir_full = std.fs.path.join(self.allocator, &.{ sessions_dir, ulid }) catch return;
        defer self.allocator.free(session_dir_full);

        const home_dir = self.cfg.home_dir;
        const opts: franky.coding.diagnostics.Options = .{
            .transcript = transcript,
            .http_trace_dir = if (self.cfg.stream_options.http_trace_dir) |d| (if (d.len > 0) d else null) else null,
            .session_dir = session_dir_full,
            .session_label = ulid,
            .mode_name = "franky-do",
        };
        const persist_opts: ?franky.coding.diagnostics.PersistOptions = if (home_dir.len > 0) .{
            .franky_home = home_dir,
            .session_id = ulid,
            .timestamp_ms = franky.ai.stream.nowMillis(),
        } else null;

        const result = franky.coding.diagnostics.runAndPersist(
            self.allocator,
            self.io,
            opts,
            persist_opts,
        ) catch |e| {
            franky.ai.log.log(.warn, "franky-do", "diagnostics", "runAndPersist failed: {s}", .{@errorName(e)});
            return;
        };
        defer result.deinit(self.allocator);

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        msg.appendSlice(self.allocator, "```\n") catch return;
        msg.appendSlice(self.allocator, result.rendered) catch return;
        msg.appendSlice(self.allocator, "```") catch return;
        if (result.persisted_path) |path| {
            msg.appendSlice(self.allocator, "\n_saved: ") catch return;
            msg.appendSlice(self.allocator, path) catch return;
            msg.append(self.allocator, '_') catch return;
        }

        var resp = self.api.chatPostMessage(.{
            .channel = channel,
            .text = msg.items,
            .thread_ts = thread_ts,
        }) catch |e| {
            franky.ai.log.log(.debug, "franky-do", "diagnostics", "chat.postMessage err: {s}", .{@errorName(e)});
            return;
        };
        defer resp.deinit();
    }

    /// v0.4.4 — short-circuit reactions on prompt messages.
    ///
    /// Pre-v0.4.4 this routed ✅⏩❌🚫 reactions to
    /// `prompts.tryReactionResolve` so users could resolve a
    /// permission prompt by reacting. v0.4.4 replaces the reaction
    /// UI with Block Kit buttons (`Bot.dispatchInteractive`); this
    /// function now just **detects** prompt messages and consumes
    /// the event so an `:x:` reaction on a prompt doesn't fall
    /// through to `abortThread` and wrongly abort the in-flight
    /// run. No resolution happens here — the buttons are
    /// authoritative.
    fn tryRoutePromptReaction(self: *Bot, ev: EventsApiEnvelope.Event) !bool {
        if (try self.prompts.get(self.allocator, self.io, ev.item.channel, ev.item.ts)) |_| {
            franky.ai.log.log(.debug, "franky-do", "prompts", "ignored reaction on prompt message (use the buttons) channel={s} ts={s} user={s} reaction={s}", .{
                ev.item.channel, ev.item.ts, ev.user, ev.reaction,
            });
            return true;
        }
        return false;
    }

    /// v0.4.4 — handle a Slack Socket Mode `interactive` envelope.
    /// Currently routes only `block_actions` payloads carrying our
    /// permission-prompt button clicks (`action_id` of the form
    /// `perm:<call_id>:<resolution>`). Anything else is dropped at
    /// debug level.
    pub fn dispatchInteractive(self: *Bot, raw_json: []const u8) !void {
        const parsed = std.json.parseFromSlice(
            InteractiveEnvelope,
            self.allocator,
            raw_json,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch |e| {
            franky.ai.log.log(.warn, "franky-do", "interactive", "envelope parse failed: {s}", .{@errorName(e)});
            return;
        };
        defer parsed.deinit();
        const env = parsed.value;
        const payload = env.payload orelse {
            franky.ai.log.log(.debug, "franky-do", "interactive", "envelope without payload — dropped", .{});
            return;
        };
        if (!std.mem.eql(u8, payload.@"type", "block_actions")) {
            franky.ai.log.log(.debug, "franky-do", "interactive", "dropped payload type={s}", .{payload.@"type"});
            return;
        }
        if (payload.actions.len == 0) {
            franky.ai.log.log(.debug, "franky-do", "interactive", "block_actions with no actions — dropped", .{});
            return;
        }
        const action = payload.actions[0];
        const parsed_action = slack_prompts.parseActionId(action.action_id) orelse {
            franky.ai.log.log(.debug, "franky-do", "interactive", "ignored non-perm action_id={s}", .{action.action_id});
            return;
        };

        const channel_id = payload.container.channel_id;
        const message_ts = payload.container.message_ts;
        const user_id = payload.user.id;

        // Atomic: race-safe lookup + winner-takes-all resolution +
        // entry removal. `tryReactionResolve` is generic over the
        // input source — its implementation just takes a
        // pre-decoded `Resolution`, which our buttons supply
        // directly.
        const outcome = self.prompts.tryReactionResolve(
            self.allocator,
            self.io,
            channel_id,
            message_ts,
            user_id,
            parsed_action.resolution,
        ) catch |e| {
            franky.ai.log.log(.warn, "franky-do", "interactive", "tryReactionResolve err: {s}", .{@errorName(e)});
            return;
        };

        switch (outcome) {
            .not_found => {
                // Button click on something that isn't a registered
                // prompt anymore (timed out + entry already removed,
                // or stale Slack-delivery race). The button is
                // already disabled in the resolved-blocks UI so
                // this is a no-op.
                franky.ai.log.log(.debug, "franky-do", "interactive", "button click on unknown prompt channel={s} ts={s}", .{ channel_id, message_ts });
            },
            .already_resolved => {
                franky.ai.log.log(.debug, "franky-do", "interactive", "stale button click on resolved prompt channel={s} ts={s}", .{ channel_id, message_ts });
            },
            .user_mismatch => |um| {
                defer self.allocator.free(um.expected_user_id_owned);
                franky.ai.log.log(.info, "franky-do", "interactive", "ignored button click by non-owner clicker={s} expected={s} channel={s}", .{
                    user_id, um.expected_user_id_owned, channel_id,
                });
                // Could send the user an ephemeral message here
                // ("only @<owner> can resolve this prompt") but
                // that's a UX polish — drop for v0.4.4.
            },
            .resolved => |r| {
                defer {
                    self.allocator.free(r.thread_ts_owned);
                    self.allocator.free(r.tool_name_owned);
                    self.allocator.free(r.args_json_owned);
                }
                // v0.4.9 — `chat.update` the prompt message to
                // remove the action row and replace it with a
                // "chosen by <@user>" context line. The pre-v0.4.9
                // code also posted a separate `✓ allowed by
                // <@user>` thread reply via `postPromptStatus`,
                // but that was a leftover from the v0.3.3
                // reaction-driven UX where the prompt message
                // itself didn't update on resolve. With v0.4.4's
                // in-place block-update, the post is redundant
                // and adds visual noise — confirmed by user
                // screenshot showing both messages stacked. Best-
                // effort: a chat.update failure doesn't change
                // the agent's flow (it still received the
                // resolution).
                self.updateResolvedPrompt(channel_id, message_ts, r.tool_name_owned, r.args_json_owned, user_id, parsed_action.resolution);
                franky.ai.log.log(.info, "franky-do", "interactive", "resolved button clicker={s} resolution={s} channel={s} prompt_ts={s}", .{
                    user_id, @tagName(parsed_action.resolution), channel_id, message_ts,
                });
            },
        }
    }

    /// v0.4.4 — `chat.update` the prompt message with the
    /// post-resolution blocks. Best-effort.
    fn updateResolvedPrompt(
        self: *Bot,
        channel: []const u8,
        prompt_ts: []const u8,
        tool_name: []const u8,
        args_json: []const u8,
        user_id: []const u8,
        resolution: permissions_mod.Resolution,
    ) void {
        const blocks = slack_prompts.buildResolvedBlocks(
            self.allocator,
            tool_name,
            args_json,
            user_id,
            resolution,
        ) catch |e| {
            franky.ai.log.log(.warn, "franky-do", "interactive", "buildResolvedBlocks err: {s}", .{@errorName(e)});
            return;
        };
        defer self.allocator.free(blocks);
        const fallback = std.fmt.allocPrint(
            self.allocator,
            "Permission resolved: {s}",
            .{@tagName(resolution)},
        ) catch return;
        defer self.allocator.free(fallback);
        var resp = self.api.chatUpdate(.{
            .channel = channel,
            .ts = prompt_ts,
            .text = fallback,
            .blocks_json = blocks,
        }) catch |e| {
            franky.ai.log.log(.debug, "franky-do", "interactive", "chat.update err: {s}", .{@errorName(e)});
            return;
        };
        defer resp.deinit();
    }

    /// Fire `Agent.abort` on the thread's live agent (if any). The
    /// in-flight loop unwinds with `agent_error{aborted}`; the
    /// stream subscriber emits whatever it had buffered. Posts a
    /// small system-message audit line in the thread per §18.4.
    fn abortThread(self: *Bot, channel: []const u8, thread_ts: []const u8, reactor: []const u8, ulid: []const u8) void {
        if (self.agents.get(ulid)) |a| {
            a.abort();
        }
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "✋ aborted by <@{s}>",
            .{reactor},
        ) catch "✋ aborted";
        var resp = self.api.chatPostMessage(.{
            .channel = channel,
            .text = msg,
            .thread_ts = thread_ts,
        }) catch return;
        defer resp.deinit();
    }

    /// Walk the thread's transcript backwards to the most recent
    /// `.user` message, then re-prompt the agent with that text.
    /// Implicitly aborts an in-flight turn (the alternative —
    /// blocking until it completes — defeats the purpose of a
    /// retry reaction). No-op if the transcript has no user
    /// messages (shouldn't happen — a thread exists because a
    /// user mentioned the bot).
    fn retryThread(
        self: *Bot,
        team_id: []const u8,
        channel: []const u8,
        thread_ts: []const u8,
        reactor: []const u8,
        ulid: []const u8,
    ) void {
        // Step 1: abort any in-flight turn. After this returns,
        // the agent's worker thread has joined and the transcript
        // is no longer being mutated — safe to read directly
        // without a mutex (Agent doesn't expose one for transcript).
        const a = self.agents.get(ulid) orelse return;
        a.abort();

        // Step 2: pull the last user prompt out of the now-quiet
        // transcript.
        const last_text = lastUserPrompt(a, self.allocator) orelse return;
        defer self.allocator.free(last_text);

        // Audit line so the thread shows what just happened.
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "↩️ retrying last prompt (requested by <@{s}>)",
            .{reactor},
        ) catch "↩️ retrying last prompt";
        if (self.api.chatPostMessage(.{
            .channel = channel,
            .text = msg,
            .thread_ts = thread_ts,
        })) |r| {
            var rr = r;
            rr.deinit();
        } else |_| {}

        // Step 3: replay through `mentionWorker` so the in-flight
        // counter + subscriber + chat.postMessage flow stay
        // identical to the original mention path. The transcript
        // ends up with the user prompt repeated; that's tolerable
        // for v0.1 and avoids hand-rolled truncation that could
        // leak content blocks.
        const team_owned = self.allocator.dupe(u8, team_id) catch return;
        errdefer self.allocator.free(team_owned);
        const channel_owned = self.allocator.dupe(u8, channel) catch return;
        errdefer self.allocator.free(channel_owned);
        const thread_owned = self.allocator.dupe(u8, thread_ts) catch return;
        errdefer self.allocator.free(thread_owned);
        const text_owned = self.allocator.dupe(u8, last_text) catch return;
        errdefer self.allocator.free(text_owned);
        // v0.3.0 — retry has no original-mention `ts` in scope; react
        // on the thread root instead (which IS the original mention
        // for top-level threads, and is at least visible in the
        // sidebar for nested ones).
        const user_ts_owned = self.allocator.dupe(u8, thread_ts) catch return;
        errdefer self.allocator.free(user_ts_owned);
        // v0.3.3 — retry runs as the user who reacted. They get
        // ownership of any new permission prompts.
        const mentioner_owned = self.allocator.dupe(u8, reactor) catch return;
        errdefer self.allocator.free(mentioner_owned);

        const args = self.allocator.create(MentionWorkerArgs) catch return;
        errdefer self.allocator.destroy(args);
        args.* = .{
            .bot = self,
            .team_id = team_owned,
            .channel = channel_owned,
            .thread_ts = thread_owned,
            .text = text_owned,
            .user_message_ts = user_ts_owned,
            .mentioner_user_id = mentioner_owned,
        };
        _ = self.in_flight.fetchAdd(1, .acq_rel);
        const t = std.Thread.spawn(.{}, mentionWorker, .{args}) catch {
            _ = self.in_flight.fetchSub(1, .acq_rel);
            return;
        };
        t.detach();
    }
};

/// v0.4.6 — terse thread-reply helper. Used by the diagnostics
/// reaction handler for the "agent busy" / "no persisted session"
/// empty-state messages. Best-effort: a chat.postMessage failure
/// is logged at debug and dropped — the reaction already landed
/// so the operator at least sees their click registered.
fn postSimpleThreadReply(
    bot: *Bot,
    channel: []const u8,
    thread_ts: []const u8,
    text: []const u8,
) void {
    var resp = bot.api.chatPostMessage(.{
        .channel = channel,
        .text = text,
        .thread_ts = thread_ts,
    }) catch |e| {
        franky.ai.log.log(.debug, "franky-do", "diagnostics", "chat.postMessage err: {s}", .{@errorName(e)});
        return;
    };
    defer resp.deinit();
}

/// Walks a transcript backwards to the most recent `.user` message
/// and returns a fresh dupe of its first text block, or null if
/// there's no user message. Caller must guarantee the agent's
/// worker thread isn't running (we're racing-prone otherwise) —
/// `Agent.abort()` followed by this read is the canonical pattern.
fn lastUserPrompt(a: *agent_mod.Agent, allocator: std.mem.Allocator) ?[]u8 {
    const msgs = a.transcript.messages.items;
    var i: usize = msgs.len;
    while (i > 0) {
        i -= 1;
        if (msgs[i].role != .user) continue;
        if (msgs[i].content.len == 0) continue;
        switch (msgs[i].content[0]) {
            .text => |t| return allocator.dupe(u8, t.text) catch null,
            else => continue,
        }
    }
    return null;
}

/// Phase 7 — per-anchor record. `seq` drives bounded-LRU eviction.
const ReplyAnchor = struct {
    thread_ts: []u8,
    seq: u64,
};

fn compositeReplyKey(buf: *[256]u8, team_id: []const u8, ts: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}:{s}", .{ team_id, ts });
}

const SlashEnvelope = struct {
    @"type": []const u8 = "",
    envelope_id: []const u8 = "",
    payload: ?Payload = null,

    const Payload = struct {
        team_id: []const u8 = "",
        channel_id: []const u8 = "",
        user_id: []const u8 = "",
        command: []const u8 = "",
        text: []const u8 = "",
        thread_ts: []const u8 = "",
    };
};

const EventsApiEnvelope = struct {
    @"type": []const u8 = "",
    envelope_id: []const u8 = "",
    payload: ?Payload = null,

    const Payload = struct {
        team_id: []const u8 = "",
        event: ?Event = null,
    };

    const Event = struct {
        @"type": []const u8 = "",
        user: []const u8 = "",
        text: []const u8 = "",
        channel: []const u8 = "",
        ts: []const u8 = "",
        thread_ts: []const u8 = "",
        // Phase 7 — `reaction_added` fields. Slack uses `reaction`
        // for the emoji name and `item` for the message reacted to.
        reaction: []const u8 = "",
        item: ReactionItem = .{},
    };

    const ReactionItem = struct {
        @"type": []const u8 = "",
        channel: []const u8 = "",
        ts: []const u8 = "",
    };
};

/// v0.4.4 — Slack Socket Mode `interactive` envelope. Only the
/// fields we route on are typed; everything else is consumed and
/// dropped via `ignore_unknown_fields`. The `payload.actions[0]`
/// shape matches Slack's `block_actions` payload.
const InteractiveEnvelope = struct {
    @"type": []const u8 = "",
    envelope_id: []const u8 = "",
    payload: ?Payload = null,

    const Payload = struct {
        @"type": []const u8 = "",
        user: User = .{},
        container: Container = .{},
        actions: []Action = &.{},
    };

    const User = struct {
        id: []const u8 = "",
        // username/name appear too but we don't need them today.
    };

    const Container = struct {
        @"type": []const u8 = "",
        channel_id: []const u8 = "",
        message_ts: []const u8 = "",
    };

    const Action = struct {
        action_id: []const u8 = "",
        block_id: []const u8 = "",
        value: []const u8 = "",
    };
};

const MentionWorkerArgs = struct {
    bot: *Bot,
    team_id: []const u8,
    channel: []const u8,
    thread_ts: []const u8,
    text: []const u8,
    /// v0.3.0 — `ts` of the user's `@`-mention message itself
    /// (NOT the thread root `thread_ts` — those differ for top-level
    /// mentions). Reactions get added to *this* message via
    /// `ReactionsSubscriber`.
    user_message_ts: []const u8,
    /// v0.3.3 — the `@`-mentioner's Slack user_id. Used by the
    /// per-mention prompt orchestrator to enforce owner-only
    /// resolution (B.3.4). Empty string if Slack didn't send it
    /// (shouldn't happen for `app_mention`).
    mentioner_user_id: []const u8,
};

fn mentionWorker(args: *MentionWorkerArgs) void {
    defer {
        args.bot.allocator.free(args.team_id);
        args.bot.allocator.free(args.channel);
        args.bot.allocator.free(args.thread_ts);
        args.bot.allocator.free(args.text);
        args.bot.allocator.free(args.user_message_ts);
        args.bot.allocator.free(args.mentioner_user_id);
        const bot_ptr = args.bot;
        args.bot.allocator.destroy(args);
        // Decrement LAST — `Bot.deinit` busy-waits on this counter
        // and is allowed to free shared state once it hits zero.
        _ = bot_ptr.in_flight.fetchSub(1, .acq_rel);
    }
    franky.ai.log.log(.info, "franky-do", "mention", "team={s} channel={s} thread_ts={s} text_bytes={d} user={s}", .{
        args.team_id, args.channel, args.thread_ts, args.text.len, args.mentioner_user_id,
    });
    args.bot.handleAppMention(args.team_id, args.channel, args.thread_ts, args.text, args.user_message_ts, args.mentioner_user_id) catch |e|
        franky.ai.log.log(.warn, "franky-do", "mention", "handleAppMention failed: {s}", .{@errorName(e)});
}

/// Strip the `<@UBOTID>` or `<@UBOTID|name>` prefix Slack injects
/// into mention text. Falls back to the input verbatim when the
/// prefix isn't there or `bot_user_id` is empty.
pub fn stripMentionPrefix(text: []const u8, bot_user_id: []const u8) []const u8 {
    if (bot_user_id.len == 0) return text;
    var prefix_buf: [64]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "<@{s}", .{bot_user_id}) catch return text;
    if (!std.mem.startsWith(u8, text, prefix)) return text;
    // Find the closing '>' of the mention block.
    const gt = std.mem.indexOfScalarPos(u8, text, prefix.len, '>') orelse return text;
    var rest = text[gt + 1 ..];
    // Trim leading whitespace after the mention.
    while (rest.len > 0 and (rest[0] == ' ' or rest[0] == '\t')) rest = rest[1..];
    return rest;
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const fp: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try fp.runSync(ctx.io, ctx.context, ctx.out);
}

/// Multi-request loopback Slack server. Replies to every
/// chat.postMessage / chat.update with `{"ok":true,"channel":"C1","ts":"99.0"}`
/// (so each call's parsed response has a non-null `ts`). Captures
/// the path + body of each request.
const FauxApiServer = struct {
    server: std.Io.net.Server,
    port: u16,
    /// Allocator-owned slice of captured (path, body) pairs.
    captures: std.ArrayList(Capture) = .empty,
    captures_mutex: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    io: std.Io,
    stop: std.atomic.Value(bool) = .init(false),

    pub const Capture = struct {
        path: []u8,
        body: []u8,
    };
};

fn fauxApiLoop(s: *FauxApiServer) void {
    while (!s.stop.load(.acquire)) {
        var stream_conn = s.server.accept(s.io) catch return;
        defer stream_conn.close(s.io);
        var buf: [16 * 1024]u8 = undefined;
        var r = stream_conn.reader(s.io, &.{});
        var total: usize = 0;
        var headers_end: ?usize = null;
        while (total < buf.len) {
            var vecs: [1][]u8 = .{buf[total..]};
            const n = r.interface.readVec(&vecs) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |idx| {
                headers_end = idx + 4;
                break;
            }
        }
        if (headers_end == null) continue;
        const head = buf[0..headers_end.?];
        var content_length: usize = 0;
        const cl_pos = std.mem.indexOf(u8, head, "content-length:") orelse
            std.mem.indexOf(u8, head, "Content-Length:");
        if (cl_pos) |pos| {
            var i = pos + "content-length:".len;
            while (i < head.len and (head[i] == ' ' or head[i] == '\t')) i += 1;
            var end = i;
            while (end < head.len and head[end] != '\r' and head[end] != '\n') end += 1;
            content_length = std.fmt.parseInt(usize, head[i..end], 10) catch 0;
        }
        while (total - headers_end.? < content_length and total < buf.len) {
            var vecs: [1][]u8 = .{buf[total..]};
            const n = r.interface.readVec(&vecs) catch break;
            if (n == 0) break;
            total += n;
        }
        const body_slice = buf[headers_end.?..@min(headers_end.? + content_length, total)];

        // Capture path.
        var path_owned: ?[]u8 = null;
        if (std.mem.indexOf(u8, head, " ")) |sp1| {
            const after = head[sp1 + 1 ..];
            if (std.mem.indexOf(u8, after, " ")) |sp2| {
                path_owned = s.allocator.dupe(u8, after[0..sp2]) catch null;
            }
        }
        const body_owned = s.allocator.dupe(u8, body_slice) catch null;
        if (path_owned) |p| if (body_owned) |b| {
            s.captures_mutex.lockUncancelable(s.io);
            s.captures.append(s.allocator, .{ .path = p, .body = b }) catch {
                s.allocator.free(p);
                s.allocator.free(b);
            };
            s.captures_mutex.unlock(s.io);
        };

        const body_str = "{\"ok\":true,\"channel\":\"C1\",\"ts\":\"99.0\"}";
        var reply: [512]u8 = undefined;
        const reply_str = std.fmt.bufPrint(
            &reply,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ body_str.len, body_str },
        ) catch return;
        var wbuf: [256]u8 = undefined;
        var w = stream_conn.writer(s.io, &wbuf);
        w.interface.writeAll(reply_str) catch {};
        w.interface.flush() catch {};
    }
}

fn bindFauxApi(allocator: std.mem.Allocator, io: std.Io) ?FauxApiServer {
    var p: u16 = 19400;
    while (p < 19499) : (p += 1) {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch continue;
        const server = std.Io.net.IpAddress.listen(&addr, io, .{
            .kernel_backlog = 16,
            .reuse_address = true,
        }) catch continue;
        return .{
            .server = server,
            .port = p,
            .allocator = allocator,
            .io = io,
        };
    }
    return null;
}

test "Bot.handleAppMention: end-to-end posts assistant text per message_end" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxApi(gpa, io) orelse return;
    defer {
        s.captures_mutex.lockUncancelable(io);
        for (s.captures.items) |c| {
            gpa.free(c.path);
            gpa.free(c.body);
        }
        s.captures.deinit(gpa);
        s.captures_mutex.unlock(io);
        s.server.deinit(io);
    }
    const server_thread = try std.Thread.spawn(.{}, fauxApiLoop, .{&s});
    defer {
        s.stop.store(true, .release);
        // Unblock accept() with a throwaway connect.
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", s.port) catch unreachable;
        if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch null) |strm| {
            var sm = strm;
            sm.close(io);
        }
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "hello there", .chunk_size = 4 } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var bot = Bot.init(gpa, io, &api, .{
        .model_id = "faux-1",
        .model_provider = "faux",
        .model_api = "faux",
        .registry = &reg,
    });
    defer bot.deinit();

    try bot.handleAppMention("T1", "C1", "1700000000.000100", "hi bot", "1700000000.000100", "U-test");

    s.captures_mutex.lockUncancelable(io);
    defer s.captures_mutex.unlock(io);
    // v0.5.0 — no placeholder, no chat.update. The subscriber posts
    // exactly one chat.postMessage per assistant message_end. Captures
    // also include reactions.add (👀 received, 💭 working, ✅ done).
    var post_count: usize = 0;
    var assistant_post: ?usize = null;
    for (s.captures.items, 0..) |c, i| {
        if (std.mem.eql(u8, c.path, "/chat.postMessage")) {
            post_count += 1;
            if (std.mem.indexOf(u8, c.body, "hello there") != null) assistant_post = i;
        }
        // The streaming path no longer issues chat.update at all.
        try testing.expect(!std.mem.eql(u8, c.path, "/chat.update"));
    }
    try testing.expectEqual(@as(usize, 1), post_count);
    try testing.expect(assistant_post != null);

    const post = s.captures.items[assistant_post.?];
    try testing.expect(std.mem.indexOf(u8, post.body, "\"text\":\"hello there\"") != null);
    try testing.expect(std.mem.indexOf(u8, post.body, "\"thread_ts\":\"1700000000.000100\"") != null);

    // Also assert the three v0.3.0 emoji reactions landed in source order.
    var seen_eyes = false;
    var seen_thinking = false;
    var seen_check = false;
    for (s.captures.items) |c| {
        if (!std.mem.eql(u8, c.path, "/reactions.add")) continue;
        if (std.mem.indexOf(u8, c.body, "\"name\":\"eyes\"") != null) seen_eyes = true;
        if (std.mem.indexOf(u8, c.body, "\"name\":\"thought_balloon\"") != null) seen_thinking = true;
        if (std.mem.indexOf(u8, c.body, "\"name\":\"white_check_mark\"") != null) seen_check = true;
    }
    try testing.expect(seen_eyes);
    try testing.expect(seen_thinking);
    try testing.expect(seen_check);

    try testing.expectEqual(@as(usize, 1), bot.sessions.count());
    try testing.expectEqual(@as(usize, 1), bot.agents.count());
}

test "Bot.resolveSessionUlid: same thread → same ULID, different thread → new ULID" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();

    var bot = Bot.init(gpa, io, &api, .{
        .model_id = "faux-1",
        .model_provider = "faux",
        .model_api = "faux",
        .registry = &reg,
    });
    defer bot.deinit();

    const ulid_a = try gpa.dupe(u8, try bot.resolveSessionUlid("T1", "1.0"));
    defer gpa.free(ulid_a);
    const ulid_b = try gpa.dupe(u8, try bot.resolveSessionUlid("T1", "1.0"));
    defer gpa.free(ulid_b);
    const ulid_c = try gpa.dupe(u8, try bot.resolveSessionUlid("T1", "2.0"));
    defer gpa.free(ulid_c);

    try testing.expectEqualStrings(ulid_a, ulid_b);
    try testing.expect(!std.mem.eql(u8, ulid_a, ulid_c));
}

test "stripMentionPrefix: simple mention" {
    try testing.expectEqualStrings("hello", stripMentionPrefix("<@UBOT> hello", "UBOT"));
}

test "stripMentionPrefix: mention with name suffix" {
    try testing.expectEqualStrings(
        "do the thing",
        stripMentionPrefix("<@UBOT|franky-do> do the thing", "UBOT"),
    );
}

test "stripMentionPrefix: no mention → unchanged" {
    try testing.expectEqualStrings("hello", stripMentionPrefix("hello", "UBOT"));
}

test "stripMentionPrefix: different bot id → unchanged" {
    try testing.expectEqualStrings(
        "<@UOTHER> hello",
        stripMentionPrefix("<@UOTHER> hello", "UBOT"),
    );
}

test "stripMentionPrefix: empty bot_user_id → unchanged" {
    try testing.expectEqualStrings("<@UBOT> hi", stripMentionPrefix("<@UBOT> hi", ""));
}

test "stripMentionPrefix: trailing whitespace after >" {
    try testing.expectEqualStrings("hi", stripMentionPrefix("<@UBOT>   hi", "UBOT"));
}

test "Bot.dispatchSlashCommand: reset drops session + posts confirmation" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxApi(gpa, io) orelse return;
    defer {
        s.captures_mutex.lockUncancelable(io);
        for (s.captures.items) |c| {
            gpa.free(c.path);
            gpa.free(c.body);
        }
        s.captures.deinit(gpa);
        s.captures_mutex.unlock(io);
        s.server.deinit(io);
    }
    const server_thread = try std.Thread.spawn(.{}, fauxApiLoop, .{&s});
    defer {
        s.stop.store(true, .release);
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", s.port) catch unreachable;
        if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch null) |strm| {
            var sm_close = strm;
            sm_close.close(io);
        }
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();

    var bot_inst = Bot.init(gpa, io, &api, .{
        .model_id = "faux-1",
        .model_provider = "faux",
        .model_api = "faux",
        .registry = &reg,
    });
    defer bot_inst.deinit();

    // Pre-seed a session for T1 / thread X.
    try bot_inst.sessions.set("T1", "1700.0001", "01ULID_FOO");
    try testing.expectEqual(@as(usize, 1), bot_inst.sessions.count());

    const slash_envelope =
        \\{"type":"slash_commands","envelope_id":"e1","payload":{
        \\"team_id":"T1","channel_id":"C1","user_id":"U1",
        \\"command":"/franky-do","text":"reset","thread_ts":"1700.0001"
        \\}}
    ;
    try bot_inst.dispatchSlashCommand(slash_envelope);

    try testing.expectEqual(@as(usize, 0), bot_inst.sessions.count());

    s.captures_mutex.lockUncancelable(io);
    defer s.captures_mutex.unlock(io);
    try testing.expect(s.captures.items.len >= 1);
    const last = s.captures.items[s.captures.items.len - 1];
    try testing.expectEqualStrings("/chat.postMessage", last.path);
    try testing.expect(std.mem.indexOf(u8, last.body, "Session reset") != null);
}

test "Bot.dispatchSlashCommand: help prints usage" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxApi(gpa, io) orelse return;
    defer {
        s.captures_mutex.lockUncancelable(io);
        for (s.captures.items) |c| {
            gpa.free(c.path);
            gpa.free(c.body);
        }
        s.captures.deinit(gpa);
        s.captures_mutex.unlock(io);
        s.server.deinit(io);
    }
    const server_thread = try std.Thread.spawn(.{}, fauxApiLoop, .{&s});
    defer {
        s.stop.store(true, .release);
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", s.port) catch unreachable;
        if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch null) |strm| {
            var sm_close = strm;
            sm_close.close(io);
        }
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();

    var bot_inst = Bot.init(gpa, io, &api, .{
        .model_id = "faux-1",
        .model_provider = "faux",
        .model_api = "faux",
        .registry = &reg,
    });
    defer bot_inst.deinit();

    const slash_envelope =
        \\{"type":"slash_commands","envelope_id":"e1","payload":{
        \\"team_id":"T1","channel_id":"C1","user_id":"U1",
        \\"command":"/franky-do","text":"help","thread_ts":""
        \\}}
    ;
    try bot_inst.dispatchSlashCommand(slash_envelope);

    s.captures_mutex.lockUncancelable(io);
    defer s.captures_mutex.unlock(io);
    try testing.expect(s.captures.items.len >= 1);
    try testing.expect(std.mem.indexOf(u8, s.captures.items[0].body, "/franky-do reset") != null);
}

test "Bot.dispatchSlackEvent: spawns mention worker that calls handleAppMention" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxApi(gpa, io) orelse return;
    defer {
        s.captures_mutex.lockUncancelable(io);
        for (s.captures.items) |c| {
            gpa.free(c.path);
            gpa.free(c.body);
        }
        s.captures.deinit(gpa);
        s.captures_mutex.unlock(io);
        s.server.deinit(io);
    }
    const server_thread = try std.Thread.spawn(.{}, fauxApiLoop, .{&s});
    defer {
        s.stop.store(true, .release);
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", s.port) catch unreachable;
        if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch null) |strm| {
            var sm = strm;
            sm.close(io);
        }
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    try faux.push(.{ .events = &.{
        .{ .text = .{ .text = "ack", .chunk_size = 2 } },
    } });

    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    var bot = Bot.init(gpa, io, &api, .{
        .model_id = "faux-1",
        .model_provider = "faux",
        .model_api = "faux",
        .registry = &reg,
    });
    defer bot.deinit();

    const envelope =
        \\{"type":"events_api","envelope_id":"e1","payload":{
        \\"team_id":"T01","event":{
        \\"type":"app_mention","user":"UALICE","text":"<@UBOT> hi there",
        \\"channel":"C01","ts":"1700000000.000100","thread_ts":""
        \\}}}
    ;

    try bot.dispatchSlackEvent("UBOT", envelope);

    // The dispatch spawned a detached worker. Wait for it via
    // the bot's in-flight counter — same gate Bot.deinit uses,
    // so we don't depend on captures.len timing.
    const deadline = ai.stream.nowMillis() + 5_000;
    while (ai.stream.nowMillis() < deadline and bot.in_flight.load(.acquire) > 0) {}
    try testing.expectEqual(@as(u32, 0), bot.in_flight.load(.acquire));
    try testing.expectEqual(@as(usize, 1), bot.sessions.count());
}

// ─── Phase 7 — reactions-as-control ───────────────────────────────

test "EventsApiEnvelope: parses a reaction_added event" {
    const json_text =
        \\{"type":"events_api","envelope_id":"e1","payload":{
        \\  "team_id":"T1",
        \\  "event":{
        \\    "type":"reaction_added",
        \\    "user":"UREACT",
        \\    "reaction":"x",
        \\    "item":{"type":"message","channel":"C1","ts":"1.0"}
        \\  }}}
    ;
    const parsed = try std.json.parseFromSlice(
        EventsApiEnvelope,
        testing.allocator,
        json_text,
        .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const ev = parsed.value.payload.?.event.?;
    try testing.expectEqualStrings("reaction_added", ev.@"type");
    try testing.expectEqualStrings("x", ev.reaction);
    try testing.expectEqualStrings("message", ev.item.@"type");
    try testing.expectEqualStrings("C1", ev.item.channel);
    try testing.expectEqualStrings("1.0", ev.item.ts);
}

test "Bot.recordReplyAnchor + resolveReactionThread: reaction on bot reply maps back to thread" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();

    var bot = Bot.init(gpa, io, &api, .{
        .model_id = "faux-1",
        .model_provider = "faux",
        .model_api = "faux",
        .registry = &reg,
    });
    defer bot.deinit();

    // Pre-seed a session for (T1, mention.ts="100.0")
    _ = try bot.resolveSessionUlid("T1", "100.0");
    // Bot replied with a message at "200.0" inside that thread.
    try bot.recordReplyAnchor("T1", "200.0", "100.0");

    // Reaction on the user's mention itself: direct hit.
    const direct = bot.resolveReactionThread("T1", "100.0").?;
    defer gpa.free(direct);
    try testing.expectEqualStrings("100.0", direct);

    // Reaction on the bot's reply: cache lookup.
    const via_anchor = bot.resolveReactionThread("T1", "200.0").?;
    defer gpa.free(via_anchor);
    try testing.expectEqualStrings("100.0", via_anchor);

    // Reaction on an unknown ts: null.
    try testing.expect(bot.resolveReactionThread("T1", "999.0") == null);
}

test "Bot.recordReplyAnchor: replacing same key frees the old entry (no leak)" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();

    var bot = Bot.init(gpa, io, &api, .{
        .model_id = "faux-1",
        .model_provider = "faux",
        .model_api = "faux",
        .registry = &reg,
    });
    defer bot.deinit();

    try bot.recordReplyAnchor("T1", "200.0", "100.0");
    try bot.recordReplyAnchor("T1", "200.0", "150.0"); // overwrite
    const a = bot.resolveReactionThread("T1", "200.0") orelse return error.Missing;
    defer gpa.free(a);
    try testing.expectEqualStrings("150.0", a);
}

test "Bot.dispatchSlackEvent: unknown reaction emoji is dropped silently" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();

    var bot = Bot.init(gpa, io, &api, .{
        .model_id = "faux-1",
        .model_provider = "faux",
        .model_api = "faux",
        .registry = &reg,
    });
    defer bot.deinit();

    // :thumbsup: isn't one of the wired reactions — should no-op
    // without an error or HTTP traffic. We feed it through
    // dispatchSlackEvent (the public surface) to exercise the
    // type switch, and assert the in-flight worker counter stayed
    // at zero (no detached worker was spawned).
    const json_text =
        \\{"type":"events_api","envelope_id":"e1","payload":{
        \\  "team_id":"T1",
        \\  "event":{
        \\    "type":"reaction_added",
        \\    "user":"UREACT",
        \\    "reaction":"thumbsup",
        \\    "item":{"type":"message","channel":"C1","ts":"1.0"}
        \\  }}}
    ;
    try bot.dispatchSlackEvent("UBOT", json_text);
    try testing.expectEqual(@as(u32, 0), bot.in_flight.load(.acquire));
}
