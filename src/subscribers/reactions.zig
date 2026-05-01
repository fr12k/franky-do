//! v0.3.0 / v0.3.4 — single-emoji status indicator on the user's
//! `@`-mention message.
//!
//! Subscribes to the agent's event stream + receives explicit "I saw
//! your mention" / "I'm done" callbacks from the bot. Fires Slack
//! `reactions.add` calls — and `reactions.remove` calls for the
//! prior state — to surface state without scrolling:
//!
//!   👀  (`:eyes:`)              — mention received (bot saw the message)
//!   💭  (`:thought_balloon:`)   — agent worker started
//!   ✅  (`:white_check_mark:`)  — final turn completed successfully
//!   ❌  (`:x:`)                 — `agent_error` fired
//!
//! Per the **revised** A.3.4 decision (v0.3.4), we keep ONLY the
//! latest state emoji. Each transition removes the previous one,
//! so the mention message at any moment shows exactly one of
//! 👀/💭/✅/❌ — the bot's *current* status, not a history.
//!
//! Per design A.3.3, the per-tool `🔧` reaction is **deliberately
//! never fired**: in a multi-tool turn it would race with Slack's
//! Tier-3 rate limit, and the streamed `chat.update` text already
//! shows what's happening. We trade per-tool granularity for a
//! tight per-mention API budget (4-7 calls: 1 add per state +
//! 1 remove per transition).
//!
//! Per A.3.3, a 429 from Slack's rate-limit logs at warn and the
//! corresponding state simply doesn't render — we don't retry,
//! and we don't fail the turn over a missing emoji. If
//! `reactions.remove` 429s the user will briefly see two emojis
//! at once; we accept that over indefinite retry loops.

const std = @import("std");
const franky = @import("franky");
const at = franky.agent.types;
const ai = franky.ai;
const web_api = @import("../slack/api.zig");

pub const Terminal = enum { success, error_state };

/// Visible single-emoji state. The subscriber tracks "what we last
/// posted" so the next transition knows what to remove. `none`
/// is the pre-`markReceived` startup state where the message has
/// no bot reactions yet.
const State = enum {
    none,
    eyes,
    thought_balloon,
    white_check_mark,
    x,

    fn name(self: State) ?[]const u8 {
        return switch (self) {
            .none => null,
            .eyes => "eyes",
            .thought_balloon => "thought_balloon",
            .white_check_mark => "white_check_mark",
            .x => "x",
        };
    }
};

