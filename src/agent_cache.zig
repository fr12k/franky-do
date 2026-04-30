//! ULID → `franky.agent.Agent` cache, with LRU + idle eviction
//! (v0.3.1).
//!
//! The cache **owns** each `Agent`. Eviction returns a `Victim`
//! that the caller is expected to persist (via
//! `agent_hibernate.persist`) before deinit'ing. This keeps the
//! cache focused on storage; persistence policy lives one layer up
//! in `bot.zig`.
//!
//! Two eviction triggers:
//!
//!   1. **Capacity-driven** — `tryPut` enforces `cap`; the
//!      least-recently-accessed entry is returned as `Victim`.
//!   2. **Idle-driven** — `popIdleOlderThan(ms)` returns every
//!      entry whose `last_access_ms` is older than the threshold,
//!      for the bot's sweeper thread.
//!
//! Concurrency: the cache's internal mutex protects the map +
//! per-entry timestamps. Callers can read `Agent` pointers
//! directly without holding the cache mutex (Agents have their
//! own internal synchronization).

const std = @import("std");
const franky = @import("franky");
const agent_mod = franky.agent;
const ai = franky.ai;
const permissions_mod = franky.coding.permissions;

pub const Entry = struct {
    agent: *agent_mod.Agent,
    /// Owned (allocator-duped). Disk path under
    /// `<home>/workspaces/<team>/sessions/` where this session
    /// lives. Used by the persist-on-evict path.
    session_dir: []u8,
    /// Wall-clock millis of the most recent `get` or `put`. Atomic
    /// so the sweeper thread can read it without taking the cache
    /// mutex.
    last_access_ms: std.atomic.Value(i64),
    /// v0.3.2 — heap-allocated `SessionGates` whose address is
    /// what `agent.tool_gate.userdata` points at. Owned by the
    /// cache; freed on evict + on `deinit`. `null` when prompts
    /// are disabled (`--no-prompts` / `FRANKY_DO_PROMPTS=0`) so
    /// the agent runs without a tool gate.
    gates: ?*permissions_mod.SessionGates = null,
};

pub const Victim = struct {
    /// Owned (allocator-duped). Caller frees.
    ulid: []const u8,
    /// Caller takes ownership. Must `deinit` then `destroy`.
    agent: *agent_mod.Agent,
    /// Owned (allocator-duped). Caller frees.
    session_dir: []const u8,
    /// v0.3.2 — see `Entry.gates`. When non-null, caller takes
    /// ownership: `gates.permissions.deinit()` is **not** called
    /// here (the Store is bot-shared, not per-agent), but the
    /// `SessionGates` struct itself is `gpa.destroy`'d after the
    /// agent is freed.
    gates: ?*permissions_mod.SessionGates = null,
};

/// Sentinel returned by `tryPut` when an entry was inserted with
/// no eviction.
pub const PutResult = union(enum) {
    inserted: void,
    evicted: Victim,
};

pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Keys: ULID strings (allocator-owned). Values: Entry.
    map: std.StringHashMapUnmanaged(Entry) = .empty,
    mutex: std.Io.Mutex = .init,
    /// Hard cap. v0.3.1 default is 16; configurable at the bot
    /// level via `FRANKY_DO_AGENT_CACHE_SIZE`.
    cap: u32 = 16,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Cache {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn deinit(self: *Cache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.session_dir);
            entry.value_ptr.agent.deinit();
            self.allocator.destroy(entry.value_ptr.agent);
            if (entry.value_ptr.gates) |g| self.allocator.destroy(g);
        }
        self.map.deinit(self.allocator);
    }

    /// Look up by ULID, refreshing `last_access_ms` on hit. Returns
    /// null if no entry exists yet.
    pub fn get(self: *Cache, ulid: []const u8) ?*agent_mod.Agent {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.getPtr(ulid)) |e| {
            e.last_access_ms.store(ai.stream.nowMillis(), .release);
            return e.agent;
        }
        return null;
    }

    /// v0.3.2 — sibling accessor for the per-entry `SessionGates`.
    /// Returned pointer is stable for the lifetime of the cache
    /// entry. Used by the bot's `handleAppMention` to flip
    /// `gates.prompter` per-call without taking ownership.
    pub fn entryGates(self: *Cache, ulid: []const u8) ?*permissions_mod.SessionGates {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.getPtr(ulid)) |e| return e.gates;
        return null;
    }

    /// Insert an Agent into the cache. If the cap is exceeded, the
    /// least-recently-accessed entry is removed from the map and
    /// returned as a Victim — the caller is responsible for
    /// persisting + deinit'ing it. Replaces an existing entry for
    /// the same ULID (the previous Agent is returned as a Victim).
    /// `session_dir` is duplicated.
    ///
    /// `gates` is optional (v0.3.2): pass null when prompts are
    /// disabled, otherwise pass a heap-allocated `SessionGates`
    /// whose address matches `agent.tool_gate.userdata`. The cache
    /// takes ownership: it frees the gates on evict + on `deinit`.
    pub fn tryPut(
        self: *Cache,
        ulid: []const u8,
        agent: *agent_mod.Agent,
        session_dir: []const u8,
        gates: ?*permissions_mod.SessionGates,
    ) !PutResult {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        // Replace path: same ULID already in cache. Eject the old
        // entry as a Victim so the caller can persist it before
        // freeing.
        if (self.map.fetchRemove(ulid)) |old| {
            const owned_dir = try self.allocator.dupe(u8, session_dir);
            errdefer self.allocator.free(owned_dir);
            const owned_key = try self.allocator.dupe(u8, ulid);
            errdefer self.allocator.free(owned_key);
            try self.map.put(self.allocator, owned_key, .{
                .agent = agent,
                .session_dir = owned_dir,
                .last_access_ms = .init(ai.stream.nowMillis()),
                .gates = gates,
            });
            return .{ .evicted = .{
                .ulid = old.key,
                .agent = old.value.agent,
                .session_dir = old.value.session_dir,
                .gates = old.value.gates,
            } };
        }

        // Eviction-on-overflow path: cap exceeded → drop LRU.
        var maybe_victim: ?Victim = null;
        if (self.map.count() >= self.cap) {
            maybe_victim = self.popLeastRecentlyUsedLocked();
        }

        const owned_key = try self.allocator.dupe(u8, ulid);
        errdefer self.allocator.free(owned_key);
        const owned_dir = try self.allocator.dupe(u8, session_dir);
        errdefer self.allocator.free(owned_dir);
        try self.map.put(self.allocator, owned_key, .{
            .agent = agent,
            .session_dir = owned_dir,
            .last_access_ms = .init(ai.stream.nowMillis()),
            .gates = gates,
        });
        return if (maybe_victim) |v| .{ .evicted = v } else .inserted;
    }

    /// Drop the entry for `ulid` without persisting; returns the
    /// Victim so the caller can free it. No-op (returns null) if
    /// absent.
    ///
    /// Used by the slash-command `/franky-do reset` path: the user
    /// explicitly wants the session gone, no need to persist.
    pub fn drop(self: *Cache, ulid: []const u8) ?Victim {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.map.fetchRemove(ulid)) |old| {
            return .{
                .ulid = old.key,
                .agent = old.value.agent,
                .session_dir = old.value.session_dir,
                .gates = old.value.gates,
            };
        }
        return null;
    }

    /// Pop every entry. Returns a Victim slice for the bot to
    /// persist on graceful shutdown. Caller-owned slice; each
    /// Victim must be `freeVictim`'d (with `deinit_agent = true`)
    /// after persistence.
    pub fn popAll(self: *Cache) ![]Victim {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        var victims: std.ArrayList(Victim) = .empty;
        errdefer {
            for (victims.items) |v| {
                self.allocator.free(v.ulid);
                self.allocator.free(v.session_dir);
            }
            victims.deinit(self.allocator);
        }
        var it = self.map.iterator();
        while (it.next()) |entry| {
            try victims.append(self.allocator, .{
                .ulid = entry.key_ptr.*,
                .agent = entry.value_ptr.agent,
                .session_dir = entry.value_ptr.session_dir,
                .gates = entry.value_ptr.gates,
            });
        }
        // Cleared map; the keys/dirs/gates are now owned by Victims.
        self.map.clearAndFree(self.allocator);
        return try victims.toOwnedSlice(self.allocator);
    }

    /// Pop every entry whose `last_access_ms` is older than `now -
    /// idle_ms`. Returns Victims for the sweeper thread to persist
    /// + deinit. Caller-owned slice.
    pub fn popIdleOlderThan(self: *Cache, idle_ms: u64) ![]Victim {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const now_ms = ai.stream.nowMillis();
        const cutoff = now_ms - @as(i64, @intCast(idle_ms));

        var victims: std.ArrayList(Victim) = .empty;
        errdefer {
            for (victims.items) |v| {
                self.allocator.free(v.ulid);
                self.allocator.free(v.session_dir);
            }
            victims.deinit(self.allocator);
        }

        // Two passes: collect keys first (can't mutate map mid-iter).
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_access_ms.load(.acquire) < cutoff) {
                try stale.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (stale.items) |key| {
            const old = self.map.fetchRemove(key).?;
            try victims.append(self.allocator, .{
                .ulid = old.key,
                .agent = old.value.agent,
                .session_dir = old.value.session_dir,
                .gates = old.value.gates,
            });
        }

        return try victims.toOwnedSlice(self.allocator);
    }

    /// Returns the number of entries currently in the cache.
    pub fn count(self: *Cache) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.map.count();
    }

    /// Free a Victim produced by drop / tryPut / popIdleOlderThan.
    /// `deinit_agent` controls whether the Agent is `deinit + destroy`'d
    /// (typical) or left for the caller to handle (rare).
    /// v0.3.2 — also frees `gates` (the bot-allocated `SessionGates`).
    /// The `Store` it points at is bot-shared and NOT freed here.
    pub fn freeVictim(self: *Cache, victim: Victim, deinit_agent: bool) void {
        self.allocator.free(victim.ulid);
        self.allocator.free(victim.session_dir);
        if (deinit_agent) {
            victim.agent.deinit();
            self.allocator.destroy(victim.agent);
        }
        if (victim.gates) |g| self.allocator.destroy(g);
    }

    fn popLeastRecentlyUsedLocked(self: *Cache) ?Victim {
        if (self.map.count() == 0) return null;
        // Linear scan — fine for cap = 16 default.
        var oldest_key: ?[]const u8 = null;
        var oldest_ts: i64 = std.math.maxInt(i64);
        var it = self.map.iterator();
        while (it.next()) |entry| {
            const ts = entry.value_ptr.last_access_ms.load(.acquire);
            if (ts < oldest_ts) {
                oldest_ts = ts;
                oldest_key = entry.key_ptr.*;
            }
        }
        const key = oldest_key orelse return null;
        const old = self.map.fetchRemove(key) orelse return null;
        return .{
            .ulid = old.key,
            .agent = old.value.agent,
            .session_dir = old.value.session_dir,
            .gates = old.value.gates,
        };
    }
};

