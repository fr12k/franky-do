//! Per-bot mapping `(team_id, thread_ts) → franky session ULID`.
//! Phase 3: in-memory only. Phase 5 adds persistence to
//! `bindings.json`.
//!
//! See franky-do.md §5 for the model.

const std = @import("std");

pub const Map = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Keys are owned `team_id ":" thread_ts` strings; values are
    /// owned ULID strings. The map's StringHashMap doesn't dupe;
    /// we do.
    map: std.StringHashMap([]u8),
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Map {
        return .{
            .allocator = allocator,
            .io = io,
            .map = std.StringHashMap([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Map) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    /// Returns the ULID for `(team_id, thread_ts)`, or null if no
    /// mapping exists yet. Returned slice is borrowed — owned by
    /// the map; valid until the next `set`/`reset`/`deinit` call
    /// for the same key.
    pub fn get(self: *Map, team_id: []const u8, thread_ts: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var key_buf: [256]u8 = undefined;
        const key = compositeKey(&key_buf, team_id, thread_ts) catch return null;
        return self.map.get(key);
    }

    /// Bind `(team_id, thread_ts) → ulid`. Replaces any prior
    /// mapping for the same key (the previous ULID is freed).
    pub fn set(self: *Map, team_id: []const u8, thread_ts: []const u8, ulid: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var key_buf: [256]u8 = undefined;
        const key_slice = try compositeKey(&key_buf, team_id, thread_ts);

        if (self.map.fetchRemove(key_slice)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        const owned_key = try self.allocator.dupe(u8, key_slice);
        errdefer self.allocator.free(owned_key);
        const owned_ulid = try self.allocator.dupe(u8, ulid);
        errdefer self.allocator.free(owned_ulid);
        try self.map.put(owned_key, owned_ulid);
    }

    /// Remove the mapping if any. Returns whether something was
    /// freed.
    pub fn reset(self: *Map, team_id: []const u8, thread_ts: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var key_buf: [256]u8 = undefined;
        const key_slice = compositeKey(&key_buf, team_id, thread_ts) catch return false;
        if (self.map.fetchRemove(key_slice)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
            return true;
        }
        return false;
    }

    /// `team_id ":" thread_ts` rendered into the caller's buffer.
    /// Returns a slice into the buffer.
    fn compositeKey(buf: []u8, team_id: []const u8, thread_ts: []const u8) ![]u8 {
        return try std.fmt.bufPrint(buf, "{s}:{s}", .{ team_id, thread_ts });
    }

    pub fn count(self: *Map) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.map.count();
    }

    /// Render the map to JSON: `{"<thread_ts>": "<ulid>", ...}`.
    /// `team_id` is split off into the `<home_dir>/workspaces/<team_id>/`
    /// path; we only save thread→ulid pairs that match `team_id`.
    pub fn persistToDisk(
        self: *Map,
        home_dir: []const u8,
        team_id: []const u8,
    ) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);
        try json.append(self.allocator, '{');
        var first = true;
        var it = self.map.iterator();
        const prefix = try std.fmt.allocPrint(self.allocator, "{s}:", .{team_id});
        defer self.allocator.free(prefix);
        while (it.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
            const thread_ts = entry.key_ptr.*[prefix.len..];
            if (!first) try json.append(self.allocator, ',');
            first = false;
            try json.append(self.allocator, '"');
            try json.appendSlice(self.allocator, thread_ts);
            try json.appendSlice(self.allocator, "\":\"");
            try json.appendSlice(self.allocator, entry.value_ptr.*);
            try json.append(self.allocator, '"');
        }
        try json.append(self.allocator, '}');

        const dir_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/workspaces/{s}",
            .{ home_dir, team_id },
        );
        defer self.allocator.free(dir_path);
        try std.Io.Dir.cwd().createDirPath(self.io, dir_path);

        const path = try std.fmt.allocPrint(self.allocator, "{s}/bindings.json", .{dir_path});
        defer self.allocator.free(path);

        const counter = persist_tmp_counter.fetchAdd(1, .monotonic);
        const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.tmp.{d}", .{ path, counter });
        defer self.allocator.free(tmp_path);

        const cwd = std.Io.Dir.cwd();
        {
            var f = try cwd.createFile(self.io, tmp_path, .{});
            defer f.close(self.io);
            try f.writeStreamingAll(self.io, json.items);
            f.sync(self.io) catch {};
        }
        cwd.rename(tmp_path, cwd, path, self.io) catch |e| {
            cwd.deleteFile(self.io, tmp_path) catch {};
            return e;
        };
    }

    /// Re-populate the map from `bindings.json`. Replaces any
    /// existing in-memory state for this team. No-op if no
    /// bindings file exists yet.
    pub fn loadFromDisk(
        self: *Map,
        home_dir: []const u8,
        team_id: []const u8,
    ) !void {
        const path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/workspaces/{s}/bindings.json",
            .{ home_dir, team_id },
        );
        defer self.allocator.free(path);

        const cwd = std.Io.Dir.cwd();
        var f = cwd.openFile(self.io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return, // no bindings yet — nothing to load
            else => return e,
        };
        defer f.close(self.io);

        const len = try f.length(self.io);
        if (len > 1024 * 1024) return error.BindingsTooLarge;
        const buf = try self.allocator.alloc(u8, @intCast(len));
        defer self.allocator.free(buf);
        const n = try f.readPositionalAll(self.io, buf, 0);

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            buf[0..n],
            .{ .ignore_unknown_fields = true },
        ) catch return error.InvalidBindingsJson;
        defer parsed.deinit();

        if (parsed.value != .object) return error.InvalidBindingsJson;

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const thread_ts = entry.key_ptr.*;
            const ulid_val = entry.value_ptr.*;
            if (ulid_val != .string) continue;
            try self.set(team_id, thread_ts, ulid_val.string);
        }
    }
};