pub const ReactionsSubscriber = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api: *web_api.Client,
    /// Channel containing the user's `@`-mention.
    channel: []const u8,
    /// `ts` of the user's mention message — what we react ON.
    /// Borrowed from the caller; must outlive this subscriber.
    user_message_ts: []const u8,

    /// State machine. Mutated under `state_mutex` so an
    /// `agent_error` event firing concurrently with a
    /// `markFinal(.success)` from the bot can't both observe the
    /// same prior state and try to remove it twice.
    state: State = .none,
    state_mutex: std.Io.Mutex = .init,

    /// Sticky error-state flag — set by `agent_error` event or by
    /// `markFinal(.error_state)`. Once set, a subsequent
    /// `markFinal(.success)` from a stale code path is upgraded
    /// to `.error_state` so the visible emoji matches reality.
    is_error_state: std.atomic.Value(bool) = .init(false),

    /// True once `markFinal` ran successfully — keeps the call
    /// idempotent across the bot's safety re-call paths.
    posted_terminal: std.atomic.Value(bool) = .init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        api: *web_api.Client,
        channel: []const u8,
        user_message_ts: []const u8,
    ) ReactionsSubscriber {
        return .{
            .allocator = allocator,
            .io = io,
            .api = api,
            .channel = channel,
            .user_message_ts = user_message_ts,
        };
    }

    /// Bot calls this synchronously the moment a mention is
    /// received, before any agent work starts. Transitions
    /// `none → 👀`.
    pub fn markReceived(self: *ReactionsSubscriber) void {
        self.transition(.eyes);
    }

    /// Bot calls this AFTER `agent.waitForIdle()` returns — once
    /// the worker thread has joined and the conversation is truly
    /// over. Transitions to ✅ on success, ❌ on error.
    /// Idempotent across calls.
    ///
    /// If `agent_error` fired during the run (flagging
    /// `is_error_state`), a subsequent `markFinal(.success)` is
    /// upgraded to `.error_state` so the visible emoji matches
    /// reality.
    pub fn markFinal(self: *ReactionsSubscriber, terminal: Terminal) void {
        if (terminal == .error_state) _ = self.is_error_state.swap(true, .acq_rel);
        if (self.posted_terminal.swap(true, .acq_rel)) return;

        const effective: Terminal = if (self.is_error_state.load(.acquire))
            .error_state
        else
            terminal;

        switch (effective) {
            .success => self.transition(.white_check_mark),
            .error_state => self.transition(.x),
        }
    }

    /// External read for the bot's `markFinal` decision. Returns
    /// true if the agent fired `agent_error` during the run.
    pub fn errorFlagged(self: *const ReactionsSubscriber) bool {
        return self.is_error_state.load(.acquire);
    }

    /// Subscriber callback for `franky.agent.Agent.subscribe`.
    /// Fires 💭 on the first `turn_start` of a run (replacing 👀)
    /// and updates `is_error_state` on `agent_error` (the bot
    /// will call `markFinal(.error_state)` shortly after; we just
    /// race-flag here so a concurrent `markFinal(.success)` from
    /// a separate code path doesn't paint over).
    pub fn onEvent(ud: ?*anyopaque, ev: at.AgentEvent) void {
        const self: *ReactionsSubscriber = @ptrCast(@alignCast(ud.?));
        switch (ev) {
            .turn_start => {
                // Only first transition to thought_balloon counts;
                // subsequent turn_starts in a multi-turn flow stay
                // at 💭.
                self.transition(.thought_balloon);
            },
            .agent_error => {
                // Don't post ❌ here — the bot's
                // `markFinal(.error_state)` owns that; we just
                // flag so a stale `markFinal(.success)` gets
                // upgraded to `.error_state` in `markFinal`.
                _ = self.is_error_state.swap(true, .acq_rel);
            },
            else => {},
        }
    }

    /// Atomic state transition. If the new state is the same as
    /// the current one, no API calls fire (idempotent —
    /// `turn_start` repeats in multi-turn flows). Otherwise:
    ///
    ///   1. Add the new emoji (best-effort).
    ///   2. Remove the prior emoji (best-effort).
    ///
    /// Order matters: if the remove fails after the add succeeds,
    /// the user briefly sees both emojis — better than the
    /// reverse failure mode (no emoji at all). State is committed
    /// BEFORE the network calls so a concurrent transition that
    /// loses the mutex race observes the new state, not the
    /// old one.
    fn transition(self: *ReactionsSubscriber, new_state: State) void {
        // Read prior + commit new under the mutex, then release
        // before doing network IO — keeping the mutex during HTTP
        // requests would serialize unrelated transitions and risk
        // priority inversion under contention.
        self.state_mutex.lockUncancelable(self.io);
        const prior = self.state;
        if (prior == new_state) {
            self.state_mutex.unlock(self.io);
            return;
        }
        self.state = new_state;
        self.state_mutex.unlock(self.io);

        if (new_state.name()) |new_name| {
            self.fireAdd(new_name);
        }
        if (prior.name()) |old_name| {
            self.fireRemove(old_name);
        }
    }

    /// Best-effort POST. Per A.3.3, 429s log at warn and we move
    /// on. Other failures (HTTP, malformed Slack response) also
    /// log and move on — a missing reaction never fails the turn.
    fn fireAdd(self: *ReactionsSubscriber, name: []const u8) void {
        ai.log.log(.debug, "franky-do", "reaction", "add channel={s} ts={s} name={s}", .{
            self.channel, self.user_message_ts, name,
        });
        var resp = self.api.reactionsAdd(.{
            .channel = self.channel,
            .timestamp = self.user_message_ts,
            .name = name,
        }) catch |e| {
            ai.log.log(.warn, "franky-do", "reaction", "reactions.add failed: {s}", .{@errorName(e)});
            return;
        };
        defer resp.deinit();
        if (!resp.value.ok) {
            const err = resp.value.@"error" orelse "unknown";
            // `already_reacted` is a noop — Slack's idempotency.
            const level: ai.log.Level = if (std.mem.eql(u8, err, "already_reacted")) .debug else .warn;
            ai.log.log(level, "franky-do", "reaction", "reactions.add !ok name={s} error={s}", .{ name, err });
        } else {
            ai.log.log(.debug, "franky-do", "reaction", "ok add name={s}", .{name});
        }
    }

    fn fireRemove(self: *ReactionsSubscriber, name: []const u8) void {
        ai.log.log(.debug, "franky-do", "reaction", "remove channel={s} ts={s} name={s}", .{
            self.channel, self.user_message_ts, name,
        });
        var resp = self.api.reactionsRemove(.{
            .channel = self.channel,
            .timestamp = self.user_message_ts,
            .name = name,
        }) catch |e| {
            ai.log.log(.warn, "franky-do", "reaction", "reactions.remove failed: {s}", .{@errorName(e)});
            return;
        };
        defer resp.deinit();
        if (!resp.value.ok) {
            const err = resp.value.@"error" orelse "unknown";
            // `no_reaction` means it was already removed (e.g. a
            // user manually removed it, or a prior remove
            // succeeded but we missed the response). Quiet.
            const level: ai.log.Level = if (std.mem.eql(u8, err, "no_reaction")) .debug else .warn;
            ai.log.log(level, "franky-do", "reaction", "reactions.remove !ok name={s} error={s}", .{ name, err });
        } else {
            ai.log.log(.debug, "franky-do", "reaction", "ok remove name={s}", .{name});
        }
    }
};

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

