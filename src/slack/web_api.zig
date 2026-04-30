//! Slack Web API client (§4 of franky-do.md).
//!
//! Four endpoints in v0.1:
//!   - `auth.test`              — verify the bot token
//!   - `apps.connections.open`  — get the WSS URL for Socket Mode
//!   - `chat.postMessage`       — post a new message
//!   - `chat.update`            — update an existing message
//!
//! Transport reuses `franky.ai.http.fetchWithRetryAndTimeoutsAndHooks`
//! so we automatically get the §F.1 retry policy and the v1.8.0
//! per-phase timeouts.
//!
//! Wire format:
//!   POST https://slack.com/api/<method>
//!   Authorization: Bearer <token>            (xoxb- or xapp-)
//!   Content-Type:  application/json; charset=utf-8
//!   Body:          JSON object
//!
//! Response is always 200 even for application errors; the JSON
//! body's `ok` field tells you whether the call succeeded. On
//! `ok=false` an `error` field carries a Slack error code string
//! (e.g. `"not_authed"`, `"rate_limited"`, `"channel_not_found"`).

const std = @import("std");
const franky = @import("franky");
const http = franky.ai.http;
const stream = franky.ai.stream;

const default_base_url = "https://slack.com/api/";

pub const ApiError = error{
    /// HTTP transport-level failure (DNS, connection reset, timeout,
    /// non-2xx status, etc.). See `last_http_error` on the client
    /// for the underlying error.
    HttpFailed,
    /// Slack returned `ok=false`. See `last_slack_error` on the
    /// client for the Slack-side error code (e.g. `"rate_limited"`).
    SlackApiError,
    /// Response body wasn't well-formed JSON or didn't have the
    /// expected shape.
    InvalidResponse,
} || std.mem.Allocator.Error;

