const std = @import("std");
const graphics = @import("chasen_graphics");
const zigimg = @import("zigimg");

/// zigimg-backed generic image decode entrypoint.
///
/// This adapter is intentionally separate from the std-only `chasen_graphics`
/// root module. The first slice only establishes the dependency and API
/// boundary; JPEG pixel conversion is added after the Zig 0.16 compiler path is
/// verified.
pub fn decodeImage(allocator: std.mem.Allocator, bytes: []const u8) !graphics.image.DecodedImage {
    return switch (graphics.image.detectSourceFormat(bytes)) {
        .png => graphics.image.decodePng(allocator, bytes),
        .jpeg => decodeJpeg(allocator, bytes),
        .webp, .unknown => error.UnsupportedImageFormat,
    };
}

/// Decode JPEG bytes through zigimg.
///
/// Currently this is a placeholder so the optional adapter can be compiled and
/// tested before enabling the zigimg conversion path that previously hit Zig
/// 0.16 compiler issues.
pub fn decodeJpeg(_: std.mem.Allocator, _: []const u8) !graphics.image.DecodedImage {
    return error.UnsupportedImageFormat;
}

test "zigimg adapter imports zigimg without touching the std-only root" {
    try std.testing.expect(@hasDecl(zigimg, "Image"));
    try std.testing.expect(@hasDecl(graphics, "image"));
}

test "zigimg adapter reports JPEG decode as unsupported for the skeleton" {
    const jpeg_bytes = [_]u8{ 0xff, 0xd8, 0xff, 0xe0 };

    try std.testing.expectError(error.UnsupportedImageFormat, decodeImage(std.testing.allocator, &jpeg_bytes));
}
