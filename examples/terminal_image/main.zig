const std = @import("std");
const chasen = @import("chasen");
const chasen_graphics_chasen = @import("chasen_graphics_chasen");

const sample_path = ".zig-cache/chasen-graphics-terminal-image-example.png";
const sample_width = 48;
const sample_height = 24;

const TerminalImageExample = struct {
    image: ?chasen.TerminalImageHandle = null,
    load_error: ?chasen.TerminalImageLoadError = null,

    pub const Msg = union(enum) {
        image_loaded: chasen.TerminalImageHandle,
        image_failed: chasen.TerminalImageLoadError,
        quit,
    };

    pub fn init(self: *TerminalImageExample, ctx: *chasen.Ctx(Msg)) !void {
        _ = self;
        _ = try ctx.image().loadPath(sample_path, &loaded, &failed);
    }

    pub fn update(self: *TerminalImageExample, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .image_loaded => |handle| {
                self.image = handle;
                self.load_error = null;
            },
            .image_failed => |reason| {
                self.image = null;
                self.load_error = reason;
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const TerminalImageExample, sfc: *chasen.Surface) !void {
        sfc.clearAll();

        _ = sfc.borrowTextAt(0, 0, "Terminal Image Example", .{ .bold = true });
        _ = sfc.borrowTextAt(0, 1, "q: quit", .{ .fg = .gray });
        _ = sfc.borrowTextAt(0, 3, "This wires chasen_graphics_chasen.decodedImagePathLoader into chasen.runWith.", .{});

        const size = sfc.size();
        const image_area = chasen.Rect{
            .col = 2,
            .row = 6,
            .width = if (size.width > 4) size.width - 4 else size.width,
            .height = if (size.height > 11) size.height - 10 else 1,
        };

        var image_surface = sfc.child(image_area);
        if (self.image) |handle| {
            // Keep the destination cells blank while the image is visible.
            // Regular text cells drawn after a Kitty placement can cover the
            // image, so the dotted placeholder is only used before load/error.
            image_surface.clearAll();
            try image_surface.drawTerminalImage(handle, chasen_graphics_chasen.coverArtTerminalImageOptions());
            _ = sfc.borrowTextAt(0, 4, "Loaded image through the optional Chasen adapter.", .{ .fg = .{ .index = 2 } });
        } else if (self.load_error) |reason| {
            sfc.fill(image_area, .{
                .char = .{ .grapheme = ".", .width = 1 },
                .style = .{ .dim = true },
            });
            const label = switch (reason) {
                .unsupported => "Terminal image loading is unsupported in this terminal.",
                .load_failed => "Could not load or transmit the PNG image.",
                .registry_full => "Image registry is full.",
            };
            _ = sfc.borrowTextAt(0, 4, label, .{ .fg = .{ .index = 1 } });
        } else {
            sfc.fill(image_area, .{
                .char = .{ .grapheme = ".", .width = 1 },
                .style = .{ .dim = true },
            });
            _ = sfc.borrowTextAt(0, 4, "Loading PNG image...", .{ .fg = .gray });
        }
    }

    pub fn handleEvent(self: *const TerminalImageExample, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }
};

fn loaded(_: chasen.TerminalImageRequestId, handle: chasen.TerminalImageHandle) TerminalImageExample.Msg {
    return .{ .image_loaded = handle };
}

fn failed(_: chasen.TerminalImageRequestId, reason: chasen.TerminalImageLoadError) TerminalImageExample.Msg {
    return .{ .image_failed = reason };
}

pub fn main(init: std.process.Init) !void {
    const sample_png = try buildSamplePng(init.gpa);
    defer init.gpa.free(sample_png);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = sample_path,
        .data = sample_png,
    });

    try chasen.runWith(.{
        .runtime = .{
            .allocator = init.gpa,
            .io = init.io,
        },
        .terminal = .{
            .env_map = init.environ_map,
            .image_path_loader = chasen_graphics_chasen.decodedImagePathLoader,
        },
    }, TerminalImageExample{});
}

fn buildSamplePng(allocator: std.mem.Allocator) ![]const u8 {
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);

    var row: usize = 0;
    while (row < sample_height) : (row += 1) {
        try raw.append(allocator, 0);
        var col: usize = 0;
        while (col < sample_width) : (col += 1) {
            const block = ((row / 4) + (col / 6)) % 2 == 0;
            const r: u8 = if (block) 0x1f else 0xec;
            const g: u8 = if (block) 0x8f else 0x5a;
            const b: u8 = if (block) 0xe5 else 0x24;
            try raw.append(allocator, r);
            try raw.append(allocator, g);
            try raw.append(allocator, b);
        }
    }

    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);
    try appendZlibStoredBlock(&idat, allocator, raw.items);

    var png: std.ArrayList(u8) = .empty;
    try png.appendSlice(allocator, &.{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a });

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(allocator);
    try appendU32Be(&ihdr, allocator, sample_width);
    try appendU32Be(&ihdr, allocator, sample_height);
    try ihdr.appendSlice(allocator, &.{ 8, 2, 0, 0, 0 });

    try appendPngChunk(&png, allocator, "IHDR", ihdr.items);
    try appendPngChunk(&png, allocator, "IDAT", idat.items);
    try appendPngChunk(&png, allocator, "IEND", "");

    return png.toOwnedSlice(allocator);
}

fn appendZlibStoredBlock(out: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    try out.appendSlice(allocator, &.{ 0x78, 0x01 });

    var remaining = data;
    while (remaining.len > 0) {
        const chunk_len = @min(remaining.len, 65535);
        const final: u8 = if (chunk_len == remaining.len) 1 else 0;
        const len: u16 = @intCast(chunk_len);
        const nlen = ~len;

        try out.append(allocator, final);
        try appendU16Le(out, allocator, len);
        try appendU16Le(out, allocator, nlen);
        try out.appendSlice(allocator, remaining[0..chunk_len]);
        remaining = remaining[chunk_len..];
    }

    try appendU32Be(out, allocator, std.hash.Adler32.hash(data));
}

fn appendPngChunk(out: *std.ArrayList(u8), allocator: std.mem.Allocator, chunk_type: *const [4]u8, data: []const u8) !void {
    try appendU32Be(out, allocator, data.len);
    try out.appendSlice(allocator, chunk_type);
    try out.appendSlice(allocator, data);

    var crc_body: std.ArrayList(u8) = .empty;
    defer crc_body.deinit(allocator);
    try crc_body.appendSlice(allocator, chunk_type);
    try crc_body.appendSlice(allocator, data);
    try appendU32Be(out, allocator, std.hash.crc.Crc32.hash(crc_body.items));
}

fn appendU16Le(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    try out.append(allocator, @intCast(value & 0xff));
    try out.append(allocator, @intCast(value >> 8));
}

fn appendU32Be(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {
    const n: u32 = @intCast(value);
    try out.append(allocator, @intCast((n >> 24) & 0xff));
    try out.append(allocator, @intCast((n >> 16) & 0xff));
    try out.append(allocator, @intCast((n >> 8) & 0xff));
    try out.append(allocator, @intCast(n & 0xff));
}
