//! v0.3.2/v0.3.3 — bot-level map `(slack_channel, prompt_ts) → PromptEntry`.
//!
//! When the agent fires a `tool_permission_request` event, the
//! bot's permission-drain thread posts a Slack message ("agent
//! wants to call `write(...)`") and registers the `(channel,
//! prompt_ts)` of that message here, plus enough context to:
//!
//!   1. Find the `PermissionPrompter` to call `resolve` on once
//!      a reaction lands.
//!   2. Verify the reactor is the original `@`-mentioner
//!      (B.3.4 owner-only resolution).
//!   3. Post a status message in the right Slack channel/thread
//!      after resolution.
//!
//! v0.3.3 adds `tryReactionResolve` + `tryTimeoutResolve` — atomic
//! "lookup + win the race + call prompter.resolve + remove" under
//! the map mutex. This is the cornerstone of safe lifetimes: any
//! code that dereferences the borrowed `*PermissionPrompter` does
//! so under the map mutex, so an `Orchestrator.stop` that holds
//! the mutex while removing its own entries has a guarantee that
//! no concurrent reactor / timeout is mid-call when it later
//! deinit's the prompter.

const std = @import("std");
const franky = @import("franky");
const permissions_mod = franky.coding.permissions;

pub const PromptEntry = struct {
    /// Borrowed pointer into the per-mention prompter that lives
    /// on the mention worker's stack (heap-allocated by the
    /// orchestrator). Invariant: dereferenced ONLY under the
    /// `Map.mutex` so the orchestrator's stop+deinit can serialize
    /// against in-flight reactors / timeouts.
    prompter: *permissions_mod.PermissionPrompter,
    /// `call_id` to pass to `prompter.resolve`.
    call_id: []u8,
    /// The `@`-mentioner — only this user_id can resolve the
    /// prompt (B.3.4). Other users' reactions are logged at debug
    /// and ignored.
    expected_user_id: []u8,
    /// Slack channel + thread_ts where the original mention was
    /// posted; used to post the resolution-status reply.
    channel: []u8,
    thread_ts: []u8,
    /// Wall-clock deadline (ms). After this passes, the per-
    /// prompt timer thread auto-resolves.
    expires_at_ms: i64,
    /// v0.4.4 — preserved for the post-resolution `chat.update`.
    /// When a Block Kit button click resolves the prompt, the bot
    /// rebuilds the same header + args view and swaps the action
    /// row for a context line; rebuilding needs the original tool
    /// name + args. Owned dups, freed alongside the entry.
    tool_name: []u8,
    args_json: []u8,
    /// Flipped when resolve fires (either by reaction or by
    /// timeout). Atomic so the timer + reaction-handler threads
    /// can race for the win, but the *winner's* `prompter.resolve`
    /// call is still serialized via the map mutex.
    resolved: std.atomic.Value(bool) = .init(false),
};

/// Outcome of `tryReactionResolve` — the bot uses this to drive
/// the user-visible status reply.
pub const ReactionOutcome = union(enum) {
    /// No entry for `(channel, prompt_ts)`. Caller should fall
    /// through to abort/retry routing or just return.
    not_found,
    /// Entry exists but the reactor isn't the `@`-mentioner.
    /// `expected_user_id` is borrowed from the entry (valid only
    /// during the call — ALREADY RELEASED when this returns since
    /// the map mutex was unlocked; caller MUST dupe before using).
    /// To avoid that footgun the field is duped here.
    user_mismatch: struct {
        expected_user_id_owned: []u8,
    },
    /// Entry was already resolved by another path (rare race —
    /// reactor lost to a faster reactor or timeout). No-op.
    already_resolved,
    /// Resolution accepted; `prompter.resolve` was called and the
    /// entry was removed. All `*_owned` slices are duped — caller
    /// frees on every code path.
    resolved: struct {
        thread_ts_owned: []u8,
        /// v0.4.4 — surfaced so the caller can rebuild the
        /// post-resolution block-kit blocks for the `chat.update`
        /// that disables the action row.
        tool_name_owned: []u8,
        args_json_owned: []u8,
    },
};

pub const TimeoutOutcome = union(enum) {
    not_found,
    already_resolved,
    /// Entry was timed-out → `prompter.resolve(.., .deny_once)`
    /// was called and the entry was removed. `thread_ts` is duped
    /// — caller frees.
    resolved: struct {
        thread_ts_owned: []u8,
    },
};

