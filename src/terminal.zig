const std = @import("std");

/// Terminal image protocols that `chasen-graphics` can model.
///
/// This namespace is intentionally terminal-specific. Browser DOM / Canvas
/// placement should use backend-neutral image/pixel primitives plus a browser
/// adapter rather than these protocol names.
pub const ImageProtocol = enum {
    kitty,
};

/// Kitty Graphics Protocol metadata and convenience helpers.
///
/// This does not encode Kitty escape sequences. The terminal backend adapter
/// should continue to use libvaxis or another backend for actual transmission.
pub const kitty = struct {
    pub const protocol: ImageProtocol = .kitty;

    /// Build an image capability snapshot from a known Kitty graphics result.
    pub fn capability(supported: bool) ImageCapability {
        return .{ .kitty_graphics = supported };
    }

    /// Plan Kitty placement using one explicit fallback.
    pub fn placement(capability_snapshot: ImageCapability, fallback: ImageFallback) PlacementPlan {
        return placementPlan(capability_snapshot, protocol, fallback);
    }

    /// Plan Kitty placement using fallback support and caller-provided order.
    pub fn placementWithFallbacks(
        capability_snapshot: ImageCapability,
        fallback_support: ImageFallbackSupport,
        fallback_order: []const ImageFallback,
    ) PlacementPlan {
        return placementPlanWithFallbacks(capability_snapshot, protocol, fallback_support, fallback_order);
    }
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

/// Fallback renderers available in the current terminal/app context.
///
/// This is not terminal detection. Runtime or adapter code should fill it from
/// known terminal capabilities, app policy, or the helpers already implemented
/// by the caller. Image-like fallbacks default to unavailable until a caller
/// wires the renderer. Text fallback and `none` are treated as always available.
pub const ImageFallbackSupport = struct {
    glyph_placeholder: bool = true,
    pixel_block: bool = false,
    ascii: bool = false,

    pub fn supports(self: ImageFallbackSupport, fallback: ImageFallback) bool {
        return switch (fallback) {
            .none, .text_placeholder => true,
            .glyph_placeholder => self.glyph_placeholder,
            .pixel_block => self.pixel_block,
            .ascii => self.ascii,
        };
    }
};

/// Conservative fallback order for terminals without image protocol support.
///
/// Prefer explicit low-resolution image-like renderers when the caller says
/// they are available, then degrade to a text placeholder, then no image.
pub const defaultFallbackOrder: []const ImageFallback = &.{
    .pixel_block,
    .ascii,
    .glyph_placeholder,
    .text_placeholder,
    .none,
};

/// Return the first supported fallback from `order`.
pub fn chooseFallback(support: ImageFallbackSupport, order: []const ImageFallback) ImageFallback {
    for (order) |fallback| {
        if (support.supports(fallback)) return fallback;
    }
    return .none;
}

/// Decide whether to use a terminal image protocol or a fallback.
pub fn placementPlan(capability: ImageCapability, protocol: ImageProtocol, fallback: ImageFallback) PlacementPlan {
    return if (capability.supports(protocol))
        .{ .protocol = protocol }
    else
        .{ .fallback = fallback };
}

/// Decide whether to use a terminal image protocol or the best supported fallback.
pub fn placementPlanWithFallbacks(
    capability: ImageCapability,
    protocol: ImageProtocol,
    fallback_support: ImageFallbackSupport,
    fallback_order: []const ImageFallback,
) PlacementPlan {
    return placementPlan(capability, protocol, chooseFallback(fallback_support, fallback_order));
}

/// Result of choosing between terminal image placement and fallback rendering.
pub const PlacementPlan = union(enum) {
    protocol: ImageProtocol,
    fallback: ImageFallback,
};

test "ImageCapability reports supported protocols" {
    const unsupported = ImageCapability{};
    try std.testing.expect(!unsupported.supports(.kitty));

    const capability = ImageCapability{ .kitty_graphics = true };
    try std.testing.expect(capability.supports(.kitty));
}

test "kitty helper builds capability snapshots" {
    try std.testing.expect(!kitty.capability(false).supports(.kitty));
    try std.testing.expect(kitty.capability(true).supports(.kitty));
}

test "kitty helper plans placement with explicit fallback" {
    const plan = kitty.placement(kitty.capability(false), .text_placeholder);

    try std.testing.expectEqual(PlacementPlan{ .fallback = .text_placeholder }, plan);
}

test "kitty helper plans placement with fallback order" {
    const plan = kitty.placementWithFallbacks(
        kitty.capability(false),
        .{ .pixel_block = true },
        defaultFallbackOrder,
    );

    try std.testing.expectEqual(PlacementPlan{ .fallback = .pixel_block }, plan);
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

test "ImageFallbackSupport reports available fallback renderers" {
    const conservative = ImageFallbackSupport{};

    try std.testing.expect(conservative.supports(.none));
    try std.testing.expect(conservative.supports(.text_placeholder));
    try std.testing.expect(conservative.supports(.glyph_placeholder));
    try std.testing.expect(!conservative.supports(.pixel_block));
    try std.testing.expect(!conservative.supports(.ascii));
}

test "chooseFallback selects the first supported fallback" {
    const support = ImageFallbackSupport{
        .glyph_placeholder = false,
        .pixel_block = false,
        .ascii = true,
    };

    const selected = chooseFallback(support, &.{ .pixel_block, .glyph_placeholder, .ascii, .text_placeholder });

    try std.testing.expectEqual(ImageFallback.ascii, selected);
}

test "chooseFallback returns none when order is empty" {
    const selected = chooseFallback(.{}, &.{});

    try std.testing.expectEqual(ImageFallback.none, selected);
}

test "placementPlanWithFallbacks selects protocol before fallback" {
    const plan = placementPlanWithFallbacks(
        .{ .kitty_graphics = true },
        .kitty,
        .{},
        defaultFallbackOrder,
    );

    try std.testing.expectEqual(PlacementPlan{ .protocol = .kitty }, plan);
}

test "placementPlanWithFallbacks selects best supported fallback" {
    const plan = placementPlanWithFallbacks(
        .{},
        .kitty,
        .{ .pixel_block = true },
        defaultFallbackOrder,
    );

    try std.testing.expectEqual(PlacementPlan{ .fallback = .pixel_block }, plan);
}

test "placementPlanWithFallbacks defaults to glyph placeholder when image renderers are unavailable" {
    const plan = placementPlanWithFallbacks(
        .{},
        .kitty,
        .{},
        defaultFallbackOrder,
    );

    try std.testing.expectEqual(PlacementPlan{ .fallback = .glyph_placeholder }, plan);
}

test {
    std.testing.refAllDecls(@This());
}
