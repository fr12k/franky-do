//! Slack Socket Mode (§3 of franky-do.md).
//!
//! Sequence:
//!   1. Call `web_api.appsConnectionsOpen()` to get a WSS URL.
//!   2. Parse the URL into (host, port, path).
//!   3. Open a `websocket.Client` with TLS, complete the handshake.
//!   4. Run `client.readLoopInNewThread(handler)` — the lib drives a
//!      background read loop that calls our `Handler.serverMessage`.
//!   5. For each `envelope_id`-bearing event, ACK synchronously via
//!      `client.write(ack_json)`.
//!   6. On disconnect / error, the read loop's `close` callback
//!      fires; the bot reconnects with backoff.
//!
//! Phase 2 scope: connect, parse + log every inbound event, ACK
//! correctly. Wiring events to the agent loop is Phase 3.

const std = @import("std");
const ws = @import("websocket");
const web_api = @import("api.zig");

/// Concrete handler type — `Handler` parameterized over `ws.Client`.
/// The websocket library calls our `serverMessage` and `close`
/// methods on the read thread.
pub const ConcreteHandler = Handler(ws.Client);

pub const SocketModeError = error{
    BadWssUrl,
    /// `apps.connections.open` returned `ok=false` or had no URL.
    HandshakeFailed,
    /// websocket.zig handshake or connect failure.
    WsConnectFailed,
} || std.mem.Allocator.Error;

// ─── URL parser ─────────────────────────────────────────────────────

pub const ParsedWssUrl = struct {
    host: []const u8,
    port: u16,
    /// Includes the leading "/" and any query string.
    path: []const u8,
};

/// Parse a `wss://host[:port]/path?query` URL into its components.
/// Returned slices reference the input — caller owns the input
/// memory, parsed slices live as long as the input does.
pub fn parseWssUrl(url: []const u8) SocketModeError!ParsedWssUrl {
    const scheme = "wss://";
    if (!std.mem.startsWith(u8, url, scheme)) return SocketModeError.BadWssUrl;
    const rest = url[scheme.len..];

    // host[:port] is the prefix up to the first '/' (or end).
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..path_start];
    if (authority.len == 0) return SocketModeError.BadWssUrl;

    var host: []const u8 = authority;
    var port: u16 = 443; // wss default
    if (std.mem.indexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch
            return SocketModeError.BadWssUrl;
    }
    if (host.len == 0) return SocketModeError.BadWssUrl;

    // Path defaults to "/" when the URL has no path component.
    const path = if (path_start < rest.len) rest[path_start..] else "/";

    return .{ .host = host, .port = port, .path = path };
}

// ─── ACK message builder ────────────────────────────────────────────

/// Build the ACK envelope Slack expects in response to every
/// inbound event. Returned buffer is allocator-owned. Caller
/// must call `client.write()` (which takes []u8 — note: not
/// []const — because the lib masks in-place).
pub fn buildAckMessage(
    allocator: std.mem.Allocator,
    envelope_id: []const u8,
) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"envelope_id\":\"");
    try buf.appendSlice(allocator, envelope_id);
    try buf.appendSlice(allocator, "\"}");
    return try buf.toOwnedSlice(allocator);
}

// ─── Event types ────────────────────────────────────────────────────

pub const EventType = enum {
    hello,
    events_api,
    slash_commands,
    interactive,
    disconnect,
    unknown,
};

/// Lightweight pre-parse of the inbound JSON. We extract just the
/// fields we route on: `type` (event class) and `envelope_id`
/// (when present). The full payload is left as a JSON slice for
/// the per-type handler to parse separately. This keeps Socket
/// Mode's hot path independent of any one event's schema.
pub const InboundEvent = struct {
    type: EventType,
    /// Borrowed slice into the inbound buffer. Empty if the event
    /// has no envelope (e.g. `hello`, `disconnect`).
    envelope_id: []const u8,
    /// Full inbound JSON. Borrowed slice into the inbound buffer.
    raw_json: []const u8,
};

