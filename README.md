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

## Development

Run tests:

```sh
zig build test
```
