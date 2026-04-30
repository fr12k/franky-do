//! v0.3.3 — per-mention permission-prompt orchestrator (v0.4-design §B Phase 2).
//!
//! Owns one short-lived `PermissionPrompter` + its dedicated
//! `AgentChannel` for the duration of a single Slack `@`-mention.
//! When the agent loop emits a `tool_permission_request` event
//! (because `permissions.SessionGates.beforeToolCall` got `ask`),
//! the prompter pushes the event onto our channel and suspends
//! the worker thread inside `requestAndWait`. Our drain thread
//! reads the event, posts a Slack message with four reactions
//! (✅ allow once / ⏩ always allow / ❌ deny once / 🚫 always
//! deny), registers the `(channel, prompt_ts)` in the bot's
//! `prompts_state.Map`, and spawns a per-prompt timeout thread
//! that auto-resolves as `deny_once` after `timeout_ms`.
//!
//! Reaction events arrive on the bot's read thread and route
//! through `Bot.dispatchReaction` — the bot calls
//! `Map.tryReactionResolve` which (under the map mutex) flips
//! the `resolved` atomic, calls `prompter.resolve`, and removes
//! the entry. `Orchestrator.stop` *also* takes the map mutex
//! while scrubbing any leftover entries before deinit'ing the
//! prompter — that's how we avoid a use-after-free where a slow
//! reactor still holds the prompter pointer when waitForIdle
//! returns.
//!
//! Lifecycle inside `Bot.handleAppMention`:
//!   1. `Orchestrator.init` — allocate channel + prompter
//!   2. `agent.tool_gate.userdata->prompter = &orch.prompter`
//!   3. `Orchestrator.start` — spawn drain thread
//!   4. `agent.prompt(text); agent.waitForIdle();`
//!   5. `agent.tool_gate.userdata->prompter = null` (defensive)
//!   6. `Orchestrator.stop` — close channel, join drain, scrub
//!      any orphan map entries, deinit prompter
//!   7. `Orchestrator.deinit`

const std = @import("std");
const franky = @import("franky");
const slack_web_api = @import("slack/web_api.zig");
const prompts_state = @import("prompts_state.zig");

const at = franky.agent.types;
const loop_mod = franky.agent.loop;
const ai = franky.ai;
const permissions_mod = franky.coding.permissions;

