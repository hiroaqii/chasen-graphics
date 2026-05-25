const std = @import("std");
const common = @import("common.zig");

pub const Info = common.JpegInfo;
pub const FrameKind = common.JpegFrameKind;
const Dimensions = common.Dimensions;

const Segment = struct {
    marker: u8,
    data: []const u8,
};

const Component = struct {
    id: u8,
    horizontal_sampling: u4,
    vertical_sampling: u4,
    quantization_table_id: u8,
};

const FrameHeader = struct {
    dimensions: Dimensions,
    precision: u8,
    components: [4]Component = undefined,
    component_count: u8,
    frame: FrameKind,
};

const QuantizationTable = struct {
    precision: u1,
    id: u8,
    values: [64]u16,
};

const HuffmanTableClass = enum {
    dc,
    ac,
};

const HuffmanTable = struct {
    class: HuffmanTableClass,
    id: u8,
    code_counts: [16]u8,
    symbols: [256]u8 = [_]u8{0} ** 256,
    symbol_count: u8,
};

const ScanComponent = struct {
    id: u8,
    dc_table_id: u8,
    ac_table_id: u8,
};

const ScanHeader = struct {
    components: [4]ScanComponent = undefined,
    component_count: u8,
    spectral_start: u8,
    spectral_end: u8,
    successive_approximation_high: u4,
    successive_approximation_low: u4,
};

const DecodeState = struct {
    frame: ?FrameHeader = null,
    quantization_tables: [4]?QuantizationTable = [_]?QuantizationTable{null} ** 4,
    dc_huffman_tables: [4]?HuffmanTable = [_]?HuffmanTable{null} ** 4,
    ac_huffman_tables: [4]?HuffmanTable = [_]?HuffmanTable{null} ** 4,
    scan: ?ScanHeader = null,
    restart_interval: ?u16 = null,
    scan_data_offset: usize = 0,
};

const HuffmanCode = struct {
    code: u16,
    length: u5,
    symbol: u8,
};

const CanonicalHuffmanTable = struct {
    codes: [256]HuffmanCode = undefined,
    count: usize = 0,

    fn init(table: HuffmanTable) !CanonicalHuffmanTable {
        var result = CanonicalHuffmanTable{};
        var code: u32 = 0;
        var symbol_index: usize = 0;

        for (table.code_counts, 0..) |code_count, length_index| {
            code <<= 1;
            const length: u5 = @intCast(length_index + 1);
            const max_code_for_length = @as(u32, 1) << length;
            if (code + code_count > max_code_for_length) return error.InvalidJpeg;

            for (0..code_count) |_| {
                if (symbol_index >= table.symbol_count) return error.InvalidJpeg;
                result.codes[result.count] = .{
                    .code = @intCast(code),
                    .length = length,
                    .symbol = table.symbols[symbol_index],
                };
                result.count += 1;
                symbol_index += 1;
                code += 1;
            }
        }

        if (symbol_index != table.symbol_count) return error.InvalidJpeg;
        return result;
    }

    fn decode(self: *const CanonicalHuffmanTable, reader: *EntropyBitReader) !u8 {
        var code: u16 = 0;
        for (1..17) |length_usize| {
            const bit = try reader.readBit();
            code = (code << 1) | bit;
            const length: u5 = @intCast(length_usize);

            for (self.codes[0..self.count]) |entry| {
                if (entry.length == length and entry.code == code) return entry.symbol;
            }
        }

        return error.InvalidJpeg;
    }
};

const EntropyBitReader = struct {
    data: []const u8,
    offset: usize = 0,
    current_byte: u8 = 0,
    bits_left: u4 = 0,

    fn init(data: []const u8) EntropyBitReader {
        return .{ .data = data };
    }

    fn readBit(self: *EntropyBitReader) !u1 {
        if (self.bits_left == 0) {
            self.current_byte = try self.nextByte();
            self.bits_left = 8;
        }

        self.bits_left -= 1;
        const shift: u3 = @intCast(self.bits_left);
        return @intCast((self.current_byte >> shift) & 1);
    }

    fn readBits(self: *EntropyBitReader, count: u4) !u16 {
        if (count > 16) return error.InvalidJpeg;
        var value: u16 = 0;
        for (0..count) |_| {
            value = (value << 1) | try self.readBit();
        }
        return value;
    }

    fn nextByte(self: *EntropyBitReader) !u8 {
        if (self.offset >= self.data.len) return error.InvalidJpeg;
        const byte = self.data[self.offset];
        self.offset += 1;
        if (byte != 0xff) return byte;

        if (self.offset >= self.data.len) return error.InvalidJpeg;
        const marker = self.data[self.offset];
        if (marker == 0x00) {
            self.offset += 1;
            return 0xff;
        }
        if (marker >= 0xd0 and marker <= 0xd7) return error.UnsupportedJpeg;
        if (marker == 0xd9) return error.InvalidJpeg;
        return error.InvalidJpeg;
    }
};

