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
