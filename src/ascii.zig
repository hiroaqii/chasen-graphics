const std = @import("std");

/// ASCII brightness ramp constants.
///
/// A ramp is ordered from darker/emptier characters to brighter/denser
/// characters. Mapping a numeric brightness value to an index is handled by a
/// later helper.
pub const ramp = struct {
    /// Basic brightness ramp commonly used for coarse ASCII rendering.
    pub const basic = " .:-=+*#%@";
};

test "ASCII ramps expose ordered brightness glyphs" {
    try std.testing.expectEqualStrings(" .:-=+*#%@", ramp.basic);
    try std.testing.expectEqual(@as(usize, 10), ramp.basic.len);
}
