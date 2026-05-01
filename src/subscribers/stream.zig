//! Per-message Slack poster (§24 of franky-do.md, v0.5.0).
//!
//! Replaces the v0.4.x throttled `chat.update` streamer. The new
//! contract:
//!
//!   * No placeholder. The 💭 reaction on the user's `@`-mention
//!     is the "still working" indicator.
//!   * No `chat.update`. Every assistant message becomes its own
//!     `chat.postMessage` at `message_end{role=.assistant}`.
//!   * No timer thread, no mutex, no throttling. `onEvent` runs on
//!     the agent's worker thread (single-threaded by construction)
//!     and calls Slack synchronously inside the event handler.
//!
//! Per-message lifecycle:
//!
//!   1. `message_start{role=.assistant}` → reset `accumulated`.
//!   2. `message_update.text` → append delta to `accumulated`.
//!   3. `message_end{role=.assistant}`:
//!        - capture `diagnostics.trace_id` (last-write-wins).
//!        - if `accumulated.len > 0`: post via `chat.postMessage`
//!          (or `files.uploadV2` when `> overflow_threshold_bytes`).
//!        - reset `accumulated`.
//!   4. `agent_error`:
//!        - flush whatever partial text is in `accumulated` first
//!          (so the user sees what got through), then post the
//!          composed error envelope as a separate bubble.
//!
//! Each successful `chat.postMessage` records its `ts` into
//! `posted_ts`. The bot drains this list after `agent.waitForIdle`
//! to register reply anchors so reactions on bot-posted bubbles
//! still resolve back to the thread (§Phase 7 reactions-as-control).

const std = @import("std");
const franky = @import("franky");
const at = franky.agent.types;
const ai = franky.ai;
const web_api = @import("../slack/api.zig");

pub const Config = struct {
    /// Threshold above which a single message is posted as a file
    /// attachment instead of inline `chat.postMessage`. Slack's
    /// hard `text` limit is ~40k chars; the 3500-byte default is
    /// the conservative "always renders cleanly as plain text"
    /// bound carried over from v0.3.8.
    overflow_threshold_bytes: usize = 3500,
};