/// Loopback Slack server for reactions.add / reactions.remove
/// tests. Counts requests + captures last body. Mirrors the
/// pattern in stream_subscriber.zig.
const TallyServer = struct {
    server: std.Io.net.Server,
    port: u16,
    count: std.atomic.Value(u32) = .init(0),
    last_body: ?[]u8 = null,
    last_body_mutex: std.Io.Mutex = .init,
    /// Captured `(path, name)` per request, in arrival order.
    /// Test reads at end. v0.3.4 — added `path` so tests can
    /// distinguish add from remove.
    calls: std.ArrayList(Call) = .empty,
    calls_mutex: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    io: std.Io,
    stop: std.atomic.Value(bool) = .init(false),
    /// Status to return per request — 200 by default; flip to
    /// 429 to test rate-limit handling.
    response_status: std.atomic.Value(u16) = .init(200),

    const Call = struct {
        path: []u8,
        name: []u8,
    };
};

fn tallyServerLoop(s: *TallyServer) void {
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

        // Parse request path from the first line ("POST /reactions.add HTTP/1.1").
        var path_owned: []u8 = s.allocator.dupe(u8, "?") catch continue;
        if (std.mem.indexOf(u8, head, "POST ")) |p_pos| {
            const after = head[p_pos + "POST ".len ..];
            if (std.mem.indexOfScalar(u8, after, ' ')) |sp| {
                s.allocator.free(path_owned);
                path_owned = s.allocator.dupe(u8, after[0..sp]) catch s.allocator.dupe(u8, "?") catch continue;
            }
        }

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
        {
            s.last_body_mutex.lockUncancelable(s.io);
            defer s.last_body_mutex.unlock(s.io);
            if (s.last_body) |b| s.allocator.free(b);
            s.last_body = s.allocator.dupe(u8, body_slice) catch null;
        }
        // Extract `name` from the JSON body.
        var name_owned: []u8 = s.allocator.dupe(u8, "") catch {
            s.allocator.free(path_owned);
            continue;
        };
        if (std.mem.indexOf(u8, body_slice, "\"name\":\"")) |name_idx| {
            const start = name_idx + "\"name\":\"".len;
            if (std.mem.indexOfScalarPos(u8, body_slice, start, '"')) |end| {
                s.allocator.free(name_owned);
                name_owned = s.allocator.dupe(u8, body_slice[start..end]) catch s.allocator.dupe(u8, "") catch {
                    s.allocator.free(path_owned);
                    continue;
                };
            }
        }
        {
            s.calls_mutex.lockUncancelable(s.io);
            defer s.calls_mutex.unlock(s.io);
            s.calls.append(s.allocator, .{ .path = path_owned, .name = name_owned }) catch {
                s.allocator.free(path_owned);
                s.allocator.free(name_owned);
            };
        }

        const status = s.response_status.load(.acquire);
        const reply_ok = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}";
        const reply_429 = "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nContent-Length: 38\r\nConnection: close\r\n\r\n{\"ok\":false,\"error\":\"ratelimited\"}";
        var wbuf: [256]u8 = undefined;
        var w = stream_conn.writer(s.io, &wbuf);
        const body = if (status == 429) reply_429 else reply_ok;
        w.interface.writeAll(body) catch {};
        w.interface.flush() catch {};

        _ = s.count.fetchAdd(1, .monotonic);
    }
}