const Block = [64]i16;
const DequantizedBlock = [64]i32;
const SampleBlock = [64]u8;

fn decodeMagnitude(value: u16, size: u4) !i16 {
    if (size == 0) return 0;
    if (size > 11) return error.UnsupportedJpeg;
    const threshold = @as(u16, 1) << (size - 1);
    if (value >= threshold) return @intCast(value);

    const extend = @as(i32, value) + 1 - (@as(i32, 1) << size);
    return @intCast(extend);
}

fn readMagnitude(reader: *EntropyBitReader, size: u4) !i16 {
    if (size == 0) return 0;
    return decodeMagnitude(try reader.readBits(size), size);
}

fn decodeBlock(
    reader: *EntropyBitReader,
    dc_table: *const CanonicalHuffmanTable,
    ac_table: *const CanonicalHuffmanTable,
    previous_dc: *i16,
) !Block {
    var block = [_]i16{0} ** 64;

    const dc_size_raw = try dc_table.decode(reader);
    if (dc_size_raw > 11) return error.InvalidJpeg;
    const dc_size: u4 = @intCast(dc_size_raw);
    const dc_delta = try readMagnitude(reader, dc_size);
    const dc_value = try addI16(previous_dc.*, dc_delta);
    block[0] = dc_value;
    previous_dc.* = dc_value;

    var index: usize = 1;
    while (index < 64) {
        const symbol = try ac_table.decode(reader);
        if (symbol == 0x00) break;
        if (symbol == 0xf0) {
            index += 16;
            if (index > 64) return error.InvalidJpeg;
            continue;
        }

        const run = symbol >> 4;
        const size_raw = symbol & 0x0f;
        if (size_raw == 0) return error.InvalidJpeg;
        if (size_raw > 10) return error.InvalidJpeg;
        index += run;
        if (index >= 64) return error.InvalidJpeg;

        const size: u4 = @intCast(size_raw);
        block[zigzag_order[index]] = try readMagnitude(reader, size);
        index += 1;
    }

    return block;
}

fn addI16(a: i16, b: i16) !i16 {
    const sum = @as(i32, a) + @as(i32, b);
    if (sum < std.math.minInt(i16) or sum > std.math.maxInt(i16)) return error.InvalidJpeg;
    return @intCast(sum);
}

fn dequantizeBlock(block: Block, table: QuantizationTable) !DequantizedBlock {
    var out: DequantizedBlock = undefined;
    for (0..64) |natural_index| {
        const quantized = @as(i32, block[natural_index]);
        const quantizer = @as(i32, quantizationValueForNaturalIndex(table, natural_index) orelse return error.InvalidJpeg);
        out[natural_index] = try std.math.mul(i32, quantized, quantizer);
    }
    return out;
}

fn quantizationValueForNaturalIndex(table: QuantizationTable, natural_index: usize) ?u16 {
    for (zigzag_order, 0..) |mapped_natural_index, zigzag_index| {
        if (mapped_natural_index == natural_index) return table.values[zigzag_index];
    }
    return null;
}

fn idctBlock(block: DequantizedBlock) SampleBlock {
    var out: SampleBlock = undefined;
    for (0..8) |y| {
        for (0..8) |x| {
            var sum: f64 = 0.0;
            for (0..8) |v| {
                for (0..8) |u| {
                    const coefficient = @as(f64, @floatFromInt(block[v * 8 + u]));
                    const cu = dctScale(u);
                    const cv = dctScale(v);
                    sum += cu * cv * coefficient * dctCos(x, u) * dctCos(y, v);
                }
            }

            const shifted = 128.0 + sum / 4.0;
            out[y * 8 + x] = clampSample(@round(shifted));
        }
    }
    return out;
}