pub const StreamSubscriber = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api: *web_api.Client,
    channel: []const u8,
    /// `thread_ts` of the originating thread. Posts land here
    /// (and the file fallback also uses it). Borrowed; caller
    /// owns. Empty string means "not in a thread" — the post is
    /// a top-level channel message and the file fallback degrades
    /// to inline truncation.
    thread_ts: []const u8,
    cfg: Config,

    /// Per-message text accumulator. Cleared on every assistant
    /// `message_start` AND after every successful flush. Single-
    /// threaded: only `onEvent` (agent worker thread) touches it.
    accumulated: std.ArrayList(u8) = .empty,

    /// v0.4.2 — error capture. The composed reply is posted
    /// either inside the `.agent_error` arm directly, or by the
    /// caller via `flushErrorReply()` if no further events arrive.
    last_error_code: ?ai.errors.Code = null,
    last_error_message: ?[]u8 = null,

    /// Counts successful `chat.postMessage` calls. Tests inspect.
    post_count: std.atomic.Value(u32) = .init(0),

    /// `ts` of every successfully-posted bubble, in order. Owned
    /// by the subscriber; drained by the bot after
    /// `agent.waitForIdle` to register reply anchors.
    posted_ts: std.ArrayList([]u8) = .empty,

    /// v0.5.2 — token + turn aggregates for the end-of-run usage
    /// summary. `total_input` / `total_output` accumulate from
    /// `Message.usage` on every `message_end{role=.assistant}` (the
    /// provider parser populates `usage` for the assistant turn;
    /// tool_result rows are synthesized locally and don't carry
    /// llm-side counts). `turn_count` increments on every
    /// `turn_start` so it tracks model round-trips, not bubbles.
    /// The bot calls `flushUsageSummary()` after `waitForIdle` to
    /// post a single trailing bubble of the form
    /// `_in: N · out: M · turns: K_`.
    total_input: u64 = 0,
    total_output: u64 = 0,
    turn_count: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        api: *web_api.Client,
        channel: []const u8,
        thread_ts: []const u8,
        cfg: Config,
    ) StreamSubscriber {
        return .{
            .allocator = allocator,
            .io = io,
            .api = api,
            .channel = channel,
            .thread_ts = thread_ts,
            .cfg = cfg,
        };
    }

    pub fn deinit(self: *StreamSubscriber) void {
        self.accumulated.deinit(self.allocator);
        if (self.last_error_message) |s| self.allocator.free(s);
        for (self.posted_ts.items) |ts| self.allocator.free(ts);
        self.posted_ts.deinit(self.allocator);
    }

    /// Subscriber callback signature for `franky.agent.Agent.subscribe`.
    pub fn onEvent(ud: ?*anyopaque, ev: at.AgentEvent) void {
        const self: *StreamSubscriber = @ptrCast(@alignCast(ud.?));
        ai.log.log(.trace, "franky-do", "stream_event", "kind={s}", .{@tagName(ev)});
        switch (ev) {
            .message_start => |s| {
                if (s.role != .assistant) return;
                ai.log.log(.debug, "franky-do", "stream_event", "message_start role=assistant — resetting accumulator", .{});
                self.accumulated.clearRetainingCapacity();
            },
            .message_update => |u| switch (u) {
                .text => |t| {
                    ai.log.log(.trace, "franky-do", "stream_event", "text_delta block={d} bytes={d}", .{ t.block_index, t.delta.len });
                    self.accumulated.appendSlice(self.allocator, t.delta) catch {};
                },
                .thinking => |t| ai.log.log(.trace, "franky-do", "stream_event", "thinking_delta block={d} bytes={d}", .{ t.block_index, t.delta.len }),
                .toolcall_args => |t| ai.log.log(.trace, "franky-do", "stream_event", "toolcall_args block={d} bytes={d}", .{ t.block_index, t.delta.len }),
            },
            .tool_execution_start => |s| ai.log.log(.info, "franky-do", "stream_event", "tool_execution_start name={s} call_id={s}", .{ s.name, s.call_id }),
            .tool_execution_end => |e| ai.log.log(.info, "franky-do", "stream_event", "tool_execution_end call_id={s} is_error={}", .{ e.call_id, e.result.is_error }),
            .message_end => |m| {
                if (m.role != .assistant) return;
                if (m.usage) |u| {
                    self.total_input += u.input;
                    self.total_output += u.output;
                }
                self.flushAssistantMessage();
            },
            .agent_error => |e| {
                ai.log.log(.warn, "franky-do", "stream_event", "agent_error code={s} message={s}", .{ @tagName(e.code), e.message });
                // Flush partial text as its own bubble so the user
                // sees what got through. Then post the composed
                // error envelope as a separate bubble.
                self.flushAssistantMessage();
                self.last_error_code = e.code;
                if (self.last_error_message) |old| self.allocator.free(old);
                self.last_error_message = self.allocator.dupe(u8, e.message) catch null;
                self.flushErrorReply();
            },
            .turn_start => {
                self.turn_count += 1;
                ai.log.log(.debug, "franky-do", "stream_event", "turn_start count={d}", .{self.turn_count});
            },
            .turn_end => ai.log.log(.debug, "franky-do", "stream_event", "turn_end", .{}),
            else => {},
        }
    }

    /// Post `accumulated` as a fresh Slack message. No-op when
    /// the buffer is empty (tool-only assistant turns produce no
    /// user-visible text). Clears the buffer on success AND on
    /// failure — a failed post is logged and dropped, the run
    /// continues, and the next assistant message starts fresh.
    fn flushAssistantMessage(self: *StreamSubscriber) void {
        if (self.accumulated.items.len == 0) return;
        defer self.accumulated.clearRetainingCapacity();
        const text = self.accumulated.items;
        if (text.len > self.cfg.overflow_threshold_bytes and self.thread_ts.len > 0) {
            self.postAsFile(text);
        } else {
            self.postInline(text);
        }
    }

    /// Compose `errorReplyText` from the captured fields and post
    /// it as a fresh bubble. Best-effort: a failed post leaves the
    /// terminal ❌ reaction (set by the bot's `markFinal`) as the
    /// only failure indicator.
    fn flushErrorReply(self: *StreamSubscriber) void {
        const code = self.last_error_code orelse return;
        const composed = errorReplyText(
            self.allocator,
            code,
            self.last_error_message,
        ) catch return;
        defer self.allocator.free(composed);
        self.postInline(composed);
    }

    /// v0.5.2 — post one final bubble summarizing token usage and
    /// turn count for the run. Called by the bot after
    /// `agent.waitForIdle` (and intentionally also after the
    /// terminal `agent_error` path so failed runs still get a
    /// summary). No-op when nothing happened (`turn_count == 0`)
    /// — that case means the agent never started, e.g. a setup
    /// error before `agent.prompt`. Best-effort: a failed post is
    /// logged and dropped.
    pub fn flushUsageSummary(self: *StreamSubscriber) void {
        if (self.turn_count == 0) return;
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buf,
            "Token in: {d} · Token out: {d} · Turns: {d}_",
            .{ self.total_input, self.total_output, self.turn_count },
        ) catch return;
        self.postInline(text);
    }

    fn postInline(self: *StreamSubscriber, text: []const u8) void {
        ai.log.log(.debug, "franky-do", "slack", "chat.postMessage send channel={s} thread_ts={s} bytes={d}", .{
            self.channel, self.thread_ts, text.len,
        });
        var resp = self.api.chatPostMessage(.{
            .channel = self.channel,
            .text = text,
            .thread_ts = if (self.thread_ts.len > 0) self.thread_ts else null,
        }) catch |e| {
            const slack_err = self.api.last_slack_error orelse "(none)";
            ai.log.log(.warn, "franky-do", "slack", "chat.postMessage failed: {s} slack_error={s} bytes={d}", .{
                @errorName(e), slack_err, text.len,
            });
            return;
        };
        defer resp.deinit();
        _ = self.post_count.fetchAdd(1, .monotonic);
        if (resp.value.ts) |ts| self.recordPostedTs(ts);
        ai.log.log(.debug, "franky-do", "slack", "chat.postMessage ok ts={s}", .{resp.value.ts orelse "(none)"});
    }

    /// Long-reply path: upload the full content as a file in the
    /// thread. On success the file lands as a bubble in the
    /// thread (its post_message_ts is recorded by Slack but not
    /// returned by `files.completeUploadExternal`, so the bot's
    /// reply-anchor cache won't get an entry for this one — users
    /// can still react on the `@`-mention to abort/retry).
    /// On failure, fall back to a truncated inline post with a
    /// scope-hint footer (the typical cause is `not_in_channel`
    /// or `missing_scope`).
    fn postAsFile(self: *StreamSubscriber, content: []const u8) void {
        ai.log.log(.info, "franky-do", "slack", "reply size {d}B exceeds threshold {d}B → file attachment", .{
            content.len, self.cfg.overflow_threshold_bytes,
        });
        self.api.uploadTextToThread(.{
            .channel_id = self.channel,
            .thread_ts = self.thread_ts,
            .filename = "reply.txt",
            .title = "Full reply",
            .content = content,
            .initial_comment = null,
        }) catch |e| {
            const slack_err = self.api.last_slack_error orelse "(none)";
            const slack_detail = self.api.last_slack_error_detail orelse "(no response_metadata.messages)";
            ai.log.log(.warn, "franky-do", "slack", "files.uploadV2 failed: {s} slack_error={s} detail={s} bytes={d}", .{
                @errorName(e), slack_err, slack_detail, content.len,
            });
            self.fallbackToTruncatedInline(content, slack_err, slack_detail);
            return;
        };
        ai.log.log(.info, "franky-do", "slack", "files.uploadV2 ok bytes={d}", .{content.len});
    }

    /// When `files.uploadV2` fails, post the first ~3000 bytes of
    /// content inline with a footer pointing at the most likely
    /// fix (missing `files:write` scope or bot-not-in-channel,
    /// both of which Slack reports as the deceptively-generic
    /// `invalid_arguments`). Best-effort.
    fn fallbackToTruncatedInline(
        self: *StreamSubscriber,
        content: []const u8,
        slack_err: []const u8,
        slack_detail: []const u8,
    ) void {
        const inline_cap: usize = 3000;
        const head = if (content.len > inline_cap) content[0..inline_cap] else content;
        const truncated = content.len > inline_cap;

        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(self.allocator);
        msg.appendSlice(self.allocator, head) catch return;

        const has_detail = slack_detail.len > 0 and !std.mem.eql(u8, slack_detail, "(no response_metadata.messages)");
        const tail = if (truncated)
            (if (has_detail) std.fmt.allocPrint(
                self.allocator,
                "\n\n_…truncated ({d}B more). File attachment failed: `{s}` — {s}. Check `files:write` scope and `/invite @franky-do` in this channel._",
                .{ content.len - inline_cap, slack_err, slack_detail },
            ) else std.fmt.allocPrint(
                self.allocator,
                "\n\n_…truncated ({d}B more). File attachment failed: `{s}` — check `files:write` scope and `/invite @franky-do` in this channel._",
                .{ content.len - inline_cap, slack_err },
            )) catch return
        else
            (if (has_detail) std.fmt.allocPrint(
                self.allocator,
                "\n\n_(file attachment failed: `{s}` — {s}. Check `files:write` scope and channel membership.)_",
                .{ slack_err, slack_detail },
            ) else std.fmt.allocPrint(
                self.allocator,
                "\n\n_(file attachment failed: `{s}` — check `files:write` scope and channel membership.)_",
                .{slack_err},
            )) catch return;
        defer self.allocator.free(tail);
        msg.appendSlice(self.allocator, tail) catch return;
        self.postInline(msg.items);
    }

    fn recordPostedTs(self: *StreamSubscriber, ts: []const u8) void {
        if (self.allocator.dupe(u8, ts)) |dup| {
            self.posted_ts.append(self.allocator, dup) catch self.allocator.free(dup);
        } else |_| {}
    }
};

