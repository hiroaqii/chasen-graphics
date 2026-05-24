const std = @import("std");
const pixel = @import("pixel.zig");

pub const png_signature = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

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

/// Basic PNG metadata read from the file header.
///
/// This is intentionally not a PNG decoder. It keeps the encoded-byte path
/// separate from `DecodedImage` while giving terminal adapters dimensions for
/// pre-encoded PNG transmission.
pub const PngInfo = struct {
    dimensions: Dimensions,
    bit_depth: u8,
    color_type: PngColorType,
    interlace_method: u8,
};

pub const PngColorType = enum(u8) {
    grayscale = 0,
    rgb = 2,
    indexed = 3,
    grayscale_alpha = 4,
    rgba = 6,
};

/// Basic JPEG metadata read from the first Start Of Frame marker.
pub const JpegInfo = struct {
    dimensions: Dimensions,
    precision: u8,
    component_count: u8,
    frame: JpegFrameKind,
};

pub const JpegFrameKind = enum {
    baseline,
    progressive,
    other,
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

/// Pixel-space rectangle used when cropping a decoded image.
pub const CropRect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
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

const PngHeader = struct {
    info: PngInfo,
    first_chunk_offset: usize,
};

/// Parse PNG header metadata from encoded bytes.
///
/// The function validates the PNG signature and IHDR location, then reads the
/// IHDR width and height. It does not inflate IDAT chunks or produce pixels.
pub fn pngInfo(bytes: []const u8) !PngInfo {
    return (try parsePngHeader(bytes)).info;
}

/// Parse JPEG dimensions and frame metadata from encoded bytes.
///
/// This does not entropy-decode image data. It only walks marker segments until
/// the first Start Of Frame marker that carries dimensions.
pub fn jpegInfo(bytes: []const u8) !JpegInfo {
    if (bytes.len < 4) return error.InvalidJpeg;
    if (bytes[0] != 0xff or bytes[1] != 0xd8) return error.InvalidJpeg;

    var offset: usize = 2;
    while (try nextJpegSegment(bytes, &offset)) |segment| {
        if (isJpegStartOfFrame(segment.marker)) {
            if (segment.data.len < 6) return error.InvalidJpeg;
            const precision = segment.data[0];
            const height = std.mem.readInt(u16, segment.data[1..3], .big);
            const width = std.mem.readInt(u16, segment.data[3..5], .big);
            const component_count = segment.data[5];
            if (width == 0 or height == 0 or component_count == 0) return error.InvalidJpeg;
            const expected_len = 6 + 3 * @as(usize, component_count);
            if (segment.data.len < expected_len) return error.InvalidJpeg;

            return .{
                .dimensions = .{ .width = width, .height = height },
                .precision = precision,
                .component_count = component_count,
                .frame = jpegFrameKind(segment.marker),
            };
        }
    }

    return error.InvalidJpeg;
}

/// Detect the source image format from encoded bytes.
///
/// This is intentionally a lightweight magic-byte check, not a full validator.
/// Decoders still validate their own container structure.
pub fn detectSourceFormat(bytes: []const u8) SourceFormat {
    if (bytes.len >= png_signature.len and std.mem.eql(u8, bytes[0..png_signature.len], &png_signature))
        return .png;
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff)
        return .jpeg;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP"))
        return .webp;
    return .unknown;
}

/// Decode encoded image bytes into `DecodedImage`.
///
/// PNG is the only implemented decoder in the first image pipeline slice.
/// Other recognized formats return `UnsupportedImageFormat` until their
/// decoder is intentionally added.
pub fn decodeImage(allocator: std.mem.Allocator, bytes: []const u8) !DecodedImage {
    return switch (detectSourceFormat(bytes)) {
        .png => decodePng(allocator, bytes),
        .jpeg, .webp, .unknown => error.UnsupportedImageFormat,
    };
}

