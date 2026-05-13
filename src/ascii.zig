const std = @import("std");
const blocks = @import("blocks.zig");

/// Brightness ramp constants.
///
/// Ramps are ordered from darker/emptier entries to brighter/denser entries.
/// Use `brightnessToIndex` to map normalized brightness to an entry index.
pub const ramp = struct {
    /// Basic brightness ramp commonly used for coarse ASCII rendering.
    pub const basic = " .:-=+*#%@";
    /// Denser brightness ramp for finer ASCII rendering.
    pub const dense = " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$";
    /// Shade/block ramp for coarse cell-density rendering.
    ///
    /// This ramp is an entry array because it contains multi-byte UTF-8 glyphs.
    /// Use `shade.len` as the brightness entry count.
    pub const shade = [_][]const u8{
        " ",
        blocks.shade.light,
        blocks.shade.medium,
        blocks.shade.dark,
        blocks.shade.full,
    };
};

/// Map normalized brightness to an entry index.
///
/// `entry_count` is the number of ramp entries, not necessarily the byte length
/// of a UTF-8 string. ASCII-only string ramps can pass `.len`; entry-array ramps
/// such as `ramp.shade` can also pass `.len`. Non-NaN brightness values are
/// clamped into `0.0...1.0`. `NaN` brightness and empty ramps return `0`.
pub fn brightnessToIndex(brightness: f32, entry_count: usize) usize {
    if (entry_count == 0 or std.math.isNan(brightness)) return 0;

    const normalized = clamp01(brightness);
    if (normalized <= 0.0) return 0;
    if (normalized >= 1.0) return entry_count - 1;

    const scaled = @floor(normalized * @as(f32, @floatFromInt(entry_count)));
    const index: usize = @intFromFloat(scaled);
    return @min(index, entry_count - 1);
}

/// Map normalized brightness to a glyph entry.
///
/// `entries` is an ordered ramp entry list. It can contain ASCII entries or
/// multi-byte UTF-8 glyphs. Non-NaN brightness values are clamped into
/// `0.0...1.0`. `NaN` brightness and empty ramps return an empty string.
pub fn brightnessToGlyph(brightness: f32, entries: []const []const u8) []const u8 {
    if (entries.len == 0 or std.math.isNan(brightness)) return "";
    return entries[brightnessToIndex(brightness, entries.len)];
}

fn clamp01(value: f32) f32 {
    if (value <= 0.0) return 0.0;
    if (value >= 1.0) return 1.0;
    return value;
}

test "ASCII ramps expose ordered brightness glyphs" {
    try std.testing.expectEqualStrings(" .:-=+*#%@", ramp.basic);
    try std.testing.expectEqual(@as(usize, 10), ramp.basic.len);
}

test "ASCII ramps expose dense brightness glyphs" {
    try std.testing.expectEqualStrings(
        " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$",
        ramp.dense,
    );
    try std.testing.expect(ramp.dense.len > ramp.basic.len);
}

test "ASCII ramps expose shade block brightness glyphs" {
    try std.testing.expectEqual(@as(usize, 5), ramp.shade.len);
    try std.testing.expectEqualStrings(" ", ramp.shade[0]);
    try std.testing.expectEqualStrings("░", ramp.shade[1]);
    try std.testing.expectEqualStrings("▒", ramp.shade[2]);
    try std.testing.expectEqualStrings("▓", ramp.shade[3]);
    try std.testing.expectEqualStrings("█", ramp.shade[4]);
}

test "brightnessToIndex maps normalized brightness to ramp entries" {
    try std.testing.expectEqual(@as(usize, 0), brightnessToIndex(0.0, 10));
    try std.testing.expectEqual(@as(usize, 2), brightnessToIndex(0.25, 10));
    try std.testing.expectEqual(@as(usize, 5), brightnessToIndex(0.5, 10));
    try std.testing.expectEqual(@as(usize, 7), brightnessToIndex(0.75, 10));
    try std.testing.expectEqual(@as(usize, 9), brightnessToIndex(1.0, 10));
}

test "brightnessToIndex clamps out-of-range brightness" {
    try std.testing.expectEqual(@as(usize, 0), brightnessToIndex(-1.0, 10));
    try std.testing.expectEqual(@as(usize, 9), brightnessToIndex(2.0, 10));
}

test "brightnessToIndex handles empty ramps and NaN brightness" {
    try std.testing.expectEqual(@as(usize, 0), brightnessToIndex(0.5, 0));
    try std.testing.expectEqual(@as(usize, 0), brightnessToIndex(std.math.nan(f32), 10));
}

test "brightnessToIndex uses entry counts for UTF-8 ramp arrays" {
    try std.testing.expectEqual(@as(usize, 2), brightnessToIndex(0.5, ramp.shade.len));
    try std.testing.expectEqual(@as(usize, 4), brightnessToIndex(1.0, ramp.shade.len));
}

test "brightnessToGlyph maps normalized brightness to glyph entries" {
    try std.testing.expectEqualStrings(" ", brightnessToGlyph(0.0, &ramp.shade));
    try std.testing.expectEqualStrings("▒", brightnessToGlyph(0.5, &ramp.shade));
    try std.testing.expectEqualStrings("█", brightnessToGlyph(1.0, &ramp.shade));
}

test "brightnessToGlyph clamps brightness and handles empty input" {
    try std.testing.expectEqualStrings(" ", brightnessToGlyph(-1.0, &ramp.shade));
    try std.testing.expectEqualStrings("█", brightnessToGlyph(2.0, &ramp.shade));
    try std.testing.expectEqualStrings("", brightnessToGlyph(0.5, &.{}));
    try std.testing.expectEqualStrings("", brightnessToGlyph(std.math.nan(f32), &ramp.shade));
}

test "brightness mapping keeps bucket boundaries stable" {
    try std.testing.expectEqual(@as(usize, 0), brightnessToIndex(0.099, 10));
    try std.testing.expectEqual(@as(usize, 1), brightnessToIndex(0.1, 10));
    try std.testing.expectEqual(@as(usize, 1), brightnessToIndex(0.199, 10));
    try std.testing.expectEqual(@as(usize, 2), brightnessToIndex(0.2, 10));
    try std.testing.expectEqual(@as(usize, 8), brightnessToIndex(0.899, 10));
    try std.testing.expectEqual(@as(usize, 9), brightnessToIndex(0.9, 10));
    try std.testing.expectEqual(@as(usize, 9), brightnessToIndex(0.999, 10));
}

test "brightness mapping handles single-entry ramps" {
    try std.testing.expectEqual(@as(usize, 0), brightnessToIndex(0.0, 1));
    try std.testing.expectEqual(@as(usize, 0), brightnessToIndex(0.5, 1));
    try std.testing.expectEqual(@as(usize, 0), brightnessToIndex(1.0, 1));

    const single = [_][]const u8{"@"};
    try std.testing.expectEqualStrings("@", brightnessToGlyph(0.0, &single));
    try std.testing.expectEqualStrings("@", brightnessToGlyph(0.5, &single));
    try std.testing.expectEqualStrings("@", brightnessToGlyph(1.0, &single));
}