/// Compose a Slack-friendly reply for a failed run. Caller owns
/// the returned slice. Special-cases `empty_response` (Gemini
/// thinking-budget exhaustion) because its remediation is
/// qualitatively different (lower thinking budget / switch profile,
/// NOT a generic retry); other codes share a single envelope so we
/// don't have to hand-render every error code in
/// `franky.ai.errors.Code`.
fn errorReplyText(
    allocator: std.mem.Allocator,
    code: ai.errors.Code,
    message: ?[]const u8,
) ![]u8 {
    const head: []const u8 = switch (code) {
        .empty_response =>
        \\:warning: *Provider returned no output* (likely thinking-budget exhaustion).
        \\Try a different profile (`/franky-do model …`), lower thinking budget, or retry once.
        ,
        .aborted => ":no_entry: *Run aborted.* Use the abort reaction or `/franky-do abort` to confirm.",
        else => "",
    };

    if (head.len > 0) return allocator.dupe(u8, head);
    return try std.fmt.allocPrint(
        allocator,
        ":warning: *Provider returned an error*: `{s}` — {s}",
        .{ @tagName(code), message orelse "(no message)" },
    );
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

/// Loopback Slack server. Counts `chat.postMessage` calls, captures
/// the body of every request (last-write-wins), and replies with a
/// monotonically-incrementing `ts` (`POSTED-1`, `POSTED-2`, …) so
/// tests can assert on the order in which bubbles got posted.
const TallyServer = struct {
    server: std.Io.net.Server,
    port: u16,
    /// Total request count (any method).
    count: std.atomic.Value(u32) = .init(0),
    /// `chat.postMessage` count.
    post_count: std.atomic.Value(u32) = .init(0),
    /// Bodies of every chat.postMessage call, in order. Owned by
    /// allocator; deinit frees the entries + ArrayList.
    post_bodies: std.ArrayList([]u8) = .empty,
    last_body: ?[]u8 = null,
    last_body_mutex: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    io: std.Io,
    stop: std.atomic.Value(bool) = .init(false),
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

        const is_post_message = std.mem.indexOf(u8, head, "/chat.postMessage") != null;

        {
            s.last_body_mutex.lockUncancelable(s.io);
            defer s.last_body_mutex.unlock(s.io);
            if (s.last_body) |b| s.allocator.free(b);
            s.last_body = s.allocator.dupe(u8, body_slice) catch null;
            if (is_post_message) {
                if (s.allocator.dupe(u8, body_slice)) |dup| {
                    s.post_bodies.append(s.allocator, dup) catch s.allocator.free(dup);
                } else |_| {}
            }
        }

        if (is_post_message) {
            const seq = s.post_count.fetchAdd(1, .monotonic) + 1;
            var rbuf: [256]u8 = undefined;
            const body = std.fmt.bufPrint(&rbuf, "{{\"ok\":true,\"ts\":\"POSTED-{d}\",\"channel\":\"C1\"}}", .{seq}) catch "{\"ok\":true}";
            var hdr_buf: [128]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch "";
            var wbuf: [512]u8 = undefined;
            var w = stream_conn.writer(s.io, &wbuf);
            w.interface.writeAll(hdr) catch {};
            w.interface.writeAll(body) catch {};
            w.interface.flush() catch {};
        } else {
            const reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}";
            var wbuf: [256]u8 = undefined;
            var w = stream_conn.writer(s.io, &wbuf);
            w.interface.writeAll(reply) catch {};
            w.interface.flush() catch {};
        }

        _ = s.count.fetchAdd(1, .monotonic);
    }
}

