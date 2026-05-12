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

/// Status-related glyph constants.
///
/// These are intentionally small semantic symbols. Applications and UI
/// components decide whether they represent validation, task state, log level,
/// or another app-specific status.
pub const status = struct {
    /// Successful or completed state.
    pub const ok = "✓";
    /// Failed or unavailable state.
    pub const err = "✗";
    /// Warning state.
    pub const warn = "!";
    /// Informational state.
    pub const info = "i";

    /// ASCII fallback for `ok`.
    pub const ok_ascii = "v";
    /// ASCII fallback for `err`.
    pub const err_ascii = "x";
};

test "rating glyphs expose unicode and ASCII fallback symbols" {
    try std.testing.expectEqualStrings("★", rating.filled);
    try std.testing.expectEqualStrings("☆", rating.empty);
    try std.testing.expectEqualStrings("*", rating.filled_ascii);
    try std.testing.expectEqualStrings("-", rating.empty_ascii);
}

test "status glyphs expose unicode and ASCII fallback symbols" {
    try std.testing.expectEqualStrings("✓", status.ok);
    try std.testing.expectEqualStrings("✗", status.err);
    try std.testing.expectEqualStrings("!", status.warn);
    try std.testing.expectEqualStrings("i", status.info);
    try std.testing.expectEqualStrings("v", status.ok_ascii);
    try std.testing.expectEqualStrings("x", status.err_ascii);
}