pub fn parseInboundEvent(allocator: std.mem.Allocator, json: []const u8) InboundEvent {
    // We only need the outer envelope's `type` and `envelope_id`.
    // Slack's payloads contain nested `type` fields (the `event`
    // object's own type, the `event_callback` wrapper, etc.) that
    // appear *before* the outer `type:"events_api"` in the JSON,
    // so a `std.mem.indexOf` first-match is wrong. Parse the
    // top-level object properly with `ignore_unknown_fields` so
    // the nested payload is skipped without a schema.
    const Outer = struct {
        type: ?[]const u8 = null,
        envelope_id: ?[]const u8 = null,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(
        Outer,
        arena.allocator(),
        json,
        .{ .ignore_unknown_fields = true },
    ) catch return .{ .type = .unknown, .envelope_id = "", .raw_json = json };

    const type_str = parsed.type orelse "";
    const tag: EventType = if (std.mem.eql(u8, type_str, "hello")) .hello
    else if (std.mem.eql(u8, type_str, "events_api")) .events_api
    else if (std.mem.eql(u8, type_str, "slash_commands")) .slash_commands
    else if (std.mem.eql(u8, type_str, "interactive")) .interactive
    else if (std.mem.eql(u8, type_str, "disconnect")) .disconnect
    else .unknown;

    // envelope_id (if any) needs to outlive the arena. The raw
    // JSON buffer outlives the call (caller owns it), so we hand
    // back a slice into `json` — find the value verbatim there.
    const env: []const u8 = if (parsed.envelope_id) |_|
        findTopLevelEnvelopeId(json) orelse ""
    else
        "";

    return .{ .type = tag, .envelope_id = env, .raw_json = json };
}

/// Locate the top-level `"envelope_id":"<value>"` substring inside
/// a Socket Mode envelope and return a slice into the original
/// buffer. Slack's envelopes always put `envelope_id` first; even
/// if they didn't, no nested object uses that exact field name,
/// so a substring search is safe for this one field.
fn findTopLevelEnvelopeId(json: []const u8) ?[]const u8 {
    const key = "\"envelope_id\":\"";
    const start = std.mem.indexOf(u8, json, key) orelse return null;
    const value_start = start + key.len;
    if (value_start >= json.len) return null;
    const value_end = std.mem.indexOfScalarPos(u8, json, value_start, '"') orelse return null;
    return json[value_start..value_end];
}

// ─── Socket Mode driver ─────────────────────────────────────────────

/// One Socket Mode session. Owns the underlying ws.Client and a
/// reference to the Web API client for ACKing / reconnecting.
///
/// **Threading**: `start` spawns the lib's background read loop on
/// its own thread; `Handler.serverMessage` runs on that thread.
/// Mutations to `SocketMode` fields from `serverMessage` use the
/// `mutex` for serialization. Inbound events are handed off to
/// the bot's work queue (Phase 3+) so the read thread doesn't
/// block on agent work.
pub const SocketMode = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    api: *web_api.Client,
    /// Optional callback invoked synchronously on the read thread
    /// for every inbound event AFTER the ACK has been sent. Phase
    /// 3 will set this to enqueue events on the bot's work queue.
    on_event: ?*const fn (userdata: ?*anyopaque, event: InboundEvent) void = null,
    on_event_userdata: ?*anyopaque = null,
    /// Most recent WSS URL — populated on connect, used on reconnect.
    wss_url: ?[]u8 = null,
    /// Whether `start` has been called and the read loop is up.
    /// Tests inspect this; production toggles via `start`/`close`.
    is_running: std.atomic.Value(bool) = .init(false),
    /// Set by `Handler.close` when the underlying WSS drops.
    /// The reconnect loop in `main.zig` reads this to distinguish
    /// a dropped connection from a graceful stop.
    disconnected: std.atomic.Value(bool) = .init(false),
    /// When true, the reconnect loop should NOT reconnect — the
    /// process is shutting down (SIGINT/SIGTERM). Set by the
    /// signal handler in `main.zig`.
    graceful_stop: std.atomic.Value(bool) = .init(false),
    /// Heap-allocated ws client. Lives across the connect/run/close
    /// lifecycle. `connect` creates it; `close` deinits + frees.
    client: ?*ws.Client = null,
    /// Heap-allocated handler that holds back-references to `self`
    /// + `client`. Initialized inside `run`.
    handler: ?*ConcreteHandler = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, api: *web_api.Client) SocketMode {
        return .{ .allocator = allocator, .io = io, .api = api };
    }

    pub fn deinit(self: *SocketMode) void {
        self.close();
        if (self.wss_url) |u| self.allocator.free(u);
        self.wss_url = null;
    }

    /// Refresh `wss_url` by calling `apps.connections.open`. Used
    /// both at first connect and on reconnect.
    pub fn refreshWssUrl(self: *SocketMode) SocketModeError!void {
        var resp = self.api.appsConnectionsOpen() catch return SocketModeError.HandshakeFailed;
        defer resp.deinit();
        const url = resp.value.url orelse return SocketModeError.HandshakeFailed;
        if (self.wss_url) |u| self.allocator.free(u);
        self.wss_url = try self.allocator.dupe(u8, url);
    }

    /// Open the WSS connection: parse URL → init ws.Client →
    /// handshake. Caller must subsequently call `run` (which blocks
    /// on the read loop) and then `close`.
    pub fn connect(self: *SocketMode) !void {
        if (self.wss_url == null) try self.refreshWssUrl();
        const parsed = try parseWssUrl(self.wss_url.?);

        const client_ptr = try self.allocator.create(ws.Client);
        errdefer self.allocator.destroy(client_ptr);

        client_ptr.* = ws.Client.init(self.io, self.allocator, .{
            .port = parsed.port,
            .host = parsed.host,
            .tls = true,
        }) catch return SocketModeError.WsConnectFailed;
        errdefer client_ptr.deinit();

        const host_header = try std.fmt.allocPrint(
            self.allocator,
            "host: {s}\r\n",
            .{parsed.host},
        );
        defer self.allocator.free(host_header);
        client_ptr.handshake(parsed.path, .{
            .timeout_ms = 10_000,
            .headers = host_header,
        }) catch return SocketModeError.WsConnectFailed;

        self.client = client_ptr;
    }

    /// Block on the WSS read loop. Returns when the connection
    /// drops (clean disconnect or error). Caller is then responsible
    /// for `close()` and (if desired) reconnecting.
    pub fn run(self: *SocketMode) !void {
        if (self.client == null) return SocketModeError.WsConnectFailed;

        const handler_ptr = try self.allocator.create(ConcreteHandler);
        errdefer self.allocator.destroy(handler_ptr);
        handler_ptr.* = .{
            .sm = self,
            .client = self.client.?,
        };
        self.handler = handler_ptr;

        self.is_running.store(true, .release);
        self.client.?.readLoop(handler_ptr) catch {};
        self.is_running.store(false, .release);
    }

    /// Tear down the ws.Client + handler. Idempotent.
    pub fn close(self: *SocketMode) void {
        if (self.client) |c| {
            c.close(.{}) catch {};
            c.deinit();
            self.allocator.destroy(c);
            self.client = null;
        }
        if (self.handler) |h| {
            self.allocator.destroy(h);
            self.handler = null;
        }
    }
};