fn bindTallyServer(allocator: std.mem.Allocator, io: std.Io) ?TallyServer {
    var p: u16 = 19500;
    while (p < 19599) : (p += 1) {
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
    for (s.post_bodies.items) |b| s.allocator.free(b);
    s.post_bodies.deinit(s.allocator);
    s.server.deinit(s.io);
}

fn wakeServer(io: std.Io, port: u16) void {
    var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    if (std.Io.net.IpAddress.connect(&addr, io, .{ .mode = .stream }) catch null) |strm| {
        var sm = strm;
        sm.close(io);
    }
}

test "errorReplyText: empty_response gets the targeted thinking-budget phrasing" {
    const gpa = testing.allocator;
    const text = try errorReplyText(gpa, .empty_response, "google-gemini returned stop_reason=stop but emitted no content");
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "no output") != null);
    try testing.expect(std.mem.indexOf(u8, text, "thinking-budget") != null);
    try testing.expect(std.mem.indexOf(u8, text, "profile") != null);
}

test "errorReplyText: generic code surfaces tag + message" {
    const gpa = testing.allocator;
    const text = try errorReplyText(gpa, .auth, "missing OAuth token");
    defer gpa.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "`auth`") != null);
    try testing.expect(std.mem.indexOf(u8, text, "missing OAuth token") != null);
}

