const std = @import("std");
const chasen = @import("chasen");
const graphics = @import("chasen_graphics");

const max_png_bytes = 16 * 1024 * 1024;
const max_image_bytes = 16 * 1024 * 1024;
const max_decoded_rgba_bytes = 64 * 1024 * 1024;

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

    return transmitEncodedPng(vx, tty, allocator, bytes);
}

/// Chasen `RunOptions.terminal_image_path_loader` for decoded local images.
///
/// Unlike `pngPathLoader`, this path goes through `graphics.image.decodeImage`
/// and transmits raw RGBA pixels. It is the format-aware loader intended for
/// callers that need JPEG cover art without pulling libvaxis' zigimg path into
/// the app compile.
pub fn decodedImagePathLoader(
    _: ?*anyopaque,
    vx: *chasen.TerminalImageLoaderVaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    path: []const u8,
) chasen.TerminalImagePathLoadError!chasen.TerminalImageLoaderImage {
    if (!vx.caps.kitty_graphics) return error.Unsupported;

    const bytes = std.Io.Dir.cwd().readFileAlloc(vx.io, path, allocator, .limited(max_image_bytes)) catch return error.LoadFailed;
    defer allocator.free(bytes);

    // Keep the existing robust path for PNG: terminals can consume encoded PNG
    // directly, while our decoded PNG subset is intentionally still small.
    if (graphics.image.detectSourceFormat(bytes) == .png) {
        return transmitEncodedPng(vx, tty, allocator, bytes);
    }

    try validateDecodedImageSize(bytes);

    var image = graphics.image.decodeImage(allocator, bytes) catch return error.LoadFailed;
    defer image.deinit(allocator);

    const rgba = rgbaBytesAlloc(allocator, &image) catch return error.LoadFailed;
    defer allocator.free(rgba);

    const encoder = std.base64.standard.Encoder;
    const encoded = allocator.alloc(u8, encoder.calcSize(rgba.len)) catch return error.LoadFailed;
    defer allocator.free(encoded);
    _ = encoder.encode(encoded, rgba);

    return vx.transmitPreEncodedImage(
        tty,
        encoded,
        @intCast(image.width),
        @intCast(image.height),
        .rgba,
    ) catch return error.LoadFailed;
}

/// Convert backend-neutral `graphics.terminal` placement options to Chasen.
///
/// Source clipping and pixel offsets are intentionally ignored for now because
/// Chasen's public terminal image options do not expose those controls yet.
/// Use this as a lossy conversion for the placement fields Chasen can currently
/// represent.
pub fn terminalImageOptions(options: graphics.terminal.ImagePlacementOptions) chasen.TerminalImageOptions {
    return .{
        .fit = switch (options.fit) {
            .none => .none,
            .fill => .fill,
            .fit => .fit,
            .contain => .contain,
        },
        .horizontal_align = switch (options.horizontal_align) {
            .left => .left,
            .center => .center,
            .right => .right,
        },
        .vertical_align = switch (options.vertical_align) {
            .top => .top,
            .middle => .middle,
            .bottom => .bottom,
        },
        .z_index = options.z_index,
    };
}

/// Chasen placement defaults for cover art.
pub fn coverArtTerminalImageOptions() chasen.TerminalImageOptions {
    return terminalImageOptions(graphics.terminal.coverArtPlacementOptions());
}