fn dctScale(index: usize) f64 {
    return if (index == 0) 0.7071067811865476 else 1.0;
}

fn dctCos(position: usize, frequency: usize) f64 {
    const numerator = @as(f64, @floatFromInt((2 * position + 1) * frequency)) * std.math.pi;
    return @cos(numerator / 16.0);
}

fn clampSample(value: f64) u8 {
    if (value <= 0.0) return 0;
    if (value >= 255.0) return 255;
    return @intFromFloat(value);
}

const zigzag_order = [_]usize{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

/// Parse JPEG dimensions and frame metadata from encoded bytes.
///
/// This does not entropy-decode image data. It only walks marker segments until
/// the first Start Of Frame marker that carries dimensions.
pub fn info(bytes: []const u8) !Info {
    if (bytes.len < 4) return error.InvalidJpeg;
    if (bytes[0] != 0xff or bytes[1] != 0xd8) return error.InvalidJpeg;

    var offset: usize = 2;
    while (try nextSegment(bytes, &offset)) |segment| {
        if (isStartOfFrame(segment.marker)) {
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
                .frame = frameKind(segment.marker),
            };
        }
    }

    return error.InvalidJpeg;
}

fn nextSegment(bytes: []const u8, offset: *usize) !?Segment {
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
    if (isStandaloneMarker(marker)) {
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

fn parseDecodeState(bytes: []const u8) !DecodeState {
    if (bytes.len < 4) return error.InvalidJpeg;
    if (bytes[0] != 0xff or bytes[1] != 0xd8) return error.InvalidJpeg;

    var state = DecodeState{};
    var offset: usize = 2;
    while (try nextDecodeSegment(bytes, &offset)) |segment| {
        switch (segment.marker) {
            0xdb => try parseDqt(&state, segment.data),
            0xc4 => try parseDht(&state, segment.data),
            0xdd => state.restart_interval = try parseDri(segment.data),
            0xc0 => state.frame = try parseFrameHeader(segment.marker, segment.data),
            0xda => {
                state.scan = try parseScanHeader(segment.data);
                state.scan_data_offset = offset;
                break;
            },
            else => {
                if (isStartOfFrame(segment.marker)) return error.UnsupportedJpeg;
            },
        }
    }

    if (state.frame == null) return error.InvalidJpeg;
    if (state.scan == null) return error.InvalidJpeg;
    return state;
}

fn nextDecodeSegment(bytes: []const u8, offset: *usize) !?Segment {
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
    if (isStandaloneMarker(marker)) {
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

fn parseFrameHeader(marker: u8, data: []const u8) !FrameHeader {
    if (data.len < 6) return error.InvalidJpeg;
    const precision = data[0];
    const height = std.mem.readInt(u16, data[1..3], .big);
    const width = std.mem.readInt(u16, data[3..5], .big);
    const component_count = data[5];
    if (width == 0 or height == 0 or component_count == 0 or component_count > 4) return error.InvalidJpeg;
    const expected_len = 6 + 3 * @as(usize, component_count);
    if (data.len < expected_len) return error.InvalidJpeg;

    var frame = FrameHeader{
        .dimensions = .{ .width = width, .height = height },
        .precision = precision,
        .component_count = component_count,
        .frame = frameKind(marker),
    };

    var offset: usize = 6;
    for (0..component_count) |index| {
        const sampling = data[offset + 1];
        const horizontal_sampling: u4 = @intCast(sampling >> 4);
        const vertical_sampling: u4 = @intCast(sampling & 0x0f);
        if (horizontal_sampling == 0 or vertical_sampling == 0) return error.InvalidJpeg;
        const quantization_table_id = data[offset + 2];
        if (quantization_table_id >= 4) return error.UnsupportedJpeg;
        frame.components[index] = .{
            .id = data[offset],
            .horizontal_sampling = horizontal_sampling,
            .vertical_sampling = vertical_sampling,
            .quantization_table_id = quantization_table_id,
        };
        offset += 3;
    }

    return frame;
}

fn parseDqt(state: *DecodeState, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const table_info = data[offset];
        offset += 1;

        const precision: u1 = switch (table_info >> 4) {
            0 => 0,
            1 => 1,
            else => return error.UnsupportedJpeg,
        };
        const id = table_info & 0x0f;
        if (id >= state.quantization_tables.len) return error.UnsupportedJpeg;

        const value_size: usize = if (precision == 0) 1 else 2;
        const values_len = try std.math.mul(usize, 64, value_size);
        if (offset + values_len > data.len) return error.InvalidJpeg;

        var table = QuantizationTable{
            .precision = precision,
            .id = id,
            .values = undefined,
        };

        for (0..64) |index| {
            const value = if (precision == 0)
                data[offset + index]
            else
                std.mem.readInt(u16, data[offset + index * 2 ..][0..2], .big);
            if (value == 0) return error.InvalidJpeg;
            table.values[index] = value;
        }

        state.quantization_tables[id] = table;
        offset += values_len;
    }
}

fn parseDht(state: *DecodeState, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        if (offset + 17 > data.len) return error.InvalidJpeg;
        const table_info = data[offset];
        offset += 1;

        const class: HuffmanTableClass = switch (table_info >> 4) {
            0 => .dc,
            1 => .ac,
            else => return error.UnsupportedJpeg,
        };
        const id = table_info & 0x0f;
        if (id >= 4) return error.UnsupportedJpeg;

        var table = HuffmanTable{
            .class = class,
            .id = id,
            .code_counts = undefined,
            .symbol_count = 0,
        };
        @memcpy(&table.code_counts, data[offset .. offset + 16]);
        offset += 16;

        var symbol_count: usize = 0;
        for (table.code_counts) |count| {
            symbol_count += count;
        }
        if (symbol_count > table.symbols.len) return error.InvalidJpeg;
        if (symbol_count > std.math.maxInt(u8)) return error.InvalidJpeg;
        if (offset + symbol_count > data.len) return error.InvalidJpeg;

        @memcpy(table.symbols[0..symbol_count], data[offset .. offset + symbol_count]);
        table.symbol_count = @intCast(symbol_count);
        offset += symbol_count;

        switch (class) {
            .dc => state.dc_huffman_tables[id] = table,
            .ac => state.ac_huffman_tables[id] = table,
        }
    }
}

fn parseDri(data: []const u8) !u16 {
    if (data.len != 2) return error.InvalidJpeg;
    return std.mem.readInt(u16, data[0..2], .big);
}

fn parseScanHeader(data: []const u8) !ScanHeader {
    if (data.len < 4) return error.InvalidJpeg;
    const component_count = data[0];
    if (component_count == 0 or component_count > 4) return error.InvalidJpeg;
    const expected_len = 1 + 2 * @as(usize, component_count) + 3;
    if (data.len < expected_len) return error.InvalidJpeg;

    var scan = ScanHeader{
        .component_count = component_count,
        .spectral_start = data[1 + 2 * @as(usize, component_count)],
        .spectral_end = data[2 + 2 * @as(usize, component_count)],
        .successive_approximation_high = @intCast(data[3 + 2 * @as(usize, component_count)] >> 4),
        .successive_approximation_low = @intCast(data[3 + 2 * @as(usize, component_count)] & 0x0f),
    };

    var offset: usize = 1;
    for (0..component_count) |index| {
        const table_selectors = data[offset + 1];
        const dc_table_id = table_selectors >> 4;
        const ac_table_id = table_selectors & 0x0f;
        if (dc_table_id >= 4 or ac_table_id >= 4) return error.UnsupportedJpeg;
        scan.components[index] = .{
            .id = data[offset],
            .dc_table_id = dc_table_id,
            .ac_table_id = ac_table_id,
        };
        offset += 2;
    }

    return scan;
}

fn isStandaloneMarker(marker: u8) bool {
    return marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7);
}

fn isStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf => true,
        else => false,
    };
}

