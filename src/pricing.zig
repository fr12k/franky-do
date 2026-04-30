//! Phase 8 — model-pricing table for the cost dashboard.
//!
//! Per-million-token rates in USD. Values are operator-editable
//! and will drift; treat the constants as a starting point, not
//! a contract. Unknown model ids resolve to `null` so the stats
//! renderer can flag them as `n/a` rather than reporting a
//! confidently-wrong cost.
//!
//! Schema mirrors `permission.md` §A.7-style pricing entries:
//! one row per model-id pattern, with a longest-prefix match
//! resolving multi-version families (`claude-sonnet-4-5` and
//! `claude-sonnet-4-6` both match the `claude-sonnet-4-` prefix).

const std = @import("std");

pub const Rate = struct {
    /// USD per million input tokens.
    input_per_mtok: f64,
    /// USD per million output tokens.
    output_per_mtok: f64,
};

const Entry = struct {
    prefix: []const u8,
    rate: Rate,
};

/// v0.1 table — Anthropic models the bot is likely to use. Add
/// rows here when bumping franky's catalog or wiring new
/// providers (OpenAI, Google).
const table = [_]Entry{
    // Order matters: longer prefix first so `claude-opus-4-6` wins
    // over a hypothetical `claude-opus-4-` family fallback.
    .{ .prefix = "claude-opus-4", .rate = .{ .input_per_mtok = 15.00, .output_per_mtok = 75.00 } },
    .{ .prefix = "claude-sonnet-4", .rate = .{ .input_per_mtok = 3.00, .output_per_mtok = 15.00 } },
    .{ .prefix = "claude-haiku-4", .rate = .{ .input_per_mtok = 1.00, .output_per_mtok = 5.00 } },
    // Older families folks might still pin against — same shape.
    .{ .prefix = "claude-3-5-sonnet", .rate = .{ .input_per_mtok = 3.00, .output_per_mtok = 15.00 } },
    .{ .prefix = "claude-3-5-haiku", .rate = .{ .input_per_mtok = 1.00, .output_per_mtok = 5.00 } },
    .{ .prefix = "claude-3-opus", .rate = .{ .input_per_mtok = 15.00, .output_per_mtok = 75.00 } },
};

/// Best-effort price lookup for a model id. Returns null when no
/// entry's prefix matches; the renderer surfaces that as
/// `cost = "n/a"` rather than guessing.
pub fn lookup(model_id: []const u8) ?Rate {
    for (table) |entry| {
        if (std.mem.startsWith(u8, model_id, entry.prefix)) return entry.rate;
    }
    return null;
}

/// Compute USD cost for an (input, output) token pair. Returns
/// null when the model id isn't in the table.
pub fn estimate(model_id: []const u8, input_tokens: u64, output_tokens: u64) ?f64 {
    const rate = lookup(model_id) orelse return null;
    const in_cost = @as(f64, @floatFromInt(input_tokens)) * rate.input_per_mtok / 1_000_000.0;
    const out_cost = @as(f64, @floatFromInt(output_tokens)) * rate.output_per_mtok / 1_000_000.0;
    return in_cost + out_cost;
}

// ─── tests ────────────────────────────────────────────────────────

const testing = std.testing;

test "lookup: known model returns its rate" {
    const r = lookup("claude-sonnet-4-6").?;
    try testing.expectEqual(@as(f64, 3.00), r.input_per_mtok);
    try testing.expectEqual(@as(f64, 15.00), r.output_per_mtok);
}

test "lookup: unknown model returns null" {
    try testing.expect(lookup("gpt-4-fancy") == null);
    try testing.expect(lookup("") == null);
}

test "lookup: prefix match handles version suffixes" {
    try testing.expect(lookup("claude-opus-4-6") != null);
    try testing.expect(lookup("claude-opus-4-7-experimental") != null);
    try testing.expect(lookup("claude-haiku-4-5-20251001") != null);
}

test "estimate: 1M input + 1M output of sonnet = $18" {
    const cost = estimate("claude-sonnet-4-6", 1_000_000, 1_000_000).?;
    try testing.expectApproxEqAbs(@as(f64, 18.0), cost, 0.001);
}

test "estimate: zero tokens → $0" {
    const cost = estimate("claude-opus-4-6", 0, 0).?;
    try testing.expectEqual(@as(f64, 0.0), cost);
}

test "estimate: unknown model → null" {
    try testing.expect(estimate("not-a-real-model", 100, 100) == null);
}
