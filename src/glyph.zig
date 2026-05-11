const std = @import("std");

/// Rating-related glyph constants.
///
/// These are pure text constants. Rendering code decides style, color,
/// placement, and whether to use Unicode or ASCII fallback symbols.
pub const rating = struct {
    /// Filled rating star.
    pub const filled = "★";
    /// Empty rating star.
    pub const empty = "☆";
    /// ASCII fallback for `filled`.
    pub const filled_ascii = "*";
    /// ASCII fallback for `empty`.
    pub const empty_ascii = "-";
};

test "rating glyphs expose unicode and ASCII fallback symbols" {
    try std.testing.expectEqualStrings("★", rating.filled);
    try std.testing.expectEqualStrings("☆", rating.empty);
    try std.testing.expectEqualStrings("*", rating.filled_ascii);
    try std.testing.expectEqualStrings("-", rating.empty_ascii);
}