fn frameKind(marker: u8) FrameKind {
    return switch (marker) {
        0xc0 => .baseline,
        0xc2 => .progressive,
        else => .other,
    };
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

    const parsed = try info(&bytes);

    try std.testing.expectEqual(Dimensions{ .width = 320, .height = 240 }, parsed.dimensions);
    try std.testing.expectEqual(@as(u8, 8), parsed.precision);
    try std.testing.expectEqual(@as(u8, 3), parsed.component_count);
    try std.testing.expectEqual(FrameKind.baseline, parsed.frame);
}

test "jpegInfo rejects non-JPEG data" {
    const bytes = [_]u8{ 'n', 'o', 't', ' ', 'j', 'p', 'e', 'g' };

    try std.testing.expectError(error.InvalidJpeg, info(&bytes));
}

test "jpegInfo rejects JPEG without SOF metadata" {
    const bytes = [_]u8{ 0xff, 0xd8, 0xff, 0xd9 };

    try std.testing.expectError(error.InvalidJpeg, info(&bytes));
}

test "jpegInfo rejects truncated marker segment" {
    const bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xe0,
        0x00, 0x10,
        'J',  'F',
    };

    try std.testing.expectError(error.InvalidJpeg, info(&bytes));
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

    try std.testing.expectError(error.InvalidJpeg, info(&bytes));
}

