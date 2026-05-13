const std = @import("std");

/// Number of dot columns represented by one Braille terminal cell.
pub const cols: u8 = 2;

/// Number of dot rows represented by one Braille terminal cell.
pub const rows: u8 = 4;

/// UTF-8 encoded Braille glyph.
///
/// Unicode Braille characters are in U+2800...U+28FF, so every glyph in this
/// range is encoded as exactly three UTF-8 bytes.
pub const Glyph = [3]u8;

/// Convert an 8-bit Braille dot mask to a UTF-8 Braille glyph.
///
/// Bit 0 maps to dot 1, bit 1 to dot 2, and so on through bit 7 / dot 8. This
/// function only encodes the glyph; it does not decide which dots should be on.
pub fn fromDots(mask: u8) Glyph {
    const codepoint: u21 = 0x2800 + @as(u21, mask);
    return .{
        @intCast(0xE0 | (codepoint >> 12)),
        @intCast(0x80 | ((codepoint >> 6) & 0x3F)),
        @intCast(0x80 | (codepoint & 0x3F)),
    };
}

test "fromDots encodes blank and full Braille glyphs" {
    try std.testing.expectEqualStrings("⠀", &fromDots(0x00));
    try std.testing.expectEqualStrings("⣿", &fromDots(0xFF));
}

test "fromDots maps individual dot bits to Braille glyphs" {
    try std.testing.expectEqualStrings("⠁", &fromDots(0b0000_0001));
    try std.testing.expectEqualStrings("⠂", &fromDots(0b0000_0010));
    try std.testing.expectEqualStrings("⠄", &fromDots(0b0000_0100));
    try std.testing.expectEqualStrings("⠈", &fromDots(0b0000_1000));
    try std.testing.expectEqualStrings("⠐", &fromDots(0b0001_0000));
    try std.testing.expectEqualStrings("⠠", &fromDots(0b0010_0000));
    try std.testing.expectEqualStrings("⡀", &fromDots(0b0100_0000));
    try std.testing.expectEqualStrings("⢀", &fromDots(0b1000_0000));
}

test "Braille geometry exposes 2x4 dot dimensions" {
    try std.testing.expectEqual(@as(u8, 2), cols);
    try std.testing.expectEqual(@as(u8, 4), rows);
}
