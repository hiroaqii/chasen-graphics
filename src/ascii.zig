const std = @import("std");
const blocks = @import("blocks.zig");

/// Brightness ramp constants.
///
/// Ramps are ordered from darker/emptier entries to brighter/denser entries.
/// Mapping a numeric brightness value to an index is handled by a later helper.
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