fn bindTallyServer(allocator: std.mem.Allocator, io: std.Io) ?TallyServer {
    var p: u16 = 19700;
    while (p < 19799) : (p += 1) {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch continue;
        const server = std.Io.net.IpAddress.listen(&addr, io, .{
            .kernel_backlog = 16,
            .reuse_address = true,
        }) catch continue;
        return .{ .server = server, .port = p, .allocator = allocator, .io = io };
    }
    return null;
}

fn deinitTallyServer(s: *TallyServer) void {
    s.last_body_mutex.lockUncancelable(s.io);
    defer s.last_body_mutex.unlock(s.io);
    if (s.last_body) |b| s.allocator.free(b);
    {
        s.calls_mutex.lockUncancelable(s.io);
        defer s.calls_mutex.unlock(s.io);
        for (s.calls.items) |c| {
            s.allocator.free(c.path);
            s.allocator.free(c.name);
        }
        s.calls.deinit(s.allocator);
    }
    s.server.deinit(s.io);
}

fn drainTallyServer(s: *TallyServer, io: std.Io, server_thread: std.Thread) void {
    s.stop.store(true, .release);
    var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", s.port) catch unreachable;
    if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch null) |strm| {
        var sm = strm;
        sm.close(io);
    }
    server_thread.join();
}

test "ReactionsSubscriber: markReceived → 👀 fires once even on repeat calls" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindTallyServer(gpa, io) orelse return;
    defer deinitTallyServer(&s);
    const server_thread = try std.Thread.spawn(.{}, tallyServerLoop, .{&s});
    defer drainTallyServer(&s, io, server_thread);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = ReactionsSubscriber.init(gpa, io, &api, "C123", "1234567890.000100");
    sub.markReceived();
    sub.markReceived(); // idempotent — should NOT issue a second add or any remove

    try testing.expectEqual(@as(u32, 1), s.count.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), s.calls.items.len);
    try testing.expectEqualStrings("/reactions.add", s.calls.items[0].path);
    try testing.expectEqualStrings("eyes", s.calls.items[0].name);
}

