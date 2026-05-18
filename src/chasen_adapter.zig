const std = @import("std");
const chasen = @import("chasen");

const max_png_bytes = 16 * 1024 * 1024;
const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

/// Chasen `RunOptions.terminal_image_path_loader` for local PNG files.
///
/// This deliberately avoids `Vaxis.loadImage`, which currently pulls zigimg
/// into the compile path that caused Zig 0.16 compiler crashes in Chasen core
/// examples. It supports PNG files only, reads the IHDR dimensions directly,
/// base64-encodes the original PNG bytes, and lets libvaxis transmit the
/// pre-encoded image.
pub fn pngPathLoader(
    _: ?*anyopaque,
    vx: *chasen.TerminalImageLoaderVaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    path: []const u8,
) chasen.TerminalImagePathLoadError!chasen.TerminalImageLoaderImage {
    if (!vx.caps.kitty_graphics) return error.Unsupported;

    const bytes = std.Io.Dir.cwd().readFileAlloc(vx.io, path, allocator, .limited(max_png_bytes)) catch return error.LoadFailed;
    defer allocator.free(bytes);

    const dimensions = parsePngDimensions(bytes) catch return error.LoadFailed;

    const encoder = std.base64.standard.Encoder;
    const encoded = allocator.alloc(u8, encoder.calcSize(bytes.len)) catch return error.LoadFailed;
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, bytes);

    return vx.transmitPreEncodedImage(
        tty,
        encoded,
        dimensions.width,
        dimensions.height,
        .png,
    ) catch return error.LoadFailed;
}

const PngDimensions = struct {
    width: u16,
    height: u16,
};

fn parsePngDimensions(bytes: []const u8) !PngDimensions {
    if (bytes.len < 24) return error.InvalidPng;
    if (!std.mem.eql(u8, bytes[0..8], &png_signature)) return error.InvalidPng;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidPng;

    const width_u32 = std.mem.readInt(u32, bytes[16..20], .big);
    const height_u32 = std.mem.readInt(u32, bytes[20..24], .big);
    if (width_u32 == 0 or height_u32 == 0) return error.InvalidPng;
    if (width_u32 > std.math.maxInt(u16) or height_u32 > std.math.maxInt(u16))
        return error.InvalidPng;

    return .{
        .width = @intCast(width_u32),
        .height = @intCast(height_u32),
    };
}

test "parsePngDimensions reads IHDR width and height" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x01, 0x40, 0x00, 0x00, 0x00, 0xf0,
    };

    const dimensions = try parsePngDimensions(&bytes);

    try std.testing.expectEqual(@as(u16, 320), dimensions.width);
    try std.testing.expectEqual(@as(u16, 240), dimensions.height);
}

test "parsePngDimensions rejects non-PNG data" {
    const bytes = [_]u8{ 'n', 'o', 't', ' ', 'p', 'n', 'g' };

    try std.testing.expectError(error.InvalidPng, parsePngDimensions(&bytes));
}
