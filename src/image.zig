const std = @import("std");
const pixel = @import("pixel.zig");

/// Original image container format before decode.
///
/// This is metadata about the source. Decoded image pixels currently use
/// `PixelFormat.rgba8` regardless of whether the source was PNG, JPEG, or
/// another format.
pub const SourceFormat = enum {
    png,
    jpeg,
    webp,
    unknown,
};

/// Pixel buffer layout for `DecodedImage`.
pub const PixelFormat = enum {
    /// One `pixel.Pixel` per source sample, with 8-bit RGB and alpha channels.
    rgba8,
};

/// Image dimensions in pixels.
pub const Dimensions = struct {
    width: u32,
    height: u32,
};

/// Fit mode used when resizing an image into a target rectangle.
pub const FitMode = enum {
    /// Preserve aspect ratio and fit fully inside the target size.
    contain,
    /// Preserve aspect ratio and cover the target size before later crop work.
    cover,
    /// Ignore aspect ratio and force the target size.
    stretch,
};

/// Resize request for backend-neutral image processing.
pub const ResizeOptions = struct {
    /// Target width in pixels.
    width: u32,
    /// Target height in pixels.
    height: u32,
    /// How the source image should fit the target rectangle.
    fit: FitMode = .contain,
    /// Whether a smaller source image may be enlarged.
    allow_upscale: bool = false,
};

/// Owned decoded image buffer.
///
/// The buffer uses row-major order and one `pixel.Pixel` per pixel. Callers own
/// the allocator and must pass the same allocator to `deinit`.
pub const DecodedImage = struct {
    width: u32,
    height: u32,
    pixels: []pixel.Pixel,
    pixel_format: PixelFormat = .rgba8,
    source_format: SourceFormat = .unknown,
    /// True when decoder-specific orientation metadata has already been
    /// applied to the pixel buffer.
    orientation_applied: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        width: u32,
        height: u32,
        source_format: SourceFormat,
    ) !DecodedImage {
        const count = try pixelCount(width, height);
        const pixels = try allocator.alloc(pixel.Pixel, count);
        return .{
            .width = width,
            .height = height,
            .pixels = pixels,
            .source_format = source_format,
        };
    }

    pub fn deinit(self: *DecodedImage, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = .{
            .width = 0,
            .height = 0,
            .pixels = &.{},
        };
    }

    pub fn dimensions(self: *const DecodedImage) Dimensions {
        return .{ .width = self.width, .height = self.height };
    }

    pub fn pixelAt(self: *const DecodedImage, x: u32, y: u32) ?pixel.Pixel {
        if (x >= self.width or y >= self.height) return null;
        return self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn setPixel(self: *DecodedImage, x: u32, y: u32, value: pixel.Pixel) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = value;
    }
};

/// Return the pixel dimensions produced by a resize request.
pub fn fittedDimensions(source: Dimensions, options: ResizeOptions) !Dimensions {
    if (source.width == 0 or source.height == 0 or options.width == 0 or options.height == 0)
        return error.InvalidDimensions;

    if (!options.allow_upscale and source.width <= options.width and source.height <= options.height)
        return source;

    return switch (options.fit) {
        .stretch => .{ .width = options.width, .height = options.height },
        .contain => scaleToFit(source, options, .contain),
        .cover => scaleToFit(source, options, .cover),
    };
}

/// Resize with nearest-neighbor sampling.
///
/// This is intentionally simple. It provides a deterministic first slice for
/// cover art and fallback rendering; higher quality sampling can be added later
/// without changing the ownership model.
pub fn resizeNearest(
    allocator: std.mem.Allocator,
    source: *const DecodedImage,
    options: ResizeOptions,
) !DecodedImage {
    const target = try fittedDimensions(source.dimensions(), options);
    var out = try DecodedImage.init(allocator, target.width, target.height, source.source_format);
    errdefer out.deinit(allocator);
    out.orientation_applied = source.orientation_applied;

    for (0..@as(usize, target.height)) |y| {
        for (0..@as(usize, target.width)) |x| {
            const src_x = @as(u32, @intCast((x * @as(usize, source.width)) / @as(usize, target.width)));
            const src_y = @as(u32, @intCast((y * @as(usize, source.height)) / @as(usize, target.height)));
            out.setPixel(@intCast(x), @intCast(y), source.pixelAt(src_x, src_y).?);
        }
    }

    return out;
}

