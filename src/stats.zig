//! Phase 8 — token + cost aggregation across persisted sessions.
//!
//! Walks `<home>/sessions/<ulid>/` directories, parses each
//! `session.json` for the model id and each `transcript.json` for
//! per-message `usage.input` / `usage.output`, sums per session,
//! and computes USD cost via `pricing.lookup`. Renders a
//! Markdown-style table to stdout from the `cmdStats` driver in
//! `main.zig`.
//!
//! Per-thread context (joining `(team_id, thread_ts)` to ULID via
//! workspaces' `bindings.json`) is the post-Phase-8 nice-to-have;
//! v0.1 keys on ULID alone, which is enough to spot the high-cost
//! sessions in any single workspace.

const std = @import("std");
const franky = @import("franky");
const session_mod = franky.coding.session;
const pricing = @import("pricing.zig");

pub const SessionStats = struct {
    ulid: []u8,
    model: []u8,
    input_tokens: u64,
    output_tokens: u64,
    /// Optional — null when the model id isn't in the pricing table.
    cost_usd: ?f64,

    pub fn deinit(self: *SessionStats, allocator: std.mem.Allocator) void {
        allocator.free(self.ulid);
        allocator.free(self.model);
    }
};

pub const Aggregate = struct {
    sessions: []SessionStats,
    total_input: u64,
    total_output: u64,
    /// Sum of session costs that had a known model. Sessions with
    /// unknown models are excluded; surface that gap by comparing
    /// `priced_session_count` to `sessions.len`.
    total_cost_usd: f64,
    priced_session_count: usize,

    pub fn deinit(self: *Aggregate, allocator: std.mem.Allocator) void {
        for (self.sessions) |*s| s.deinit(allocator);
        allocator.free(self.sessions);
    }
};

/// Walk `<home>/sessions/*` and return aggregated stats. Sessions
/// whose `session.json` or `transcript.json` is unreadable get
/// silently skipped — the dashboard is best-effort, not a
/// correctness check.
pub fn collect(
    allocator: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
) !Aggregate {
    var result: std.ArrayList(SessionStats) = .empty;
    errdefer {
        for (result.items) |*s| s.deinit(allocator);
        result.deinit(allocator);
    }

    const sessions_dir = try std.fmt.allocPrint(allocator, "{s}/sessions", .{home_dir});
    defer allocator.free(sessions_dir);

    var dir = std.Io.Dir.cwd().openDir(io, sessions_dir, .{ .iterate = true }) catch |e| switch (e) {
        // No sessions yet — return an empty aggregate rather than erroring.
        error.FileNotFound => {
            const empty = try result.toOwnedSlice(allocator);
            return .{
                .sessions = empty,
                .total_input = 0,
                .total_output = 0,
                .total_cost_usd = 0,
                .priced_session_count = 0,
            };
        },
        else => return e,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // ULIDs are 26 chars Crockford base32 — anything else is
        // a stray dir, skip.
        if (entry.name.len != 26) continue;
        const session_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ sessions_dir, entry.name });
        defer allocator.free(session_dir);

        var stats = collectOne(allocator, io, session_dir, entry.name) catch continue;
        errdefer stats.deinit(allocator);
        try result.append(allocator, stats);
    }

    var total_in: u64 = 0;
    var total_out: u64 = 0;
    var total_cost: f64 = 0;
    var priced: usize = 0;
    for (result.items) |s| {
        total_in += s.input_tokens;
        total_out += s.output_tokens;
        if (s.cost_usd) |c| {
            total_cost += c;
            priced += 1;
        }
    }

    const owned = try result.toOwnedSlice(allocator);
    return .{
        .sessions = owned,
        .total_input = total_in,
        .total_output = total_out,
        .total_cost_usd = total_cost,
        .priced_session_count = priced,
    };
}

fn collectOne(
    allocator: std.mem.Allocator,
    io: std.Io,
    session_dir: []const u8,
    ulid: []const u8,
) !SessionStats {
    const model = try readSessionModel(allocator, io, session_dir);
    errdefer allocator.free(model);

    var transcript = session_mod.readTranscript(allocator, io, session_dir) catch |e| switch (e) {
        error.FileNotFound => return SessionStats{
            .ulid = try allocator.dupe(u8, ulid),
            .model = model,
            .input_tokens = 0,
            .output_tokens = 0,
            .cost_usd = pricing.estimate(model, 0, 0),
        },
        else => return e,
    };
    defer transcript.deinit();

    var input: u64 = 0;
    var output: u64 = 0;
    for (transcript.messages.items) |m| {
        if (m.usage) |u| {
            input += u.input;
            output += u.output;
        }
    }

    return .{
        .ulid = try allocator.dupe(u8, ulid),
        .model = model,
        .input_tokens = input,
        .output_tokens = output,
        .cost_usd = pricing.estimate(model, input, output),
    };
}