// ─── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const at = franky.agent.types;

/// `std.Thread.sleep` is gone in Zig 0.17-dev; tests use this libc
/// nanosleep wrapper. Same pattern as `stream_subscriber.zig`.
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

fn fauxShim(ctx: ai.registry.StreamCtx) anyerror!void {
    const fp: *ai.providers.faux.FauxProvider = @ptrCast(@alignCast(ctx.userdata.?));
    try fp.runSync(ctx.io, ctx.context, ctx.out);
}

/// Test fixture bundling Agent + the heap allocations it depends
/// on (registry + faux provider). franky's Agent stores the
/// registry as a `*const` pointer; the registry stores the faux
/// pointer as an opaque `userdata`. Neither carries the
/// allocations through `Agent.deinit`, so the test owns + frees
/// both via this struct.
const TestAgentFixture = struct {
    agent: *agent_mod.Agent,
    registry: *ai.registry.Registry,
    faux: *ai.providers.faux.FauxProvider,
};

fn makeAgent(gpa: std.mem.Allocator, io: std.Io) !TestAgentFixture {
    const reg = try gpa.create(ai.registry.Registry);
    errdefer gpa.destroy(reg);
    reg.* = ai.registry.Registry.init(gpa);
    errdefer reg.deinit();

    const faux = try gpa.create(ai.providers.faux.FauxProvider);
    errdefer gpa.destroy(faux);
    faux.* = ai.providers.faux.FauxProvider.init(gpa);
    errdefer faux.deinit();

    try reg.register(.{
        .api = "faux",
        .provider = "faux",
        .stream_fn = fauxShim,
        .userdata = @ptrCast(faux),
    });

    const a = try gpa.create(agent_mod.Agent);
    errdefer gpa.destroy(a);
    a.* = try agent_mod.Agent.init(gpa, io, .{
        .model = .{ .id = "faux-1", .provider = "faux", .api = "faux" },
        .registry = reg,
    });
    return .{ .agent = a, .registry = reg, .faux = faux };
}

fn destroyAgentFixture(gpa: std.mem.Allocator, fx: TestAgentFixture) void {
    fx.agent.deinit();
    gpa.destroy(fx.agent);
    fx.registry.deinit();
    gpa.destroy(fx.registry);
    fx.faux.deinit();
    gpa.destroy(fx.faux);
}

test "Cache: get/tryPut round-trip and last-access touch" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cache = Cache.init(gpa, io);
    // Fixture lives outside cache.deinit(); cache only owns the
    // Agent pointer (frees it via deinit) — tests need to free
    // registry+faux separately.
    const fx = try makeAgent(gpa, io);
    // Cache.deinit() will deinit + destroy the Agent. We free the
    // registry + faux ourselves.
    defer {
        cache.deinit();
        fx.registry.deinit();
        gpa.destroy(fx.registry);
        fx.faux.deinit();
        gpa.destroy(fx.faux);
    }

    const r = try cache.tryPut("01ABC", fx.agent, "/tmp/sessions/01ABC", null);
    try testing.expect(r == .inserted);
    try testing.expect(cache.get("01ABC") == fx.agent);
    try testing.expectEqual(@as(usize, 1), cache.count());
}