pub const Map = struct {
    /// Composite key = `<channel>":"<prompt_ts>` (allocator-
    /// duped). Values: heap-allocated `PromptEntry` (so the
    /// `resolved` flag has a stable address).
    map: std.StringHashMapUnmanaged(*PromptEntry) = .empty,
    mutex: std.Io.Mutex = .init,

    pub fn deinit(self: *Map, allocator: std.mem.Allocator, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            const e = entry.value_ptr.*;
            freeEntryStrings(allocator, e);
            allocator.destroy(e);
        }
        self.map.deinit(allocator);
    }

    pub fn put(
        self: *Map,
        allocator: std.mem.Allocator,
        io: std.Io,
        channel: []const u8,
        prompt_ts: []const u8,
        entry: PromptEntry,
    ) !void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const key = try compositeKey(allocator, channel, prompt_ts);
        errdefer allocator.free(key);
        const e_ptr = try allocator.create(PromptEntry);
        errdefer allocator.destroy(e_ptr);
        e_ptr.* = entry;
        try self.map.put(allocator, key, e_ptr);
    }

    /// Look up by `(channel, prompt_ts)`. Returned pointer is
    /// borrowed (the mutex is RELEASED on return!) — only safe
    /// for non-prompter fields. Prefer `tryReactionResolve` /
    /// `tryTimeoutResolve` if you need to deref `entry.prompter`.
    pub fn get(
        self: *Map,
        allocator: std.mem.Allocator,
        io: std.Io,
        channel: []const u8,
        prompt_ts: []const u8,
    ) !?*PromptEntry {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const key = try compositeKey(allocator, channel, prompt_ts);
        defer allocator.free(key);
        return self.map.get(key);
    }

    /// Drop the mapping for `(channel, prompt_ts)` and free the
    /// entry. No-op if absent.
    pub fn remove(
        self: *Map,
        allocator: std.mem.Allocator,
        io: std.Io,
        channel: []const u8,
        prompt_ts: []const u8,
    ) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const key = compositeKey(allocator, channel, prompt_ts) catch return;
        defer allocator.free(key);
        if (self.map.fetchRemove(key)) |kv| {
            allocator.free(kv.key);
            const e = kv.value;
            freeEntryStrings(allocator, e);
            allocator.destroy(e);
        }
    }

    /// v0.4.4 — single-source helper for releasing a `PromptEntry`'s
    /// owned strings. Adding a field touches one place instead of
    /// four.
    fn freeEntryStrings(allocator: std.mem.Allocator, e: *PromptEntry) void {
        allocator.free(e.call_id);
        allocator.free(e.expected_user_id);
        allocator.free(e.channel);
        allocator.free(e.thread_ts);
        allocator.free(e.tool_name);
        allocator.free(e.args_json);
    }

    /// Atomic reaction-resolution path. Holds the map mutex from
    /// lookup through `prompter.resolve` through `remove`, so a
    /// concurrent `Orchestrator.stop` that takes the same mutex
    /// can safely deinit the prompter once it returns.
    ///
    /// Owner-only check (B.3.4): `reactor_user_id` must match
    /// `entry.expected_user_id`, otherwise returns
    /// `.user_mismatch`. The `prompter.resolve` `error.NotPending`
    /// case is folded into `.already_resolved` (the slot was
    /// pulled by a faster path).
    pub fn tryReactionResolve(
        self: *Map,
        allocator: std.mem.Allocator,
        io: std.Io,
        channel: []const u8,
        prompt_ts: []const u8,
        reactor_user_id: []const u8,
        resolution: permissions_mod.Resolution,
    ) !ReactionOutcome {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const key = try compositeKey(allocator, channel, prompt_ts);
        defer allocator.free(key);

        const entry = self.map.get(key) orelse return .not_found;

        if (!std.mem.eql(u8, entry.expected_user_id, reactor_user_id)) {
            return .{ .user_mismatch = .{
                .expected_user_id_owned = try allocator.dupe(u8, entry.expected_user_id),
            } };
        }

        if (entry.resolved.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) {
            return .already_resolved;
        }

        entry.prompter.resolve(entry.call_id, resolution) catch |e| {
            // `error.NotPending` means the prompter slot was
            // already pulled by another path — treat as already-
            // resolved (the user-facing status post is a no-op).
            franky.ai.log.log(.debug, "franky-do", "prompts", "tryReactionResolve: prompter.resolve err: {s}", .{@errorName(e)});
        };

        // v0.4.4 — surface tool_name + args_json on the outcome so
        // the bot can rebuild the post-resolution blocks for
        // `chat.update` without a second map lookup.
        const thread_ts_dup = try allocator.dupe(u8, entry.thread_ts);
        errdefer allocator.free(thread_ts_dup);
        const tool_name_dup = try allocator.dupe(u8, entry.tool_name);
        errdefer allocator.free(tool_name_dup);
        const args_json_dup = try allocator.dupe(u8, entry.args_json);
        errdefer allocator.free(args_json_dup);

        if (self.map.fetchRemove(key)) |kv| {
            allocator.free(kv.key);
            const e = kv.value;
            freeEntryStrings(allocator, e);
            allocator.destroy(e);
        }

        return .{ .resolved = .{
            .thread_ts_owned = thread_ts_dup,
            .tool_name_owned = tool_name_dup,
            .args_json_owned = args_json_dup,
        } };
    }

    /// Atomic timeout-resolution path. Same critical section as
    /// `tryReactionResolve` minus the user check (the timer is a
    /// privileged actor). Resolution is hard-coded to `deny_once`.
    pub fn tryTimeoutResolve(
        self: *Map,
        allocator: std.mem.Allocator,
        io: std.Io,
        channel: []const u8,
        prompt_ts: []const u8,
    ) !TimeoutOutcome {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        const key = try compositeKey(allocator, channel, prompt_ts);
        defer allocator.free(key);

        const entry = self.map.get(key) orelse return .not_found;

        if (entry.resolved.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) {
            return .already_resolved;
        }

        entry.prompter.resolve(entry.call_id, .deny_once) catch |e| {
            franky.ai.log.log(.debug, "franky-do", "prompts", "tryTimeoutResolve: prompter.resolve err: {s}", .{@errorName(e)});
        };

        const thread_ts_dup = try allocator.dupe(u8, entry.thread_ts);

        if (self.map.fetchRemove(key)) |kv| {
            allocator.free(kv.key);
            const e = kv.value;
            freeEntryStrings(allocator, e);
            allocator.destroy(e);
        }

        return .{ .resolved = .{ .thread_ts_owned = thread_ts_dup } };
    }
};

