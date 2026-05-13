# chasen-graphics

Small terminal graphics primitive package for [Chasen](https://github.com/hiroaqii/chasen)
terminal applications.

The Zig module name is `chasen_graphics`.

`chasen-graphics` starts as std-only. Pure glyph, ramp, and Braille helpers
should stay usable without depending on Chasen core, `chasen-ui`, or a renderer.

## Scope

Initial scope:

- glyph and symbol sets
- spinner and progress glyph data
- ASCII / glyph brightness ramps
- Braille dot helpers
- pixel / image fallback helpers

Out of scope:

- animation timing
- UI component state
- app-specific image download or cache policy
- required image decoder dependencies

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

Shade blocks are ordered from lighter to darker. Numeric brightness mapping is
left to a later helper.

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
- `pixel.halfBlock(upper, lower)`: build a half-block render plan.

Pixel input types are std-only data shapes. Decoding, compositing, terminal
style conversion, and rendering policy are handled by later helpers or callers.

`pixel.halfBlock` uses the upper-half block glyph and preserves both input
pixels. Foreground/background style conversion and alpha policy are handled by
later helpers.

## Braille

- `braille.cols`: number of dot columns in one Braille cell.
- `braille.rows`: number of dot rows in one Braille cell.
- `braille.fromDots(mask)`: convert an 8-bit dot mask to a UTF-8 Braille glyph.
- `braille.dotMask(x, y)`: return the bit mask for a zero-based dot coordinate.

Braille helpers are std-only. They encode dot masks into text glyphs; callers or
later helpers decide which dots should be active.

## Development

Run tests:

```sh
zig build test
```