/// Decode a small baseline subset of PNG into `DecodedImage`.
///
/// Supported first slice:
/// - bit depth 8
/// - color type RGB or RGBA
/// - no interlace
/// - PNG filters 0..4
pub fn decodePng(allocator: std.mem.Allocator, bytes: []const u8) !DecodedImage {
    const header = try parsePngHeader(bytes);
    const info = header.info;
    if (info.bit_depth != 8) return error.UnsupportedPng;
    if (info.interlace_method != 0) return error.UnsupportedPng;
    const channels: usize = switch (info.color_type) {
        .rgb => 3,
        .rgba => 4,
        else => return error.UnsupportedPng,
    };

    const compressed = try collectPngIdat(allocator, bytes, header.first_chunk_offset);
    defer allocator.free(compressed);

    const width_usize: usize = @intCast(info.dimensions.width);
    const height_usize: usize = @intCast(info.dimensions.height);
    const row_data_len = try checkedMul(width_usize, channels);
    const inflated_len = try checkedMul(height_usize, row_data_len + 1);
    const inflated = try allocator.alloc(u8, inflated_len);
    defer allocator.free(inflated);

    try inflateZlibExact(allocator, compressed, inflated);

    var image = try DecodedImage.init(allocator, info.dimensions.width, info.dimensions.height, .png);
    errdefer image.deinit(allocator);
    image.orientation_applied = true;

    try unfilterPngRows(allocator, &image, inflated, row_data_len, channels, info.color_type);
    return image;
}

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

/// Copy a rectangular region into a new owned image.
pub fn crop(
    allocator: std.mem.Allocator,
    source: *const DecodedImage,
    rect: CropRect,
) !DecodedImage {
    if (rect.width == 0 or rect.height == 0) return error.InvalidDimensions;
    const right = std.math.add(u32, rect.x, rect.width) catch return error.InvalidCrop;
    const bottom = std.math.add(u32, rect.y, rect.height) catch return error.InvalidCrop;
    if (right > source.width or bottom > source.height) return error.InvalidCrop;

    var out = try DecodedImage.init(allocator, rect.width, rect.height, source.source_format);
    errdefer out.deinit(allocator);
    out.orientation_applied = source.orientation_applied;

    for (0..@as(usize, rect.height)) |y| {
        for (0..@as(usize, rect.width)) |x| {
            const src_x = rect.x + @as(u32, @intCast(x));
            const src_y = rect.y + @as(u32, @intCast(y));
            out.setPixel(@intCast(x), @intCast(y), source.pixelAt(src_x, src_y).?);
        }
    }

    return out;
}

/// Crop the center of a decoded image to the requested dimensions.
pub fn cropCenter(
    allocator: std.mem.Allocator,
    source: *const DecodedImage,
    target: Dimensions,
) !DecodedImage {
    if (target.width == 0 or target.height == 0) return error.InvalidDimensions;
    if (target.width > source.width or target.height > source.height) return error.InvalidCrop;

    const x = (source.width - target.width) / 2;
    const y = (source.height - target.height) / 2;
    return crop(allocator, source, .{
        .x = x,
        .y = y,
        .width = target.width,
        .height = target.height,
    });
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

const JpegSegment = struct {
    marker: u8,
    data: []const u8,
};

fn nextJpegSegment(bytes: []const u8, offset: *usize) !?JpegSegment {
    while (offset.* < bytes.len and bytes[offset.*] != 0xff) {
        offset.* += 1;
    }
    if (offset.* >= bytes.len) return null;

    while (offset.* < bytes.len and bytes[offset.*] == 0xff) {
        offset.* += 1;
    }
    if (offset.* >= bytes.len) return error.InvalidJpeg;

    const marker = bytes[offset.*];
    offset.* += 1;

    if (marker == 0x00) return error.InvalidJpeg;
    if (marker == 0xd9) return null;
    if (marker == 0xda) return error.InvalidJpeg;
    if (isJpegStandaloneMarker(marker)) {
        return .{ .marker = marker, .data = &.{} };
    }

    if (offset.* + 2 > bytes.len) return error.InvalidJpeg;
    const segment_len = std.mem.readInt(u16, bytes[offset.*..][0..2], .big);
    if (segment_len < 2) return error.InvalidJpeg;

    const data_start = offset.* + 2;
    const data_len = @as(usize, segment_len) - 2;
    const data_end = try std.math.add(usize, data_start, data_len);
    if (data_end > bytes.len) return error.InvalidJpeg;

    offset.* = data_end;
    return .{ .marker = marker, .data = bytes[data_start..data_end] };
}

fn isJpegStandaloneMarker(marker: u8) bool {
    return marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7);
}