// ─── Handler ────────────────────────────────────────────────────────

/// websocket.zig's `readLoopInNewThread` requires a struct with a
/// `serverMessage` method. We keep this as a separate type from
/// `SocketMode` so the lifecycle is independent — the handler
/// owns the `*ws.Client` (so it can write ACKs back) and a back
/// reference to the SocketMode for `on_event` dispatch.
pub fn Handler(comptime ClientT: type) type {
    return struct {
        const Self = @This();
        sm: *SocketMode,
        client: *ClientT,
        /// Set to true on `close` callback (lib calls it exactly
        /// once per read-loop lifecycle). Tests poll this to
        /// confirm a clean shutdown happened.
        closed: std.atomic.Value(bool) = .init(false),

        pub fn serverMessage(self: *Self, data: []u8) !void {
            const event = parseInboundEvent(self.sm.allocator, data);
            // ACK synchronously if there's an envelope. Slack gives
            // us 3 seconds; this is well inside that.
            if (event.envelope_id.len > 0) {
                const ack = try buildAckMessage(self.sm.allocator, event.envelope_id);
                defer self.sm.allocator.free(ack);
                // ws.Client.write expects []u8 (it masks in-place);
                // the buffer we just allocated is mutable so this
                // is fine.
                try self.client.write(ack);
            }
            if (self.sm.on_event) |cb| cb(self.sm.on_event_userdata, event);
        }

        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
            self.sm.is_running.store(false, .release);
            self.sm.disconnected.store(true, .release);
        }
    };
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "parseWssUrl: standard Slack format" {
    const u = try parseWssUrl("wss://wss-primary.slack.com/link/?ticket=abc&app_id=A1");
    try testing.expectEqualStrings("wss-primary.slack.com", u.host);
    try testing.expectEqual(@as(u16, 443), u.port);
    try testing.expectEqualStrings("/link/?ticket=abc&app_id=A1", u.path);
}