/// Read just the `model` field out of session.json without paying
/// for the full SessionHeader parse. Returns "(unknown)" when the
/// field is missing or malformed.
fn readSessionModel(allocator: std.mem.Allocator, io: std.Io, session_dir: []const u8) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/session.json", .{session_dir});
    defer allocator.free(path);

    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return allocator.dupe(u8, "(unknown)");
    defer f.close(io);

    const len = f.length(io) catch return allocator.dupe(u8, "(unknown)");
    if (len == 0 or len > 1 * 1024 * 1024) return allocator.dupe(u8, "(unknown)");
    const buf = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(buf);
    const n = f.readPositionalAll(io, buf, 0) catch return allocator.dupe(u8, "(unknown)");

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const parsed = std.json.parseFromSlice(std.json.Value, scratch.allocator(), buf[0..n], .{}) catch return allocator.dupe(u8, "(unknown)");
    if (parsed.value != .object) return allocator.dupe(u8, "(unknown)");
    const model_v = parsed.value.object.get("model") orelse return allocator.dupe(u8, "(unknown)");
    if (model_v != .string) return allocator.dupe(u8, "(unknown)");
    return allocator.dupe(u8, model_v.string);
}

/// Render the aggregate as a Markdown-style table.
pub fn render(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    agg: *const Aggregate,
) !void {
    if (agg.sessions.len == 0) {
        try out.appendSlice(allocator, "(no sessions found)\n");
        return;
    }

    try out.appendSlice(allocator, "ulid                       model                              input    output     cost\n");
    try out.appendSlice(allocator, "-------------------------- ---------------------------- --------- --------- --------\n");
    for (agg.sessions) |s| {
        const cost_str = try formatCost(allocator, s.cost_usd);
        defer allocator.free(cost_str);
        const line = try std.fmt.allocPrint(
            allocator,
            "{s} {s:<28} {d:>9} {d:>9} {s:>8}\n",
            .{ s.ulid, s.model, s.input_tokens, s.output_tokens, cost_str },
        );
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }

    const total_cost_str = try formatCost(allocator, if (agg.priced_session_count > 0) agg.total_cost_usd else null);
    defer allocator.free(total_cost_str);
    const totals = try std.fmt.allocPrint(
        allocator,
        "-------------------------- ---------------------------- --------- --------- --------\n" ++
            "{d} session(s){s:<22} {d:>9} {d:>9} {s:>8}\n",
        .{
            agg.sessions.len,
            "",
            agg.total_input,
            agg.total_output,
            total_cost_str,
        },
    );
    defer allocator.free(totals);
    try out.appendSlice(allocator, totals);

    if (agg.priced_session_count < agg.sessions.len) {
        const hint = try std.fmt.allocPrint(
            allocator,
            "\n({d} of {d} sessions have unknown-model pricing — totals exclude those)\n",
            .{ agg.sessions.len - agg.priced_session_count, agg.sessions.len },
        );
        defer allocator.free(hint);
        try out.appendSlice(allocator, hint);
    }
}

fn formatCost(allocator: std.mem.Allocator, cost: ?f64) ![]u8 {
    if (cost) |c| return std.fmt.allocPrint(allocator, "${d:.4}", .{c});
    return allocator.dupe(u8, "n/a");
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "render: empty aggregate" {
    const gpa = testing.allocator;
    const agg = Aggregate{
        .sessions = &[_]SessionStats{},
        .total_input = 0,
        .total_output = 0,
        .total_cost_usd = 0,
        .priced_session_count = 0,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try render(gpa, &out, &agg);
    try testing.expectEqualStrings("(no sessions found)\n", out.items);
}

test "render: single known-model session" {
    const gpa = testing.allocator;
    var sessions = [_]SessionStats{.{
        .ulid = try gpa.dupe(u8, "01JABCDEFGHJKMNPQRSTVWXYZ0"),
        .model = try gpa.dupe(u8, "claude-sonnet-4-6"),
        .input_tokens = 12_300,
        .output_tokens = 2_150,
        .cost_usd = pricing.estimate("claude-sonnet-4-6", 12_300, 2_150),
    }};
    defer for (&sessions) |*s| s.deinit(gpa);

    const agg = Aggregate{
        .sessions = sessions[0..],
        .total_input = 12_300,
        .total_output = 2_150,
        .total_cost_usd = sessions[0].cost_usd.?,
        .priced_session_count = 1,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try render(gpa, &out, &agg);
    try testing.expect(std.mem.indexOf(u8, out.items, "01JABCDEFGHJKMNPQRSTVWXYZ0") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "claude-sonnet-4-6") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "12300") != null);
    // 12.3k * 3 + 2.15k * 15 = $0.06915 (rounds to $0.0691 or $0.0692
    // depending on the last digit; both are correct).
    try testing.expect(std.mem.indexOf(u8, out.items, "$0.069") != null);
}

test "render: unknown-model session shows 'n/a' cost + hint" {
    const gpa = testing.allocator;
    var sessions = [_]SessionStats{.{
        .ulid = try gpa.dupe(u8, "01JABCDEFGHJKMNPQRSTVWXYZ1"),
        .model = try gpa.dupe(u8, "weird-model-x"),
        .input_tokens = 100,
        .output_tokens = 50,
        .cost_usd = null,
    }};
    defer for (&sessions) |*s| s.deinit(gpa);

    const agg = Aggregate{
        .sessions = sessions[0..],
        .total_input = 100,
        .total_output = 50,
        .total_cost_usd = 0,
        .priced_session_count = 0,
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try render(gpa, &out, &agg);
    try testing.expect(std.mem.indexOf(u8, out.items, "n/a") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "1 of 1 sessions have unknown-model pricing") != null);
}