fn isJpegStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf => true,
        else => false,
    };
}

fn jpegFrameKind(marker: u8) JpegFrameKind {
    return switch (marker) {
        0xc0 => .baseline,
        0xc2 => .progressive,
        else => .other,
    };
}

fn parsePngHeader(bytes: []const u8) !PngHeader {
    if (bytes.len < 33) return error.InvalidPng;
    if (!std.mem.eql(u8, bytes[0..8], &png_signature)) return error.InvalidPng;
    const ihdr_len = std.mem.readInt(u32, bytes[8..12], .big);
    if (ihdr_len != 13) return error.InvalidPng;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidPng;
    const expected_crc = std.mem.readInt(u32, bytes[29..33], .big);
    const actual_crc = pngChunkCrc("IHDR", bytes[16..29]);
    if (actual_crc != expected_crc) return error.InvalidPng;

    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    if (width == 0 or height == 0) return error.InvalidPng;

    const color_type: PngColorType = switch (bytes[25]) {
        0 => .grayscale,
        2 => .rgb,
        3 => .indexed,
        4 => .grayscale_alpha,
        6 => .rgba,
        else => return error.InvalidPng,
    };
    if (bytes[26] != 0 or bytes[27] != 0) return error.InvalidPng;

    return .{
        .info = .{
            .dimensions = .{ .width = width, .height = height },
            .bit_depth = bytes[24],
            .color_type = color_type,
            .interlace_method = bytes[28],
        },
        .first_chunk_offset = 33,
    };
}

fn collectPngIdat(allocator: std.mem.Allocator, bytes: []const u8, start_offset: usize) ![]u8 {
    var total_len: usize = 0;
    var seen_iend = false;
    var seen_idat = false;
    var closed_idat = false;
    var offset = start_offset;
    while (try nextChunk(bytes, &offset)) |chunk| {
        if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            if (closed_idat) return error.InvalidPng;
            seen_idat = true;
            total_len = try std.math.add(usize, total_len, chunk.data.len);
        } else if (std.mem.eql(u8, chunk.kind, "IEND")) {
            if (chunk.data.len != 0) return error.InvalidPng;
            seen_iend = true;
            break;
        } else if (seen_idat) {
            closed_idat = true;
        }
    }
    if (!seen_iend) return error.InvalidPng;
    if (total_len == 0) return error.InvalidPng;

    const out = try allocator.alloc(u8, total_len);
    errdefer allocator.free(out);
    var written: usize = 0;
    offset = start_offset;
    while (try nextChunk(bytes, &offset)) |chunk| {
        if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            @memcpy(out[written .. written + chunk.data.len], chunk.data);
            written += chunk.data.len;
        } else if (std.mem.eql(u8, chunk.kind, "IEND")) {
            break;
        }
    }

    return out;
}

const PngChunk = struct {
    kind: []const u8,
    data: []const u8,
};

fn nextChunk(bytes: []const u8, offset: *usize) !?PngChunk {
    if (offset.* == bytes.len) return null;
    if (offset.* + 12 > bytes.len) return error.InvalidPng;

    const len = std.mem.readInt(u32, bytes[offset.*..][0..4], .big);
    const data_start = try std.math.add(usize, offset.*, 8);
    const data_end = try std.math.add(usize, data_start, @intCast(len));
    const crc_end = try std.math.add(usize, data_end, 4);
    if (crc_end > bytes.len) return error.InvalidPng;

    const expected_crc = std.mem.readInt(u32, bytes[data_end..][0..4], .big);
    const actual_crc = pngChunkCrc(bytes[offset.* + 4 .. offset.* + 8], bytes[data_start..data_end]);
    if (actual_crc != expected_crc) return error.InvalidPng;

    const chunk = PngChunk{
        .kind = bytes[offset.* + 4 .. offset.* + 8],
        .data = bytes[data_start..data_end],
    };
    offset.* = crc_end;
    return chunk;
}

