const std = @import("std");
const common = @import("common.zig");
const pixel = @import("../pixel.zig");

pub const Info = common.JpegInfo;
pub const FrameKind = common.JpegFrameKind;
const Dimensions = common.Dimensions;

pub const DecodedPixels = struct {
    dimensions: Dimensions,
    pixels: []pixel.Pixel,

    pub fn deinit(self: *DecodedPixels, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        self.* = .{
            .dimensions = .{ .width = 0, .height = 0 },
            .pixels = &.{},
        };
    }
};

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

const ScanData = struct {
    header: ScanHeader,
    data_start: usize,
    data_end: usize,
    dc_huffman_tables: [4]?HuffmanTable,
    ac_huffman_tables: [4]?HuffmanTable,
};

const ComponentPlan = struct {
    frame_component: Component,
    scan_component: ScanComponent,
    quantization_table: QuantizationTable,
    dc_table: CanonicalHuffmanTable,
    ac_table: CanonicalHuffmanTable,
    previous_dc: i16 = 0,
};

const BaselineScanPlan = struct {
    components: [4]ComponentPlan = undefined,
    component_count: u8,
    max_horizontal_sampling: u4,
    max_vertical_sampling: u4,

    fn mcuWidth(self: BaselineScanPlan) u32 {
        return @as(u32, self.max_horizontal_sampling) * 8;
    }

    fn mcuHeight(self: BaselineScanPlan) u32 {
        return @as(u32, self.max_vertical_sampling) * 8;
    }
};

const ComponentSampleBlocks = struct {
    blocks: [4]SampleBlock = undefined,
    horizontal_sampling: u4,
    vertical_sampling: u4,
};

const McuSampleBlocks = struct {
    components: [4]ComponentSampleBlocks = undefined,
    component_count: u8,
    max_horizontal_sampling: u4,
    max_vertical_sampling: u4,
};