fn transmitEncodedPng(
    vx: *chasen.TerminalImageLoaderVaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    bytes: []const u8,
) chasen.TerminalImagePathLoadError!chasen.TerminalImageLoaderImage {
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

fn validateDecodedImageSize(bytes: []const u8) chasen.TerminalImagePathLoadError!void {
    const dimensions = switch (graphics.image.detectSourceFormat(bytes)) {
        .png => png: {
            const info = graphics.image.pngInfo(bytes) catch return error.LoadFailed;
            break :png info.dimensions;
        },
        .jpeg => jpeg: {
            const jpeg_info = graphics.image.jpegInfo(bytes) catch return error.LoadFailed;
            break :jpeg jpeg_info.dimensions;
        },
        .webp, .unknown => return error.LoadFailed,
    };
    if (dimensions.width > std.math.maxInt(u16) or dimensions.height > std.math.maxInt(u16))
        return error.LoadFailed;
    const pixels = std.math.mul(usize, @intCast(dimensions.width), @intCast(dimensions.height)) catch return error.LoadFailed;
    const rgba_bytes = std.math.mul(usize, pixels, 4) catch return error.LoadFailed;
    if (rgba_bytes > max_decoded_rgba_bytes) return error.LoadFailed;
}

fn rgbaBytesAlloc(allocator: std.mem.Allocator, image: *const graphics.image.DecodedImage) ![]u8 {
    const rgba_len = try std.math.mul(usize, image.pixels.len, 4);
    const out = try allocator.alloc(u8, rgba_len);
    var offset: usize = 0;
    for (image.pixels) |px| {
        out[offset] = px.rgb.r;
        out[offset + 1] = px.rgb.g;
        out[offset + 2] = px.rgb.b;
        out[offset + 3] = px.alpha;
        offset += 4;
    }
    return out;
}

test "RGBA byte conversion keeps row-major pixel order" {
    var image = try graphics.image.DecodedImage.init(std.testing.allocator, 2, 1, .jpeg);
    defer image.deinit(std.testing.allocator);
    image.setPixel(0, 0, .{ .rgb = .{ .r = 10, .g = 20, .b = 30 }, .alpha = 40 });
    image.setPixel(1, 0, .{ .rgb = .{ .r = 50, .g = 60, .b = 70 }, .alpha = 80 });

    const bytes = try rgbaBytesAlloc(std.testing.allocator, &image);
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60, 70, 80 }, bytes);
}

test "terminalImageOptions maps graphics placement to Chasen placement" {
    const opts = terminalImageOptions(.{
        .fit = .contain,
        .horizontal_align = .right,
        .vertical_align = .bottom,
        .z_index = 3,
    });

    try std.testing.expectEqual(chasen.TerminalImageFit.contain, opts.fit);
    try std.testing.expectEqual(chasen.terminal_image.TerminalImageHorizontalAlign.right, opts.horizontal_align);
    try std.testing.expectEqual(chasen.terminal_image.TerminalImageVerticalAlign.bottom, opts.vertical_align);
    try std.testing.expectEqual(@as(?i32, 3), opts.z_index);
}

test "terminalImageOptions intentionally ignores unsupported placement fields" {
    const opts = terminalImageOptions(.{
        .fit = .fit,
        .source_clip_px = .{
            .x = 1,
            .y = 2,
            .width = 3,
            .height = 4,
        },
        .pixel_offset = .{
            .x = 5,
            .y = 6,
        },
    });

    try std.testing.expectEqual(chasen.TerminalImageFit.fit, opts.fit);
    try std.testing.expectEqual(chasen.terminal_image.TerminalImageHorizontalAlign.left, opts.horizontal_align);
    try std.testing.expectEqual(chasen.terminal_image.TerminalImageVerticalAlign.top, opts.vertical_align);
    try std.testing.expectEqual(@as(?i32, null), opts.z_index);
}

test "coverArtTerminalImageOptions uses centered fit placement" {
    const opts = coverArtTerminalImageOptions();

    try std.testing.expectEqual(chasen.TerminalImageFit.fit, opts.fit);
    try std.testing.expectEqual(chasen.terminal_image.TerminalImageHorizontalAlign.center, opts.horizontal_align);
    try std.testing.expectEqual(chasen.terminal_image.TerminalImageVerticalAlign.middle, opts.vertical_align);
    try std.testing.expectEqual(@as(?i32, 1), opts.z_index);
}
