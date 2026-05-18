const std = @import("std");

/// Terminal image protocols that `chasen-graphics` can model.
///
/// This namespace is intentionally terminal-specific. Browser DOM / Canvas
/// placement should use backend-neutral image/pixel primitives plus a browser
/// adapter rather than these protocol names.
pub const ImageProtocol = enum {
    kitty,
};

/// Image scaling policy in a terminal-cell destination area.
///
/// The names mirror libvaxis' image scale vocabulary so a later adapter can
/// translate without inventing another set of meanings.
pub const ImageFit = enum {
    /// Keep the original image size.
    none,
    /// Stretch or shrink to fill the destination area.
    fill,
    /// Scale to fit the destination area while preserving aspect ratio.
    fit,
    /// Scale to fit only when the image is larger than the destination area.
    contain,
};

/// Pixel offset inside the top-left terminal cell.
///
/// This is terminal image placement detail, not browser layout. Values are
/// interpreted by the eventual terminal backend adapter.
pub const PixelOffset = struct {
    x: u16 = 0,
    y: u16 = 0,
};

/// Source-image crop region measured in pixels.
///
/// This is separate from destination clipping in terminal cells. Destination
/// clipping belongs to `Surface.child(rect)` or a later placement adapter.
pub const SourceClipPx = struct {
    x: ?u16 = null,
    y: ?u16 = null,
    width: ?u16 = null,
    height: ?u16 = null,
};

/// Backend-neutral placement options for terminal image adapters.
///
/// The type avoids direct Chasen/libvaxis fields so the first Phase 5 slice can
/// stay std-only. A later adapter can translate this into concrete backend draw
/// options.
pub const ImagePlacementOptions = struct {
    fit: ImageFit = .none,
    z_index: ?i32 = null,
    source_clip_px: ?SourceClipPx = null,
    pixel_offset: ?PixelOffset = null,
};

/// Terminal graphics capabilities known to the caller.
///
/// Detection is not performed here yet. Terminal runtime or adapter code should
/// fill this shape from libvaxis or another backend capability source.
pub const ImageCapability = struct {
    kitty_graphics: bool = false,

    pub fn supports(self: ImageCapability, protocol: ImageProtocol) bool {
        return switch (protocol) {
            .kitty => self.kitty_graphics,
        };
    }
};

/// Fallback rendering policy when a terminal image protocol is unavailable.
///
/// `pixel_block` and `ascii` are stable policy names even though richer fallback
/// renderers may arrive later. Implementation availability should be documented
/// on helpers, not encoded into enum variant names.
pub const ImageFallback = enum {
    none,
    text_placeholder,
    glyph_placeholder,
    pixel_block,
    ascii,
};

/// Decide whether to use a terminal image protocol or a fallback.
pub fn placementPlan(capability: ImageCapability, protocol: ImageProtocol, fallback: ImageFallback) PlacementPlan {
    return if (capability.supports(protocol))
        .{ .protocol = protocol }
    else
        .{ .fallback = fallback };
}

/// Result of choosing between terminal image placement and fallback rendering.
pub const PlacementPlan = union(enum) {
    protocol: ImageProtocol,
    fallback: ImageFallback,
};

test "ImageCapability reports supported protocols" {
    const unsupported = ImageCapability{};
    try std.testing.expect(!unsupported.supports(.kitty));

    const kitty = ImageCapability{ .kitty_graphics = true };
    try std.testing.expect(kitty.supports(.kitty));
}

test "ImagePlacementOptions defaults to unscaled placement" {
    const opts = ImagePlacementOptions{};

    try std.testing.expectEqual(ImageFit.none, opts.fit);
    try std.testing.expectEqual(@as(?i32, null), opts.z_index);
    try std.testing.expectEqual(@as(?SourceClipPx, null), opts.source_clip_px);
    try std.testing.expectEqual(@as(?PixelOffset, null), opts.pixel_offset);
}

test "SourceClipPx models source crop separately from destination placement" {
    const clip = SourceClipPx{
        .x = 10,
        .y = 20,
        .width = 120,
        .height = 80,
    };

    try std.testing.expectEqual(@as(?u16, 10), clip.x);
    try std.testing.expectEqual(@as(?u16, 20), clip.y);
    try std.testing.expectEqual(@as(?u16, 120), clip.width);
    try std.testing.expectEqual(@as(?u16, 80), clip.height);
}

test "placementPlan selects protocol when capability is available" {
    const plan = placementPlan(.{ .kitty_graphics = true }, .kitty, .text_placeholder);

    try std.testing.expectEqual(PlacementPlan{ .protocol = .kitty }, plan);
}

test "placementPlan selects fallback when capability is unavailable" {
    const plan = placementPlan(.{}, .kitty, .glyph_placeholder);

    try std.testing.expectEqual(PlacementPlan{ .fallback = .glyph_placeholder }, plan);
}

test {
    std.testing.refAllDecls(@This());
}