/// Per-bot Slack client.
pub const Client = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Bot token (xoxb-...) — used for chat.* / auth.test.
    bot_token: []const u8,
    /// App-level token (xapp-...) — used for apps.connections.open.
    /// Optional; only required for Socket Mode setup.
    app_token: ?[]const u8 = null,
    /// Base URL (default `https://slack.com/api/`). Tests override
    /// to point at a loopback HTTP server.
    base_url: []const u8 = default_base_url,
    /// Last-call diagnostics. Populated on every call so callers
    /// can inspect the failure reason without parsing errors.
    last_http_error: ?anyerror = null,
    /// Allocator-owned. Caller must free if they want to keep it
    /// past the next call; the Client overwrites/frees on each
    /// call.
    last_slack_error: ?[]const u8 = null,
    /// v0.4.11 — Slack's `response_metadata.messages` array, joined
    /// with `; `. Often carries the SPECIFIC reason behind a
    /// generic code like `invalid_arguments` (e.g. `[ERROR]
    /// missing required field 'files'` or `[ERROR] not_in_channel`).
    /// Same lifetime semantics as `last_slack_error`.
    last_slack_error_detail: ?[]const u8 = null,
    /// v0.3.9 — when set, every internal `franky.ai.http.Client` is
    /// proxy-initialized via `initDefaultProxies(env_map)` —
    /// same path the LLM providers use. Honors `HTTP_PROXY` /
    /// `HTTPS_PROXY` / `NO_PROXY` (and lowercase variants).
    /// Borrowed; outlives the Client. Wired from main.zig after
    /// `Client.init`.
    environ_map: ?*std.process.Environ.Map = null,
    /// v0.4.11 — when non-null, every Slack API call AND the
    /// presigned-URL upload step write a full request/response
    /// trace file via `franky.ai.http.writeTraceFile`. Same
    /// directory as the LLM-provider traces; filename prefix
    /// distinguishes them by provider field
    /// (`slack-<method>` / `slack-files-upload-presigned`).
    /// Borrowed slice; outlives the Client. Wired from main.zig
    /// after `Client.init`.
    http_trace_dir: ?[]const u8 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        bot_token: []const u8,
    ) Client {
        return .{
            .allocator = allocator,
            .io = io,
            .bot_token = bot_token,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.last_slack_error) |s| self.allocator.free(s);
        self.last_slack_error = null;
        if (self.last_slack_error_detail) |s| self.allocator.free(s);
        self.last_slack_error_detail = null;
    }

    /// Token to send for a given method. `apps.connections.open`
    /// needs the app-level token; everything else uses the bot
    /// token. Returns null if the required token isn't set.
    fn tokenFor(self: *const Client, method: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, method, "apps.connections.open")) return self.app_token;
        return self.bot_token;
    }

    fn updateSlackError(self: *Client, slack_err: ?[]const u8) !void {
        if (self.last_slack_error) |s| {
            self.allocator.free(s);
            self.last_slack_error = null;
        }
        if (slack_err) |e| {
            self.last_slack_error = try self.allocator.dupe(u8, e);
        }
    }

    /// Issue a POST to `base_url ++ method`. Caller owns the parsed
    /// response. Returns either the parsed response struct or one
    /// of the `ApiError` variants. On error, `last_http_error` /
    /// `last_slack_error` are populated.
    fn callMethod(
        self: *Client,
        comptime ResponseT: type,
        method: []const u8,
        payload_json: []const u8,
    ) ApiError!std.json.Parsed(ResponseT) {
        self.last_http_error = null;
        try self.updateSlackError(null);

        const token = self.tokenFor(method) orelse {
            self.last_http_error = error.MissingToken;
            return ApiError.HttpFailed;
        };

        const url = std.fmt.allocPrint(
            self.allocator,
            "{s}{s}",
            .{ self.base_url, method },
        ) catch return ApiError.OutOfMemory;
        defer self.allocator.free(url);

        const auth_hdr = std.fmt.allocPrint(
            self.allocator,
            "Bearer {s}",
            .{token},
        ) catch return ApiError.OutOfMemory;
        defer self.allocator.free(auth_hdr);

        var bw = std.Io.Writer.Allocating.init(self.allocator);
        defer bw.deinit();

        var http_client = franky.ai.http.Client{
            .allocator = self.allocator,
            .io = self.io,
        };
        defer http_client.deinit();

        // v0.3.9/v0.4.0 — proxy + FRANKY_CA_BUNDLE in one call.
        // Same helper the LLM providers use (franky v1.25.0).
        if (self.environ_map) |env_map| {
            http.setupClientFromEnv(&http_client, self.allocator, self.io, env_map) catch |e| {
                self.last_http_error = e;
                return ApiError.HttpFailed;
            };
        }

        var cancel: stream.Cancel = .{};
        const headers = [_]std.http.Header{
            .{ .name = "Authorization", .value = auth_hdr },
            .{ .name = "Content-Type", .value = "application/json; charset=utf-8" },
            .{ .name = "Accept", .value = "application/json" },
        };

        const result = http.fetchWithRetryAndTimeoutsAndHooks(
            &http_client,
            .{
                .location = .{ .url = url },
                .method = .POST,
                .payload = payload_json,
                .extra_headers = &headers,
            },
            &bw,
            &cancel,
            .{},
            .{},
            .{},
        ) catch |e| {
            self.last_http_error = e;
            return ApiError.HttpFailed;
        };

        const body = bw.written();

        // v0.4.11 — write the full request + response to the
        // operator's `--http-trace-dir`. Same convention as the
        // LLM-provider traces; provider field is
        // `slack-<method>` so a `ls /tmp/franky-trace` shows
        // both LLM and Slack calls interleaved by ts. Best-
        // effort: writeTraceFile swallows IO errors internally.
        if (self.http_trace_dir) |dir| {
            const provider_buf = std.fmt.allocPrint(
                self.allocator,
                "slack-{s}",
                .{method},
            ) catch null;
            if (provider_buf) |provider_label| {
                defer self.allocator.free(provider_label);
                if (http.writeTraceFile(
                    self.allocator,
                    self.io,
                    dir,
                    provider_label,
                    url,
                    "POST",
                    @intFromEnum(result.status),
                    payload_json,
                    body,
                )) |trace_id| self.allocator.free(trace_id);
            }
        }

        if (@intFromEnum(result.status) >= 400) {
            self.last_http_error = error.HttpErrorStatus;
            return ApiError.HttpFailed;
        }

        const parsed = std.json.parseFromSlice(
            ResponseT,
            self.allocator,
            body,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        ) catch {
            return ApiError.InvalidResponse;
        };

        // Slack's `ok` field is the load-bearing signal. Every
        // typed response has it as the first field.
        const ok = parsed.value.ok;
        if (!ok) {
            // Pull the Slack `error` code out for diagnostics.
            // Field name is `error` in JSON; in Zig the field is
            // declared as `@"error"` because `error` is reserved,
            // but `@field` takes the unescaped name.
            const err_field = @field(parsed.value, "error");
            try self.updateSlackError(err_field);
            // v0.4.11 — also pull `response_metadata.messages` out
            // of the raw response body. This array often carries
            // the SPECIFIC failure reason behind a generic code
            // like `invalid_arguments` (e.g. `[ERROR] missing
            // required field 'files'` or
            // `[ERROR] not_in_channel`). Re-parse the body
            // because the typed response struct doesn't include
            // these fields. Best-effort: a parse failure leaves
            // last_slack_error_detail null.
            try self.captureResponseMetadataMessages(body);
            // Free the parsed JSON arena before returning — the
            // caller never sees `parsed` on the error path, so it
            // would leak otherwise.
            var p = parsed;
            p.deinit();
            return ApiError.SlackApiError;
        }
        // Clear any stale detail from a prior failed call.
        if (self.last_slack_error_detail) |s| {
            self.allocator.free(s);
            self.last_slack_error_detail = null;
        }
        return parsed;
    }

    /// v0.4.11 — extract `response_metadata.messages[]` from a
    /// Slack error response body and join into a single
    /// `; `-separated string on `last_slack_error_detail`. Pure
    /// best-effort: any IO/parse error silently leaves the
    /// field as-is. Caller frees the previous value first.
    fn captureResponseMetadataMessages(self: *Client, body: []const u8) !void {
        if (self.last_slack_error_detail) |s| {
            self.allocator.free(s);
            self.last_slack_error_detail = null;
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch return;
        if (parsed != .object) return;
        const meta = parsed.object.get("response_metadata") orelse return;
        if (meta != .object) return;
        const messages = meta.object.get("messages") orelse return;
        if (messages != .array or messages.array.items.len == 0) return;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        for (messages.array.items, 0..) |m, i| {
            if (m != .string) continue;
            if (i > 0) try buf.appendSlice(self.allocator, "; ");
            try buf.appendSlice(self.allocator, m.string);
        }
        if (buf.items.len > 0) {
            self.last_slack_error_detail = try self.allocator.dupe(u8, buf.items);
        }
    }

    // ── Endpoint: auth.test ──

    pub const AuthTestResponse = struct {
        ok: bool,
        @"error": ?[]const u8 = null,
        url: ?[]const u8 = null,
        team: ?[]const u8 = null,
        user: ?[]const u8 = null,
        team_id: ?[]const u8 = null,
        user_id: ?[]const u8 = null,
        bot_id: ?[]const u8 = null,
    };

    pub fn authTest(self: *Client) ApiError!std.json.Parsed(AuthTestResponse) {
        return self.callMethod(AuthTestResponse, "auth.test", "{}");
    }

    // ── Endpoint: apps.connections.open ──

    pub const AppsConnectionsOpenResponse = struct {
        ok: bool,
        @"error": ?[]const u8 = null,
        url: ?[]const u8 = null,
    };

    pub fn appsConnectionsOpen(self: *Client) ApiError!std.json.Parsed(AppsConnectionsOpenResponse) {
        return self.callMethod(AppsConnectionsOpenResponse, "apps.connections.open", "{}");
    }

    // ── Endpoint: chat.postMessage ──

    pub const ChatPostMessageArgs = struct {
        channel: []const u8,
        text: []const u8,
        thread_ts: ?[]const u8 = null,
        /// Send as a reply *and* broadcast to the channel. Slack's
        /// `reply_broadcast` field. Default false.
        reply_broadcast: bool = false,
        /// v0.4.4 — raw JSON for Slack's Block Kit `blocks` array.
        /// Embedded verbatim into the request body — caller is
        /// responsible for producing well-formed JSON. `text`
        /// remains required as Slack uses it for notifications and
        /// the screen-reader fallback when `blocks` is set.
        blocks_json: ?[]const u8 = null,
    };

    pub const ChatPostMessageResponse = struct {
        ok: bool,
        @"error": ?[]const u8 = null,
        channel: ?[]const u8 = null,
        ts: ?[]const u8 = null,
    };

    pub fn chatPostMessage(
        self: *Client,
        args: ChatPostMessageArgs,
    ) ApiError!std.json.Parsed(ChatPostMessageResponse) {
        const body = try buildChatPostMessageBody(self.allocator, args);
        defer self.allocator.free(body);
        return self.callMethod(ChatPostMessageResponse, "chat.postMessage", body);
    }

    // ── Endpoint: chat.update ──

    pub const ChatUpdateArgs = struct {
        channel: []const u8,
        ts: []const u8,
        text: []const u8,
        /// v0.4.4 — same semantics as `ChatPostMessageArgs.blocks_json`.
        /// When set, `chat.update` replaces the message's blocks; when
        /// null the existing blocks are removed and only `text` shows
        /// (matches Slack's documented behavior). Used by the v0.4.4
        /// permission-prompt flow to disable the action buttons after
        /// resolution.
        blocks_json: ?[]const u8 = null,
    };

    pub const ChatUpdateResponse = struct {
        ok: bool,
        @"error": ?[]const u8 = null,
        channel: ?[]const u8 = null,
        ts: ?[]const u8 = null,
        text: ?[]const u8 = null,
    };

    pub fn chatUpdate(
        self: *Client,
        args: ChatUpdateArgs,
    ) ApiError!std.json.Parsed(ChatUpdateResponse) {
        const body = try buildChatUpdateBody(self.allocator, args);
        defer self.allocator.free(body);
        return self.callMethod(ChatUpdateResponse, "chat.update", body);
    }

    // ── Endpoint: reactions.add ──
    //
    // v0.3.0 — used by `ReactionsSubscriber` to surface agent state
    // (👀 received / 💭 working / ✅ done / ❌ error) on the user's
    // `@`-mention message. Slack's mobile clients animate reactions on
    // the source message, so this gives real-time feedback without
    // forcing the user to scroll to the bot's reply.

    pub const ReactionsAddArgs = struct {
        channel: []const u8,
        /// Timestamp of the message to react on (e.g. the user's
        /// `@`-mention `ts`).
        timestamp: []const u8,
        /// Reaction name without colons — `eyes`, `thought_balloon`,
        /// `white_check_mark`, `x`.
        name: []const u8,
    };

    pub const ReactionsAddResponse = struct {
        ok: bool,
        @"error": ?[]const u8 = null,
    };

    pub fn reactionsAdd(
        self: *Client,
        args: ReactionsAddArgs,
    ) ApiError!std.json.Parsed(ReactionsAddResponse) {
        const body = try buildReactionsAddBody(self.allocator, args);
        defer self.allocator.free(body);
        return self.callMethod(ReactionsAddResponse, "reactions.add", body);
    }

    // ── Endpoint: reactions.remove ──
    //
    // v0.3.4 — used by `ReactionsSubscriber` to drop the prior
    // state emoji when transitioning. Body shape mirrors
    // `reactions.add` (channel/timestamp/name).

    pub const ReactionsRemoveArgs = struct {
        channel: []const u8,
        timestamp: []const u8,
        name: []const u8,
    };

    pub const ReactionsRemoveResponse = struct {
        ok: bool,
        @"error": ?[]const u8 = null,
    };

    pub fn reactionsRemove(
        self: *Client,
        args: ReactionsRemoveArgs,
    ) ApiError!std.json.Parsed(ReactionsRemoveResponse) {
        const body = try buildReactionsRemoveBody(self.allocator, args);
        defer self.allocator.free(body);
        return self.callMethod(ReactionsRemoveResponse, "reactions.remove", body);
    }

    // ── Endpoint: files.getUploadURLExternal (v0.3.8) ──
    //
    // Step 1 of the 3-step modern files-upload flow. POSTs
    // `filename` + `length` (bytes) and gets back a `file_id` and
    // a presigned `upload_url`. We then POST the file body to
    // `upload_url` (step 2 — `uploadFileToPresignedUrl`) and
    // finalize via `files.completeUploadExternal` (step 3).
    //
    // Rate-limit tier: Tier 4 (~100/min). Plenty of headroom
    // for franky-do's "long replies become attachments" flow.

    pub const FilesGetUploadURLExternalArgs = struct {
        filename: []const u8,
        /// Bytes of the file we're about to upload. Slack requires
        /// this so it can size the presigned URL.
        length: u64,
    };

    pub const FilesGetUploadURLExternalResponse = struct {
        ok: bool,
        @"error": ?[]const u8 = null,
        upload_url: ?[]const u8 = null,
        file_id: ?[]const u8 = null,
    };

    pub fn filesGetUploadURLExternal(
        self: *Client,
        args: FilesGetUploadURLExternalArgs,
    ) ApiError!std.json.Parsed(FilesGetUploadURLExternalResponse) {
        const body = try buildFilesGetUploadURLBody(self.allocator, args);
        defer self.allocator.free(body);
        return self.callMethod(FilesGetUploadURLExternalResponse, "files.getUploadURLExternal", body);
    }

    // ── Endpoint: files.completeUploadExternal (v0.3.8) ──
    //
    // Step 3 of the 3-step files-upload flow. Finalizes the
    // upload (Slack now associates the file with the channel +
    // optional thread_ts + initial_comment) and posts a message
    // referencing the file in the thread.

    pub const CompleteUploadFile = struct {
        id: []const u8,
        title: []const u8,
    };

    pub const FilesCompleteUploadExternalArgs = struct {
        files: []const CompleteUploadFile,
        channel_id: []const u8,
        thread_ts: ?[]const u8 = null,
        initial_comment: ?[]const u8 = null,
    };

    pub const FilesCompleteUploadExternalResponse = struct {
        ok: bool,
        @"error": ?[]const u8 = null,
    };

    pub fn filesCompleteUploadExternal(
        self: *Client,
        args: FilesCompleteUploadExternalArgs,
    ) ApiError!std.json.Parsed(FilesCompleteUploadExternalResponse) {
        const body = try buildFilesCompleteUploadBody(self.allocator, args);
        defer self.allocator.free(body);
        return self.callMethod(FilesCompleteUploadExternalResponse, "files.completeUploadExternal", body);
    }

    // ── Step 2: presigned-URL upload (v0.3.8) ──
    //
    // POSTs the file body to the URL returned by step 1. Uses
    // `multipart/form-data` per Slack's docs. The presigned URL
    // is on a Slack-controlled host but is NOT a /api/* method —
    // so this bypasses `callMethod` and posts directly via the
    // shared http transport.
    pub fn uploadFileToPresignedUrl(
        self: *Client,
        upload_url: []const u8,
        filename: []const u8,
        content: []const u8,
    ) ApiError!void {
        const boundary = try makeMultipartBoundary(self.allocator);
        defer self.allocator.free(boundary);
        const body = try buildMultipartFile(self.allocator, boundary, filename, content);
        defer self.allocator.free(body);

        const ct_hdr = std.fmt.allocPrint(
            self.allocator,
            "multipart/form-data; boundary={s}",
            .{boundary},
        ) catch return ApiError.OutOfMemory;
        defer self.allocator.free(ct_hdr);

        var bw = std.Io.Writer.Allocating.init(self.allocator);
        defer bw.deinit();
        var http_client = franky.ai.http.Client{ .allocator = self.allocator, .io = self.io };
        defer http_client.deinit();
        // v0.3.9/v0.4.0 — proxy + FRANKY_CA_BUNDLE for the file-
        // upload step too; the presigned URL host hits the same
        // MITM proxy as the /api/* endpoints.
        if (self.environ_map) |env_map| {
            http.setupClientFromEnv(&http_client, self.allocator, self.io, env_map) catch |e| {
                self.last_http_error = e;
                return ApiError.HttpFailed;
            };
        }
        var cancel: stream.Cancel = .{};
        const headers = [_]std.http.Header{
            .{ .name = "Content-Type", .value = ct_hdr },
        };
        const result = http.fetchWithRetryAndTimeoutsAndHooks(
            &http_client,
            .{
                .location = .{ .url = upload_url },
                .method = .POST,
                .payload = body,
                .extra_headers = &headers,
            },
            &bw,
            &cancel,
            .{},
            .{},
            .{},
        ) catch |e| {
            self.last_http_error = e;
            return ApiError.HttpFailed;
        };

        // v0.4.11 — trace the presigned-URL upload too. Note that
        // the request body is multipart/form-data with the FULL
        // file content embedded; trace files for big uploads
        // get correspondingly large. Acceptable for diagnostics.
        if (self.http_trace_dir) |dir| {
            // The multipart body includes the raw file bytes;
            // for diagnosability prefer to log the boundary
            // headers and a truncated content marker rather than
            // the full payload. But for a first cut, dump as-is —
            // it's gated on opt-in --http-trace-dir.
            if (http.writeTraceFile(
                self.allocator,
                self.io,
                dir,
                "slack-files-upload-presigned",
                upload_url,
                "POST",
                @intFromEnum(result.status),
                body,
                bw.written(),
            )) |trace_id| self.allocator.free(trace_id);
        }

        if (@intFromEnum(result.status) >= 400) {
            self.last_http_error = error.HttpErrorStatus;
            return ApiError.HttpFailed;
        }
    }

    // ── High-level orchestrator (v0.3.8) ──
    //
    // `uploadTextToThread` runs the full 3-step flow + posts the
    // file as a comment in the given thread. Returns the file_id
    // on success so the caller can log / link.
    pub const UploadTextToThreadArgs = struct {
        channel_id: []const u8,
        thread_ts: ?[]const u8 = null,
        filename: []const u8,
        title: []const u8,
        content: []const u8,
        initial_comment: ?[]const u8 = null,
    };

    pub fn uploadTextToThread(
        self: *Client,
        args: UploadTextToThreadArgs,
    ) ApiError!void {
        // Step 1
        var step1_resp = try self.filesGetUploadURLExternal(.{
            .filename = args.filename,
            .length = args.content.len,
        });
        defer step1_resp.deinit();
        const upload_url = step1_resp.value.upload_url orelse return ApiError.InvalidResponse;
        const file_id = step1_resp.value.file_id orelse return ApiError.InvalidResponse;

        // Step 2
        try self.uploadFileToPresignedUrl(upload_url, args.filename, args.content);

        // Step 3
        const files = [_]CompleteUploadFile{
            .{ .id = file_id, .title = args.title },
        };
        var step3_resp = try self.filesCompleteUploadExternal(.{
            .files = &files,
            .channel_id = args.channel_id,
            .thread_ts = args.thread_ts,
            .initial_comment = args.initial_comment,
        });
        defer step3_resp.deinit();
    }
};