var persist_tmp_counter = std.atomic.Value(u64).init(0);

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
}

test "Map: get returns null on miss" {
    var t = testIo();
    defer t.deinit();
    var m = Map.init(testing.allocator, t.io());
    defer m.deinit();
    try testing.expectEqual(@as(?[]const u8, null), m.get("T1", "1.0"));
}

test "Map: set then get" {
    var t = testIo();
    defer t.deinit();
    var m = Map.init(testing.allocator, t.io());
    defer m.deinit();
    try m.set("T1", "1.0", "01ULID");
    try testing.expectEqualStrings("01ULID", m.get("T1", "1.0").?);
}

test "Map: distinct teams don't collide" {
    var t = testIo();
    defer t.deinit();
    var m = Map.init(testing.allocator, t.io());
    defer m.deinit();
    try m.set("T1", "1.0", "01A");
    try m.set("T2", "1.0", "01B");
    try testing.expectEqualStrings("01A", m.get("T1", "1.0").?);
    try testing.expectEqualStrings("01B", m.get("T2", "1.0").?);
}

test "Map: distinct threads don't collide" {
    var t = testIo();
    defer t.deinit();
    var m = Map.init(testing.allocator, t.io());
    defer m.deinit();
    try m.set("T1", "1.0", "01A");
    try m.set("T1", "2.0", "01B");
    try testing.expectEqualStrings("01A", m.get("T1", "1.0").?);
    try testing.expectEqualStrings("01B", m.get("T1", "2.0").?);
}

test "Map: set on existing key replaces" {
    var t = testIo();
    defer t.deinit();
    var m = Map.init(testing.allocator, t.io());
    defer m.deinit();
    try m.set("T1", "1.0", "old");
    try m.set("T1", "1.0", "new");
    try testing.expectEqualStrings("new", m.get("T1", "1.0").?);
    try testing.expectEqual(@as(usize, 1), m.count());
}

test "Map: reset removes the binding" {
    var t = testIo();
    defer t.deinit();
    var m = Map.init(testing.allocator, t.io());
    defer m.deinit();
    try m.set("T1", "1.0", "01A");
    try testing.expect(m.reset("T1", "1.0"));
    try testing.expectEqual(@as(?[]const u8, null), m.get("T1", "1.0"));
}

test "Map: reset on missing key returns false" {
    var t = testIo();
    defer t.deinit();
    var m = Map.init(testing.allocator, t.io());
    defer m.deinit();
    try testing.expect(!m.reset("T1", "missing"));
}

var persist_test_counter = std.atomic.Value(u64).init(0);

fn tempPersistHome(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const seq = persist_test_counter.fetchAdd(1, .monotonic);
    const path = try std.fmt.allocPrint(allocator, "/tmp/franky-do-persist-{d}", .{seq});
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}

fn cleanupPersistHome(io: std.Io, path: []const u8) void {
    _ = std.Io.Dir.cwd().deleteTree(io, path) catch {};
}

test "Map: persistToDisk + loadFromDisk round-trip" {
    var t = testIo();
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const home = try tempPersistHome(gpa, io);
    defer {
        cleanupPersistHome(io, home);
        gpa.free(home);
    }

    var m1 = Map.init(gpa, io);
    defer m1.deinit();
    try m1.set("T1", "1700000000.000100", "01ULID_A");
    try m1.set("T1", "1700000001.000200", "01ULID_B");
    try m1.set("T2", "1700000002.000300", "01ULID_C"); // different team — must not bleed
    try m1.persistToDisk(home, "T1");

    var m2 = Map.init(gpa, io);
    defer m2.deinit();
    try m2.loadFromDisk(home, "T1");

    try testing.expectEqual(@as(usize, 2), m2.count());
    try testing.expectEqualStrings("01ULID_A", m2.get("T1", "1700000000.000100").?);
    try testing.expectEqualStrings("01ULID_B", m2.get("T1", "1700000001.000200").?);
    // T2's binding wasn't saved into T1's bindings file.
    try testing.expectEqual(@as(?[]const u8, null), m2.get("T2", "1700000002.000300"));
}

test "Map: loadFromDisk on missing file is a no-op" {
    var t = testIo();
    defer t.deinit();
    const io = t.io();
    const gpa = testing.allocator;

    const home = try tempPersistHome(gpa, io);
    defer {
        cleanupPersistHome(io, home);
        gpa.free(home);
    }

    var m = Map.init(gpa, io);
    defer m.deinit();
    try m.loadFromDisk(home, "T_NEVER_INSTALLED");
    try testing.expectEqual(@as(usize, 0), m.count());
}