pub const Orchestrator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api: *slack_web_api.Client,
    prompts_map: *prompts_state.Map,

    /// Slack channel + thread where the original `@`-mention
    /// landed. Owned-duped at init.
    channel: []u8,
    thread_ts: []u8,
    /// The user we will accept reactions from (B.3.4 owner-only).
    expected_user_id: []u8,
    /// Per-prompt deadline in ms. Default 600_000 (10 min) per
    /// B.3.3.
    timeout_ms: u64,

    /// The channel the prompter pushes `tool_permission_request`
    /// events onto. Separate from the agent's internal channel so
    /// regular events (turn_start, message_update, etc.) don't
    /// interleave through here.
    permission_channel: loop_mod.AgentChannel,
    prompter: permissions_mod.PermissionPrompter,
    drain_thread: ?std.Thread = null,

    /// `prompt_ts` strings for prompts we registered in the bot
    /// map. Used by `stop` to scrub any leftover entries before
    /// deinit'ing the prompter. Single-writer (drain thread only)
    /// followed by single-reader (stop, after join) — no mutex
    /// needed.
    registered_prompts: std.ArrayList([]u8) = .empty,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        api: *slack_web_api.Client,
        prompts_map: *prompts_state.Map,
        channel: []const u8,
        thread_ts: []const u8,
        expected_user_id: []const u8,
        timeout_ms: u64,
    ) !*Orchestrator {
        const self = try allocator.create(Orchestrator);
        errdefer allocator.destroy(self);

        const channel_dup = try allocator.dupe(u8, channel);
        errdefer allocator.free(channel_dup);
        const thread_ts_dup = try allocator.dupe(u8, thread_ts);
        errdefer allocator.free(thread_ts_dup);
        const user_dup = try allocator.dupe(u8, expected_user_id);
        errdefer allocator.free(user_dup);

        // 64-event burst buffer — tool prompts are a rare event,
        // even a deeply-nested turn caps out well under that.
        var ch = try loop_mod.AgentChannel.initWithDrop(
            allocator,
            64,
            at.AgentEvent.deinit,
            allocator,
        );
        errdefer ch.deinit();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .api = api,
            .prompts_map = prompts_map,
            .channel = channel_dup,
            .thread_ts = thread_ts_dup,
            .expected_user_id = user_dup,
            .timeout_ms = timeout_ms,
            .permission_channel = ch,
            // The prompter is initialized with a *pointer* into
            // `self.permission_channel`, which has now been moved
            // into `self.*`. The address is stable for the
            // lifetime of `self` — heap-allocated via `create`.
            .prompter = permissions_mod.PermissionPrompter.init(
                allocator,
                io,
                undefined, // patched below
            ),
        };
        // Patch the channel pointer now that `self` has its final
        // address. (Init-then-patch dance because a moved struct
        // can't carry an internal self-pointer.)
        self.prompter.channel = &self.permission_channel;

        return self;
    }

    pub fn start(self: *Orchestrator) !void {
        self.drain_thread = try std.Thread.spawn(.{}, drainMain, .{self});
    }

    /// Stop the drain thread and scrub any orphan map entries.
    /// SAFE to call multiple times. Caller is responsible for
    /// having unset `gates.prompter` BEFORE calling stop, so the
    /// agent loop won't try to push new requests onto a closing
    /// channel.
    pub fn stop(self: *Orchestrator) void {
        // Idempotency: if the drain thread is already gone we've
        // been stopped; nothing to do.
        if (self.drain_thread == null) return;

        self.permission_channel.close(self.io);
        if (self.drain_thread) |t| {
            t.join();
            self.drain_thread = null;
        }

        // Scrub any orphan entries — these are prompts we
        // registered that never got resolved (which shouldn't
        // happen post-`waitForIdle`, but defensive). Force-resolve
        // as `deny_once` under the map mutex so a concurrent
        // late-arriving reactor will see `not_found`.
        for (self.registered_prompts.items) |pt| {
            const out = self.prompts_map.tryTimeoutResolve(
                self.allocator,
                self.io,
                self.channel,
                pt,
            ) catch continue;
            switch (out) {
                .resolved => |r| self.allocator.free(r.thread_ts_owned),
                .not_found, .already_resolved => {},
            }
        }
        for (self.registered_prompts.items) |pt| self.allocator.free(pt);
        self.registered_prompts.deinit(self.allocator);
        self.registered_prompts = .empty;

        // Now safe to deinit the prompter — the map no longer
        // references it.
        self.prompter.deinit();
    }

    pub fn deinit(self: *Orchestrator) void {
        // `stop` is idempotent and a no-op if already stopped.
        // Callers normally call stop explicitly so they can log /
        // retry, but we double-check here for safety.
        self.stop();
        self.permission_channel.deinit();
        self.allocator.free(self.channel);
        self.allocator.free(self.thread_ts);
        self.allocator.free(self.expected_user_id);
        self.allocator.destroy(self);
    }
};

fn drainMain(self: *Orchestrator) void {
    while (self.permission_channel.next(self.io)) |ev| {
        switch (ev) {
            .tool_permission_request => |req| {
                handleRequest(self, req) catch |e| {
                    ai.log.log(.warn, "franky-do", "prompts", "drain: handleRequest failed: {s}", .{@errorName(e)});
                };
            },
            else => {
                // Other event types shouldn't appear here — only
                // `PermissionPrompter.requestAndWait` pushes to
                // this channel and it pushes only the one variant.
            },
        }
        ev.deinit(self.allocator);
    }
}

