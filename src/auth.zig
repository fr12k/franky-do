//! Workspace auth storage (§9 of franky-do.md).
//!
//! On-disk layout (under `$FRANKY_DO_HOME/workspaces/<team_id>/`):
//!
//!   auth.json
//!     {
//!       "team_id":   "T0123456",
//!       "team_name": "Acme",
//!       "app_token": "xapp-…",
//!       "bot_token": "xoxb-…",
//!       "bot_user_id": "U…",
//!       "installed_at_ms": 1700000000000
//!     }
//!
//! Atomic writes: tempfile + rename, mirroring franky's
//! session.zig pattern. Uses `std.Io.Dir.cwd()` so file ops go
//! through the franky `io` (matches the rest of franky-do).

const std = @import("std");

pub const AuthError = error{
    InvalidJson,
    InvalidWorkspace,
    NotInstalled,
} || std.mem.Allocator.Error;

pub const Auth = struct {
    team_id: []const u8,
    team_name: []const u8 = "",
    app_token: []const u8,
    bot_token: []const u8,
    bot_user_id: []const u8 = "",
    installed_at_ms: i64 = 0,

    /// Free strings dup'd by `read`. Caller-side: only call this
    /// on Auth values that came from `read` — never on inline
    /// constructions.
    pub fn deinit(self: *Auth, allocator: std.mem.Allocator) void {
        allocator.free(self.team_id);
        allocator.free(self.team_name);
        allocator.free(self.app_token);
        allocator.free(self.bot_token);
        allocator.free(self.bot_user_id);
    }
};

/// Persist `auth` to `<home_dir>/workspaces/<team_id>/auth.json`.
/// Atomic via tempfile + rename.
pub fn write(
    allocator: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    a: Auth,
) !void {
    if (a.team_id.len == 0) return AuthError.InvalidWorkspace;
    if (a.app_token.len == 0 or a.bot_token.len == 0) return AuthError.InvalidWorkspace;

    const dir_path = try std.fmt.allocPrint(
        allocator,
        "{s}/workspaces/{s}",
        .{ home_dir, a.team_id },
    );
    defer allocator.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    var json_buf: std.ArrayList(u8) = .empty;
    defer json_buf.deinit(allocator);
    try renderAuthJson(allocator, &json_buf, a);

    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/auth.json",
        .{dir_path},
    );
    defer allocator.free(path);
    try atomicWriteFile(io, allocator, path, json_buf.items);
}

/// Load auth for `team_id`. Returns `AuthError.NotInstalled` if
/// no auth.json exists for that workspace.
pub fn read(
    allocator: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    team_id: []const u8,
) !Auth {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/workspaces/{s}/auth.json",
        .{ home_dir, team_id },
    );
    defer allocator.free(path);

    const cwd = std.Io.Dir.cwd();
    var f = cwd.openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return AuthError.NotInstalled,
        else => return e,
    };
    defer f.close(io);
    const len = try f.length(io);
    if (len > 16 * 1024) return AuthError.InvalidJson;
    const buf = try allocator.alloc(u8, @intCast(len));
    defer allocator.free(buf);
    const n = try f.readPositionalAll(io, buf, 0);

    return parseAuthJson(allocator, buf[0..n]);
}

/// List all installed workspace IDs (top-level dirs under
/// `<home_dir>/workspaces/`). Caller frees via `freeList`.
pub fn list(
    allocator: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
) ![][]u8 {
    var result: std.ArrayList([]u8) = .empty;
    errdefer {
        for (result.items) |s| allocator.free(s);
        result.deinit(allocator);
    }

    const ws_path = try std.fmt.allocPrint(allocator, "{s}/workspaces", .{home_dir});
    defer allocator.free(ws_path);

    var dir = std.Io.Dir.cwd().openDir(io, ws_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return try result.toOwnedSlice(allocator),
        else => return e,
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        // Sanity: only accept Slack-shape team IDs ("T" + alnum).
        if (entry.name.len < 2 or entry.name[0] != 'T') continue;
        const owned = try allocator.dupe(u8, entry.name);
        try result.append(allocator, owned);
    }
    return try result.toOwnedSlice(allocator);
}

