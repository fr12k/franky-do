//! v0.3.1 — persist + reload Agents to/from disk.
//!
//! `persist(allocator, io, session_dir, agent, model_id, …)` writes
//! `<session_dir>/{session.json,transcript.json}` via franky's
//! `coding/session.zig` AND a sibling `franky_do.json` carrying the
//! franky-do-specific metadata (last activity timestamp, future
//! per-thread cwd).
//!
//! `load(allocator, io, parent_dir, ulid, agent_cfg)` reads the
//! mirror image and returns a freshly-initialized `Agent` ready for
//! `subscribe` + `prompt`. Returns `error.SessionNotFound` if no
//! `transcript.json` exists for that ULID — the caller should mint
//! a fresh Agent in that case (clean cache miss).
//!
//! **Compaction trigger (deferred to v0.3.1.1)**. Per design C.3.6
//! a transcript exceeding 0.8 × context_window should be compacted
//! before the next turn. v0.3.1 logs a warning at that threshold
//! but does NOT run compaction — the franky-core `coding.compaction`
//! API requires a `branching.Tree` + an LLM round-trip we don't
//! want to add here. v0.3.1.1 will wire it. Until then, the worst
//! case is `context_overflow` on the next turn (an explicit error
//! the user can `/franky-do reset` past).

const std = @import("std");
const franky = @import("franky");
const ai = franky.ai;
const agent_mod = franky.agent;
const at = agent_mod.types;
const session_mod = franky.coding.session;
const auth_mod = franky.coding.auth;
const compaction_mod = franky.coding.compaction;

pub const HibernateError = error{
    /// `<parent_dir>/<ulid>/transcript.json` doesn't exist. The
    /// caller mints a fresh Agent in that case.
    SessionNotFound,
    /// Disk error during session.json/transcript.json read or
    /// `franky_do.json` write. Distinguished from
    /// `error.SessionNotFound`: this is real corruption / permission
    /// failure, the caller should warn-then-mint-fresh.
    HibernateIoFailed,
    InvalidSessionDir,
} || std.mem.Allocator.Error;

/// Write the agent's transcript + header + `franky_do.json` into
/// `<session_dir>`. Best-effort: callers wrap in a `catch` and log.
///
/// `session_dir` is the FULL path including the ULID
/// (`<home>/workspaces/<team>/sessions/<ulid>`). franky's
/// `session.save` takes a `parent_dir`, not `session_dir`, so we
/// split here.
pub fn persist(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    agent: *agent_mod.Agent,
    model_id: []const u8,
    model_provider: []const u8,
    model_api: []const u8,
    system_prompt: []const u8,
) !void {
    // session.save wants <parent>/<id> = parent + ulid. Split.
    const parent_dir = std.fs.path.dirname(session_dir) orelse return error.InvalidSessionDir;
    const ulid = std.fs.path.basename(session_dir);

    const sys_hash_hex = try session_mod.sha256Hex(allocator, system_prompt);
    defer allocator.free(sys_hash_hex);

    const now_ms = ai.stream.nowMillis();
    const header: session_mod.SessionHeader = .{
        .id = ulid,
        .created_at_ms = now_ms,
        .updated_at_ms = now_ms,
        .title = "",
        .provider = model_provider,
        .model = model_id,
        .api = model_api,
        .thinking_level = "off",
        .active_branch = "main",
        .system_prompt_hash = sys_hash_hex,
    };

    try session_mod.save(allocator, io, parent_dir, header, &agent.transcript);

    // v0.3.1 — `franky_do.json`. Currently just the last-activity
    // timestamp; v0.3.2+ adds per-thread cwd + custom prompt overlay
    // when those become persistent state.
    try writeFrankyDoMeta(allocator, io, session_dir, .{
        .last_active_ms = ai.stream.nowMillis(),
    });
}

