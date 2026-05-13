const std = @import("std");

/// 8-bit RGB color used by pixel helpers.
///
/// This type intentionally does not depend on Chasen or libvaxis color types.
/// Later adapters can translate it to terminal style/color values.
pub const Rgb = struct {
    /// Red channel.
    r: u8,
    /// Green channel.
    g: u8,
    /// Blue channel.
    b: u8,
};

/// A decoded pixel sample used by pixel/block renderers.
///
/// `alpha` is an opacity value where `0` means fully transparent and `255`
/// means fully opaque. `chasen-graphics` does not define compositing policy at
/// this layer; renderers decide how to treat transparent pixels.
pub const Pixel = struct {
    /// Pixel color.
    rgb: Rgb,
    /// Pixel opacity.
    alpha: u8 = 255,
};

/// A terminal-cell-sized half-block render plan for two vertical pixels.
///
/// The `glyph` is the upper-half block character. `upper` and `lower` keep the
/// original pixel samples so later helpers can decide how to convert them to
/// foreground/background colors or how to treat alpha.
pub const HalfBlockCell = struct {
    /// Half-block glyph used to represent two vertical pixels in one cell.
    glyph: []const u8 = "▀",
    /// Pixel represented by the upper half of the cell.
    upper: Pixel,
    /// Pixel represented by the lower half of the cell.
    lower: Pixel,
};

/// Minimal terminal truecolor style plan.
///
/// This is not a Chasen or libvaxis style. It is a std-only data shape that
/// records the intended foreground/background RGB colors before a later adapter
/// converts them to the renderer's concrete cell style type.
pub const TrueColorStyle = struct {
    /// Foreground RGB color, when the glyph needs one.
    fg: ?Rgb = null,
    /// Background RGB color, when the cell needs one.
    bg: ?Rgb = null,
};

/// A glyph plus a std-only truecolor style plan.
///
/// This type lets pixel helpers describe what should be drawn without deciding
/// how a specific terminal renderer stores color attributes.
pub const TrueColorCell = struct {
    /// Glyph to draw in the terminal cell.
    glyph: []const u8,
    /// Foreground/background color plan for the glyph.
    style: TrueColorStyle,
};

/// Build a half-block cell plan from two vertical pixels.
///
/// This function does not composite, blend, or convert colors to terminal
/// styles. It only preserves the two input samples with the glyph convention
/// used by later renderers.
pub fn halfBlock(upper: Pixel, lower: Pixel) HalfBlockCell {
    return .{
        .upper = upper,
        .lower = lower,
    };
}

/// Map a half-block cell plan to a std-only truecolor cell plan.
///
/// The upper pixel becomes the foreground color of the `▀` glyph, and the lower
/// pixel becomes the background color. Alpha is intentionally preserved on the
/// original `HalfBlockCell` but ignored here; transparency/compositing policy is
/// left to a later helper or caller.
pub fn halfBlockTrueColor(cell: HalfBlockCell) TrueColorCell {
    return .{
        .glyph = cell.glyph,
        .style = .{
            .fg = cell.upper.rgb,
            .bg = cell.lower.rgb,
        },
    };
}

test "Rgb stores 8-bit color channels" {
    const color = Rgb{ .r = 10, .g = 20, .b = 30 };

    try std.testing.expectEqual(@as(u8, 10), color.r);
    try std.testing.expectEqual(@as(u8, 20), color.g);
    try std.testing.expectEqual(@as(u8, 30), color.b);
}

test "Pixel defaults to fully opaque" {
    const pixel = Pixel{ .rgb = .{ .r = 1, .g = 2, .b = 3 } };

    try std.testing.expectEqual(@as(u8, 1), pixel.rgb.r);
    try std.testing.expectEqual(@as(u8, 2), pixel.rgb.g);
    try std.testing.expectEqual(@as(u8, 3), pixel.rgb.b);
    try std.testing.expectEqual(@as(u8, 255), pixel.alpha);
}

test "Pixel can represent transparent samples" {
    const pixel = Pixel{
        .rgb = .{ .r = 0, .g = 0, .b = 0 },
        .alpha = 0,
    };

    try std.testing.expectEqual(@as(u8, 0), pixel.alpha);
}

test "halfBlock creates an upper-half render plan" {
    const upper = Pixel{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };
    const lower = Pixel{ .rgb = .{ .r = 0, .g = 0, .b = 255 } };
    const cell = halfBlock(upper, lower);

    try std.testing.expectEqualStrings("▀", cell.glyph);
    try std.testing.expectEqual(@as(u8, 255), cell.upper.rgb.r);
    try std.testing.expectEqual(@as(u8, 0), cell.upper.rgb.g);
    try std.testing.expectEqual(@as(u8, 0), cell.upper.rgb.b);
    try std.testing.expectEqual(@as(u8, 0), cell.lower.rgb.r);
    try std.testing.expectEqual(@as(u8, 0), cell.lower.rgb.g);
    try std.testing.expectEqual(@as(u8, 255), cell.lower.rgb.b);
}

test "halfBlock preserves alpha for later policy decisions" {
    const upper = Pixel{
        .rgb = .{ .r = 1, .g = 2, .b = 3 },
        .alpha = 128,
    };
    const lower = Pixel{
        .rgb = .{ .r = 4, .g = 5, .b = 6 },
        .alpha = 0,
    };
    const cell = halfBlock(upper, lower);

    try std.testing.expectEqual(@as(u8, 128), cell.upper.alpha);
    try std.testing.expectEqual(@as(u8, 0), cell.lower.alpha);
}

test "halfBlockTrueColor maps upper pixel to foreground and lower pixel to background" {
    const upper = Pixel{ .rgb = .{ .r = 255, .g = 10, .b = 20 } };
    const lower = Pixel{ .rgb = .{ .r = 30, .g = 40, .b = 255 } };
    const styled = halfBlockTrueColor(halfBlock(upper, lower));

    try std.testing.expectEqualStrings("▀", styled.glyph);
    try std.testing.expect(styled.style.fg != null);
    try std.testing.expect(styled.style.bg != null);
    try std.testing.expectEqual(@as(u8, 255), styled.style.fg.?.r);
    try std.testing.expectEqual(@as(u8, 10), styled.style.fg.?.g);
    try std.testing.expectEqual(@as(u8, 20), styled.style.fg.?.b);
    try std.testing.expectEqual(@as(u8, 30), styled.style.bg.?.r);
    try std.testing.expectEqual(@as(u8, 40), styled.style.bg.?.g);
    try std.testing.expectEqual(@as(u8, 255), styled.style.bg.?.b);
}

test "halfBlockTrueColor leaves alpha policy outside the style mapping" {
    const upper = Pixel{
        .rgb = .{ .r = 1, .g = 2, .b = 3 },
        .alpha = 0,
    };
    const lower = Pixel{
        .rgb = .{ .r = 4, .g = 5, .b = 6 },
        .alpha = 128,
    };
    const styled = halfBlockTrueColor(halfBlock(upper, lower));

    try std.testing.expectEqual(@as(u8, 1), styled.style.fg.?.r);
    try std.testing.expectEqual(@as(u8, 4), styled.style.bg.?.r);
}
