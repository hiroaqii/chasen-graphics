const std = @import("std");

pub const glyph = @import("glyph.zig");
pub const blocks = @import("blocks.zig");

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
}

test {
    std.testing.refAllDecls(@This());
}