fn compositeKey(allocator: std.mem.Allocator, channel: []const u8, prompt_ts: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, channel);
    try buf.append(allocator, ':');
    try buf.appendSlice(allocator, prompt_ts);
    return try buf.toOwnedSlice(allocator);
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "Map: put + get + remove round-trip" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var m: Map = .{};
    defer m.deinit(gpa, io);

    var fake_prompter: permissions_mod.PermissionPrompter = undefined;

    try m.put(gpa, io, "C123", "1.0", .{
        .prompter = &fake_prompter,
        .call_id = try gpa.dupe(u8, "call-x"),
        .expected_user_id = try gpa.dupe(u8, "U001"),
        .channel = try gpa.dupe(u8, "C123"),
        .thread_ts = try gpa.dupe(u8, "0.5"),
        .expires_at_ms = 9999,
        .tool_name = try gpa.dupe(u8, "write"),
        .args_json = try gpa.dupe(u8, "{\"path\":\"/tmp/x\"}"),
    });

    const got = try m.get(gpa, io, "C123", "1.0");
    try testing.expect(got != null);
    try testing.expectEqualStrings("call-x", got.?.call_id);
    try testing.expectEqualStrings("U001", got.?.expected_user_id);
    try testing.expectEqual(@as(i64, 9999), got.?.expires_at_ms);

    m.remove(gpa, io, "C123", "1.0");
    const after = try m.get(gpa, io, "C123", "1.0");
    try testing.expect(after == null);
}

test "Map: missing key returns null without error" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var m: Map = .{};
    defer m.deinit(gpa, io);

    const got = try m.get(gpa, io, "C-nope", "0.0");
    try testing.expect(got == null);
}

