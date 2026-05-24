const std = @import("std");
const chasen = @import("chasen");
const graphics = @import("chasen_graphics");

const max_png_bytes = 16 * 1024 * 1024;

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

    const info = graphics.image.pngInfo(bytes) catch return error.LoadFailed;
    if (info.dimensions.width > std.math.maxInt(u16) or info.dimensions.height > std.math.maxInt(u16))
        return error.LoadFailed;

    const encoder = std.base64.standard.Encoder;
    const encoded = allocator.alloc(u8, encoder.calcSize(bytes.len)) catch return error.LoadFailed;
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, bytes);

    return vx.transmitPreEncodedImage(
        tty,
        encoded,
        @intCast(info.dimensions.width),
        @intCast(info.dimensions.height),
        .png,
    ) catch return error.LoadFailed;
}