fn handleRequest(
    self: *Orchestrator,
    req: anytype,
) !void {
    // v0.4.4 — Block Kit prompt with four interactive buttons.
    // Replaces the v0.3.3 seed-four-reactions flow. The `text`
    // field is still required by Slack as the notification +
    // screen-reader fallback; we make it a brief one-liner since
    // the rich body lives in `blocks`.
    const blocks_json = try buildPromptBlocks(self.allocator, req.tool_name, req.args_json, req.call_id);
    defer self.allocator.free(blocks_json);
    const text_fallback = try std.fmt.allocPrint(
        self.allocator,
        "Permission required: {s} — open in Slack to allow or deny.",
        .{req.tool_name},
    );
    defer self.allocator.free(text_fallback);

    var resp = self.api.chatPostMessage(.{
        .channel = self.channel,
        .text = text_fallback,
        .thread_ts = self.thread_ts,
        .blocks_json = blocks_json,
    }) catch |e| {
        ai.log.log(.warn, "franky-do", "prompts", "chat.postMessage failed: {s}", .{@errorName(e)});
        return e;
    };
    defer resp.deinit();

    const prompt_ts = resp.value.ts orelse {
        ai.log.log(.warn, "franky-do", "prompts", "chat.postMessage returned no ts", .{});
        return error.NoPromptTs;
    };

    const expires_at_ms = ai.stream.nowMillis() + @as(i64, @intCast(self.timeout_ms));

    try self.prompts_map.put(
        self.allocator,
        self.io,
        self.channel,
        prompt_ts,
        .{
            .prompter = &self.prompter,
            .call_id = try self.allocator.dupe(u8, req.call_id),
            .expected_user_id = try self.allocator.dupe(u8, self.expected_user_id),
            .channel = try self.allocator.dupe(u8, self.channel),
            .thread_ts = try self.allocator.dupe(u8, self.thread_ts),
            .expires_at_ms = expires_at_ms,
            // v0.4.4 — duped so they outlive the request struct and
            // are available at chat.update time.
            .tool_name = try self.allocator.dupe(u8, req.tool_name),
            .args_json = try self.allocator.dupe(u8, req.args_json),
        },
    );

    // Track for orchestrator-stop scrubbing.
    try self.registered_prompts.append(self.allocator, try self.allocator.dupe(u8, prompt_ts));

    ai.log.log(.info, "franky-do", "prompts", "posted prompt tool={s} call_id={s} channel={s} prompt_ts={s} timeout_ms={d}", .{
        req.tool_name, req.call_id, self.channel, prompt_ts, self.timeout_ms,
    });

    // Spawn the timeout thread. Detached — the timer is
    // single-shot, completes quickly once it fires, and the
    // `tryTimeoutResolve` no-ops if the user already reacted.
    const timeout_args = try self.allocator.create(TimeoutArgs);
    errdefer self.allocator.destroy(timeout_args);
    timeout_args.* = .{
        .allocator = self.allocator,
        .io = self.io,
        .api = self.api,
        .prompts_map = self.prompts_map,
        .channel = try self.allocator.dupe(u8, self.channel),
        .prompt_ts = try self.allocator.dupe(u8, prompt_ts),
        .timeout_ms = self.timeout_ms,
    };
    const t = try std.Thread.spawn(.{}, timeoutMain, .{timeout_args});
    t.detach();
}