test "tryReactionResolve happy path: allow_once resolves prompter and removes entry" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var ch = try franky.agent.loop.AgentChannel.initWithDrop(
        gpa,
        16,
        franky.agent.types.AgentEvent.deinit,
        gpa,
    );
    defer ch.deinit();

    var prompter = permissions_mod.PermissionPrompter.init(gpa, io, &ch);
    defer prompter.deinit();

    var m: Map = .{};
    defer m.deinit(gpa, io);

    // Seed the prompter with a pending call (simulates the worker
    // thread suspending in `requestAndWait`).
    const Worker = struct {
        fn run(p: *permissions_mod.PermissionPrompter, out: *?permissions_mod.Resolution) void {
            const r = p.requestAndWait("write", "call-1", "{}") catch return;
            out.* = r;
        }
    };
    var got_resolution: ?permissions_mod.Resolution = null;
    const t = try std.Thread.spawn(.{}, Worker.run, .{ &prompter, &got_resolution });

    // Drain the request event off the channel so we don't leak.
    const ev = ch.next(io).?;
    defer ev.deinit(gpa);
    try testing.expect(ev == .tool_permission_request);

    // Register the prompt in the bot map.
    try m.put(gpa, io, "C1", "5.0", .{
        .prompter = &prompter,
        .call_id = try gpa.dupe(u8, "call-1"),
        .expected_user_id = try gpa.dupe(u8, "U-owner"),
        .channel = try gpa.dupe(u8, "C1"),
        .thread_ts = try gpa.dupe(u8, "4.0"),
        .expires_at_ms = 9_999_999_999,
        .tool_name = try gpa.dupe(u8, "write"),
        .args_json = try gpa.dupe(u8, "{}"),
    });

    const outcome = try m.tryReactionResolve(gpa, io, "C1", "5.0", "U-owner", .allow_once);
    switch (outcome) {
        .resolved => |r| {
            try testing.expectEqualStrings("4.0", r.thread_ts_owned);
            try testing.expectEqualStrings("write", r.tool_name_owned);
            try testing.expectEqualStrings("{}", r.args_json_owned);
            gpa.free(r.thread_ts_owned);
            gpa.free(r.tool_name_owned);
            gpa.free(r.args_json_owned);
        },
        else => try testing.expect(false),
    }
    // Entry must be gone.
    try testing.expect((try m.get(gpa, io, "C1", "5.0")) == null);

    // Worker should have woken up with allow_once.
    t.join();
    try testing.expectEqual(permissions_mod.Resolution.allow_once, got_resolution.?);
}

test "tryReactionResolve user_mismatch returns expected_user_id and leaves entry" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var fake_prompter: permissions_mod.PermissionPrompter = undefined;
    var m: Map = .{};
    defer m.deinit(gpa, io);

    try m.put(gpa, io, "C2", "5.1", .{
        .prompter = &fake_prompter,
        .call_id = try gpa.dupe(u8, "call-2"),
        .expected_user_id = try gpa.dupe(u8, "U-alice"),
        .channel = try gpa.dupe(u8, "C2"),
        .thread_ts = try gpa.dupe(u8, "4.1"),
        .expires_at_ms = 9_999_999_999,
        .tool_name = try gpa.dupe(u8, "write"),
        .args_json = try gpa.dupe(u8, "{}"),
    });

    const outcome = try m.tryReactionResolve(gpa, io, "C2", "5.1", "U-bob", .allow_once);
    switch (outcome) {
        .user_mismatch => |um| {
            try testing.expectEqualStrings("U-alice", um.expected_user_id_owned);
            gpa.free(um.expected_user_id_owned);
        },
        else => try testing.expect(false),
    }
    // Entry must still be there.
    try testing.expect((try m.get(gpa, io, "C2", "5.1")) != null);
}

test "tryReactionResolve already_resolved returns without erroring" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var ch = try franky.agent.loop.AgentChannel.initWithDrop(
        gpa,
        16,
        franky.agent.types.AgentEvent.deinit,
        gpa,
    );
    defer ch.deinit();

    var prompter = permissions_mod.PermissionPrompter.init(gpa, io, &ch);
    defer prompter.deinit();

    var m: Map = .{};
    defer m.deinit(gpa, io);

    try m.put(gpa, io, "C3", "5.2", .{
        .prompter = &prompter,
        .call_id = try gpa.dupe(u8, "call-3"),
        .expected_user_id = try gpa.dupe(u8, "U-x"),
        .channel = try gpa.dupe(u8, "C3"),
        .thread_ts = try gpa.dupe(u8, "4.2"),
        .expires_at_ms = 9_999_999_999,
        .tool_name = try gpa.dupe(u8, "write"),
        .args_json = try gpa.dupe(u8, "{}"),
    });

    // Pre-mark resolved (simulates the timer winning the race).
    const e = (try m.get(gpa, io, "C3", "5.2")).?;
    e.resolved.store(true, .release);

    const outcome = try m.tryReactionResolve(gpa, io, "C3", "5.2", "U-x", .allow_once);
    try testing.expect(outcome == .already_resolved);
    // Entry stays in map (caller's responsibility to clean up via
    // tryTimeoutResolve / orchestrator stop path).
    try testing.expect((try m.get(gpa, io, "C3", "5.2")) != null);
    // Manually clean up so deinit doesn't double-free.
    m.remove(gpa, io, "C3", "5.2");
}