fn pngChunkCrc(kind: []const u8, data: []const u8) u32 {
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    return crc.final();
}

fn inflateZlibExact(allocator: std.mem.Allocator, compressed: []const u8, out: []u8) !void {
    if (compressed.len < std.compress.flate.Container.zlib.size()) return error.InvalidPng;

    var reader: std.Io.Reader = .fixed(compressed);
    var flate_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&reader, .zlib, &flate_buffer);

    const scratch_len = try std.math.add(usize, out.len, 1);
    const scratch = try allocator.alloc(u8, scratch_len);
    defer allocator.free(scratch);

    var writer: std.Io.Writer = .fixed(scratch);
    const decompressed_len = decompress.reader.streamRemaining(&writer) catch return error.InvalidPng;
    if (decompressed_len != out.len) return error.InvalidPng;
    @memcpy(out, scratch[0..out.len]);

    const expected_adler = std.mem.readInt(u32, compressed[compressed.len - 4 ..][0..4], .big);
    const actual_adler = std.hash.Adler32.hash(out);
    if (actual_adler != expected_adler) return error.InvalidPng;
}

fn unfilterPngRows(allocator: std.mem.Allocator, image: *DecodedImage, inflated: []const u8, row_data_len: usize, channels: usize, color_type: PngColorType) !void {
    const height: usize = @intCast(image.height);
    const width: usize = @intCast(image.width);
    const previous_row = try allocator.alloc(u8, row_data_len);
    defer allocator.free(previous_row);
    @memset(previous_row, 0);

    const current_row = try allocator.alloc(u8, row_data_len);
    defer allocator.free(current_row);

    for (0..height) |y| {
        const row_start = y * (row_data_len + 1);
        const filter = inflated[row_start];
        const encoded = inflated[row_start + 1 .. row_start + 1 + row_data_len];
        try unfilterRow(current_row, encoded, previous_row, channels, filter);

        for (0..width) |x| {
            const offset = x * channels;
            const value = switch (color_type) {
                .rgb => pixel.Pixel{ .rgb = .{
                    .r = current_row[offset],
                    .g = current_row[offset + 1],
                    .b = current_row[offset + 2],
                } },
                .rgba => pixel.Pixel{
                    .rgb = .{
                        .r = current_row[offset],
                        .g = current_row[offset + 1],
                        .b = current_row[offset + 2],
                    },
                    .alpha = current_row[offset + 3],
                },
                else => unreachable,
            };
            image.setPixel(@intCast(x), @intCast(y), value);
        }

        @memcpy(previous_row, current_row);
    }
}

fn unfilterRow(out: []u8, encoded: []const u8, previous: []const u8, bytes_per_pixel: usize, filter: u8) !void {
    for (encoded, 0..) |byte, index| {
        const left = if (index >= bytes_per_pixel) out[index - bytes_per_pixel] else 0;
        const up = previous[index];
        const upper_left = if (index >= bytes_per_pixel) previous[index - bytes_per_pixel] else 0;
        const predictor: u8 = switch (filter) {
            0 => 0,
            1 => left,
            2 => up,
            3 => @intCast((@as(u16, left) + @as(u16, up)) / 2),
            4 => paeth(left, up, upper_left),
            else => return error.UnsupportedPng,
        };
        out[index] = byte +% predictor;
    }
}

fn paeth(left: u8, up: u8, upper_left: u8) u8 {
    const a: i32 = left;
    const b: i32 = up;
    const c: i32 = upper_left;
    const p = a + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return left;
    if (pb <= pc) return up;
    return upper_left;
}

fn checkedMul(a: usize, b: usize) !usize {
    return std.math.mul(usize, a, b) catch error.ImageTooLarge;
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

test "pngInfo reads IHDR width and height" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x01, 0x40, 0x00, 0x00, 0x00, 0xf0,
        0x08, 0x06, 0x00, 0x00, 0x00, 113,  45,   189,
        107,
    };

    const info = try pngInfo(&bytes);

    try std.testing.expectEqual(Dimensions{ .width = 320, .height = 240 }, info.dimensions);
    try std.testing.expectEqual(@as(u8, 8), info.bit_depth);
    try std.testing.expectEqual(PngColorType.rgba, info.color_type);
}