test "ReactionsSubscriber: state machine adds new + removes prior in order" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindTallyServer(gpa, io) orelse return;
    defer deinitTallyServer(&s);
    const server_thread = try std.Thread.spawn(.{}, tallyServerLoop, .{&s});
    defer drainTallyServer(&s, io, server_thread);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = ReactionsSubscriber.init(gpa, io, &api, "C123", "1234567890.000100");
    // none → eyes (1 add)
    sub.markReceived();
    // eyes → thought_balloon (1 add + 1 remove)
    ReactionsSubscriber.onEvent(@ptrCast(&sub), .turn_start);
    // thought_balloon → thought_balloon (no-op, second turn_start)
    ReactionsSubscriber.onEvent(@ptrCast(&sub), .turn_start);
    // thought_balloon → white_check_mark (1 add + 1 remove)
    sub.markFinal(.success);

    // Total = 5 calls: add(eyes) + add(thought_balloon) +
    // remove(eyes) + add(white_check_mark) + remove(thought_balloon)
    try testing.expectEqual(@as(u32, 5), s.count.load(.monotonic));
    try testing.expectEqual(@as(usize, 5), s.calls.items.len);

    try testing.expectEqualStrings("/reactions.add", s.calls.items[0].path);
    try testing.expectEqualStrings("eyes", s.calls.items[0].name);
    try testing.expectEqualStrings("/reactions.add", s.calls.items[1].path);
    try testing.expectEqualStrings("thought_balloon", s.calls.items[1].name);
    try testing.expectEqualStrings("/reactions.remove", s.calls.items[2].path);
    try testing.expectEqualStrings("eyes", s.calls.items[2].name);
    try testing.expectEqualStrings("/reactions.add", s.calls.items[3].path);
    try testing.expectEqualStrings("white_check_mark", s.calls.items[3].name);
    try testing.expectEqualStrings("/reactions.remove", s.calls.items[4].path);
    try testing.expectEqualStrings("thought_balloon", s.calls.items[4].name);
}

test "ReactionsSubscriber: agent_error then markFinal(.error_state) fires ❌ and removes prior" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindTallyServer(gpa, io) orelse return;
    defer deinitTallyServer(&s);
    const server_thread = try std.Thread.spawn(.{}, tallyServerLoop, .{&s});
    defer drainTallyServer(&s, io, server_thread);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = ReactionsSubscriber.init(gpa, io, &api, "C123", "1234567890.000100");
    sub.markReceived();
    ReactionsSubscriber.onEvent(@ptrCast(&sub), .turn_start);
    // agent_error event — flags error but doesn't post.
    ReactionsSubscriber.onEvent(@ptrCast(&sub), .{ .agent_error = .{
        .code = .internal,
        .message = "test",
    } });
    sub.markFinal(.error_state);
    // Race case: stale .success after error — must NOT fire.
    sub.markFinal(.success);

    // Calls: add(eyes), add(thought_balloon), remove(eyes), add(x), remove(thought_balloon)
    try testing.expectEqual(@as(u32, 5), s.count.load(.monotonic));
    try testing.expectEqualStrings("x", s.calls.items[3].name);
    try testing.expectEqualStrings("/reactions.add", s.calls.items[3].path);
    try testing.expectEqualStrings("thought_balloon", s.calls.items[4].name);
    try testing.expectEqualStrings("/reactions.remove", s.calls.items[4].path);
}

test "ReactionsSubscriber: 429 from Slack does not panic" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindTallyServer(gpa, io) orelse return;
    defer deinitTallyServer(&s);
    s.response_status.store(429, .release);
    const server_thread = try std.Thread.spawn(.{}, tallyServerLoop, .{&s});
    defer drainTallyServer(&s, io, server_thread);

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = ReactionsSubscriber.init(gpa, io, &api, "C123", "1234567890.000100");
    // Should not throw / crash even though Slack returns 429.
    sub.markReceived();
    sub.markFinal(.success);

    // The subscriber attempted both transitions — server saw at
    // least 1 request despite all failing. State still flips so
    // we don't retry.
    try testing.expect(s.count.load(.monotonic) >= 1);
}