test "parseWssUrl: explicit port" {
    const u = try parseWssUrl("wss://wss.example.com:9443/socket");
    try testing.expectEqualStrings("wss.example.com", u.host);
    try testing.expectEqual(@as(u16, 9443), u.port);
    try testing.expectEqualStrings("/socket", u.path);
}

test "parseWssUrl: no path → defaults to /" {
    const u = try parseWssUrl("wss://example.com");
    try testing.expectEqualStrings("example.com", u.host);
    try testing.expectEqual(@as(u16, 443), u.port);
    try testing.expectEqualStrings("/", u.path);
}

test "parseWssUrl: rejects ws://" {
    try testing.expectError(SocketModeError.BadWssUrl, parseWssUrl("ws://example.com"));
}

test "parseWssUrl: rejects http://" {
    try testing.expectError(SocketModeError.BadWssUrl, parseWssUrl("http://example.com"));
}

test "parseWssUrl: rejects empty host" {
    try testing.expectError(SocketModeError.BadWssUrl, parseWssUrl("wss:///path"));
}

test "parseWssUrl: rejects malformed port" {
    try testing.expectError(SocketModeError.BadWssUrl, parseWssUrl("wss://host:abc/"));
}

test "buildAckMessage: simple envelope" {
    const ack = try buildAckMessage(testing.allocator, "abc-123");
    defer testing.allocator.free(ack);
    try testing.expectEqualStrings("{\"envelope_id\":\"abc-123\"}", ack);
}

test "parseInboundEvent: hello" {
    const e = parseInboundEvent(testing.allocator, "{\"type\":\"hello\",\"num_connections\":1}");
    try testing.expectEqual(EventType.hello, e.type);
    try testing.expectEqualStrings("", e.envelope_id);
}

test "parseInboundEvent: events_api with envelope" {
    const e = parseInboundEvent(testing.allocator,
        "{\"envelope_id\":\"env-42\",\"type\":\"events_api\",\"payload\":{\"event\":{}}}",
    );
    try testing.expectEqual(EventType.events_api, e.type);
    try testing.expectEqualStrings("env-42", e.envelope_id);
}

test "parseInboundEvent: events_api with payload BEFORE outer type (real Slack ordering)" {
    // Slack sends `payload` first, with the outer envelope's `type`
    // appearing last. The inner `payload.event.type` field comes
    // before the outer `type`. The hand-rolled first-match parser
    // would mis-tag this as the inner type → unknown. JSON parsing
    // gets it right.
    const e = parseInboundEvent(testing.allocator,
        "{\"envelope_id\":\"e1\",\"payload\":{\"event\":{\"type\":\"message\"},\"type\":\"event_callback\"},\"type\":\"events_api\"}",
    );
    try testing.expectEqual(EventType.events_api, e.type);
    try testing.expectEqualStrings("e1", e.envelope_id);
}

test "parseInboundEvent: app_mention payload with payload-first ordering" {
    // Mirrors the real frame shape Slack sent in the v0.2.x repro:
    // payload arrives before outer type, payload's nested
    // `event.type:"app_mention"` precedes the outer `type:"events_api"`.
    const e = parseInboundEvent(testing.allocator,
        "{\"envelope_id\":\"abc\",\"payload\":{\"event\":{\"type\":\"app_mention\"},\"type\":\"event_callback\"},\"type\":\"events_api\"}",
    );
    try testing.expectEqual(EventType.events_api, e.type);
    try testing.expectEqualStrings("abc", e.envelope_id);
}

test "parseInboundEvent: disconnect" {
    const e = parseInboundEvent(testing.allocator,
        "{\"type\":\"disconnect\",\"reason\":\"warning\",\"debug_info\":{}}",
    );
    try testing.expectEqual(EventType.disconnect, e.type);
    try testing.expectEqualStrings("", e.envelope_id);
}