test "pngInfo rejects non-PNG data" {
    const bytes = [_]u8{ 'n', 'o', 't', ' ', 'p', 'n', 'g' };

    try std.testing.expectError(error.InvalidPng, pngInfo(&bytes));
}

test "pngInfo rejects invalid IHDR length" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0c, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x01, 0x40, 0x00, 0x00, 0x00, 0xf0,
        0x08, 0x06, 0x00, 0x00, 0x00, 113,  45,   189,
        107,
    };

    try std.testing.expectError(error.InvalidPng, pngInfo(&bytes));
}

test "pngInfo rejects invalid IHDR CRC" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x01, 0x40, 0x00, 0x00, 0x00, 0xf0,
        0x08, 0x06, 0x00, 0x00, 0x00, 113,  45,   189,
        108,
    };

    try std.testing.expectError(error.InvalidPng, pngInfo(&bytes));
}

test "jpegInfo reads SOF dimensions" {
    const bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xe0,
        0x00, 0x10,
        'J',  'F',
        'I',  'F',
        0x00, 0x01,
        0x01, 0x00,
        0x00, 0x01,
        0x00, 0x01,
        0x00, 0x00,
        0xff, 0xc0,
        0x00, 0x11,
        0x08, 0x00,
        0xf0, 0x01,
        0x40, 0x03,
        0x01, 0x11,
        0x00, 0x02,
        0x11, 0x00,
        0x03, 0x11,
        0x00, 0xff,
        0xd9,
    };

    const info = try jpegInfo(&bytes);

    try std.testing.expectEqual(Dimensions{ .width = 320, .height = 240 }, info.dimensions);
    try std.testing.expectEqual(@as(u8, 8), info.precision);
    try std.testing.expectEqual(@as(u8, 3), info.component_count);
    try std.testing.expectEqual(JpegFrameKind.baseline, info.frame);
}

test "jpegInfo rejects non-JPEG data" {
    const bytes = [_]u8{ 'n', 'o', 't', ' ', 'j', 'p', 'e', 'g' };

    try std.testing.expectError(error.InvalidJpeg, jpegInfo(&bytes));
}

test "jpegInfo rejects JPEG without SOF metadata" {
    const bytes = [_]u8{ 0xff, 0xd8, 0xff, 0xd9 };

    try std.testing.expectError(error.InvalidJpeg, jpegInfo(&bytes));
}

test "jpegInfo rejects truncated marker segment" {
    const bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xe0,
        0x00, 0x10,
        'J',  'F',
    };

    try std.testing.expectError(error.InvalidJpeg, jpegInfo(&bytes));
}

test "jpegInfo rejects incomplete SOF component specs" {
    const bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xc0,
        0x00, 0x08,
        0x08, 0x00,
        0xf0, 0x01,
        0x40, 0x03,
        0xff, 0xd9,
    };

    try std.testing.expectError(error.InvalidJpeg, jpegInfo(&bytes));
}

test "detectSourceFormat recognizes common image containers" {
    const png_bytes = [_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    const jpeg_bytes = [_]u8{ 0xff, 0xd8, 0xff, 0xe0 };
    const webp_bytes = [_]u8{ 'R', 'I', 'F', 'F', 1, 0, 0, 0, 'W', 'E', 'B', 'P' };
    const unknown_bytes = [_]u8{ 'n', 'o', 'p', 'e' };

    try std.testing.expectEqual(SourceFormat.png, detectSourceFormat(&png_bytes));
    try std.testing.expectEqual(SourceFormat.jpeg, detectSourceFormat(&jpeg_bytes));
    try std.testing.expectEqual(SourceFormat.webp, detectSourceFormat(&webp_bytes));
    try std.testing.expectEqual(SourceFormat.unknown, detectSourceFormat(&unknown_bytes));
}

test "decodeImage rejects unsupported formats" {
    const jpeg_bytes = [_]u8{ 0xff, 0xd8, 0xff, 0xe0 };

    try std.testing.expectError(error.UnsupportedImageFormat, decodeImage(std.testing.allocator, &jpeg_bytes));
}

test "decodePng decodes RGBA8 pixels" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 31,   21,   196,
        137,  0x00, 0x00, 0x00, 0x0d, 'I',  'D',  'A',
        'T',  120,  156,  99,   248,  207,  192,  240,
        31,   0,    5,    0,    1,    255,  137,  153,
        61,   29,   0x00, 0x00, 0x00, 0x00, 'I',  'E',
        'N',  'D',  174,  66,   96,   130,
    };

    var image = try decodePng(std.testing.allocator, &bytes);
    defer image.deinit(std.testing.allocator);

    const value = image.pixelAt(0, 0).?;
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqual(@as(u8, 255), value.rgb.r);
    try std.testing.expectEqual(@as(u8, 0), value.rgb.g);
    try std.testing.expectEqual(@as(u8, 0), value.rgb.b);
    try std.testing.expectEqual(@as(u8, 255), value.alpha);
    try std.testing.expect(image.orientation_applied);
}