/// Remove `<home_dir>/workspaces/<team_id>/` recursively. No-op
/// if the dir doesn't exist.
pub fn uninstall(
    allocator: std.mem.Allocator,
    io: std.Io,
    home_dir: []const u8,
    team_id: []const u8,
) !void {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/workspaces/{s}",
        .{ home_dir, team_id },
    );
    defer allocator.free(path);

    // deleteTree's error set doesn't include FileNotFound — it
    // walks the tree and skips already-missing entries. Just call
    // it directly.
    try std.Io.Dir.cwd().deleteTree(io, path);
}

pub fn freeList(allocator: std.mem.Allocator, items: [][]u8) void {
    for (items) |s| allocator.free(s);
    allocator.free(items);
}

// ─── Atomic file write ─────────────────────────────────────────────

var tmp_counter = std.atomic.Value(u64).init(0);

fn atomicWriteFile(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    bytes: []const u8,
) !void {
    const counter = tmp_counter.fetchAdd(1, .monotonic);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp.{d}", .{ path, counter });
    defer allocator.free(tmp_path);

    const cwd = std.Io.Dir.cwd();
    {
        var f = try cwd.createFile(io, tmp_path, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, bytes);
        f.sync(io) catch {};
    }
    cwd.rename(tmp_path, cwd, path, io) catch |e| {
        cwd.deleteFile(io, tmp_path) catch {};
        return e;
    };
}

// ─── JSON marshal/unmarshal ────────────────────────────────────────

fn renderAuthJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    a: Auth,
) !void {
    try out.append(allocator, '{');
    try jsonStr(allocator, out, "team_id", a.team_id);
    try out.append(allocator, ',');
    try jsonStr(allocator, out, "team_name", a.team_name);
    try out.append(allocator, ',');
    try jsonStr(allocator, out, "app_token", a.app_token);
    try out.append(allocator, ',');
    try jsonStr(allocator, out, "bot_token", a.bot_token);
    try out.append(allocator, ',');
    try jsonStr(allocator, out, "bot_user_id", a.bot_user_id);
    try out.appendSlice(allocator, ",\"installed_at_ms\":");
    var num: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num, "{d}", .{a.installed_at_ms}) catch unreachable;
    try out.appendSlice(allocator, num_str);
    try out.append(allocator, '}');
}

fn jsonStr(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    name: []const u8,
    value: []const u8,
) !void {
    try out.append(allocator, '"');
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, "\":\"");
    for (value) |c| switch (c) {
        '"' => try out.appendSlice(allocator, "\\\""),
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        0...0x07, 0x0b, 0x0e...0x1f => {
            var tmp: [8]u8 = undefined;
            const w = std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}) catch unreachable;
            try out.appendSlice(allocator, w);
        },
        else => try out.append(allocator, c),
    };
    try out.append(allocator, '"');
}

const RawAuth = struct {
    team_id: []const u8 = "",
    team_name: []const u8 = "",
    app_token: []const u8 = "",
    bot_token: []const u8 = "",
    bot_user_id: []const u8 = "",
    installed_at_ms: i64 = 0,
};

fn parseAuthJson(allocator: std.mem.Allocator, bytes: []const u8) !Auth {
    const parsed = std.json.parseFromSlice(RawAuth, allocator, bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return AuthError.InvalidJson;
    defer parsed.deinit();
    if (parsed.value.team_id.len == 0) return AuthError.InvalidJson;
    if (parsed.value.app_token.len == 0 or parsed.value.bot_token.len == 0) return AuthError.InvalidJson;

    return .{
        .team_id = try allocator.dupe(u8, parsed.value.team_id),
        .team_name = try allocator.dupe(u8, parsed.value.team_name),
        .app_token = try allocator.dupe(u8, parsed.value.app_token),
        .bot_token = try allocator.dupe(u8, parsed.value.bot_token),
        .bot_user_id = try allocator.dupe(u8, parsed.value.bot_user_id),
        .installed_at_ms = parsed.value.installed_at_ms,
    };
}

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

var test_home_counter = std.atomic.Value(u64).init(0);

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
}

