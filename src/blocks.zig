const std = @import("std");

/// Progress bar block glyph constants.
///
/// These are only cell labels for filled and empty progress regions. Apps or UI
/// components decide progress value, width, clipping, style, and redraw timing.
pub const progress = struct {
    /// Filled progress cell using a full block.
    pub const filled = "█";
    /// Empty progress cell.
    ///
    /// A space is useful when the renderer or component uses background style
    /// to show the empty region. Use `empty_ascii` when visible empty cells are
    /// needed in plain text.
    pub const empty = " ";
    /// ASCII fallback for `filled`.
    pub const filled_ascii = "|";
    /// ASCII fallback for `empty`.
    pub const empty_ascii = ".";
};

/// Shaded block glyph constants ordered from lighter to darker.
///
/// These are reusable cell labels for coarse density or brightness displays.
/// Numeric brightness mapping belongs in a later helper, not in this data set.
pub const shade = struct {
    /// Light shade block.
    pub const light = "░";
    /// Medium shade block.
    pub const medium = "▒";
    /// Dark shade block.
    pub const dark = "▓";
    /// Full block.
    pub const full = "█";
};

test "progress blocks expose unicode and ASCII fallback glyphs" {
    try std.testing.expectEqualStrings("█", progress.filled);
    try std.testing.expectEqualStrings(" ", progress.empty);
    try std.testing.expectEqualStrings("|", progress.filled_ascii);
    try std.testing.expectEqualStrings(".", progress.empty_ascii);
}

test "shade blocks expose ordered density glyphs" {
    try std.testing.expectEqualStrings("░", shade.light);
    try std.testing.expectEqualStrings("▒", shade.medium);
    try std.testing.expectEqualStrings("▓", shade.dark);
    try std.testing.expectEqualStrings("█", shade.full);
}