test "JPEG parser state reads tables frame sampling and scan header" {
    const bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xdb,
        0x00, 0x43,
        0x00, 1,
        2,    3,
        4,    5,
        6,    7,
        8,    9,
        10,   11,
        12,   13,
        14,   15,
        16,   17,
        18,   19,
        20,   21,
        22,   23,
        24,   25,
        26,   27,
        28,   29,
        30,   31,
        32,   33,
        34,   35,
        36,   37,
        38,   39,
        40,   41,
        42,   43,
        44,   45,
        46,   47,
        48,   49,
        50,   51,
        52,   53,
        54,   55,
        56,   57,
        58,   59,
        60,   61,
        62,   63,
        64,   0xff,
        0xc4, 0x00,
        0x14, 0x00,
        1,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0x00, 0xff,
        0xc4, 0x00,
        0x14, 0x10,
        1,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0x00, 0xff,
        0xdd, 0x00,
        0x04, 0x00,
        0x08, 0xff,
        0xc0, 0x00,
        0x11, 0x08,
        0x00, 0x08,
        0x00, 0x08,
        0x03, 0x01,
        0x21, 0x00,
        0x02, 0x11,
        0x00, 0x03,
        0x11, 0x00,
        0xff, 0xda,
        0x00, 0x0c,
        0x03, 0x01,
        0x00, 0x02,
        0x00, 0x03,
        0x00, 0x00,
        0x3f, 0x00,
        0xff, 0xd9,
    };

    const state = try parseDecodeState(&bytes);
    const frame = state.frame.?;
    const scan = state.scan.?;
    const qt = state.quantization_tables[0].?;
    const dc = state.dc_huffman_tables[0].?;
    const ac = state.ac_huffman_tables[0].?;

    try std.testing.expectEqual(Dimensions{ .width = 8, .height = 8 }, frame.dimensions);
    try std.testing.expectEqual(FrameKind.baseline, frame.frame);
    try std.testing.expectEqual(@as(u8, 3), frame.component_count);
    try std.testing.expectEqual(@as(u8, 1), frame.components[0].id);
    try std.testing.expectEqual(@as(u4, 2), frame.components[0].horizontal_sampling);
    try std.testing.expectEqual(@as(u4, 1), frame.components[0].vertical_sampling);
    try std.testing.expectEqual(@as(u8, 0), frame.components[0].quantization_table_id);
    try std.testing.expectEqual(@as(u16, 1), qt.values[0]);
    try std.testing.expectEqual(@as(u16, 64), qt.values[63]);
    try std.testing.expectEqual(@as(u8, 1), dc.symbol_count);
    try std.testing.expectEqual(@as(u8, 1), ac.symbol_count);
    try std.testing.expectEqual(@as(u16, 8), state.restart_interval.?);
    try std.testing.expectEqual(@as(u8, 3), scan.component_count);
    try std.testing.expectEqual(@as(u8, 1), scan.components[0].id);
    try std.testing.expectEqual(@as(u8, 0), scan.components[0].dc_table_id);
    try std.testing.expectEqual(@as(u8, 0), scan.components[0].ac_table_id);
    try std.testing.expectEqual(@as(u8, 0), scan.spectral_start);
    try std.testing.expectEqual(@as(u8, 63), scan.spectral_end);
    try std.testing.expect(state.scan_data_offset < bytes.len);
}

test "JPEG parser state rejects progressive frames as unsupported" {
    const bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xc2,
        0x00, 0x11,
        0x08, 0x00,
        0x08, 0x00,
        0x08, 0x03,
        0x01, 0x11,
        0x00, 0x02,
        0x11, 0x00,
        0x03, 0x11,
        0x00, 0xff,
        0xd9,
    };

    try std.testing.expectError(error.UnsupportedJpeg, parseDecodeState(&bytes));
}

