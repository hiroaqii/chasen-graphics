//! Deterministic cell samples for small terminal loading indicators.
//!
//! Callers own the clock, scheduling, placement, colors, and clearing. A phase
//! of 1 is one complete cycle. All returned glyphs have program lifetime.
const std = @import("std");
const braille = @import("braille.zig");
const blocks = @import("blocks.zig");

pub const Kind = enum { blocks, arc, ripple };
pub const Size = enum { small, medium, large };
pub const Dimensions = struct { width: u16, height: u16 };
pub const Cell = struct {
    /// One terminal cell; borrowed from immutable program-lifetime data.
    glyph: []const u8 = " ",
    /// Relative brightness in 0...1. Zero denotes an empty cell.
    intensity: f32 = 0,
};

/// Nominal dimensions, excluding any label. Circles assume 1:2 terminal cells.
pub fn dimensions(kind: Kind, size: Size) Dimensions {
    const scale: u16 = @as(u16, @intFromEnum(size)) + 1;
    return if (kind == .blocks)
        .{ .width = 6 * scale + 2, .height = 3 * scale + 2 }
    else
        .{ .width = 4 * scale + 4, .height = 2 * scale + 2 };
}

/// Sample a cell without allocating. Finite phases wrap modulo one;
/// non-finite phases select phase zero. Out-of-bounds cells are empty.
pub fn sample(kind: Kind, size: Size, phase: f32, col: u16, row: u16) Cell {
    const dims = dimensions(kind, size);
    if (col >= dims.width or row >= dims.height) return .{};
    const p = wrap(phase);
    if (kind == .blocks) return sampleBlocks(size, p, col, row);

    const cx = (@as(f32, @floatFromInt(dims.width)) * 2 - 1) / 2;
    const cy = (@as(f32, @floatFromInt(dims.height)) * 4 - 1) / 2;
    const radius = @min(cx, cy) - 0.5;
    var mask: u8 = 0;
    var intensity: f32 = 0;
    for (0..braille.rows) |dy| {
        for (0..braille.cols) |dx| {
            const x = @as(f32, @floatFromInt(@as(usize, col) * 2 + dx)) - cx;
            const y = @as(f32, @floatFromInt(@as(usize, row) * 4 + dy)) - cy;
            const distance = @sqrt(x * x + y * y);
            var light: f32 = 0;
            switch (kind) {
                .arc => {
                    if (@abs(distance - radius) <= 0.8) {
                        // Zero points up; positive phase moves clockwise.
                        const angle = (std.math.atan2(y, x) + std.math.pi * 0.5) / (2.0 * std.math.pi);
                        const age = wrap(p - angle);
                        if (age < 0.7) light = 1 - age / 0.7;
                    }
                },
                .ripple => {
                    for (0..3) |ring| {
                        const age = wrap(p + @as(f32, @floatFromInt(ring)) / 3);
                        if (@abs(distance - age * radius) <= 0.8)
                            light = @max(light, 1 - age);
                    }
                },
                .blocks => unreachable,
            }
            if (light > 0) {
                mask |= braille.dotMask(@intCast(dx), @intCast(dy));
                intensity = @max(intensity, light);
            }
        }
    }
    if (mask == 0) return .{};
    return .{ .glyph = braille.glyph(mask), .intensity = intensity };
}

fn wrap(phase: f32) f32 {
    return if (std.math.isFinite(phase)) phase - @floor(phase) else 0;
}

fn sampleBlocks(size: Size, phase: f32, col: u16, row: u16) Cell {
    const scale: u16 = @as(u16, @intFromEnum(size)) + 1;
    const block_width = 2 * scale;
    if (col % (block_width + 1) == block_width or row % (scale + 1) == scale)
        return .{};
    const index = (row / (scale + 1)) * 3 + col / (block_width + 1);
    const head: u16 = @intFromFloat(phase * 9);
    const age = (head + 9 - index) % 9;
    const light = 1 - @as(f32, @floatFromInt(age)) / 9;
    const glyph = if (light > 0.8) blocks.shade.full else if (light > 0.5) blocks.shade.dark else if (light > 0.25) blocks.shade.medium else blocks.shade.light;
    return .{ .glyph = glyph, .intensity = light };
}