test "decodeImage dispatches PNG bytes" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 31,   21,   196,
        137,  0x00, 0x00, 0x00, 0x0d, 'I',  'D',  'A',
        'T',  120,  156,  99,   248,  207,  192,  240,
        31,   0,    5,    0,    1,    255,  137,  153,
        61,   29,   0x00, 0x00, 0x00, 0x00, 'I',  'E',
        'N',  'D',  174,  66,   96,   130,
    };

    var image = try decodeImage(std.testing.allocator, &bytes);
    defer image.deinit(std.testing.allocator);

    try std.testing.expectEqual(SourceFormat.png, image.source_format);
    try std.testing.expectEqual(@as(u8, 255), image.pixelAt(0, 0).?.rgb.r);
}

test "decodePng rejects extra decompressed bytes" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 31,   21,   196,
        137,  0x00, 0x00, 0x00, 0x0e, 'I',  'D',  'A',
        'T',  120,  156,  99,   248,  207,  192,  240,
        159,  1,    0,    6,    255,  1,    255,  7,
        43,   142,  246,  0x00, 0x00, 0x00, 0x00, 'I',
        'E',  'N',  'D',  174,  66,   96,   130,
    };

    try std.testing.expectError(error.InvalidPng, decodePng(std.testing.allocator, &bytes));
}

test "decodePng rejects corrupted zlib checksum" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 31,   21,   196,
        137,  0x00, 0x00, 0x00, 0x0d, 'I',  'D',  'A',
        'T',  120,  156,  99,   248,  207,  192,  240,
        31,   0,    5,    0,    1,    254,  254,  158,
        13,   139,  0x00, 0x00, 0x00, 0x00, 'I',  'E',
        'N',  'D',  174,  66,   96,   130,
    };

    try std.testing.expectError(error.InvalidPng, decodePng(std.testing.allocator, &bytes));
}

test "decodePng rejects non-empty IEND chunk" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 31,   21,   196,
        137,  0x00, 0x00, 0x00, 0x0d, 'I',  'D',  'A',
        'T',  120,  156,  99,   248,  207,  192,  240,
        31,   0,    5,    0,    1,    255,  137,  153,
        61,   29,   0x00, 0x00, 0x00, 0x01, 'I',  'E',
        'N',  'D',  'x',  143,  196,  182,  239,
    };

    try std.testing.expectError(error.InvalidPng, decodePng(std.testing.allocator, &bytes));
}

test "decodePng rejects non-contiguous IDAT chunks" {
    const bytes = [_]u8{
        0x89, 'P',  'N',  'G',  '\r', '\n', 0x1a, '\n',
        0x00, 0x00, 0x00, 0x0d, 'I',  'H',  'D',  'R',
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 31,   21,   196,
        137,  0x00, 0x00, 0x00, 0x0d, 'I',  'D',  'A',
        'T',  120,  156,  99,   248,  207,  192,  240,
        31,   0,    5,    0,    1,    255,  137,  153,
        61,   29,   0x00, 0x00, 0x00, 0x00, 't',  'E',
        'X',  't',  150,  66,   197,  133,  0x00, 0x00,
        0x00, 0x00, 'I',  'D',  'A',  'T',  53,   175,
        6,    30,   0x00, 0x00, 0x00, 0x00, 'I',  'E',
        'N',  'D',  174,  66,   96,   130,
    };

    try std.testing.expectError(error.InvalidPng, decodePng(std.testing.allocator, &bytes));
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

test "resizeNearest cover returns dimensions that cover target" {
    var source = try DecodedImage.init(std.testing.allocator, 4, 2, .png);
    defer source.deinit(std.testing.allocator);

    var resized = try resizeNearest(std.testing.allocator, &source, .{
        .width = 2,
        .height = 2,
        .fit = .cover,
    });
    defer resized.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 4), resized.width);
    try std.testing.expectEqual(@as(u32, 2), resized.height);
}