test "JPEG parser state rejects too many Huffman symbols instead of trapping" {
    var bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xc4,
        0x01, 0x13,
        0x00, 0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,    0,
        0,
    } ++ ([_]u8{0} ** 256) ++ [_]u8{
        0xff, 0xd9,
    };
    bytes[7] = 255;
    bytes[8] = 1;

    try std.testing.expectError(error.InvalidJpeg, parseDecodeState(&bytes));
}

test "JPEG parser state rejects invalid DQT precision instead of trapping" {
    const bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xdb,
        0x00, 0x43,
        0x20,
    } ++ ([_]u8{0} ** 64) ++ [_]u8{
        0xff, 0xd9,
    };

    try std.testing.expectError(error.UnsupportedJpeg, parseDecodeState(&bytes));
}

test "JPEG parser state rejects zero quantization table values" {
    var bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xdb,
        0x00, 0x43,
        0x00,
    } ++ ([_]u8{1} ** 64) ++ [_]u8{
        0xff, 0xd9,
    };
    bytes[7] = 0;

    try std.testing.expectError(error.InvalidJpeg, parseDecodeState(&bytes));
}

test "JPEG parser state rejects out-of-range SOF table ids" {
    const bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xc0,
        0x00, 0x0b,
        0x08, 0x00,
        0x08, 0x00,
        0x08, 0x01,
        0x01, 0x11,
        0x04, 0xff,
        0xd9,
    };

    try std.testing.expectError(error.UnsupportedJpeg, parseDecodeState(&bytes));
}

test "JPEG parser state rejects out-of-range SOS table ids" {
    const bytes = [_]u8{
        0xff, 0xd8,
        0xff, 0xc0,
        0x00, 0x0b,
        0x08, 0x00,
        0x08, 0x00,
        0x08, 0x01,
        0x01, 0x11,
        0x00, 0xff,
        0xda, 0x00,
        0x08, 0x01,
        0x01, 0x40,
        0x00, 0x3f,
        0x00, 0xff,
        0xd9,
    };

    try std.testing.expectError(error.UnsupportedJpeg, parseDecodeState(&bytes));
}

test "JPEG canonical Huffman table decodes symbols from entropy bits" {
    const table = HuffmanTable{
        .class = .dc,
        .id = 0,
        .code_counts = .{
            1, 2, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        },
        .symbols = .{ 0xaa, 0xbb, 0xcc } ++ ([_]u8{0} ** 253),
        .symbol_count = 3,
    };
    const canonical = try CanonicalHuffmanTable.init(table);
    var reader = EntropyBitReader.init(&[_]u8{0b0101_1000});

    try std.testing.expectEqual(@as(u8, 0xaa), try canonical.decode(&reader));
    try std.testing.expectEqual(@as(u8, 0xbb), try canonical.decode(&reader));
    try std.testing.expectEqual(@as(u8, 0xcc), try canonical.decode(&reader));
}

test "JPEG canonical Huffman table rejects over-subscribed lengths" {
    const table = HuffmanTable{
        .class = .ac,
        .id = 0,
        .code_counts = .{
            3, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        },
        .symbols = .{ 1, 2, 3 } ++ ([_]u8{0} ** 253),
        .symbol_count = 3,
    };

    try std.testing.expectError(error.InvalidJpeg, CanonicalHuffmanTable.init(table));
}

test "JPEG entropy bit reader handles byte stuffing" {
    var reader = EntropyBitReader.init(&[_]u8{ 0xff, 0x00, 0x80 });

    try std.testing.expectEqual(@as(u16, 0xff), try reader.readBits(8));
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
}

test "JPEG entropy bit reader rejects restart markers for this slice" {
    var reader = EntropyBitReader.init(&[_]u8{ 0xff, 0xd0 });

    try std.testing.expectError(error.UnsupportedJpeg, reader.readBit());
}

test "JPEG magnitude decode sign-extends category values" {
    try std.testing.expectEqual(@as(i16, 1), try decodeMagnitude(0b1, 1));
    try std.testing.expectEqual(@as(i16, -1), try decodeMagnitude(0b0, 1));
    try std.testing.expectEqual(@as(i16, 3), try decodeMagnitude(0b11, 2));
    try std.testing.expectEqual(@as(i16, -3), try decodeMagnitude(0b00, 2));
    try std.testing.expectEqual(@as(i16, -2), try decodeMagnitude(0b01, 2));
}