/// v0.4.4 — render the permission-prompt as a Block Kit blocks
/// array (JSON-stringified). Caller owns the result.
///
/// Layout:
///   - section block: ":warning: *Permission required*\nThe agent wants to call `<tool>`"
///   - section block: a fenced code block carrying the tool args, capped at 1024 chars
///   - actions block: four buttons (allow_once / always_allow / deny_once / always_deny)
///     with `style: primary` on always_allow and `style: danger` on always_deny so the
///     UX visually telegraphs the safe-vs-unsafe choices.
///
/// Each button's `action_id` carries the tuple
/// `perm:<call_id>:<resolution>` so the inbound `block_actions`
/// payload can be routed back to `prompts_state.tryActionResolve`
/// without needing to consult the prompts_state map for the
/// resolution itself.
pub fn buildPromptBlocks(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args_json: []const u8,
    call_id: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');

    // Block 1: header section.
    try buf.appendSlice(allocator, "{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":");
    {
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(allocator);
        try head.appendSlice(allocator, ":warning: *Permission required*\nThe agent wants to call `");
        try head.appendSlice(allocator, tool_name);
        try head.append(allocator, '`');
        try appendJsonStr(allocator, &buf, head.items);
    }
    try buf.appendSlice(allocator, "}}");

    // Block 2: args preview (fenced code block via mrkdwn).
    try buf.appendSlice(allocator, ",{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":");
    {
        var preview: std.ArrayList(u8) = .empty;
        defer preview.deinit(allocator);
        try preview.appendSlice(allocator, "```\n");
        const max_args: usize = 1024;
        if (args_json.len <= max_args) {
            try preview.appendSlice(allocator, args_json);
        } else {
            try preview.appendSlice(allocator, args_json[0..max_args]);
            try preview.appendSlice(allocator, "…(truncated)");
        }
        try preview.appendSlice(allocator, "\n```");
        try appendJsonStr(allocator, &buf, preview.items);
    }
    try buf.appendSlice(allocator, "}}");

    // Block 3: actions row with four buttons.
    try buf.appendSlice(allocator, ",{\"type\":\"actions\",\"block_id\":\"perm_actions\",\"elements\":[");
    try appendButton(allocator, &buf, "Allow Once", "allow_once", call_id, null, false);
    try buf.append(allocator, ',');
    try appendButton(allocator, &buf, "Always Allow", "always_allow", call_id, "primary", false);
    try buf.append(allocator, ',');
    try appendButton(allocator, &buf, "Deny Once", "deny_once", call_id, null, false);
    try buf.append(allocator, ',');
    try appendButton(allocator, &buf, "Always Deny", "always_deny", call_id, "danger", false);
    try buf.appendSlice(allocator, "]}");

    try buf.append(allocator, ']');
    return try buf.toOwnedSlice(allocator);
}

/// v0.4.4 — render the post-resolution blocks. After a click,
/// the orchestrator `chat.update`s the prompt message with these
/// to disable further interaction. Same first two section blocks
/// as the prompt; the actions row is replaced with a context
/// block summarizing who decided and how.
pub fn buildResolvedBlocks(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    args_json: []const u8,
    user_id: []const u8,
    resolution: permissions_mod.Resolution,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');

    // Block 1: header (matches prompt).
    try buf.appendSlice(allocator, "{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":");
    {
        var head: std.ArrayList(u8) = .empty;
        defer head.deinit(allocator);
        try head.appendSlice(allocator, ":warning: *Permission required*\nThe agent wants to call `");
        try head.appendSlice(allocator, tool_name);
        try head.append(allocator, '`');
        try appendJsonStr(allocator, &buf, head.items);
    }
    try buf.appendSlice(allocator, "}}");

    // Block 2: args preview (matches prompt).
    try buf.appendSlice(allocator, ",{\"type\":\"section\",\"text\":{\"type\":\"mrkdwn\",\"text\":");
    {
        var preview: std.ArrayList(u8) = .empty;
        defer preview.deinit(allocator);
        try preview.appendSlice(allocator, "```\n");
        const max_args: usize = 1024;
        if (args_json.len <= max_args) {
            try preview.appendSlice(allocator, args_json);
        } else {
            try preview.appendSlice(allocator, args_json[0..max_args]);
            try preview.appendSlice(allocator, "…(truncated)");
        }
        try preview.appendSlice(allocator, "\n```");
        try appendJsonStr(allocator, &buf, preview.items);
    }
    try buf.appendSlice(allocator, "}}");

    // Block 3: context line replacing the action row.
    try buf.appendSlice(allocator, ",{\"type\":\"context\",\"elements\":[{\"type\":\"mrkdwn\",\"text\":");
    {
        var ctx: std.ArrayList(u8) = .empty;
        defer ctx.deinit(allocator);
        try ctx.appendSlice(allocator, resolutionEmoji(resolution));
        try ctx.appendSlice(allocator, " ");
        try ctx.appendSlice(allocator, resolutionLabel(resolution));
        try ctx.appendSlice(allocator, " — chosen by <@");
        try ctx.appendSlice(allocator, user_id);
        try ctx.appendSlice(allocator, ">");
        try appendJsonStr(allocator, &buf, ctx.items);
    }
    try buf.appendSlice(allocator, "}]}");

    try buf.append(allocator, ']');
    return try buf.toOwnedSlice(allocator);
}

fn resolutionEmoji(r: permissions_mod.Resolution) []const u8 {
    return switch (r) {
        .allow_once => ":white_check_mark:",
        .always_allow => ":fast_forward:",
        .deny_once => ":x:",
        .always_deny => ":no_entry_sign:",
    };
}

fn resolutionLabel(r: permissions_mod.Resolution) []const u8 {
    return switch (r) {
        .allow_once => "Allowed once",
        .always_allow => "Always allowed",
        .deny_once => "Denied once",
        .always_deny => "Always denied",
    };
}

fn appendButton(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    label: []const u8,
    resolution: []const u8,
    call_id: []const u8,
    style: ?[]const u8,
    confirm: bool,
) !void {
    _ = confirm; // reserved — Slack `confirm` dialog as a future hardening for `always_*`
    try buf.appendSlice(allocator, "{\"type\":\"button\",\"text\":{\"type\":\"plain_text\",\"text\":");
    try appendJsonStr(allocator, buf, label);
    try buf.appendSlice(allocator, "},\"value\":");
    try appendJsonStr(allocator, buf, resolution);
    try buf.appendSlice(allocator, ",\"action_id\":");
    {
        // action_id format: `perm:<call_id>:<resolution>` so the
        // inbound block_actions handler can route + decide without
        // a second lookup.
        var aid: std.ArrayList(u8) = .empty;
        defer aid.deinit(allocator);
        try aid.appendSlice(allocator, "perm:");
        try aid.appendSlice(allocator, call_id);
        try aid.append(allocator, ':');
        try aid.appendSlice(allocator, resolution);
        try appendJsonStr(allocator, buf, aid.items);
    }
    if (style) |s| {
        try buf.appendSlice(allocator, ",\"style\":");
        try appendJsonStr(allocator, buf, s);
    }
    try buf.append(allocator, '}');
}

/// Local JSON-string emitter. Slack rejects raw control chars and
/// requires `\"` / `\\` escaping. Keeps the prompt builder
/// free-standing without depending on the heavier
/// `web_api`-internal helper.
fn appendJsonStr(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    s: []const u8,
) !void {
    try buf.append(allocator, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0x08 => try buf.appendSlice(allocator, "\\b"),
        0x0c => try buf.appendSlice(allocator, "\\f"),
        else => {
            if (c < 0x20) {
                const esc = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                defer allocator.free(esc);
                try buf.appendSlice(allocator, esc);
            } else try buf.append(allocator, c);
        },
    };
    try buf.append(allocator, '"');
}

/// v0.4.4 — parse a `perm:<call_id>:<resolution>` action_id back
/// into its components. Used by `Bot.dispatchInteractive` to
/// route incoming `block_actions` payloads. Returns null when
/// the action_id doesn't match the prefix or has the wrong
/// shape (e.g. it's some other interactive action we don't own).
pub const ParsedAction = struct {
    call_id: []const u8, // borrowed slice into the input
    resolution: permissions_mod.Resolution,
};

pub fn parseActionId(action_id: []const u8) ?ParsedAction {
    const prefix = "perm:";
    if (!std.mem.startsWith(u8, action_id, prefix)) return null;
    const rest = action_id[prefix.len..];
    const sep = std.mem.lastIndexOfScalar(u8, rest, ':') orelse return null;
    const call_id = rest[0..sep];
    if (call_id.len == 0) return null;
    const res_str = rest[sep + 1 ..];
    const res = permissions_mod.Resolution.fromString(res_str) orelse return null;
    return .{ .call_id = call_id, .resolution = res };
}

const TimeoutArgs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api: *slack_web_api.Client,
    prompts_map: *prompts_state.Map,
    /// Owned dups — freed by `timeoutMain` on exit.
    channel: []u8,
    prompt_ts: []u8,
    timeout_ms: u64,
};

fn timeoutMain(args: *TimeoutArgs) void {
    defer {
        args.allocator.free(args.channel);
        args.allocator.free(args.prompt_ts);
        args.allocator.destroy(args);
    }
    sleepMs(args.timeout_ms);

    const out = args.prompts_map.tryTimeoutResolve(
        args.allocator,
        args.io,
        args.channel,
        args.prompt_ts,
    ) catch |e| {
        ai.log.log(.warn, "franky-do", "prompts", "timeout tryTimeoutResolve err: {s}", .{@errorName(e)});
        return;
    };

    const thread_ts_owned: []u8 = switch (out) {
        .resolved => |r| r.thread_ts_owned,
        .not_found, .already_resolved => return,
    };
    defer args.allocator.free(thread_ts_owned);

    var resp = args.api.chatPostMessage(.{
        .channel = args.channel,
        .text = ":hourglass_flowing_sand: no response — denied; ask again to retry",
        .thread_ts = thread_ts_owned,
    }) catch |e| {
        ai.log.log(.debug, "franky-do", "prompts", "timeout status post err: {s}", .{@errorName(e)});
        return;
    };
    defer resp.deinit();
}

fn sleepMs(ms: u64) void {
    if (@import("builtin").link_libc) {
        const sec: i64 = @intCast(ms / 1000);
        const nsec: i64 = @intCast((ms % 1000) * std.time.ns_per_ms);
        const ts = std.c.timespec{ .sec = @intCast(sec), .nsec = @intCast(nsec) };
        _ = std.c.nanosleep(&ts, null);
        return;
    }
    const start = ai.stream.nowMillis();
    const deadline = start + @as(i64, @intCast(ms));
    while (ai.stream.nowMillis() < deadline) {}
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "buildPromptBlocks: emits valid JSON with tool name, args, and four buttons" {
    const gpa = testing.allocator;
    const blocks = try buildPromptBlocks(gpa, "write", "{\"path\":\"/tmp/x\"}", "gcall-7");
    defer gpa.free(blocks);

    // Round-trip parse so we know it's a structurally valid JSON
    // array — Slack rejects malformed payloads at the API layer.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, blocks, .{});
    defer parsed.deinit();
    try testing.expectEqual(std.json.Value.array, std.meta.activeTag(parsed.value));
    try testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);

    // Sanity: tool name + args appear in the body.
    try testing.expect(std.mem.indexOf(u8, blocks, "write") != null);
    try testing.expect(std.mem.indexOf(u8, blocks, "/tmp/x") != null);

    // Four buttons present, each with the expected action_id shape
    // (`perm:<call_id>:<resolution>`).
    try testing.expect(std.mem.indexOf(u8, blocks, "perm:gcall-7:allow_once") != null);
    try testing.expect(std.mem.indexOf(u8, blocks, "perm:gcall-7:always_allow") != null);
    try testing.expect(std.mem.indexOf(u8, blocks, "perm:gcall-7:deny_once") != null);
    try testing.expect(std.mem.indexOf(u8, blocks, "perm:gcall-7:always_deny") != null);

    // Always-allow gets primary styling; always-deny gets danger.
    try testing.expect(std.mem.indexOf(u8, blocks, "\"style\":\"primary\"") != null);
    try testing.expect(std.mem.indexOf(u8, blocks, "\"style\":\"danger\"") != null);
}

test "buildPromptBlocks: truncates over-long args" {
    const gpa = testing.allocator;
    const big = "a" ** 4096;
    const blocks = try buildPromptBlocks(gpa, "bash", big, "gcall-0");
    defer gpa.free(blocks);

    try testing.expect(std.mem.indexOf(u8, blocks, "(truncated)") != null);
    // Body shouldn't carry the full 4 KB of args verbatim.
    try testing.expect(blocks.len < big.len + 1024);
}

test "buildPromptBlocks: JSON-escapes control chars in args" {
    // Args carrying a literal newline would break Slack's strict
    // JSON parser if we didn't escape. Pin the escape behavior.
    const gpa = testing.allocator;
    const blocks = try buildPromptBlocks(gpa, "write", "line1\nline2", "gcall-0");
    defer gpa.free(blocks);

    // Round-trip parse must succeed.
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, blocks, .{});
    defer parsed.deinit();

    // The escaped form `\n` appears in the JSON; raw newlines do not.
    try testing.expect(std.mem.indexOf(u8, blocks, "\\n") != null);
}

test "buildResolvedBlocks: emits header + args + chosen-by context line" {
    const gpa = testing.allocator;
    const blocks = try buildResolvedBlocks(
        gpa,
        "write",
        "{\"path\":\"/tmp/x\"}",
        "U-frank",
        .always_allow,
    );
    defer gpa.free(blocks);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, blocks, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);

    try testing.expect(std.mem.indexOf(u8, blocks, "Always allowed") != null);
    try testing.expect(std.mem.indexOf(u8, blocks, "<@U-frank>") != null);
    // Context block, not actions — no buttons in the resolved view.
    try testing.expect(std.mem.indexOf(u8, blocks, "\"type\":\"actions\"") == null);
    try testing.expect(std.mem.indexOf(u8, blocks, "\"type\":\"context\"") != null);
}