test "crop copies a rectangular region" {
    var source = try DecodedImage.init(std.testing.allocator, 3, 2, .png);
    defer source.deinit(std.testing.allocator);

    source.setPixel(0, 0, .{ .rgb = .{ .r = 10, .g = 0, .b = 0 } });
    source.setPixel(1, 0, .{ .rgb = .{ .r = 20, .g = 0, .b = 0 } });
    source.setPixel(2, 0, .{ .rgb = .{ .r = 30, .g = 0, .b = 0 } });
    source.setPixel(0, 1, .{ .rgb = .{ .r = 40, .g = 0, .b = 0 } });
    source.setPixel(1, 1, .{ .rgb = .{ .r = 50, .g = 0, .b = 0 } });
    source.setPixel(2, 1, .{ .rgb = .{ .r = 60, .g = 0, .b = 0 } });

    var cropped = try crop(std.testing.allocator, &source, .{
        .x = 1,
        .y = 0,
        .width = 2,
        .height = 2,
    });
    defer cropped.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), cropped.width);
    try std.testing.expectEqual(@as(u32, 2), cropped.height);
    try std.testing.expectEqual(@as(u8, 20), cropped.pixelAt(0, 0).?.rgb.r);
    try std.testing.expectEqual(@as(u8, 30), cropped.pixelAt(1, 0).?.rgb.r);
    try std.testing.expectEqual(@as(u8, 50), cropped.pixelAt(0, 1).?.rgb.r);
    try std.testing.expectEqual(@as(u8, 60), cropped.pixelAt(1, 1).?.rgb.r);
}

test "crop rejects out-of-bounds regions" {
    var source = try DecodedImage.init(std.testing.allocator, 2, 2, .png);
    defer source.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidCrop, crop(std.testing.allocator, &source, .{
        .x = 1,
        .y = 0,
        .width = 2,
        .height = 1,
    }));
}

test "crop rejects overflowing regions as invalid crop" {
    var source = try DecodedImage.init(std.testing.allocator, 2, 2, .png);
    defer source.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidCrop, crop(std.testing.allocator, &source, .{
        .x = std.math.maxInt(u32),
        .y = 0,
        .width = 1,
        .height = 1,
    }));
}

test "cropCenter crops the centered region" {
    var source = try DecodedImage.init(std.testing.allocator, 4, 2, .png);
    defer source.deinit(std.testing.allocator);

    source.setPixel(1, 0, .{ .rgb = .{ .r = 20, .g = 0, .b = 0 } });
    source.setPixel(2, 0, .{ .rgb = .{ .r = 30, .g = 0, .b = 0 } });
    source.setPixel(1, 1, .{ .rgb = .{ .r = 60, .g = 0, .b = 0 } });
    source.setPixel(2, 1, .{ .rgb = .{ .r = 70, .g = 0, .b = 0 } });

    var cropped = try cropCenter(std.testing.allocator, &source, .{ .width = 2, .height = 2 });
    defer cropped.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), cropped.width);
    try std.testing.expectEqual(@as(u32, 2), cropped.height);
    try std.testing.expectEqual(@as(u8, 20), cropped.pixelAt(0, 0).?.rgb.r);
    try std.testing.expectEqual(@as(u8, 30), cropped.pixelAt(1, 0).?.rgb.r);
    try std.testing.expectEqual(@as(u8, 60), cropped.pixelAt(0, 1).?.rgb.r);
    try std.testing.expectEqual(@as(u8, 70), cropped.pixelAt(1, 1).?.rgb.r);
}