fn scaleToFit(source: Dimensions, options: ResizeOptions, mode: FitMode) Dimensions {
    const width_limited = @as(u64, options.width) * @as(u64, source.height) <= @as(u64, options.height) * @as(u64, source.width);
    const use_width = switch (mode) {
        .contain => width_limited,
        .cover => !width_limited,
        .stretch => unreachable,
    };

    var result = if (use_width) Dimensions{
        .width = options.width,
        .height = scaledOtherDimension(source.height, options.width, source.width),
    } else Dimensions{
        .width = scaledOtherDimension(source.width, options.height, source.height),
        .height = options.height,
    };

    if (!options.allow_upscale) {
        result.width = @min(result.width, source.width);
        result.height = @min(result.height, source.height);
    }

    result.width = @max(1, result.width);
    result.height = @max(1, result.height);
    return result;
}

fn scaledOtherDimension(source_other: u32, target_axis: u32, source_axis: u32) u32 {
    const numerator = @as(u64, source_other) * @as(u64, target_axis);
    const denominator = @as(u64, source_axis);
    return @intCast(@max(1, numerator / denominator));
}

fn pixelCount(width: u32, height: u32) !usize {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const count = @as(u64, width) * @as(u64, height);
    if (count > std.math.maxInt(usize)) return error.ImageTooLarge;
    return @intCast(count);
}

test "DecodedImage owns a row-major pixel buffer" {
    var image = try DecodedImage.init(std.testing.allocator, 2, 2, .png);
    defer image.deinit(std.testing.allocator);

    const red = pixel.Pixel{ .rgb = .{ .r = 255, .g = 0, .b = 0 } };
    image.setPixel(1, 1, red);

    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqual(SourceFormat.png, image.source_format);
    try std.testing.expectEqual(@as(u8, 255), image.pixelAt(1, 1).?.rgb.r);
    try std.testing.expect(image.pixelAt(2, 1) == null);
}

test "fittedDimensions contain preserves aspect ratio" {
    const dimensions = try fittedDimensions(.{ .width = 400, .height = 200 }, .{
        .width = 100,
        .height = 100,
    });

    try std.testing.expectEqual(Dimensions{ .width = 100, .height = 50 }, dimensions);
}

test "fittedDimensions cover preserves aspect ratio and covers target" {
    const dimensions = try fittedDimensions(.{ .width = 400, .height = 200 }, .{
        .width = 100,
        .height = 100,
        .fit = .cover,
    });

    try std.testing.expectEqual(Dimensions{ .width = 200, .height = 100 }, dimensions);
}

test "fittedDimensions stretch forces target size" {
    const dimensions = try fittedDimensions(.{ .width = 400, .height = 200 }, .{
        .width = 100,
        .height = 75,
        .fit = .stretch,
    });

    try std.testing.expectEqual(Dimensions{ .width = 100, .height = 75 }, dimensions);
}

test "fittedDimensions does not upscale by default" {
    const dimensions = try fittedDimensions(.{ .width = 40, .height = 20 }, .{
        .width = 100,
        .height = 100,
    });

    try std.testing.expectEqual(Dimensions{ .width = 40, .height = 20 }, dimensions);
}

test "resizeNearest samples source pixels" {
    var source = try DecodedImage.init(std.testing.allocator, 2, 2, .png);
    defer source.deinit(std.testing.allocator);

    source.setPixel(0, 0, .{ .rgb = .{ .r = 10, .g = 0, .b = 0 } });
    source.setPixel(1, 0, .{ .rgb = .{ .r = 20, .g = 0, .b = 0 } });
    source.setPixel(0, 1, .{ .rgb = .{ .r = 30, .g = 0, .b = 0 } });
    source.setPixel(1, 1, .{ .rgb = .{ .r = 40, .g = 0, .b = 0 } });

    var resized = try resizeNearest(std.testing.allocator, &source, .{
        .width = 1,
        .height = 1,
    });
    defer resized.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 1), resized.width);
    try std.testing.expectEqual(@as(u32, 1), resized.height);
    try std.testing.expectEqual(@as(u8, 10), resized.pixelAt(0, 0).?.rgb.r);
}
