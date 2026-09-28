# Graphics API Guide

[Back to README](../README.md)

The helpers below belong to `chasen_graphics`, except for the Chasen adapter
functions in [Terminal Images](#terminal-images). In code snippets, `graphics`
refers to `@import("chasen_graphics")`. Run build commands from the repository root.

- [Glyphs](#glyphs)
- [Blocks](#blocks)
- [ASCII / Ramps](#ascii--ramps)
- [Pixel](#pixel)
- [Braille](#braille)
- [Loading Indicators](#loading-indicators)
- [Image Processing](#image-processing)
- [Terminal Images](#terminal-images)

## Glyphs

- `glyph.rating.filled`: filled rating star.
- `glyph.rating.empty`: empty rating star.
- `glyph.rating.filled_ascii`: ASCII fallback for filled rating.
- `glyph.rating.empty_ascii`: ASCII fallback for empty rating.
- `glyph.status.ok`: successful or completed status.
- `glyph.status.err`: failed or unavailable status.
- `glyph.status.warn`: warning status.
- `glyph.status.info`: informational status.
- `glyph.status.ok_ascii`: ASCII fallback for successful status.
- `glyph.status.err_ascii`: ASCII fallback for failed status.
- `glyph.selection.marker`: active or focused item marker.
- `glyph.selection.marker_ascii`: ASCII fallback for active or focused item marker.
- `glyph.checkbox.unchecked`: unchecked checkbox marker.
- `glyph.checkbox.checked`: checked checkbox marker.
- `glyph.radio.unselected`: unselected radio marker.
- `glyph.radio.selected`: selected radio marker.
- `glyph.spinner.line`: four-frame ASCII line spinner.
- `glyph.spinner.ascii`: conservative ASCII fallback spinner.
- `glyph.spinner.dots`: ten-frame Unicode dot spinner.
- `glyph.spinner.circle`: four-frame Unicode circle spinner.
- `glyph.spinner.linear_dots`: three five-cell frames of sequential dots.
- `glyph.spinner.wave`: eight five-cell frames of rising/falling bars.
- `glyph.spinner.linear_dots_tiny`: eight one-cell frames of a moving Braille dot.
- `glyph.spinner.wave_tiny`: eight one-cell frames of a rising/falling bar.

Selection marker meaning is app/component policy; the constants only provide
default glyph choices.

Checkbox and radio state are app/component policy; the constants only provide
default marker glyphs.

Spinner frame advancement is app/component/animation policy; the constants only
provide ordered frame labels.

Unicode spinner frames depend on terminal/font support. Use ASCII frame sets
when a conservative fallback is needed.
`glyph.spinner.ascii` currently exposes the same frames as `glyph.spinner.line`.

## Blocks

- `blocks.progress.filled`: filled progress cell.
- `blocks.progress.empty`: empty progress cell.
- `blocks.progress.filled_ascii`: ASCII fallback for filled progress.
- `blocks.progress.empty_ascii`: ASCII fallback for empty progress.
- `blocks.shade.light`: light shade block.
- `blocks.shade.medium`: medium shade block.
- `blocks.shade.dark`: dark shade block.
- `blocks.shade.full`: full block.

Progress value, width, clipping, style, and redraw timing are app/component
policy; the constants only provide reusable cell labels.

`blocks.progress.empty` is a space so renderers can use background style for the
empty region. Use `blocks.progress.empty_ascii` when visible empty cells are
needed in plain text.

Shade blocks are ordered from lighter to darker. Use the `ascii` brightness
helpers below to map numeric values to ramp entries.

## ASCII / Ramps

- `ascii.ramp.basic`: basic brightness ramp ordered from darker to brighter.
- `ascii.ramp.dense`: dense brightness ramp ordered from darker to brighter.
- `ascii.ramp.shade`: shade/block ramp entries ordered from darker to brighter.

Brightness-to-index mapping is a separate helper; the ramp constants only
provide reusable ordered character sets.

`ascii.ramp.basic` and `ascii.ramp.dense` are ASCII-only strings. `ascii.ramp.shade`
is an entry array because it contains multi-byte UTF-8 block glyphs.

- `ascii.brightnessToIndex(brightness, entry_count)`: map normalized brightness
  to a ramp entry index.
- `ascii.brightnessToGlyph(brightness, entries)`: map normalized brightness to
  a ramp glyph entry.

Pass the number of ramp entries to `brightnessToIndex`. For ASCII-only string
ramps, `.len` is the entry count. For UTF-8 entry-array ramps such as
`ascii.ramp.shade`, `.len` is also the entry count.

Pass an entry array to `brightnessToGlyph`. It is safe for multi-byte UTF-8
glyphs because it indexes entries, not raw bytes.

## Pixel

- `pixel.Rgb`: 8-bit RGB color sample.
- `pixel.Pixel`: decoded pixel sample with RGB color and 8-bit alpha.
- `pixel.HalfBlockCell`: std-only half-block render plan for two vertical pixels.
- `pixel.TrueColorStyle`: std-only foreground/background RGB style plan.
- `pixel.TrueColorCell`: glyph plus std-only truecolor style plan.
- `pixel.halfBlock(upper, lower)`: build a half-block render plan.
- `pixel.halfBlockTrueColor(cell)`: map a half-block plan to a truecolor cell plan.
- `pixel.renderHalfBlockRowTrueColor(out, upper_row, lower_row)`: render one row into caller-provided cells.
- `pixel.nearestColorIndex(color, palette)`: find the nearest palette index.
- `pixel.nearestColor(color, palette)`: find the nearest palette color.

Pixel input types are std-only data shapes. The `image` module decodes pixels;
callers own compositing, terminal style conversion, and rendering policy.

`pixel.halfBlock` uses the upper-half block glyph and preserves both input
pixels. `halfBlockTrueColor` converts them to foreground/background RGB colors
and ignores alpha; callers must handle transparency before that conversion.

`pixel.halfBlockTrueColor` maps the upper pixel to foreground and the lower
pixel to background. It still returns std-only data; Chasen/libvaxis style
conversion is the caller's responsibility.

`pixel.renderHalfBlockRowTrueColor` fills a caller-provided `TrueColorCell`
buffer. It is a small std-only rendering helper; it does not allocate and does
not write to a Chasen `Surface`.

`pixel.nearestColorIndex` and `pixel.nearestColor` use simple squared RGB
distance. They are fallback helpers for callers that need to map truecolor input
to a limited palette.

## Braille

- `braille.cols`: number of dot columns in one Braille cell.
- `braille.rows`: number of dot rows in one Braille cell.
- `braille.fromDots(mask)`: convert an 8-bit dot mask to a UTF-8 Braille glyph.
- `braille.glyph(mask)`: borrow a UTF-8 glyph with program lifetime.
- `braille.dotMask(x, y)`: return the bit mask for a zero-based dot coordinate.

Braille helpers encode dot masks into text glyphs; callers decide which dots
should be active.

Run the small Braille mask example:

```sh
zig build run-braille-mask
```

## Loading Indicators

`loading` samples Blocks, Arc, and Ripple as individual terminal cells without
allocating. Pass a cycle phase (one full cycle is `1.0`), a `Kind`, a `Size`,
and zero-based column/row coordinates:

```zig
const dims = graphics.loading.dimensions(.arc, .medium);
const cell = graphics.loading.sample(.arc, .medium, 0.25, 3, 0);
// cell.glyph is borrowed for program lifetime; cell.intensity is in 0...1.
```

| Kind | Tiny | Small | Medium | Large |
| --- | --- | --- | --- | --- |
| Blocks | 1×1 | 8×5 | 14×8 | 20×11 |
| Arc / Ripple | 1×1 | 8×4 | 12×6 | 16×8 |

Dimensions are terminal cells and exclude labels. Finite phases wrap modulo
one; non-finite phases select phase zero. Out-of-bounds samples are empty.
Arc/Ripple use Braille dots and assume the usual 1:2 terminal cell proportions.
Glyph appearance and dim brightness depend on the terminal/font.

Use `.tiny` for the minimum non-empty size, one terminal cell. Within that
cell, Blocks rotates a quadrant, Arc rotates three Braille dots, and Ripple
expands from center to outer dots before fading. These are simplified motions;
small, medium, and large sizes use more detailed shapes.

The caller owns time, speed, color, placement, clipping, and clearing the
previous frame. These helpers do not write to a terminal or request frames.
The Dots/Wave presets above can be passed to an existing one-line spinner
instead of using cell sampling. Choose `linear_dots_tiny` / `wave_tiny` for
one-cell frames, or `linear_dots` / `wave` for the existing five-cell frames.

## Image Processing

The [image module](../src/image.zig) provides:

- `detectSourceFormat`, `pngInfo`, and `jpegInfo`: format and metadata inspection.
- `decodeImage`, `decodePng`, and `decodeJpeg`: decode into owned `DecodedImage` pixels.
- `encodePngRgbaAlloc`: encode RGBA pixels as PNG using uncompressed zlib data.
- `fittedDimensions`, `resizeNearest`, `crop`, and `cropCenter`: sizing and pixel transforms.

Free decoded images with `deinit` using the same allocator. Encoded PNG buffers
are also caller-owned and must be freed. The encoder favors simple terminal
transport over small file sizes.

| Format | Built-in decoding |
| --- | --- |
| PNG | 8-bit RGB/RGBA, non-interlaced, filters 0–4 |
| JPEG | Limited 8-bit baseline/progressive support; grayscale or YCbCr, sampling factors up to 2×2, no restart intervals |
| WebP | Detected, but decoding returns `UnsupportedImageFormat` |

JPEG decoding does not apply EXIF orientation. Format detection or metadata
inspection does not guarantee that pixel decoding supports a particular file.

## Terminal Images

- `terminal.ImagePlacementOptions`: backend-neutral terminal image placement policy.
- `terminal.coverArtPlacementOptions()`: centered fit placement for cover art.
- `terminal.ImageCapability`: caller-provided terminal image capability snapshot.
- `terminal.chooseKittyTransport(...)`: choose direct Kitty, tmux passthrough, or unsupported.
- `terminal.chooseFallback(...)`: choose a supported fallback renderer from an ordered policy.

The optional `chasen_graphics_chasen` module provides:

- `pngPathLoader`: Chasen terminal image loader for local encoded PNG files.
- `decodedImagePathLoader`: passes PNG files through; decodes supported JPEG files
  with the built-in decoder and re-encodes them as PNG for terminal transport.
- `terminalImageOptions`: convert `terminal.ImagePlacementOptions` to Chasen `TerminalImageOptions`.
- `coverArtTerminalImageOptions`: Chasen cover-art placement defaults.

Both path loaders require Kitty graphics support. PNG passthrough sends the
original encoded file without using the limited built-in PNG pixel decoder.
They accept files up to 16 MiB. The JPEG decode path also limits decoded RGBA
pixel data to 64 MiB.

`terminalImageOptions` is currently a lossy conversion for fields Chasen can
represent. `source_clip_px` and `pixel_offset` remain std-only policy fields
until Chasen exposes matching terminal image options.

Run the optional Chasen adapter tests:

```sh
zig build check-chasen-adapter
```

Build the terminal image example:

```sh
zig build check-terminal-image
```

The [terminal image example](../examples/terminal_image/main.zig) generates a sample
PNG and displays it through Chasen. Run `zig build run-terminal-image` in a
terminal with Kitty graphics support; press `q` to exit.
