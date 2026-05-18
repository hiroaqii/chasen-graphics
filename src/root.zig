const std = @import("std");

pub const glyph = @import("glyph.zig");
pub const blocks = @import("blocks.zig");
pub const ascii = @import("ascii.zig");
pub const pixel = @import("pixel.zig");
pub const braille = @import("braille.zig");
pub const terminal = @import("terminal.zig");

/// Package version exposed as a simple smoke-testable value.
///
/// `chasen-graphics` starts as a std-only package. Later modules may integrate
/// with Chasen `Surface` types, but pure glyph/block data should stay usable
/// without pulling in the Chasen runtime.
pub const version = "0.0.0";

test "chasen-graphics root imports" {
    try std.testing.expectEqualStrings("0.0.0", version);
    try std.testing.expect(@hasDecl(@This(), "glyph"));
    try std.testing.expect(@hasDecl(@This(), "blocks"));
    try std.testing.expect(@hasDecl(@This(), "ascii"));
    try std.testing.expect(@hasDecl(@This(), "pixel"));
    try std.testing.expect(@hasDecl(@This(), "braille"));
    try std.testing.expect(@hasDecl(@This(), "terminal"));
}

test {
    std.testing.refAllDecls(@This());
}
