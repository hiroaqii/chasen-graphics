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

/// Selection-related glyph constants.
///
/// Selection markers indicate a current, focused, active, or chosen item. The
/// exact meaning stays with the app or UI component. Rendering code can choose
/// the Unicode marker or ASCII fallback based on terminal/font needs.
pub const selection = struct {
    /// Compact marker for the active or focused item.
    pub const marker = "▶";
    /// ASCII fallback for `marker`.
    pub const marker_ascii = ">";
};

/// Checkbox marker glyph constants.
///
/// These markers mirror the current chasen-ui defaults. They are still plain
/// glyph data: checked state and toggle behavior stay with the app or UI
/// component.
pub const checkbox = struct {
    /// Unchecked checkbox marker.
    pub const unchecked = "[ ]";
    /// Checked checkbox marker.
    pub const checked = "[x]";
};

/// Radio marker glyph constants.
///
/// These markers mirror the current chasen-ui defaults. Group selection policy
/// stays with the app or UI component.
pub const radio = struct {
    /// Unselected radio marker.
    pub const unselected = "( )";
    /// Selected radio marker.
    pub const selected = "(o)";
};

/// Spinner frame glyph constants.
///
/// These are ordered frame labels, not animation state. Apps, `chasen-anim`, or
/// UI components decide which index to show for a given frame or tick.
pub const spinner = struct {
    /// Four-frame ASCII line spinner.
    pub const line = [_][]const u8{ "|", "/", "-", "\\" };
    /// Ten-frame Unicode dot spinner.
    pub const dots = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
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

test "selection glyphs expose unicode and ASCII fallback symbols" {
    try std.testing.expectEqualStrings("▶", selection.marker);
    try std.testing.expectEqualStrings(">", selection.marker_ascii);
}

test "checkbox and radio glyphs expose marker symbols" {
    try std.testing.expectEqualStrings("[ ]", checkbox.unchecked);
    try std.testing.expectEqualStrings("[x]", checkbox.checked);
    try std.testing.expectEqualStrings("( )", radio.unselected);
    try std.testing.expectEqualStrings("(o)", radio.selected);
}

test "spinner glyphs expose ordered line frames" {
    try std.testing.expectEqual(@as(usize, 4), spinner.line.len);
    try std.testing.expectEqualStrings("|", spinner.line[0]);
    try std.testing.expectEqualStrings("/", spinner.line[1]);
    try std.testing.expectEqualStrings("-", spinner.line[2]);
    try std.testing.expectEqualStrings("\\", spinner.line[3]);
}

test "spinner glyphs expose ordered dot frames" {
    try std.testing.expectEqual(@as(usize, 10), spinner.dots.len);
    try std.testing.expectEqualStrings("⠋", spinner.dots[0]);
    try std.testing.expectEqualStrings("⠙", spinner.dots[1]);
    try std.testing.expectEqualStrings("⠹", spinner.dots[2]);
    try std.testing.expectEqualStrings("⠸", spinner.dots[3]);
    try std.testing.expectEqualStrings("⠼", spinner.dots[4]);
    try std.testing.expectEqualStrings("⠴", spinner.dots[5]);
    try std.testing.expectEqualStrings("⠦", spinner.dots[6]);
    try std.testing.expectEqualStrings("⠧", spinner.dots[7]);
    try std.testing.expectEqualStrings("⠇", spinner.dots[8]);
    try std.testing.expectEqualStrings("⠏", spinner.dots[9]);
}
