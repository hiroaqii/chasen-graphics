const std = @import("std");

/// ASCII brightness ramp constants.
///
/// A ramp is ordered from darker/emptier characters to brighter/denser
/// characters. Mapping a numeric brightness value to an index is handled by a
/// later helper.
pub const ramp = struct {
    /// Basic brightness ramp commonly used for coarse ASCII rendering.
    pub const basic = " .:-=+*#%@";
    /// Denser brightness ramp for finer ASCII rendering.
    pub const dense = " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$";
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