// ─── Body builders (factored out for testability) ──────────────────

fn buildChatPostMessageBody(
    allocator: std.mem.Allocator,
    args: Client.ChatPostMessageArgs,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonField(allocator, &buf, "channel", args.channel, true);
    try buf.append(allocator, ',');
    try appendJsonField(allocator, &buf, "text", args.text, true);
    if (args.thread_ts) |t| {
        try buf.append(allocator, ',');
        try appendJsonField(allocator, &buf, "thread_ts", t, true);
    }
    if (args.reply_broadcast) {
        try buf.appendSlice(allocator, ",\"reply_broadcast\":true");
    }
    if (args.blocks_json) |b| {
        try buf.appendSlice(allocator, ",\"blocks\":");
        try buf.appendSlice(allocator, b);
    }
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn buildChatUpdateBody(
    allocator: std.mem.Allocator,
    args: Client.ChatUpdateArgs,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonField(allocator, &buf, "channel", args.channel, true);
    try buf.append(allocator, ',');
    try appendJsonField(allocator, &buf, "ts", args.ts, true);
    try buf.append(allocator, ',');
    try appendJsonField(allocator, &buf, "text", args.text, true);
    if (args.blocks_json) |b| {
        try buf.appendSlice(allocator, ",\"blocks\":");
        try buf.appendSlice(allocator, b);
    }
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn buildReactionsAddBody(
    allocator: std.mem.Allocator,
    args: Client.ReactionsAddArgs,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonField(allocator, &buf, "channel", args.channel, true);
    try buf.append(allocator, ',');
    try appendJsonField(allocator, &buf, "timestamp", args.timestamp, true);
    try buf.append(allocator, ',');
    try appendJsonField(allocator, &buf, "name", args.name, true);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn buildReactionsRemoveBody(
    allocator: std.mem.Allocator,
    args: Client.ReactionsRemoveArgs,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonField(allocator, &buf, "channel", args.channel, true);
    try buf.append(allocator, ',');
    try appendJsonField(allocator, &buf, "timestamp", args.timestamp, true);
    try buf.append(allocator, ',');
    try appendJsonField(allocator, &buf, "name", args.name, true);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn buildFilesGetUploadURLBody(
    allocator: std.mem.Allocator,
    args: Client.FilesGetUploadURLExternalArgs,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonField(allocator, &buf, "filename", args.filename, true);
    try buf.append(allocator, ',');
    try buf.appendSlice(allocator, "\"length\":");
    const len_s = try std.fmt.allocPrint(allocator, "{d}", .{args.length});
    defer allocator.free(len_s);
    try buf.appendSlice(allocator, len_s);
    try buf.append(allocator, '}');
    return try buf.toOwnedSlice(allocator);
}

fn buildFilesCompleteUploadBody(
    allocator: std.mem.Allocator,
    args: Client.FilesCompleteUploadExternalArgs,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonField(allocator, &buf, "channel_id", args.channel_id, true);
    if (args.thread_ts) |t| {
        try buf.append(allocator, ',');
        try appendJsonField(allocator, &buf, "thread_ts", t, true);
    }
    if (args.initial_comment) |c| {
        try buf.append(allocator, ',');
        try appendJsonField(allocator, &buf, "initial_comment", c, true);
    }
    try buf.appendSlice(allocator, ",\"files\":[");
    for (args.files, 0..) |f, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try appendJsonField(allocator, &buf, "id", f.id, true);
        try buf.append(allocator, ',');
        try appendJsonField(allocator, &buf, "title", f.title, true);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
    return try buf.toOwnedSlice(allocator);
}

/// v0.3.8 — random multipart boundary keyed off wall-clock so
/// concurrent uploads don't collide. Boundaries that appear in
/// the file content would corrupt the request, but since we only
/// upload text-of-known-shape franky-do generates, the fixed
/// `franky-do-` prefix + a millisecond suffix is safe.
fn makeMultipartBoundary(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "----franky-do-mp-{d}",
        .{stream.nowMillis()},
    );
}

/// v0.3.8 — minimal multipart/form-data builder for Slack's
/// presigned upload URL. Two parts: `filename` (text) and
/// `file` (the bytes themselves). Slack's docs say the file
/// part is called `file` with a `filename=` directive on the
/// Content-Disposition.
fn buildMultipartFile(
    allocator: std.mem.Allocator,
    boundary: []const u8,
    filename: []const u8,
    content: []const u8,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "--");
    try buf.appendSlice(allocator, boundary);
    try buf.appendSlice(allocator, "\r\nContent-Disposition: form-data; name=\"filename\"\r\n\r\n");
    try buf.appendSlice(allocator, filename);
    try buf.appendSlice(allocator, "\r\n--");
    try buf.appendSlice(allocator, boundary);
    try buf.appendSlice(allocator, "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"");
    try buf.appendSlice(allocator, filename);
    try buf.appendSlice(allocator, "\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n");
    try buf.appendSlice(allocator, content);
    try buf.appendSlice(allocator, "\r\n--");
    try buf.appendSlice(allocator, boundary);
    try buf.appendSlice(allocator, "--\r\n");
    return try buf.toOwnedSlice(allocator);
}

fn appendJsonField(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
    quote_value: bool,
) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, name);
    try buf.appendSlice(allocator, "\":");
    if (quote_value) {
        try buf.append(allocator, '"');
        try appendJsonStringContent(allocator, buf, value);
        try buf.append(allocator, '"');
    } else {
        try buf.appendSlice(allocator, value);
    }
}

fn appendJsonStringContent(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    s: []const u8,
) !void {
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(allocator, "\\\""),
        '\\' => try buf.appendSlice(allocator, "\\\\"),
        '\n' => try buf.appendSlice(allocator, "\\n"),
        '\r' => try buf.appendSlice(allocator, "\\r"),
        '\t' => try buf.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try buf.appendSlice(allocator, w);
        },
        else => try buf.append(allocator, c),
    };
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "buildChatPostMessageBody: basic shape" {
    const body = try buildChatPostMessageBody(testing.allocator, .{
        .channel = "C123",
        .text = "hello",
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings("{\"channel\":\"C123\",\"text\":\"hello\"}", body);
}

test "buildChatPostMessageBody: with thread_ts" {
    const body = try buildChatPostMessageBody(testing.allocator, .{
        .channel = "C123",
        .text = "reply",
        .thread_ts = "1234567890.000100",
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"channel\":\"C123\",\"text\":\"reply\",\"thread_ts\":\"1234567890.000100\"}",
        body,
    );
}

test "buildChatPostMessageBody: escapes newlines and quotes" {
    const body = try buildChatPostMessageBody(testing.allocator, .{
        .channel = "C123",
        .text = "she said \"hi\"\nnext line",
    });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\\\"hi\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\\n") != null);
}

test "buildChatUpdateBody: basic shape" {
    const body = try buildChatUpdateBody(testing.allocator, .{
        .channel = "C123",
        .ts = "1234567890.000100",
        .text = "edit",
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"channel\":\"C123\",\"ts\":\"1234567890.000100\",\"text\":\"edit\"}",
        body,
    );
}

test "buildReactionsAddBody: basic shape" {
    const body = try buildReactionsAddBody(testing.allocator, .{
        .channel = "C123",
        .timestamp = "1234567890.000100",
        .name = "white_check_mark",
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"channel\":\"C123\",\"timestamp\":\"1234567890.000100\",\"name\":\"white_check_mark\"}",
        body,
    );
}

test "buildFilesGetUploadURLBody: filename + integer length (v0.3.8)" {
    const body = try buildFilesGetUploadURLBody(testing.allocator, .{
        .filename = "reply.txt",
        .length = 5890,
    });
    defer testing.allocator.free(body);
    try testing.expectEqualStrings(
        "{\"filename\":\"reply.txt\",\"length\":5890}",
        body,
    );
}

test "buildFilesCompleteUploadBody: with thread_ts + initial_comment (v0.3.8)" {
    const files = [_]Client.CompleteUploadFile{
        .{ .id = "F1234", .title = "Full reply" },
    };
    const body = try buildFilesCompleteUploadBody(testing.allocator, .{
        .files = &files,
        .channel_id = "C123",
        .thread_ts = "1700000000.000100",
        .initial_comment = "see attached",
    });
    defer testing.allocator.free(body);
    try testing.expect(std.mem.indexOf(u8, body, "\"channel_id\":\"C123\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"thread_ts\":\"1700000000.000100\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"initial_comment\":\"see attached\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"files\":[{\"id\":\"F1234\",\"title\":\"Full reply\"}]") != null);
}

test "buildMultipartFile: shape carries filename + content + boundary (v0.3.8)" {
    const body = try buildMultipartFile(
        testing.allocator,
        "----franky-do-mp-test",
        "reply.txt",
        "the full reply\n",
    );
    defer testing.allocator.free(body);
    try testing.expect(std.mem.startsWith(u8, body, "------franky-do-mp-test\r\n"));
    try testing.expect(std.mem.indexOf(u8, body, "name=\"filename\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "name=\"file\"; filename=\"reply.txt\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "the full reply\n") != null);
    try testing.expect(std.mem.endsWith(u8, body, "------franky-do-mp-test--\r\n"));
}

// ─── Loopback server for end-to-end Web API tests ─────────────────

const FauxSlackResponse = struct {
    /// Status to send back. 200 unless we want to test 5xx paths.
    status: u16 = 200,
    /// JSON body to send back as the reply.
    body: []const u8,
};

const FauxSlackServer = struct {
    server: std.Io.net.Server,
    port: u16,
    response: FauxSlackResponse,
    /// Captured request body (most recent). Allocator-owned.
    /// Test reads this after the call to assert payload shape.
    captured_body: ?[]u8 = null,
    /// Captured Authorization header (most recent). Allocator-owned.
    captured_auth: ?[]u8 = null,
    /// Captured request path (most recent). Allocator-owned.
    captured_path: ?[]u8 = null,
    allocator: std.mem.Allocator,
    io: std.Io,
};

fn fauxSlackLoop(s: *FauxSlackServer) void {
    var stream_conn = s.server.accept(s.io) catch return;
    defer stream_conn.close(s.io);

    // Read the entire request (headers + body). We just look for
    // "\r\n\r\n" and then read up to Content-Length, no parsing of
    // any other headers — lightweight enough for tests.
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
    if (headers_end == null) return;
    const head = buf[0..headers_end.?];

    // Parse Content-Length. franky.ai.http.Client lowercases header
    // names on the wire, so we accept either case.
    var content_length: usize = 0;
    const cl_pos = std.mem.indexOf(u8, head, "Content-Length:") orelse
        std.mem.indexOf(u8, head, "content-length:");
    if (cl_pos) |pos| {
        var i = pos + "content-length:".len;
        while (i < head.len and (head[i] == ' ' or head[i] == '\t')) i += 1;
        var end = i;
        while (end < head.len and head[end] != '\r' and head[end] != '\n') end += 1;
        content_length = std.fmt.parseInt(usize, head[i..end], 10) catch 0;
    }

    // Read remaining body bytes if not all already in buffer.
    while (total - headers_end.? < content_length and total < buf.len) {
        var vecs: [1][]u8 = .{buf[total..]};
        const n = r.interface.readVec(&vecs) catch break;
        if (n == 0) break;
        total += n;
    }

    const body_slice = buf[headers_end.?..@min(headers_end.? + content_length, total)];
    s.captured_body = s.allocator.dupe(u8, body_slice) catch null;

    // Capture path from request line.
    if (std.mem.indexOf(u8, head, " ")) |sp1| {
        const after = head[sp1 + 1 ..];
        if (std.mem.indexOf(u8, after, " ")) |sp2| {
            s.captured_path = s.allocator.dupe(u8, after[0..sp2]) catch null;
        }
    }

    // Capture Authorization header (case-insensitive match).
    const auth_pos = std.mem.indexOf(u8, head, "Authorization:") orelse
        std.mem.indexOf(u8, head, "authorization:");
    if (auth_pos) |pos| {
        var i = pos + "authorization:".len;
        while (i < head.len and (head[i] == ' ' or head[i] == '\t')) i += 1;
        var end = i;
        while (end < head.len and head[end] != '\r' and head[end] != '\n') end += 1;
        s.captured_auth = s.allocator.dupe(u8, head[i..end]) catch null;
    }

    // Send canned response.
    var reply: [4096]u8 = undefined;
    const reply_str = std.fmt.bufPrint(
        &reply,
        "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ s.response.status, s.response.body.len, s.response.body },
    ) catch return;
    var wbuf: [256]u8 = undefined;
    var w = stream_conn.writer(s.io, &wbuf);
    w.interface.writeAll(reply_str) catch {};
    w.interface.flush() catch {};
}

fn bindFauxSlackServer(
    allocator: std.mem.Allocator,
    io: std.Io,
    response: FauxSlackResponse,
) ?FauxSlackServer {
    const from: u16 = 19000;
    const to: u16 = 19099;
    var p = from;
    while (p < to) : (p += 1) {
        var addr = std.Io.net.IpAddress.parseIp4("127.0.0.1", p) catch continue;
        const server = std.Io.net.IpAddress.listen(&addr, io, .{
            .kernel_backlog = 4,
            .reuse_address = true,
        }) catch continue;
        return .{
            .server = server,
            .port = p,
            .response = response,
            .allocator = allocator,
            .io = io,
        };
    }
    return null;
}

fn deinitFauxServer(s: *FauxSlackServer) void {
    if (s.captured_body) |b| s.allocator.free(b);
    if (s.captured_auth) |a| s.allocator.free(a);
    if (s.captured_path) |p| s.allocator.free(p);
    s.server.deinit(s.io);
}

test "Client.authTest: parses team/user/bot ids on success" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxSlackServer(gpa, io,
        .{ .body = "{\"ok\":true,\"team_id\":\"T123\",\"user_id\":\"U456\",\"bot_id\":\"B789\"}" },
    ) orelse return;
    defer deinitFauxServer(&s);
    const server_thread = try std.Thread.spawn(.{}, fauxSlackLoop, .{&s});
    defer server_thread.join();

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var client = Client.init(gpa, io, "xoxb-fake");
    defer client.deinit();
    client.base_url = base;

    var resp = try client.authTest();
    defer resp.deinit();

    try testing.expect(resp.value.ok);
    try testing.expectEqualStrings("T123", resp.value.team_id.?);
    try testing.expectEqualStrings("U456", resp.value.user_id.?);
    try testing.expectEqualStrings("B789", resp.value.bot_id.?);

    // Headers + path went out correctly.
    try testing.expect(s.captured_path != null);
    try testing.expectEqualStrings("/auth.test", s.captured_path.?);
    try testing.expect(s.captured_auth != null);
    try testing.expectEqualStrings("Bearer xoxb-fake", s.captured_auth.?);
}

test "Client.authTest: surfaces SlackApiError + last_slack_error on ok=false" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxSlackServer(gpa, io,
        .{ .body = "{\"ok\":false,\"error\":\"not_authed\"}" },
    ) orelse return;
    defer deinitFauxServer(&s);
    const server_thread = try std.Thread.spawn(.{}, fauxSlackLoop, .{&s});
    defer server_thread.join();

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var client = Client.init(gpa, io, "xoxb-bad");
    defer client.deinit();
    client.base_url = base;

    const r = client.authTest();
    try testing.expectError(ApiError.SlackApiError, r);
    try testing.expect(client.last_slack_error != null);
    try testing.expectEqualStrings("not_authed", client.last_slack_error.?);
}

test "Client.appsConnectionsOpen: uses app_token, returns wss URL" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxSlackServer(gpa, io,
        .{ .body = "{\"ok\":true,\"url\":\"wss://wss-primary.slack.com/link/?ticket=abc\"}" },
    ) orelse return;
    defer deinitFauxServer(&s);
    const server_thread = try std.Thread.spawn(.{}, fauxSlackLoop, .{&s});
    defer server_thread.join();

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var client = Client.init(gpa, io, "xoxb-bot");
    defer client.deinit();
    client.app_token = "xapp-app";
    client.base_url = base;

    var resp = try client.appsConnectionsOpen();
    defer resp.deinit();

    try testing.expect(resp.value.ok);
    try testing.expectEqualStrings("wss://wss-primary.slack.com/link/?ticket=abc", resp.value.url.?);
    // Auth header used the APP token, not the bot token.
    try testing.expectEqualStrings("Bearer xapp-app", s.captured_auth.?);
    try testing.expectEqualStrings("/apps.connections.open", s.captured_path.?);
}

test "Client.appsConnectionsOpen: HttpFailed when app_token missing" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var client = Client.init(gpa, io, "xoxb-bot");
    defer client.deinit();
    // Deliberately no app_token set.

    const r = client.appsConnectionsOpen();
    try testing.expectError(ApiError.HttpFailed, r);
    try testing.expectEqual(@as(?anyerror, error.MissingToken), client.last_http_error);
}

test "Client.chatPostMessage: sends correct payload, parses ts" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxSlackServer(gpa, io,
        .{ .body = "{\"ok\":true,\"channel\":\"C123\",\"ts\":\"9999.0001\"}" },
    ) orelse return;
    defer deinitFauxServer(&s);
    const server_thread = try std.Thread.spawn(.{}, fauxSlackLoop, .{&s});
    defer server_thread.join();

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var client = Client.init(gpa, io, "xoxb-bot");
    defer client.deinit();
    client.base_url = base;

    var resp = try client.chatPostMessage(.{
        .channel = "C123",
        .text = "hello",
        .thread_ts = "1234.5678",
    });
    defer resp.deinit();

    try testing.expect(resp.value.ok);
    try testing.expectEqualStrings("9999.0001", resp.value.ts.?);
    try testing.expectEqualStrings("C123", resp.value.channel.?);
    try testing.expectEqualStrings("/chat.postMessage", s.captured_path.?);
    // Body must include all three fields.
    try testing.expect(std.mem.indexOf(u8, s.captured_body.?, "\"channel\":\"C123\"") != null);
    try testing.expect(std.mem.indexOf(u8, s.captured_body.?, "\"text\":\"hello\"") != null);
    try testing.expect(std.mem.indexOf(u8, s.captured_body.?, "\"thread_ts\":\"1234.5678\"") != null);
}

test "Client.chatUpdate: targets the correct ts" {
    var threaded = std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var s = bindFauxSlackServer(gpa, io,
        .{ .body = "{\"ok\":true,\"channel\":\"C123\",\"ts\":\"9999.0001\",\"text\":\"updated\"}" },
    ) orelse return;
    defer deinitFauxServer(&s);
    const server_thread = try std.Thread.spawn(.{}, fauxSlackLoop, .{&s});
    defer server_thread.join();

    const base = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/", .{s.port});
    defer gpa.free(base);

    var client = Client.init(gpa, io, "xoxb-bot");
    defer client.deinit();
    client.base_url = base;

    var resp = try client.chatUpdate(.{
        .channel = "C123",
        .ts = "9999.0001",
        .text = "updated",
    });
    defer resp.deinit();

    try testing.expect(resp.value.ok);
    try testing.expectEqualStrings("/chat.update", s.captured_path.?);
    try testing.expect(std.mem.indexOf(u8, s.captured_body.?, "\"ts\":\"9999.0001\"") != null);
    try testing.expect(std.mem.indexOf(u8, s.captured_body.?, "\"text\":\"updated\"") != null);
}