test "parseInboundEvent: slash_commands with envelope" {
    const e = parseInboundEvent(testing.allocator,
        "{\"envelope_id\":\"e2\",\"type\":\"slash_commands\",\"payload\":{}}",
    );
    try testing.expectEqual(EventType.slash_commands, e.type);
    try testing.expectEqualStrings("e2", e.envelope_id);
}

test "parseInboundEvent: interactive with envelope" {
    const e = parseInboundEvent(testing.allocator,
        "{\"envelope_id\":\"e3\",\"type\":\"interactive\",\"payload\":{}}",
    );
    try testing.expectEqual(EventType.interactive, e.type);
    try testing.expectEqualStrings("e3", e.envelope_id);
}

test "parseInboundEvent: unknown type" {
    const e = parseInboundEvent(testing.allocator, "{\"type\":\"newfangled_thing\"}");
    try testing.expectEqual(EventType.unknown, e.type);
}

test "parseInboundEvent: missing type → unknown" {
    const e = parseInboundEvent(testing.allocator, "{\"foo\":\"bar\"}");
    try testing.expectEqual(EventType.unknown, e.type);
}

test "parseInboundEvent: malformed JSON → unknown (not a crash)" {
    const e = parseInboundEvent(testing.allocator, "{not json");
    try testing.expectEqual(EventType.unknown, e.type);
}

// ─── Loopback test for SocketMode.refreshWssUrl ─────────────────

const FauxApiResponse = struct { body: []const u8 };
const FauxApiServer = struct {
    server: std.Io.net.Server,
    port: u16,
    response: FauxApiResponse,
    allocator: std.mem.Allocator,
    io: std.Io,
};

fn fauxApiLoop(s: *FauxApiServer) void {
    var stream_conn = s.server.accept(s.io) catch return;
    defer stream_conn.close(s.io);
    var buf: [4096]u8 = undefined;
    var r = stream_conn.reader(s.io, &.{});
    var total: usize = 0;
    while (total < buf.len) {
        var vecs: [1][]u8 = .{buf[total..]};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        total += n;
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }
    var reply: [1024]u8 = undefined;
    const reply_str = std.fmt.bufPrint(
        &reply,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ s.response.body.len, s.response.body },
    ) catch return;
    var wbuf: [256]u8 = undefined;
    var w = stream_conn.writer(s.io, &wbuf);
    w.interface.writeAll(reply_str) catch {};
    w.interface.flush() catch {};
}

fn bindFauxApiServer(allocator: std.mem.Allocator, io: std.Io, body: []const u8) ?FauxApiServer {
    var p: u16 = 19200;
    while (p < 19299) : (p += 1) {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch continue;
        const server = std.Io.net.IpAddress.listen(&addr, io, .{
            .kernel_backlog = 4,
            .reuse_address = true,
        }) catch continue;
        return .{
            .server = server,
            .port = p,
            .response = .{ .body = body },
            .allocator = allocator,
            .io = io,
        };
    }
    return null;
}

test "SocketMode.refreshWssUrl: pulls URL from apps.connections.open" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxApiServer(gpa, io,
        "{\"ok\":true,\"url\":\"wss://wss-primary.slack.com/link/?ticket=t1\"}",
    ) orelse return;
    defer s.server.deinit(io);
    const server_thread = try std.Thread.spawn(.{}, fauxApiLoop, .{&s});
    defer server_thread.join();

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.app_token = "xapp-fake";
    api.base_url = base;

    var sm = SocketMode.init(gpa, io, &api);
    defer sm.deinit();

    try sm.refreshWssUrl();
    try testing.expect(sm.wss_url != null);
    try testing.expectEqualStrings(
        "wss://wss-primary.slack.com/link/?ticket=t1",
        sm.wss_url.?,
    );
}

test "SocketMode.refreshWssUrl: HandshakeFailed when Slack returns ok=false" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxApiServer(gpa, io,
        "{\"ok\":false,\"error\":\"invalid_auth\"}",
    ) orelse return;
    defer s.server.deinit(io);
    const server_thread = try std.Thread.spawn(.{}, fauxApiLoop, .{&s});
    defer server_thread.join();

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var api = web_api.Client.init(gpa, io, "xoxb-fake");
    defer api.deinit();
    api.app_token = "xapp-fake";
    api.base_url = base;

    var sm = SocketMode.init(gpa, io, &api);
    defer sm.deinit();

    try testing.expectError(SocketModeError.HandshakeFailed, sm.refreshWssUrl());
}
