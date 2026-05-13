const std = @import("std");
const graphics = @import("chasen_graphics");

/// Small example for turning a 2x4 boolean dot matrix into one Braille glyph.
///
/// This mirrors the shape a later image / pixel loader can use: decide which
/// tiny dots are on, OR their masks together, then pass the final mask to
/// `braille.fromDots`.
pub fn main() !void {
    const braille = graphics.braille;

    const dots = [braille.rows][braille.cols]bool{
        .{ true, false },
        .{ true, false },
        .{ false, true },
        .{ false, false },
    };

    var mask: u8 = 0;
    for (dots, 0..) |row, y| {
        for (row, 0..) |on, x| {
            if (on) {
                mask |= braille.dotMask(@intCast(x), @intCast(y));
            }
        }
    }

    const glyph = braille.fromDots(mask);

    std.debug.print("dot matrix:\n", .{});
    for (dots) |row| {
        for (row) |on| {
            std.debug.print("{s}", .{if (on) "on  " else "off "});
        }
        std.debug.print("\n", .{});
    }

    std.debug.print("\nmask: 0b{b:0>8}\n", .{mask});
    std.debug.print("glyph: {s}\n", .{&glyph});
}