test "Cache: cap-driven LRU eviction returns oldest as Victim" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cache = Cache.init(gpa, io);
    cache.cap = 2;

    const fx1 = try makeAgent(gpa, io);
    const fx2 = try makeAgent(gpa, io);
    const fx3 = try makeAgent(gpa, io);
    // Cache will deinit fx1's + fx3's Agents on cache.deinit; fx2's
    // Agent will be evicted as a Victim and we free it manually
    // below. Either way, registry+faux for all three need explicit
    // teardown.
    defer {
        cache.deinit();
        fx1.registry.deinit();
        gpa.destroy(fx1.registry);
        fx1.faux.deinit();
        gpa.destroy(fx1.faux);
        fx2.registry.deinit();
        gpa.destroy(fx2.registry);
        fx2.faux.deinit();
        gpa.destroy(fx2.faux);
        fx3.registry.deinit();
        gpa.destroy(fx3.registry);
        fx3.faux.deinit();
        gpa.destroy(fx3.faux);
    }

    _ = try cache.tryPut("01A", fx1.agent, "/tmp/sessions/01A", null);
    // Sleep a millisecond so fx2's last_access > fx1's. The cache
    // uses wall-clock timestamps; without the gap, both inserts can
    // land in the same ms and ordering is undefined.
    sleepMs(2);
    _ = try cache.tryPut("01B", fx2.agent, "/tmp/sessions/01B", null);
    sleepMs(2);

    // Touch 01A to make 01B the LRU.
    _ = cache.get("01A");
    sleepMs(2);

    const r = try cache.tryPut("01C", fx3.agent, "/tmp/sessions/01C", null);
    try testing.expect(r == .evicted);
    try testing.expectEqualStrings("01B", r.evicted.ulid);
    try testing.expectEqualStrings("/tmp/sessions/01B", r.evicted.session_dir);
    cache.freeVictim(r.evicted, true);

    try testing.expectEqual(@as(usize, 2), cache.count());
    try testing.expect(cache.get("01A") == fx1.agent);
    try testing.expect(cache.get("01C") == fx3.agent);
    try testing.expect(cache.get("01B") == null);
}

test "Cache: popIdleOlderThan returns stale entries" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cache = Cache.init(gpa, io);
    const fx1 = try makeAgent(gpa, io);
    const fx2 = try makeAgent(gpa, io);
    defer {
        cache.deinit();
        fx1.registry.deinit();
        gpa.destroy(fx1.registry);
        fx1.faux.deinit();
        gpa.destroy(fx1.faux);
        fx2.registry.deinit();
        gpa.destroy(fx2.registry);
        fx2.faux.deinit();
        gpa.destroy(fx2.faux);
    }

    _ = try cache.tryPut("01A", fx1.agent, "/tmp/sessions/01A", null);
    // Sleep so 01A's last_access lags behind a future cutoff.
    sleepMs(50);
    _ = try cache.tryPut("01B", fx2.agent, "/tmp/sessions/01B", null);

    // Sweeper window: anything older than 10ms.
    const victims = try cache.popIdleOlderThan(10);
    defer gpa.free(victims);
    try testing.expectEqual(@as(usize, 1), victims.len);
    try testing.expectEqualStrings("01A", victims[0].ulid);
    cache.freeVictim(victims[0], true);

    try testing.expectEqual(@as(usize, 1), cache.count());
    try testing.expect(cache.get("01B") == fx2.agent);
}

test "Cache: drop returns Victim without persistence concerns" {
    var threaded = franky.test_helpers.threadedIo();
    defer threaded.deinit();
    const io = threaded.io();
    const gpa = testing.allocator;

    var cache = Cache.init(gpa, io);
    const fx = try makeAgent(gpa, io);
    defer {
        cache.deinit();
        fx.registry.deinit();
        gpa.destroy(fx.registry);
        fx.faux.deinit();
        gpa.destroy(fx.faux);
    }

    _ = try cache.tryPut("01A", fx.agent, "/tmp/sessions/01A", null);

    const victim = cache.drop("01A");
    try testing.expect(victim != null);
    cache.freeVictim(victim.?, true);
    try testing.expect(cache.drop("01A") == null);
    try testing.expectEqual(@as(usize, 0), cache.count());
}