test "parseActionId: round-trips the four resolutions" {
    const cases = [_]struct {
        action_id: []const u8,
        expected_call_id: []const u8,
        expected_resolution: permissions_mod.Resolution,
    }{
        .{ .action_id = "perm:gcall-0:allow_once", .expected_call_id = "gcall-0", .expected_resolution = .allow_once },
        .{ .action_id = "perm:toolu_01ABC:always_allow", .expected_call_id = "toolu_01ABC", .expected_resolution = .always_allow },
        .{ .action_id = "perm:gcall-9:deny_once", .expected_call_id = "gcall-9", .expected_resolution = .deny_once },
        .{ .action_id = "perm:abc:always_deny", .expected_call_id = "abc", .expected_resolution = .always_deny },
    };
    for (cases) |c| {
        const parsed = parseActionId(c.action_id) orelse return error.UnexpectedNull;
        try testing.expectEqualStrings(c.expected_call_id, parsed.call_id);
        try testing.expectEqual(c.expected_resolution, parsed.resolution);
    }
}

test "parseActionId: rejects non-perm prefixes and bad shapes" {
    try testing.expect(parseActionId("hello") == null);
    try testing.expect(parseActionId("perm:") == null);
    try testing.expect(parseActionId("perm::allow_once") == null); // empty call_id
    try testing.expect(parseActionId("perm:gcall-0:not_a_resolution") == null);
}