const DecodeState = struct {
    frame: ?FrameHeader = null,
    quantization_tables: [4]?QuantizationTable = [_]?QuantizationTable{null} ** 4,
    dc_huffman_tables: [4]?HuffmanTable = [_]?HuffmanTable{null} ** 4,
    ac_huffman_tables: [4]?HuffmanTable = [_]?HuffmanTable{null} ** 4,
    scan: ?ScanHeader = null,
    scans: [16]ScanData = undefined,
    scan_count: usize = 0,
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
    symbols: [256]u8 = undefined,
    min_code: [17]i32 = [_]i32{-1} ** 17,
    max_code: [17]i32 = [_]i32{-1} ** 17,
    value_offset: [17]i32 = [_]i32{0} ** 17,
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

            if (code_count > 0) {
                result.min_code[length] = @intCast(code);
                result.max_code[length] = @intCast(code + code_count - 1);
                result.value_offset[length] = @as(i32, @intCast(symbol_index)) - @as(i32, @intCast(code));
            }

            for (0..code_count) |_| {
                if (symbol_index >= table.symbol_count) return error.InvalidJpeg;
                result.codes[result.count] = .{
                    .code = @intCast(code),
                    .length = length,
                    .symbol = table.symbols[symbol_index],
                };
                result.symbols[symbol_index] = table.symbols[symbol_index];
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
            const code_i32: i32 = code;
            if (code_i32 >= self.min_code[length_usize] and code_i32 <= self.max_code[length_usize]) {
                const symbol_index: usize = @intCast(self.value_offset[length_usize] + code_i32);
                if (symbol_index >= self.count) return error.InvalidJpeg;
                return self.symbols[symbol_index];
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

    fn finish(self: *const EntropyBitReader) !void {
        if (self.bits_left > 0) {
            const shift: u3 = @intCast(self.bits_left);
            const mask = (@as(u8, 1) << shift) - 1;
            if ((self.current_byte & mask) != mask) return error.InvalidJpeg;
        }

        try self.finishByteAligned();
    }

    fn finishByteAligned(self: *const EntropyBitReader) !void {
        if (self.offset == self.data.len) return;
        var offset = self.offset;
        while (offset < self.data.len and self.data[offset] == 0xff) {
            offset += 1;
        }
        if (offset >= self.data.len) return error.InvalidJpeg;
        if (self.data[offset] != 0xd9) return error.InvalidJpeg;
        if (offset + 1 != self.data.len) return error.InvalidJpeg;
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

fn buildBaselineScanPlan(state: DecodeState) !BaselineScanPlan {
    const frame = state.frame orelse return error.InvalidJpeg;
    const scan = state.scan orelse return error.InvalidJpeg;
    if (frame.frame != .baseline) return error.UnsupportedJpeg;
    if (frame.precision != 8) return error.UnsupportedJpeg;
    if ((state.restart_interval orelse 0) != 0) return error.UnsupportedJpeg;
    if (scan.spectral_start != 0 or scan.spectral_end != 63) return error.UnsupportedJpeg;
    if (scan.successive_approximation_high != 0 or scan.successive_approximation_low != 0) return error.UnsupportedJpeg;
    if (scan.component_count != frame.component_count) return error.UnsupportedJpeg;
    if (scan.component_count != 1 and scan.component_count != 3) return error.UnsupportedJpeg;
    try validateUniqueFrameComponentIds(frame);

    var plan = BaselineScanPlan{
        .component_count = scan.component_count,
        .max_horizontal_sampling = 1,
        .max_vertical_sampling = 1,
    };

    for (0..frame.component_count) |index| {
        const component = frame.components[index];
        plan.max_horizontal_sampling = @max(plan.max_horizontal_sampling, component.horizontal_sampling);
        plan.max_vertical_sampling = @max(plan.max_vertical_sampling, component.vertical_sampling);
    }

    for (0..scan.component_count) |index| {
        const scan_component = scan.components[index];
        if (scanComponentSeen(scan, scan_component.id, index)) return error.InvalidJpeg;
        const frame_component = findFrameComponent(frame, scan_component.id) orelse return error.InvalidJpeg;

        // Keep the first sampling slice to the common cover-art cases:
        // non-subsampled, 4:2:2, and 4:2:0. Larger sampling grids need
        // additional bounds and quality tests before they are accepted.
        if (frame_component.horizontal_sampling > 2 or frame_component.vertical_sampling > 2) return error.UnsupportedJpeg;

        const quantization_table = state.quantization_tables[frame_component.quantization_table_id] orelse return error.InvalidJpeg;
        const dc_table = state.dc_huffman_tables[scan_component.dc_table_id] orelse return error.InvalidJpeg;
        const ac_table = state.ac_huffman_tables[scan_component.ac_table_id] orelse return error.InvalidJpeg;

        plan.components[index] = .{
            .frame_component = frame_component,
            .scan_component = scan_component,
            .quantization_table = quantization_table,
            .dc_table = try CanonicalHuffmanTable.init(dc_table),
            .ac_table = try CanonicalHuffmanTable.init(ac_table),
        };
    }

    return plan;
}

fn validateUniqueFrameComponentIds(frame: FrameHeader) !void {
    for (0..frame.component_count) |index| {
        const id = frame.components[index].id;
        for (frame.components[0..index]) |previous| {
            if (previous.id == id) return error.InvalidJpeg;
        }
    }
}

fn scanComponentSeen(scan: ScanHeader, id: u8, end: usize) bool {
    for (scan.components[0..end]) |previous| {
        if (previous.id == id) return true;
    }
    return false;
}

fn findFrameComponent(frame: FrameHeader, id: u8) ?Component {
    for (frame.components[0..frame.component_count]) |component| {
        if (component.id == id) return component;
    }
    return null;
}

fn mcuGrid(frame: FrameHeader, plan: BaselineScanPlan) Dimensions {
    return .{
        .width = ceilDivU32(frame.dimensions.width, plan.mcuWidth()),
        .height = ceilDivU32(frame.dimensions.height, plan.mcuHeight()),
    };
}

fn ceilDivU32(numerator: u32, denominator: u32) u32 {
    return (numerator + denominator - 1) / denominator;
}

fn ycbcrToRgb(y: u8, cb: u8, cr: u8) pixel.Pixel {
    const yf = @as(f64, @floatFromInt(y));
    const cbf = @as(f64, @floatFromInt(cb)) - 128.0;
    const crf = @as(f64, @floatFromInt(cr)) - 128.0;

    return .{
        .rgb = .{
            .r = clampSample(@round(yf + 1.402 * crf)),
            .g = clampSample(@round(yf - 0.344136 * cbf - 0.714136 * crf)),
            .b = clampSample(@round(yf + 1.772 * cbf)),
        },
    };
}

fn decodeMcuSampleBlocks(reader: *EntropyBitReader, plan: *BaselineScanPlan) !McuSampleBlocks {
    var out = McuSampleBlocks{
        .component_count = plan.component_count,
        .max_horizontal_sampling = plan.max_horizontal_sampling,
        .max_vertical_sampling = plan.max_vertical_sampling,
    };

    for (plan.components[0..plan.component_count], 0..) |*component, index| {
        const h: usize = component.frame_component.horizontal_sampling;
        const v: usize = component.frame_component.vertical_sampling;
        out.components[index] = .{
            .horizontal_sampling = component.frame_component.horizontal_sampling,
            .vertical_sampling = component.frame_component.vertical_sampling,
        };

        for (0..v) |block_y| {
            for (0..h) |block_x| {
                const block = try decodeBlock(reader, &component.dc_table, &component.ac_table, &component.previous_dc);
                const dequantized = try dequantizeBlock(block, component.quantization_table);
                out.components[index].blocks[block_y * h + block_x] = idctBlock(dequantized);
            }
        }
    }

    return out;
}

fn mcuPixelAt(blocks: McuSampleBlocks, x: usize, y: usize) !pixel.Pixel {
    if (blocks.component_count == 1) {
        const sample = try componentSampleAt(blocks, 0, x, y);
        return ycbcrToRgb(sample, 128, 128);
    }
    if (blocks.component_count == 3) {
        return ycbcrToRgb(
            try componentSampleAt(blocks, 0, x, y),
            try componentSampleAt(blocks, 1, x, y),
            try componentSampleAt(blocks, 2, x, y),
        );
    }
    return error.UnsupportedJpeg;
}

fn componentSampleAt(blocks: McuSampleBlocks, component_index: usize, x: usize, y: usize) !u8 {
    if (component_index >= blocks.component_count) return error.InvalidJpeg;
    const component = blocks.components[component_index];
    const sample_x = x * @as(usize, component.horizontal_sampling) / @as(usize, blocks.max_horizontal_sampling);
    const sample_y = y * @as(usize, component.vertical_sampling) / @as(usize, blocks.max_vertical_sampling);
    const block_x = sample_x / 8;
    const block_y = sample_y / 8;
    const block_index = block_y * @as(usize, component.horizontal_sampling) + block_x;
    if (block_index >= @as(usize, component.horizontal_sampling) * @as(usize, component.vertical_sampling)) return error.InvalidJpeg;
    return component.blocks[block_index][(sample_y % 8) * 8 + (sample_x % 8)];
}

fn decodeBaselinePixels(state: DecodeState, entropy_data: []const u8, out: []pixel.Pixel) !void {
    const frame = state.frame orelse return error.InvalidJpeg;
    const expected_pixels = try jpegPixelCount(frame.dimensions);
    if (out.len != expected_pixels) return error.InvalidJpeg;

    var plan = try buildBaselineScanPlan(state);
    var reader = EntropyBitReader.init(entropy_data);
    const grid = mcuGrid(frame, plan);

    for (0..grid.height) |mcu_y| {
        for (0..grid.width) |mcu_x| {
            const blocks = try decodeMcuSampleBlocks(&reader, &plan);

            for (0..plan.mcuHeight()) |local_y| {
                const y = mcu_y * plan.mcuHeight() + local_y;
                if (y >= frame.dimensions.height) break;

                for (0..plan.mcuWidth()) |local_x| {
                    const x = mcu_x * plan.mcuWidth() + local_x;
                    if (x >= frame.dimensions.width) break;
                    out[@as(usize, y) * @as(usize, frame.dimensions.width) + @as(usize, x)] = try mcuPixelAt(blocks, local_x, local_y);
                }
            }
        }
    }

    try reader.finishByteAligned();
}

const ProgressiveComponent = struct {
    frame_component: Component,
    quantization_table: QuantizationTable,
    block_width: u32,
    block_height: u32,
    coded_block_width: u32,
    coded_block_height: u32,
    previous_dc: i16 = 0,
    blocks: []Block,
};

const ProgressiveImage = struct {
    frame: FrameHeader,
    max_horizontal_sampling: u4,
    max_vertical_sampling: u4,
    components: [4]ProgressiveComponent = undefined,
    component_count: u8,

    fn deinit(self: *ProgressiveImage, allocator: std.mem.Allocator) void {
        for (self.components[0..self.component_count]) |component| {
            allocator.free(component.blocks);
        }
    }

    fn mcuWidth(self: ProgressiveImage) u32 {
        return @as(u32, self.max_horizontal_sampling) * 8;
    }

    fn mcuHeight(self: ProgressiveImage) u32 {
        return @as(u32, self.max_vertical_sampling) * 8;
    }
};

const ProgressiveSamples = struct {
    components: [4]ComponentSampleGrid = undefined,
    component_count: u8,
    max_horizontal_sampling: u4,
    max_vertical_sampling: u4,

    fn deinit(self: *ProgressiveSamples, allocator: std.mem.Allocator) void {
        for (self.components[0..self.component_count]) |component| {
            allocator.free(component.blocks);
        }
    }
};

const ComponentSampleGrid = struct {
    horizontal_sampling: u4,
    vertical_sampling: u4,
    block_width: u32,
    block_height: u32,
    blocks: []SampleBlock,
};

fn decodeProgressivePixels(allocator: std.mem.Allocator, state: DecodeState, bytes: []const u8, out: []pixel.Pixel) !void {
    var progressive = try initProgressiveImage(allocator, state);
    defer progressive.deinit(allocator);

    for (state.scans[0..state.scan_count]) |scan| {
        try decodeProgressiveScan(&progressive, scan, bytes[scan.data_start..scan.data_end]);
    }

    var samples = try buildProgressiveSamples(allocator, progressive);
    defer samples.deinit(allocator);

    const expected_pixels = try jpegPixelCount(progressive.frame.dimensions);
    if (out.len != expected_pixels) return error.InvalidJpeg;

    for (0..progressive.frame.dimensions.height) |y| {
        for (0..progressive.frame.dimensions.width) |x| {
            out[@as(usize, y) * @as(usize, progressive.frame.dimensions.width) + @as(usize, x)] =
                try progressivePixelAt(samples, @intCast(x), @intCast(y));
        }
    }
}

fn initProgressiveImage(allocator: std.mem.Allocator, state: DecodeState) !ProgressiveImage {
    const frame = state.frame orelse return error.InvalidJpeg;
    if (frame.frame != .progressive) return error.UnsupportedJpeg;
    if (frame.precision != 8) return error.UnsupportedJpeg;
    if ((state.restart_interval orelse 0) != 0) return error.UnsupportedJpeg;
    if (frame.component_count != 1 and frame.component_count != 3) return error.UnsupportedJpeg;
    try validateUniqueFrameComponentIds(frame);

    var image = ProgressiveImage{
        .frame = frame,
        .component_count = frame.component_count,
        .max_horizontal_sampling = 1,
        .max_vertical_sampling = 1,
    };
    errdefer image.deinit(allocator);

    for (frame.components[0..frame.component_count]) |component| {
        if (component.horizontal_sampling > 2 or component.vertical_sampling > 2) return error.UnsupportedJpeg;
        image.max_horizontal_sampling = @max(image.max_horizontal_sampling, component.horizontal_sampling);
        image.max_vertical_sampling = @max(image.max_vertical_sampling, component.vertical_sampling);
    }

    const grid_width = ceilDivU32(frame.dimensions.width, image.mcuWidth());
    const grid_height = ceilDivU32(frame.dimensions.height, image.mcuHeight());
    for (frame.components[0..frame.component_count], 0..) |component, index| {
        const block_width = try std.math.mul(u32, grid_width, component.horizontal_sampling);
        const block_height = try std.math.mul(u32, grid_height, component.vertical_sampling);
        const component_sample_width = ceilDivU32(try std.math.mul(u32, frame.dimensions.width, component.horizontal_sampling), image.max_horizontal_sampling);
        const component_sample_height = ceilDivU32(try std.math.mul(u32, frame.dimensions.height, component.vertical_sampling), image.max_vertical_sampling);
        const coded_block_width = ceilDivU32(component_sample_width, 8);
        const coded_block_height = ceilDivU32(component_sample_height, 8);
        const block_count = try std.math.mul(usize, @intCast(block_width), @intCast(block_height));
        const blocks = try allocator.alloc(Block, block_count);
        @memset(blocks, [_]i16{0} ** 64);
        image.components[index] = .{
            .frame_component = component,
            .quantization_table = state.quantization_tables[component.quantization_table_id] orelse return error.InvalidJpeg,
            .block_width = block_width,
            .block_height = block_height,
            .coded_block_width = coded_block_width,
            .coded_block_height = coded_block_height,
            .blocks = blocks,
        };
    }

    return image;
}

fn decodeProgressiveScan(image: *ProgressiveImage, scan_data: ScanData, entropy_data: []const u8) !void {
    const scan = scan_data.header;
    if (scan.spectral_start > scan.spectral_end or scan.spectral_end > 63) return error.InvalidJpeg;
    if (scan.spectral_start == 0 and scan.spectral_end != 0) return error.InvalidJpeg;
    if (scan.spectral_start != 0 and scan.component_count != 1) return error.UnsupportedJpeg;
    try validateProgressiveApproximation(scan);

    var reader = EntropyBitReader.init(entropy_data);
    if (scan.spectral_start == 0) {
        if (scan.successive_approximation_high == 0) {
            try decodeProgressiveDcFirst(scan_data, image, &reader);
        } else {
            try decodeProgressiveDcRefine(image, scan, &reader);
        }
    } else {
        if (scan.successive_approximation_high == 0) {
            try decodeProgressiveAcFirst(scan_data, image, &reader);
        } else {
            try decodeProgressiveAcRefine(scan_data, image, &reader);
        }
    }
    // Progressive refinement scans in the BGG cover-art samples can leave
    // padding bytes that are not useful for image reconstruction. Keep strict
    // marker parsing at the segment boundary and let the decoded coefficients
    // drive the first supported progressive slice.
}

fn decodeProgressiveDcFirst(
    scan_data: ScanData,
    image: *ProgressiveImage,
    reader: *EntropyBitReader,
) !void {
    const scan = scan_data.header;
    if (scan.component_count != image.component_count) return error.UnsupportedJpeg;
    const grid_width = ceilDivU32(image.frame.dimensions.width, image.mcuWidth());
    const grid_height = ceilDivU32(image.frame.dimensions.height, image.mcuHeight());

    var component_indices: [4]usize = undefined;
    var dc_tables: [4]CanonicalHuffmanTable = undefined;
    for (scan.components[0..scan.component_count], 0..) |scan_component, index| {
        const component_index = progressiveComponentIndex(image.*, scan_component.id) orelse return error.InvalidJpeg;
        component_indices[index] = component_index;
        const dc_table = scan_data.dc_huffman_tables[scan_component.dc_table_id] orelse return error.InvalidJpeg;
        dc_tables[index] = try CanonicalHuffmanTable.init(dc_table);
    }

    for (0..grid_height) |mcu_y| {
        for (0..grid_width) |mcu_x| {
            for (scan.components[0..scan.component_count], 0..) |_, scan_index| {
                const component = &image.components[component_indices[scan_index]];
                for (0..component.frame_component.vertical_sampling) |block_y| {
                    for (0..component.frame_component.horizontal_sampling) |block_x| {
                        const dc_size_raw = try dc_tables[scan_index].decode(reader);
                        if (dc_size_raw > 11) return error.InvalidJpeg;
                        const dc_delta = try readMagnitude(reader, @intCast(dc_size_raw));
                        const dc_value = try addI16(component.previous_dc, dc_delta);
                        component.previous_dc = dc_value;
                        const block = try progressiveBlockAt(component, @intCast(mcu_x * component.frame_component.horizontal_sampling + block_x), @intCast(mcu_y * component.frame_component.vertical_sampling + block_y));
                        block[0] = try shiftCoefficient(dc_value, scan.successive_approximation_low);
                    }
                }
            }
        }
    }
}

fn decodeProgressiveDcRefine(image: *ProgressiveImage, scan: ScanHeader, reader: *EntropyBitReader) !void {
    const bit = try refinementBit(scan.successive_approximation_low);
    for (scan.components[0..scan.component_count]) |scan_component| {
        const component_index = progressiveComponentIndex(image.*, scan_component.id) orelse return error.InvalidJpeg;
        const component = &image.components[component_index];
        for (component.blocks) |*block| {
            if (try reader.readBit() == 1) {
                block[0] = try addRefinementBit(block[0], bit);
            }
        }
    }
}

fn decodeProgressiveAcFirst(
    scan_data: ScanData,
    image: *ProgressiveImage,
    reader: *EntropyBitReader,
) !void {
    const scan = scan_data.header;
    const scan_component = scan.components[0];
    const component_index = progressiveComponentIndex(image.*, scan_component.id) orelse return error.InvalidJpeg;
    const component = &image.components[component_index];
    const ac_table = try CanonicalHuffmanTable.init(scan_data.ac_huffman_tables[scan_component.ac_table_id] orelse return error.InvalidJpeg);
    var eob_run: usize = 0;

    for (0..component.coded_block_height) |block_y| {
        for (0..component.coded_block_width) |block_x| {
            const block = try progressiveBlockAt(component, @intCast(block_x), @intCast(block_y));
            if (eob_run > 0) {
                eob_run -= 1;
                continue;
            }

            var k: usize = scan.spectral_start;
            while (k <= scan.spectral_end) {
                const symbol = try ac_table.decode(reader);
                const run = symbol >> 4;
                const size_raw = symbol & 0x0f;
                if (size_raw == 0) {
                    if (run == 15) {
                        k += 16;
                        continue;
                    }
                    eob_run = try progressiveEobRun(reader, @intCast(run));
                    break;
                }
                if (size_raw > 10) return error.InvalidJpeg;

                k += run;
                if (k > scan.spectral_end) return error.InvalidJpeg;
                block[zigzag_order[k]] = try shiftCoefficient(try readMagnitude(reader, @intCast(size_raw)), scan.successive_approximation_low);
                k += 1;
            }
        }
    }
}

fn decodeProgressiveAcRefine(
    scan_data: ScanData,
    image: *ProgressiveImage,
    reader: *EntropyBitReader,
) !void {
    const scan = scan_data.header;
    const scan_component = scan.components[0];
    const component_index = progressiveComponentIndex(image.*, scan_component.id) orelse return error.InvalidJpeg;
    const component = &image.components[component_index];
    const ac_table = try CanonicalHuffmanTable.init(scan_data.ac_huffman_tables[scan_component.ac_table_id] orelse return error.InvalidJpeg);
    var eob_run: usize = 0;
    const bit = try refinementBit(scan.successive_approximation_low);

    for (0..component.coded_block_height) |block_y| {
        for (0..component.coded_block_width) |block_x| {
            const block = try progressiveBlockAt(component, @intCast(block_x), @intCast(block_y));
            if (eob_run > 0) {
                try refineNonZeroAcCoefficients(reader, block, scan.spectral_start, scan.spectral_end, bit);
                eob_run -= 1;
                continue;
            }

            var k: usize = scan.spectral_start;
            while (k <= scan.spectral_end) {
                const symbol = ac_table.decode(reader) catch |err| switch (err) {
                    error.InvalidJpeg => {
                        if (reader.offset >= reader.data.len) return;
                        return err;
                    },
                    else => |e| return e,
                };
                var run: usize = symbol >> 4;
                const size_raw = symbol & 0x0f;
                var new_coefficient: ?i16 = null;
                if (size_raw == 0) {
                    if (run < 15) {
                        eob_run = try progressiveEobRun(reader, @intCast(run));
                        try refineNonZeroAcCoefficients(reader, block, k, scan.spectral_end, bit);
                        break;
                    }
                } else if (size_raw != 1) {
                    return error.InvalidJpeg;
                } else {
                    new_coefficient = try shiftCoefficient(try readMagnitude(reader, 1), scan.successive_approximation_low);
                }

                while (k <= scan.spectral_end) : (k += 1) {
                    const natural_index = zigzag_order[k];
                    if (block[natural_index] != 0) {
                        try refineCoefficient(reader, &block[natural_index], bit);
                    } else if (run == 0) {
                        if (new_coefficient) |coefficient| {
                            block[natural_index] = coefficient;
                        }
                        k += 1;
                        break;
                    } else {
                        run -= 1;
                    }
                }
                if (k > scan.spectral_end and size_raw != 0) break;
            }
        }
    }
}

fn progressiveEobRun(reader: *EntropyBitReader, run: u4) !usize {
    const base = @as(usize, 1) << run;
    const extra = if (run == 0) 0 else try reader.readBits(run);
    return base + extra - 1;
}

fn refineNonZeroAcCoefficients(reader: *EntropyBitReader, block: *Block, start: usize, end: usize, bit: i32) !void {
    var k = start;
    while (k <= end) : (k += 1) {
        const natural_index = zigzag_order[k];
        if (block[natural_index] != 0) try refineCoefficient(reader, &block[natural_index], bit);
    }
}

fn refineCoefficient(reader: *EntropyBitReader, coefficient: *i16, bit: i32) !void {
    const value: i32 = coefficient.*;
    const magnitude = if (value < 0) -value else value;
    if ((magnitude & bit) != 0) return;
    if (try reader.readBit() == 0) return;
    coefficient.* = try addRefinementBit(coefficient.*, bit);
}

fn validateProgressiveApproximation(scan: ScanHeader) !void {
    if (scan.successive_approximation_low > 14) return error.InvalidJpeg;
    if (scan.successive_approximation_high == 0) return;
    if (scan.successive_approximation_high != scan.successive_approximation_low + 1)
        return error.InvalidJpeg;
}

fn refinementBit(approximation_low: u4) !i32 {
    if (approximation_low > 14) return error.InvalidJpeg;
    return @as(i32, 1) << approximation_low;
}

fn addRefinementBit(coefficient: i16, bit: i32) !i16 {
    const delta: i32 = if (coefficient >= 0) bit else -bit;
    const value = @as(i32, coefficient) + delta;
    if (value < std.math.minInt(i16) or value > std.math.maxInt(i16)) return error.InvalidJpeg;
    return @intCast(value);
}

fn shiftCoefficient(value: i16, approximation_low: u4) !i16 {
    const shifted = @as(i32, value) * (@as(i32, 1) << approximation_low);
    if (shifted < std.math.minInt(i16) or shifted > std.math.maxInt(i16)) return error.InvalidJpeg;
    return @intCast(shifted);
}

fn buildProgressiveSamples(allocator: std.mem.Allocator, image: ProgressiveImage) !ProgressiveSamples {
    var samples = ProgressiveSamples{
        .component_count = image.component_count,
        .max_horizontal_sampling = image.max_horizontal_sampling,
        .max_vertical_sampling = image.max_vertical_sampling,
    };
    errdefer samples.deinit(allocator);

    for (image.components[0..image.component_count], 0..) |component, index| {
        const blocks = try allocator.alloc(SampleBlock, component.blocks.len);
        for (component.blocks, 0..) |block, block_index| {
            blocks[block_index] = idctBlock(try dequantizeBlock(block, component.quantization_table));
        }
        samples.components[index] = .{
            .horizontal_sampling = component.frame_component.horizontal_sampling,
            .vertical_sampling = component.frame_component.vertical_sampling,
            .block_width = component.block_width,
            .block_height = component.block_height,
            .blocks = blocks,
        };
    }

    return samples;
}

fn progressivePixelAt(samples: ProgressiveSamples, x: usize, y: usize) !pixel.Pixel {
    if (samples.component_count == 1) {
        const sample = try progressiveSampleAt(samples, 0, x, y);
        return ycbcrToRgb(sample, 128, 128);
    }
    if (samples.component_count == 3) {
        return ycbcrToRgb(
            try progressiveSampleAt(samples, 0, x, y),
            try progressiveSampleAt(samples, 1, x, y),
            try progressiveSampleAt(samples, 2, x, y),
        );
    }
    return error.UnsupportedJpeg;
}

fn progressiveSampleAt(samples: ProgressiveSamples, component_index: usize, x: usize, y: usize) !u8 {
    if (component_index >= samples.component_count) return error.InvalidJpeg;
    const component = samples.components[component_index];
    const sample_x = x * @as(usize, component.horizontal_sampling) / @as(usize, samples.max_horizontal_sampling);
    const sample_y = y * @as(usize, component.vertical_sampling) / @as(usize, samples.max_vertical_sampling);
    const block_x = sample_x / 8;
    const block_y = sample_y / 8;
    if (block_x >= component.block_width or block_y >= component.block_height) return error.InvalidJpeg;
    const block_index = block_y * @as(usize, component.block_width) + block_x;
    return component.blocks[block_index][(sample_y % 8) * 8 + (sample_x % 8)];
}

fn progressiveBlockAt(component: *ProgressiveComponent, block_x: usize, block_y: usize) !*Block {
    if (block_x >= component.block_width or block_y >= component.block_height) return error.InvalidJpeg;
    return &component.blocks[block_y * @as(usize, component.block_width) + block_x];
}

fn progressiveComponentIndex(image: ProgressiveImage, component_id: u8) ?usize {
    for (image.components[0..image.component_count], 0..) |component, index| {
        if (component.frame_component.id == component_id) return index;
    }
    return null;
}

fn jpegPixelCount(dimensions: Dimensions) !usize {
    const width: usize = @intCast(dimensions.width);
    const height: usize = @intCast(dimensions.height);
    return std.math.mul(usize, width, height) catch error.ImageTooLarge;
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

pub fn decodePixels(allocator: std.mem.Allocator, bytes: []const u8) !DecodedPixels {
    const state = try parseDecodeState(bytes);
    const frame = state.frame orelse return error.InvalidJpeg;
    const pixels = try allocator.alloc(pixel.Pixel, try jpegPixelCount(frame.dimensions));
    errdefer allocator.free(pixels);

    switch (frame.frame) {
        .baseline => try decodeBaselinePixels(state, bytes[state.scan_data_offset..], pixels),
        .progressive => try decodeProgressivePixels(allocator, state, bytes, pixels),
        .other => return error.UnsupportedJpeg,
    }
    return .{
        .dimensions = frame.dimensions,
        .pixels = pixels,
    };
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
            0xc2 => state.frame = try parseFrameHeader(segment.marker, segment.data),
            0xda => {
                const scan = try parseScanHeader(segment.data);
                if (state.scan == null) {
                    state.scan = scan;
                    state.scan_data_offset = offset;
                }
                if (state.scan_count >= state.scans.len) return error.UnsupportedJpeg;
                const data_start = offset;
                const data_end = try scanDataEnd(bytes, data_start);
                state.scans[state.scan_count] = .{
                    .header = scan,
                    .data_start = data_start,
                    .data_end = data_end,
                    .dc_huffman_tables = state.dc_huffman_tables,
                    .ac_huffman_tables = state.ac_huffman_tables,
                };
                state.scan_count += 1;
                offset = data_end;
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

fn scanDataEnd(bytes: []const u8, start: usize) !usize {
    var offset = start;
    while (offset < bytes.len) {
        if (bytes[offset] != 0xff) {
            offset += 1;
            continue;
        }

        var marker_offset = offset + 1;
        while (marker_offset < bytes.len and bytes[marker_offset] == 0xff) {
            marker_offset += 1;
        }
        if (marker_offset >= bytes.len) return error.InvalidJpeg;

        const marker = bytes[marker_offset];
        if (marker == 0x00) {
            offset = marker_offset + 1;
            continue;
        }
        if (marker >= 0xd0 and marker <= 0xd7) return error.UnsupportedJpeg;
        return offset;
    }

    return error.InvalidJpeg;
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

test "JPEG parser state accepts progressive frame metadata but still requires a scan" {
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

    try std.testing.expectError(error.InvalidJpeg, parseDecodeState(&bytes));
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

test "JPEG entropy bit reader finish accepts fill bits and EOI marker" {
    var reader = EntropyBitReader.init(&[_]u8{ 0b0011_1111, 0xff, 0xd9 });

    try std.testing.expectEqual(@as(u16, 0), try reader.readBits(2));
    try reader.finish();
}

test "JPEG entropy bit reader finish rejects extra entropy bytes" {
    var reader = EntropyBitReader.init(&[_]u8{ 0b0011_1111, 0x00, 0xff, 0xd9 });

    try std.testing.expectEqual(@as(u16, 0), try reader.readBits(2));
    try std.testing.expectError(error.InvalidJpeg, reader.finish());
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

test "JPEG baseline scan plan accepts non-subsampled three component scans" {
    const state = testDecodeState(.{ .width = 17, .height = 9 }, 0x11);

    const plan = try buildBaselineScanPlan(state);
    const grid = mcuGrid(state.frame.?, plan);

    try std.testing.expectEqual(@as(u8, 3), plan.component_count);
    try std.testing.expectEqual(@as(u32, 8), plan.mcuWidth());
    try std.testing.expectEqual(@as(u32, 8), plan.mcuHeight());
    try std.testing.expectEqual(Dimensions{ .width = 3, .height = 2 }, grid);
}

test "JPEG baseline scan plan allows DRI zero" {
    var state = testDecodeState(.{ .width = 8, .height = 8 }, 0x11);
    state.restart_interval = 0;

    _ = try buildBaselineScanPlan(state);
}

test "JPEG baseline scan plan rejects non-zero restart interval" {
    var state = testDecodeState(.{ .width = 8, .height = 8 }, 0x11);
    state.restart_interval = 4;

    try std.testing.expectError(error.UnsupportedJpeg, buildBaselineScanPlan(state));
}

test "JPEG baseline scan plan accepts common 4:2:0 sampling" {
    const state = testDecodeState(.{ .width = 16, .height = 16 }, 0x22);

    const plan = try buildBaselineScanPlan(state);
    const grid = mcuGrid(state.frame.?, plan);

    try std.testing.expectEqual(@as(u32, 16), plan.mcuWidth());
    try std.testing.expectEqual(@as(u32, 16), plan.mcuHeight());
    try std.testing.expectEqual(Dimensions{ .width = 1, .height = 1 }, grid);
}

test "JPEG baseline scan plan accepts common 4:2:2 sampling" {
    const state = testDecodeState(.{ .width = 16, .height = 8 }, 0x21);
    var adjusted = state;
    adjusted.frame.?.components[0].vertical_sampling = 1;

    const plan = try buildBaselineScanPlan(adjusted);
    const grid = mcuGrid(adjusted.frame.?, plan);

    try std.testing.expectEqual(@as(u32, 16), plan.mcuWidth());
    try std.testing.expectEqual(@as(u32, 8), plan.mcuHeight());
    try std.testing.expectEqual(Dimensions{ .width = 1, .height = 1 }, grid);
}

test "JPEG baseline scan plan rejects larger sampling grids" {
    const state = testDecodeState(.{ .width = 24, .height = 8 }, 0x31);

    try std.testing.expectError(error.UnsupportedJpeg, buildBaselineScanPlan(state));
}

test "JPEG baseline scan plan rejects duplicate frame component ids" {
    var state = testDecodeState(.{ .width = 8, .height = 8 }, 0x11);
    state.frame.?.components[1].id = 1;

    try std.testing.expectError(error.InvalidJpeg, buildBaselineScanPlan(state));
}

test "JPEG baseline scan plan rejects duplicate scan component ids" {
    var state = testDecodeState(.{ .width = 8, .height = 8 }, 0x11);
    state.scan.?.components[1].id = 1;

    try std.testing.expectError(error.InvalidJpeg, buildBaselineScanPlan(state));
}

test "JPEG baseline scan plan rejects unsupported two component scans before entropy decode" {
    var state = testDecodeState(.{ .width = 8, .height = 8 }, 0x11);
    state.frame.?.component_count = 2;
    state.scan.?.component_count = 2;

    try std.testing.expectError(error.UnsupportedJpeg, buildBaselineScanPlan(state));
}

test "JPEG baseline scan plan rejects unsupported four component scans before entropy decode" {
    var state = testDecodeState(.{ .width = 8, .height = 8 }, 0x11);
    state.frame.?.component_count = 4;
    state.frame.?.components[3] = .{ .id = 4, .horizontal_sampling = 1, .vertical_sampling = 1, .quantization_table_id = 0 };
    state.scan.?.component_count = 4;
    state.scan.?.components[3] = .{ .id = 4, .dc_table_id = 0, .ac_table_id = 0 };

    try std.testing.expectError(error.UnsupportedJpeg, buildBaselineScanPlan(state));
}

test "JPEG YCbCr conversion maps neutral chroma to grayscale" {
    const px = ycbcrToRgb(80, 128, 128);

    try std.testing.expectEqual(@as(u8, 80), px.rgb.r);
    try std.testing.expectEqual(@as(u8, 80), px.rgb.g);
    try std.testing.expectEqual(@as(u8, 80), px.rgb.b);
}

test "JPEG YCbCr conversion clamps RGB output" {
    const px = ycbcrToRgb(255, 255, 255);

    try std.testing.expectEqual(@as(u8, 255), px.rgb.r);
    try std.testing.expect(px.rgb.g < 255);
    try std.testing.expectEqual(@as(u8, 255), px.rgb.b);
}

test "JPEG MCU sample block decode reads all plan components" {
    const state = testDecodeState(.{ .width = 8, .height = 8 }, 0x11);
    var plan = try buildBaselineScanPlan(state);
    var reader = EntropyBitReader.init(&[_]u8{0});

    const blocks = try decodeMcuSampleBlocks(&reader, &plan);
    const px = try mcuPixelAt(blocks, 0, 0);

    try std.testing.expectEqual(@as(u8, 3), blocks.component_count);
    try std.testing.expectEqual(@as(u8, 128), blocks.components[0].blocks[0][0]);
    try std.testing.expectEqual(@as(u8, 128), blocks.components[1].blocks[0][0]);
    try std.testing.expectEqual(@as(u8, 128), blocks.components[2].blocks[0][0]);
    try std.testing.expectEqual(@as(u8, 128), px.rgb.r);
    try std.testing.expectEqual(@as(u8, 128), px.rgb.g);
    try std.testing.expectEqual(@as(u8, 128), px.rgb.b);
}

test "JPEG MCU sample lookup maps 4:2:0 chroma over larger luma grid" {
    const state = testDecodeState(.{ .width = 16, .height = 16 }, 0x22);
    var plan = try buildBaselineScanPlan(state);
    var reader = EntropyBitReader.init(&[_]u8{ 0, 0 });

    const blocks = try decodeMcuSampleBlocks(&reader, &plan);
    const top_left = try mcuPixelAt(blocks, 0, 0);
    const bottom_right = try mcuPixelAt(blocks, 15, 15);

    try std.testing.expectEqual(@as(u4, 2), blocks.max_horizontal_sampling);
    try std.testing.expectEqual(@as(u4, 2), blocks.max_vertical_sampling);
    try std.testing.expectEqual(@as(u8, 128), top_left.rgb.r);
    try std.testing.expectEqual(@as(u8, 128), bottom_right.rgb.b);
}

test "JPEG MCU sample block decode keeps component DC predictors" {
    const state = testDecodeState(.{ .width = 16, .height = 8 }, 0x11);
    var plan = try buildBaselineScanPlan(state);
    plan.components[0].previous_dc = 10;
    var reader = EntropyBitReader.init(&[_]u8{0});

    _ = try decodeMcuSampleBlocks(&reader, &plan);

    try std.testing.expectEqual(@as(i16, 10), plan.components[0].previous_dc);
    try std.testing.expectEqual(@as(i16, 0), plan.components[1].previous_dc);
    try std.testing.expectEqual(@as(i16, 0), plan.components[2].previous_dc);
}

test "JPEG baseline pixel decode writes neutral gray image buffer" {
    const state = testDecodeState(.{ .width = 8, .height = 8 }, 0x11);
    var out: [64]pixel.Pixel = undefined;

    try decodeBaselinePixels(state, &[_]u8{0b0000_0011}, &out);

    for (out) |px| {
        try std.testing.expectEqual(@as(u8, 128), px.rgb.r);
        try std.testing.expectEqual(@as(u8, 128), px.rgb.g);
        try std.testing.expectEqual(@as(u8, 128), px.rgb.b);
    }
}

test "JPEG baseline pixel decode clips edge MCUs to image dimensions" {
    const state = testDecodeState(.{ .width = 9, .height = 9 }, 0x11);
    var out: [81]pixel.Pixel = undefined;

    try decodeBaselinePixels(state, &[_]u8{ 0, 0, 0 }, &out);

    try std.testing.expectEqual(@as(u8, 128), out[0].rgb.r);
    try std.testing.expectEqual(@as(u8, 128), out[8].rgb.r);
    try std.testing.expectEqual(@as(u8, 128), out[72].rgb.r);
    try std.testing.expectEqual(@as(u8, 128), out[80].rgb.r);
}

test "JPEG baseline pixel decode rejects trailing entropy data" {
    const state = testDecodeState(.{ .width = 8, .height = 8 }, 0x11);
    var out: [64]pixel.Pixel = undefined;

    try std.testing.expectError(
        error.InvalidJpeg,
        decodeBaselinePixels(state, &[_]u8{ 0b0000_0011, 0x00 }, &out),
    );
}

fn testDecodeState(dimensions: Dimensions, first_component_sampling: u8) DecodeState {
    return .{
        .frame = .{
            .dimensions = dimensions,
            .precision = 8,
            .component_count = 3,
            .frame = .baseline,
            .components = .{
                .{
                    .id = 1,
                    .horizontal_sampling = @intCast(first_component_sampling >> 4),
                    .vertical_sampling = @intCast(first_component_sampling & 0x0f),
                    .quantization_table_id = 0,
                },
                .{ .id = 2, .horizontal_sampling = 1, .vertical_sampling = 1, .quantization_table_id = 0 },
                .{ .id = 3, .horizontal_sampling = 1, .vertical_sampling = 1, .quantization_table_id = 0 },
                undefined,
            },
        },
        .quantization_tables = .{ testQuantizationTable(), null, null, null },
        .dc_huffman_tables = .{ testHuffmanTable(.dc), null, null, null },
        .ac_huffman_tables = .{ testHuffmanTable(.ac), null, null, null },
        .scan = .{
            .component_count = 3,
            .spectral_start = 0,
            .spectral_end = 63,
            .successive_approximation_high = 0,
            .successive_approximation_low = 0,
            .components = .{
                .{ .id = 1, .dc_table_id = 0, .ac_table_id = 0 },
                .{ .id = 2, .dc_table_id = 0, .ac_table_id = 0 },
                .{ .id = 3, .dc_table_id = 0, .ac_table_id = 0 },
                undefined,
            },
        },
    };
}

fn testQuantizationTable() QuantizationTable {
    return .{
        .precision = 0,
        .id = 0,
        .values = [_]u16{1} ** 64,
    };
}

fn testHuffmanTable(class: HuffmanTableClass) HuffmanTable {
    return .{
        .class = class,
        .id = 0,
        .code_counts = .{
            1, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
            0, 0, 0, 0,
        },
        .symbols = .{0} ++ ([_]u8{0} ** 255),
        .symbol_count = 1,
    };
}