test "StreamSubscriber: posts one chat.postMessage per assistant message_end" {
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
    defer {
        s.stop.store(true, .release);
        wakeServer(io, s.port);
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = StreamSubscriber.init(gpa, io, &api, "C1", "9999.0001", .{});
    defer sub.deinit();

    // Message 1.
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_start = .{ .role = .assistant } });
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "Looking at the file. ",
    } } });
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "Calling read.",
    } } });
    const msg1: ai.types.Message = .{ .role = .assistant, .content = &.{}, .timestamp = 0 };
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_end = msg1 });

    // Tool result message — must NOT trigger a post.
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_start = .{ .role = .tool_result } });
    const tool_msg: ai.types.Message = .{ .role = .tool_result, .content = &.{}, .timestamp = 0 };
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_end = tool_msg });

    // Message 2.
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_start = .{ .role = .assistant } });
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "Got it. The file contains foo.",
    } } });
    const msg2: ai.types.Message = .{ .role = .assistant, .content = &.{}, .timestamp = 0 };
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_end = msg2 });

    // Exactly two posts (one per assistant message_end).
    try testing.expectEqual(@as(u32, 2), sub.post_count.load(.monotonic));
    try testing.expectEqual(@as(u32, 2), s.post_count.load(.monotonic));
    try testing.expectEqual(@as(usize, 2), sub.posted_ts.items.len);
    try testing.expectEqualStrings("POSTED-1", sub.posted_ts.items[0]);
    try testing.expectEqualStrings("POSTED-2", sub.posted_ts.items[1]);

    // Bodies carry each message's full text + the thread_ts.
    try testing.expect(s.post_bodies.items.len == 2);
    try testing.expect(std.mem.indexOf(u8, s.post_bodies.items[0], "Looking at the file") != null);
    try testing.expect(std.mem.indexOf(u8, s.post_bodies.items[0], "Calling read") != null);
    try testing.expect(std.mem.indexOf(u8, s.post_bodies.items[0], "thread_ts") != null);
    try testing.expect(std.mem.indexOf(u8, s.post_bodies.items[1], "Got it. The file contains foo") != null);
    // Message 2 must NOT contain message 1's text — each assistant
    // message gets its own bubble.
    try testing.expect(std.mem.indexOf(u8, s.post_bodies.items[1], "Calling read") == null);
}

test "StreamSubscriber: tool-only assistant message (no text) does NOT post" {
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
    defer {
        s.stop.store(true, .release);
        wakeServer(io, s.port);
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = StreamSubscriber.init(gpa, io, &api, "C1", "9999.0001", .{});
    defer sub.deinit();

    // Assistant message with NO text deltas — the model only
    // produced a tool call.
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_start = .{ .role = .assistant } });
    const msg: ai.types.Message = .{ .role = .assistant, .content = &.{}, .timestamp = 0 };
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_end = msg });

    try testing.expectEqual(@as(u32, 0), sub.post_count.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), sub.posted_ts.items.len);
}