/// Read `<parent_dir>/<ulid>/transcript.json` and return an Agent
/// initialized with `cfg` plus the loaded transcript. Returns
/// `error.SessionNotFound` if `transcript.json` is missing — caller
/// should treat that as "first interaction in this thread."
pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    parent_dir: []const u8,
    ulid: []const u8,
    cfg: agent_mod.Agent.Config,
) HibernateError!agent_mod.Agent {
    const session_dir = try std.fs.path.join(allocator, &.{ parent_dir, ulid });
    defer allocator.free(session_dir);

    // Probe for transcript.json; absence = clean miss.
    const transcript_path = try std.fs.path.join(allocator, &.{ session_dir, "transcript.json" });
    defer allocator.free(transcript_path);
    {
        const f = std.Io.Dir.cwd().openFile(io, transcript_path, .{}) catch |e| switch (e) {
            error.FileNotFound => return error.SessionNotFound,
            else => return error.HibernateIoFailed,
        };
        f.close(io);
    }

    const loaded_session = session_mod.load(allocator, io, parent_dir, ulid) catch |e| switch (e) {
        error.FileNotFound => return error.SessionNotFound,
        else => return error.HibernateIoFailed,
    };
    defer session_mod.freeSessionHeader(allocator, loaded_session.header);

    var agent = agent_mod.Agent.init(allocator, io, cfg) catch return error.HibernateIoFailed;
    errdefer agent.deinit();

    // Hand the loaded transcript into the agent. agent_mod.Agent.init
    // creates an empty transcript; replace with the loaded one and
    // free the empty placeholder.
    agent.transcript.deinit();
    agent.transcript = loaded_session.transcript;

    // v0.3.1 — context-window threshold check. franky's
    // `compaction.shouldTrigger` returns `.soft` at 80% / `.hard` at
    // 92%. We warn at `.soft` so operators have a heads-up; actual
    // compaction is v0.3.1.1.
    {
        var total_bytes: usize = 0;
        for (agent.transcript.messages.items) |m| {
            for (m.content) |cb| {
                switch (cb) {
                    .text => |t| total_bytes += t.text.len,
                    .thinking => |th| total_bytes += th.thinking.len,
                    .tool_call => |tc| total_bytes += tc.arguments_json.len + tc.name.len,
                    .image => {},
                }
            }
        }
        const tokens_est = compaction_mod.estimateFromLen(total_bytes, .english);
        const window: u32 = 200_000; // conservative default; real window per model
        const trigger = compaction_mod.shouldTrigger(tokens_est, window);
        if (trigger != .none) {
            ai.log.log(.warn, "franky-do", "hibernate", "rehydrated transcript estimated {d} tokens ({s}); compaction-on-reload deferred to v0.3.1.1 — next turn may hit context_overflow", .{
                tokens_est, @tagName(trigger),
            });
        }
    }

    return agent;
}

const FrankyDoMeta = struct {
    last_active_ms: i64 = 0,
};

fn writeFrankyDoMeta(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    meta: FrankyDoMeta,
) !void {
    const path = try std.fs.path.join(allocator, &.{ session_dir, "franky_do.json" });
    defer allocator.free(path);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"last_active_ms\":");
    var num: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num, "{d}", .{meta.last_active_ms}) catch unreachable;
    try buf.appendSlice(allocator, num_str);
    try buf.appendSlice(allocator, "}\n");

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, session_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var f = try cwd.createFile(io, path, .{});
    defer f.close(io);
    try f.writeStreamingAll(io, buf.items);
    f.sync(io) catch {};
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const fp: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try fp.runSync(ctx.io, ctx.context, ctx.out);
}

test "persist + load: fresh agent round-trips transcript through disk" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_do_hibernate_test";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    const cfg: agent_mod.Agent.Config = .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .system_prompt = "test sys prompt",
        .registry = &reg,
    };

    // Seed an Agent with one user + one assistant message.
    var agent = try agent_mod.Agent.init(gpa, io, cfg);
    defer agent.deinit();

    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "hello") } };
        try agent.transcript.append(.{ .role = .user, .content = blocks, .timestamp = 1 });
    }
    {
        const blocks = try gpa.alloc(ai.types.ContentBlock, 1);
        blocks[0] = .{ .text = .{ .text = try gpa.dupe(u8, "world") } };
        try agent.transcript.append(.{ .role = .assistant, .content = blocks, .timestamp = 2 });
    }

    const ulid = "01TESTSESSION0000000000000";
    const session_dir = try std.fs.path.join(gpa, &.{ base, ulid });
    defer gpa.free(session_dir);

    try persist(gpa, io, session_dir, &agent, "faux-1", "faux", "faux", "test sys prompt");

    // Verify both files landed.
    const transcript_path = try std.fs.path.join(gpa, &.{ session_dir, "transcript.json" });
    defer gpa.free(transcript_path);
    const meta_path = try std.fs.path.join(gpa, &.{ session_dir, "franky_do.json" });
    defer gpa.free(meta_path);
    {
        var f = try std.Io.Dir.cwd().openFile(io, transcript_path, .{});
        f.close(io);
    }
    {
        var f = try std.Io.Dir.cwd().openFile(io, meta_path, .{});
        f.close(io);
    }

    // Reload into a fresh Agent and assert the transcript matches.
    var loaded = try load(gpa, io, base, ulid, cfg);
    defer loaded.deinit();
    try testing.expectEqual(@as(usize, 2), loaded.transcript.messages.items.len);
    try testing.expectEqualStrings("hello", loaded.transcript.messages.items[0].content[0].text.text);
    try testing.expectEqualStrings("world", loaded.transcript.messages.items[1].content[0].text.text);
}

test "load: missing transcript.json returns SessionNotFound" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    const base = "/tmp/franky_do_hibernate_missing";
    _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    defer _ = std.Io.Dir.cwd().deleteTree(io, base) catch {};
    try std.Io.Dir.cwd().createDirPath(io, base);

    var faux = ai.providers.faux.FauxProvider.init(gpa);
    defer faux.deinit();
    var reg = ai.registry.Registry.init(gpa);
    defer reg.deinit();
    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(&faux),
    });

    const cfg: agent_mod.Agent.Config = .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = &reg,
    };
    const result = load(gpa, io, base, "01ULIDTHATDOESNOTEXIST00000", cfg);
    try testing.expectError(error.SessionNotFound, result);
}