fn tempHomeDir(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const seq = test_home_counter.fetchAdd(1, .monotonic);
    const path = try std.fmt.allocPrint(
        allocator,
        "/tmp/franky-do-test-home-{d}",
        .{seq},
    );
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn cleanupHomeDir(io: std.Io, home: []const u8) void {
    _ = std.Io.Dir.cwd().deleteTree(io, home) catch {};
}

test "Auth: write + read round-trip" {
    var t = testIo();
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const home = try tempHomeDir(gpa, io);
    defer {
        cleanupHomeDir(io, home);
        gpa.free(home);
    }

    try write(gpa, io, home, .{
        .team_id = "T01TEAM",
        .team_name = "Acme Corp",
        .app_token = "xapp-1-X-Y-Z",
        .bot_token = "xoxb-1-A-B-C",
        .bot_user_id = "UBOT",
        .installed_at_ms = 1_700_000_000_000,
    });

    var loaded = try read(gpa, io, home, "T01TEAM");
    defer loaded.deinit(gpa);
    try testing.expectEqualStrings("T01TEAM", loaded.team_id);
    try testing.expectEqualStrings("Acme Corp", loaded.team_name);
    try testing.expectEqualStrings("xapp-1-X-Y-Z", loaded.app_token);
    try testing.expectEqualStrings("xoxb-1-A-B-C", loaded.bot_token);
    try testing.expectEqualStrings("UBOT", loaded.bot_user_id);
    try testing.expectEqual(@as(i64, 1_700_000_000_000), loaded.installed_at_ms);
}

test "Auth: read on missing workspace returns NotInstalled" {
    var t = testIo();
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const home = try tempHomeDir(gpa, io);
    defer {
        cleanupHomeDir(io, home);
        gpa.free(home);
    }

    try testing.expectError(AuthError.NotInstalled, read(gpa, io, home, "T_MISSING"));
}

test "Auth: list enumerates installed workspaces" {
    var t = testIo();
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const home = try tempHomeDir(gpa, io);
    defer {
        cleanupHomeDir(io, home);
        gpa.free(home);
    }

    const teams = [_][]const u8{ "T01ALPHA", "T02BETA", "T03GAMMA" };
    for (teams) |tt| {
        try write(gpa, io, home, .{
            .team_id = tt,
            .app_token = "xapp-x",
            .bot_token = "xoxb-x",
        });
    }

    const found = try list(gpa, io, home);
    defer freeList(gpa, found);
    try testing.expectEqual(@as(usize, 3), found.len);
    var saw_alpha = false;
    var saw_beta = false;
    var saw_gamma = false;
    for (found) |id| {
        if (std.mem.eql(u8, id, "T01ALPHA")) saw_alpha = true;
        if (std.mem.eql(u8, id, "T02BETA")) saw_beta = true;
        if (std.mem.eql(u8, id, "T03GAMMA")) saw_gamma = true;
    }
    try testing.expect(saw_alpha and saw_beta and saw_gamma);
}

test "Auth: list on empty home returns empty slice" {
    var t = testIo();
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const home = try tempHomeDir(gpa, io);
    defer {
        cleanupHomeDir(io, home);
        gpa.free(home);
    }

    const found = try list(gpa, io, home);
    defer freeList(gpa, found);
    try testing.expectEqual(@as(usize, 0), found.len);
}

test "Auth: uninstall removes workspace dir" {
    var t = testIo();
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const home = try tempHomeDir(gpa, io);
    defer {
        cleanupHomeDir(io, home);
        gpa.free(home);
    }

    try write(gpa, io, home, .{
        .team_id = "T01GONE",
        .app_token = "xapp-x",
        .bot_token = "xoxb-x",
    });
    try uninstall(gpa, io, home, "T01GONE");
    try testing.expectError(AuthError.NotInstalled, read(gpa, io, home, "T01GONE"));
}

test "Auth: write rejects empty team_id" {
    var t = testIo();
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const home = try tempHomeDir(gpa, io);
    defer {
        cleanupHomeDir(io, home);
        gpa.free(home);
    }

    try testing.expectError(AuthError.InvalidWorkspace, write(gpa, io, home, .{
        .team_id = "",
        .app_token = "xapp-x",
        .bot_token = "xoxb-x",
    }));
}

test "Auth: write rejects empty tokens" {
    var t = testIo();
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const home = try tempHomeDir(gpa, io);
    defer {
        cleanupHomeDir(io, home);
        gpa.free(home);
    }

    try testing.expectError(AuthError.InvalidWorkspace, write(gpa, io, home, .{
        .team_id = "T01X",
        .app_token = "",
        .bot_token = "xoxb-x",
    }));
}