test "loading dimensions describe all three sizes" {
    const expected = [_]Dimensions{
        .{ .width = 8, .height = 5 },
        .{ .width = 14, .height = 8 },
        .{ .width = 20, .height = 11 },
    };
    for ([_]Size{ .small, .medium, .large }, expected) |size, dims| {
        try std.testing.expectEqual(dims, dimensions(.blocks, size));
        const circle = dimensions(.arc, size);
        try std.testing.expectEqual(circle, dimensions(.ripple, size));
        try std.testing.expectEqual(circle.width, circle.height * 2);
    }
}

test "loading sampling wraps a cycle and leaves outside cells empty" {
    for ([_]Kind{ .blocks, .arc, .ripple }) |kind| {
        for ([_]Size{ .small, .medium, .large }) |size| {
            const dims = dimensions(kind, size);
            try std.testing.expectEqualStrings(" ", sample(kind, size, 0, dims.width, 0).glyph);
            try std.testing.expectEqualStrings(" ", sample(kind, size, 0, 0, dims.height).glyph);
            var visible: usize = 0;
            for (0..dims.height) |row| {
                for (0..dims.width) |col| {
                    const a = sample(kind, size, 0, @intCast(col), @intCast(row));
                    const b = sample(kind, size, 1, @intCast(col), @intCast(row));
                    try std.testing.expectEqualStrings(a.glyph, b.glyph);
                    try std.testing.expectEqual(a.intensity, b.intensity);
                    try std.testing.expect(a.intensity >= 0 and a.intensity <= 1);
                    try std.testing.expect(std.unicode.utf8ValidateSlice(a.glyph));
                    if (a.intensity > 0) visible += 1;
                }
            }
            try std.testing.expect(visible > 0);
        }
    }
}

test "loading invalid phases select the initial frame" {
    for ([_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32) }) |phase| {
        const initial = sample(.arc, .small, 0, 3, 0);
        const actual = sample(.arc, .small, phase, 3, 0);
        try std.testing.expectEqualStrings(initial.glyph, actual.glyph);
        try std.testing.expectEqual(initial.intensity, actual.intensity);
    }
    const negative = sample(.arc, .small, -0.75, 3, 0);
    const positive = sample(.arc, .small, 0.25, 3, 0);
    try std.testing.expectEqualStrings(positive.glyph, negative.glyph);
    try std.testing.expectEqual(positive.intensity, negative.intensity);
}

test "blocks retain their gaps while the bright cell advances" {
    try std.testing.expectEqual(@as(f32, 1), sample(.blocks, .small, 0, 0, 0).intensity);
    try std.testing.expectEqual(@as(f32, 0), sample(.blocks, .small, 0, 2, 0).intensity);
    try std.testing.expectEqual(@as(f32, 0), sample(.blocks, .small, 0, 0, 1).intensity);
    try std.testing.expectEqual(@as(f32, 1), sample(.blocks, .small, 0.15, 3, 0).intensity);
    try std.testing.expect(sample(.blocks, .small, 0.15, 0, 0).intensity < 1);
}

test "arc head rotates away from the top without drawing corner dots" {
    const head = sample(.arc, .small, 0, 3, 0);
    const tail = sample(.arc, .small, 0.5, 3, 0);
    try std.testing.expect(head.intensity > 0.8);
    try std.testing.expect(tail.intensity < head.intensity);
    try std.testing.expectEqualStrings(" ", sample(.arc, .small, 0, 0, 0).glyph);
}

test "ripple moves the innermost ring away from the center" {
    const start = sample(.ripple, .small, 0, 3, 1);
    const later = sample(.ripple, .small, 0.25, 3, 1);
    const start_mask: u8 = @intCast((try std.unicode.utf8Decode(start.glyph)) - 0x2800);
    const later_mask: u8 = if (std.mem.eql(u8, later.glyph, " ")) 0 else @intCast((try std.unicode.utf8Decode(later.glyph)) - 0x2800);
    // (1,3) in this cell is the dot immediately above-left of the center.
    const center = braille.dotMask(1, 3);
    try std.testing.expect(start_mask & center != 0);
    try std.testing.expect(later_mask & center == 0);
}