test "StreamSubscriber: agent_error posts a composed error reply" {
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
    defer {
        s.stop.store(true, .release);
        wakeServer(io, s.port);
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = StreamSubscriber.init(gpa, io, &api, "C1", "9999.0001", .{});
    defer sub.deinit();

    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .agent_error = .{
        .code = .empty_response,
        .message = "google-gemini returned stop_reason=stop but emitted no content",
    } });

    // One post — the composed error envelope.
    try testing.expectEqual(@as(u32, 1), sub.post_count.load(.monotonic));
    try testing.expect(s.post_bodies.items.len == 1);
    try testing.expect(std.mem.indexOf(u8, s.post_bodies.items[0], "no output") != null);
    try testing.expect(std.mem.indexOf(u8, s.post_bodies.items[0], "thinking-budget") != null);
}

test "StreamSubscriber: partial text + agent_error → two posts (text then error)" {
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
    defer {
        s.stop.store(true, .release);
        wakeServer(io, s.port);
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = StreamSubscriber.init(gpa, io, &api, "C1", "9999.0001", .{});
    defer sub.deinit();

    // Partial text streams in but message_end never fires before
    // the error (provider died mid-stream). The subscriber must
    // post the partial text first AND then the error envelope.
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_start = .{ .role = .assistant } });
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "Partial answer cut sho",
    } } });
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .agent_error = .{
        .code = .transport,
        .message = "connection reset by peer",
    } });

    try testing.expectEqual(@as(u32, 2), sub.post_count.load(.monotonic));
    try testing.expect(s.post_bodies.items.len == 2);
    try testing.expect(std.mem.indexOf(u8, s.post_bodies.items[0], "Partial answer cut sho") != null);
    try testing.expect(std.mem.indexOf(u8, s.post_bodies.items[1], "transport") != null);
}

test "StreamSubscriber: flushUsageSummary posts in/out/turns totals after a multi-turn run" {
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
    defer {
        s.stop.store(true, .release);
        wakeServer(io, s.port);
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = StreamSubscriber.init(gpa, io, &api, "C1", "9999.0001", .{});
    defer sub.deinit();

    // Turn 1: assistant text + usage.
    StreamSubscriber.onEvent(@ptrCast(&sub), .turn_start);
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_start = .{ .role = .assistant } });
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "first turn",
    } } });
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_end = .{
        .role = .assistant,
        .content = &.{},
        .timestamp = 0,
        .usage = .{ .input = 1200, .output = 340 },
    } });

    // Turn 2: more usage.
    StreamSubscriber.onEvent(@ptrCast(&sub), .turn_start);
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_start = .{ .role = .assistant } });
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_update = .{ .text = .{
        .block_index = 0,
        .delta = "second turn",
    } } });
    StreamSubscriber.onEvent(@ptrCast(&sub), .{ .message_end = .{
        .role = .assistant,
        .content = &.{},
        .timestamp = 0,
        .usage = .{ .input = 800, .output = 250 },
    } });

    try testing.expectEqual(@as(u64, 2000), sub.total_input);
    try testing.expectEqual(@as(u64, 590), sub.total_output);
    try testing.expectEqual(@as(u32, 2), sub.turn_count);

    // Now post the summary.
    sub.flushUsageSummary();

    // Three posts total: 2 turn bubbles + 1 summary bubble.
    try testing.expectEqual(@as(u32, 3), sub.post_count.load(.monotonic));
    try testing.expect(s.post_bodies.items.len == 3);

    const summary = s.post_bodies.items[2];
    try testing.expect(std.mem.indexOf(u8, summary, "Token in: 2000") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "Token out: 590") != null);
    try testing.expect(std.mem.indexOf(u8, summary, "Turns: 2") != null);
    // Cache and cost are deliberately NOT in the summary.
    try testing.expect(std.mem.indexOf(u8, summary, "cache") == null);
    try testing.expect(std.mem.indexOf(u8, summary, "$") == null);
}

test "StreamSubscriber: flushUsageSummary is a no-op when no turn ran" {
    // e.g. a setup error before agent.prompt — no `turn_start`,
    // nothing to summarize, nothing to post.
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
    defer {
        s.stop.store(true, .release);
        wakeServer(io, s.port);
        server_thread.join();
    }

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.base_url = base;

    var sub = StreamSubscriber.init(gpa, io, &api, "C1", "9999.0001", .{});
    defer sub.deinit();

    sub.flushUsageSummary();

    try testing.expectEqual(@as(u32, 0), sub.post_count.load(.monotonic));
}