test "JPEG block decoder reads DC and AC coefficients" {
    const dc_table = try CanonicalHuffmanTable.init(.{
        .class = .dc,
        .id = 0,
        .code_counts = .{
            1, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        },
        .symbols = .{2} ++ ([_]u8{0} ** 255),
        .symbol_count = 1,
    });
    const ac_table = try CanonicalHuffmanTable.init(.{
        .class = .ac,
        .id = 0,
        .code_counts = .{
            2, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        },
        .symbols = .{ 0x01, 0x00 } ++ ([_]u8{0} ** 254),
        .symbol_count = 2,
    });
    var reader = EntropyBitReader.init(&[_]u8{0b0110_1100});
    var previous_dc: i16 = 4;

    const block = try decodeBlock(&reader, &dc_table, &ac_table, &previous_dc);

    try std.testing.expectEqual(@as(i16, 7), block[0]);
    try std.testing.expectEqual(@as(i16, 1), block[1]);
    try std.testing.expectEqual(@as(i16, 7), previous_dc);
    try std.testing.expectEqual(@as(i16, 0), block[2]);
}

test "JPEG block decoder applies AC run length with zigzag order" {
    const dc_table = try CanonicalHuffmanTable.init(.{
        .class = .dc,
        .id = 0,
        .code_counts = .{
            1, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        },
        .symbols = .{0} ++ ([_]u8{0} ** 255),
        .symbol_count = 1,
    });
    const ac_table = try CanonicalHuffmanTable.init(.{
        .class = .ac,
        .id = 0,
        .code_counts = .{
            2, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        },
        .symbols = .{ 0x21, 0x00 } ++ ([_]u8{0} ** 254),
        .symbol_count = 2,
    });
    var reader = EntropyBitReader.init(&[_]u8{0b0011_0000});
    var previous_dc: i16 = 0;

    const block = try decodeBlock(&reader, &dc_table, &ac_table, &previous_dc);

    try std.testing.expectEqual(@as(i16, 1), block[16]);
    try std.testing.expectEqual(@as(i16, 0), block[1]);
    try std.testing.expectEqual(@as(i16, 0), block[8]);
}

test "JPEG block decoder rejects AC category above baseline limit" {
    const dc_table = try CanonicalHuffmanTable.init(.{
        .class = .dc,
        .id = 0,
        .code_counts = .{
            1, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        },
        .symbols = .{0} ++ ([_]u8{0} ** 255),
        .symbol_count = 1,
    });
    const ac_table = try CanonicalHuffmanTable.init(.{
        .class = .ac,
        .id = 0,
        .code_counts = .{
            2, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        },
        .symbols = .{ 0x0b, 0x00 } ++ ([_]u8{0} ** 254),
        .symbol_count = 2,
    });
    var reader = EntropyBitReader.init(&[_]u8{0b0000_0000});
    var previous_dc: i16 = 0;

    try std.testing.expectError(
        error.InvalidJpeg,
        decodeBlock(&reader, &dc_table, &ac_table, &previous_dc),
    );
}

test "JPEG dequantize maps quantization table from zigzag order" {
    var block = [_]i16{0} ** 64;
    block[0] = 2;
    block[16] = 3;

    var table = QuantizationTable{
        .precision = 0,
        .id = 0,
        .values = undefined,
    };
    for (0..64) |index| {
        table.values[index] = @intCast(index + 1);
    }

    const dequantized = try dequantizeBlock(block, table);

    try std.testing.expectEqual(@as(i32, 2), dequantized[0]);
    try std.testing.expectEqual(@as(i32, 12), dequantized[16]);
    try std.testing.expectEqual(@as(i32, 0), dequantized[1]);
}

test "JPEG IDCT level shifts empty block to neutral gray" {
    const samples = idctBlock([_]i32{0} ** 64);

    for (samples) |sample| {
        try std.testing.expectEqual(@as(u8, 128), sample);
    }
}

test "JPEG IDCT applies DC coefficient uniformly" {
    var block = [_]i32{0} ** 64;
    block[0] = 80;

    const samples = idctBlock(block);

    for (samples) |sample| {
        try std.testing.expectEqual(@as(u8, 138), sample);
    }
}
