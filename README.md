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
- ASCII brightness ramps
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

## ASCII

- `ascii.ramp.basic`: basic brightness ramp ordered from darker to brighter.

Brightness-to-index mapping is a separate helper; the ramp constants only
provide reusable ordered character sets.

## Development

Run tests:

```sh
zig build test
```
