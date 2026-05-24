/// Image dimensions in pixels.
pub const Dimensions = struct {
    width: u32,
    height: u32,
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
