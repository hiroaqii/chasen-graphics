# chasen-graphics

Small terminal graphics primitive package for [Chasen](https://github.com/hiroaqii/chasen)
terminal applications.

The Zig module name is `chasen_graphics`.

The `chasen_graphics` module uses only the Zig standard library. Its PNG/JPEG
decoders are implemented in this package. Chasen integration lives in a
separate module.

## Requirements

Zig 0.16.0.

## Current Status

Experimental; the API may change. Image format support is limited; see
[Image Processing](docs/GRAPHICS.md#image-processing) for supported formats.

## Scope

The package provides:

- glyph and symbol sets
- spinner and progress glyph data
- ASCII / glyph brightness ramps
- Braille dot helpers
- cell sampling for Blocks, Arc, and Ripple loading indicators
- pixel / image fallback helpers
- backend-neutral terminal image placement policy
- PNG/JPEG decoding, PNG encoding, resizing, and cropping
- optional Chasen terminal image loader adapter

Out of scope:

- animation timing
- UI component state
- app-specific image download or cache policy
- integration with external image decoder libraries

## Modules and Dependencies

| Zig module | Purpose | Dependencies |
| --- | --- | --- |
| `chasen_graphics` | Glyphs, loading indicators, pixel/image helpers, and terminal image policy | Zig standard library |
| `chasen_graphics_chasen` | Image loaders and placement conversion for Chasen | `chasen_graphics` and Chasen |

The package build resolves Chasen from a fixed Git commit and hash in
[build.zig.zon](build.zig.zon); no sibling checkout is required. The build
currently resolves this dependency even when running core tests, while the
core source module itself remains independent of Chasen.

## Installation

From your application's Zig project:

```sh
zig fetch --save git+https://github.com/hiroaqii/chasen-graphics.git
```

Add the dependency to `build.zig`. This complete example builds `src/main.zig`
with the core module:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const graphics = b.dependency("chasen_graphics", .{
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "graphics-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "chasen_graphics", .module = graphics.module("chasen_graphics") }},
        }),
    });
    b.installArtifact(exe);
}
```

### Optional Chasen adapter

For a Chasen application, insert the following before `b.installArtifact(exe)`
in the example above. Obtain Chasen from the graphics dependency so the
application and adapter use the same Chasen module:

```zig
const chasen = graphics.builder.lazyDependency("chasen", .{
    .target = target,
    .optimize = optimize,
}) orelse return;
exe.root_module.addImport("chasen", chasen.module("chasen"));
exe.root_module.addImport("chasen_graphics_chasen", graphics.module("chasen_graphics_chasen"));
exe.use_llvm = true;
exe.use_lld = if (target.result.os.tag == .linux) true else null;
```

The LLVM backend and Linux LLD setting match Chasen's native build configuration.
In `src/main.zig`, import `chasen` and `chasen_graphics_chasen` to use the adapter.
See the [terminal image example](examples/terminal_image/main.zig) for wiring
`decodedImagePathLoader` into `chasen.runWith`.

## Usage

The application owns animation timing and rendering. This example samples a
loading indicator and prints its glyphs once; a Chasen application would draw
the same cells to its surface and use `intensity` to choose a style.

Save this as `src/main.zig`, then run `zig build` and
`./zig-out/bin/graphics-demo`:

```zig
const std = @import("std");
const graphics = @import("chasen_graphics");

pub fn main() void {
    // One full animation cycle is 1.0. The caller supplies the phase.
    const phase = 0.25;
    const dims = graphics.loading.dimensions(.arc, .small);
    for (0..dims.height) |row| {
        for (0..dims.width) |col| {
            const cell = graphics.loading.sample(.arc, .small, phase, @intCast(col), @intCast(row));
            // Glyphs are borrowed for program lifetime; no allocation is needed.
            std.debug.print("{s}", .{cell.glyph});
        }
        std.debug.print("\n", .{});
    }
}
```

Use [chasen-anim](https://github.com/hiroaqii/chasen-anim) for frame counters,
phases, or easing if needed. It is not a dependency of this package.

## API Guide

See the [Graphics API Guide](docs/GRAPHICS.md) for available helpers and their
behavior:

- [Glyphs, blocks, and brightness ramps](docs/GRAPHICS.md#glyphs)
- [Pixels and Braille](docs/GRAPHICS.md#pixel)
- [Loading indicators](docs/GRAPHICS.md#loading-indicators)
- [Image processing and supported formats](docs/GRAPHICS.md#image-processing)
- [Terminal image policy and Chasen integration](docs/GRAPHICS.md#terminal-images)

## Development

From a repository checkout, run core tests:

```sh
zig build test
```

Run core and Chasen adapter tests, build the terminal image example, and run
the Braille mask example:

```sh
zig build test check-chasen-adapter check-terminal-image run-braille-mask --summary all
```

The command above compiles the terminal image example without launching it.
Displaying it requires an interactive terminal with Kitty graphics support.
The Braille mask example prints text and can run without an interactive terminal.

`test` covers the core module; Chasen adapter tests are a separate step.
The core module can also be tested without evaluating the package build or
fetching Chasen:

```sh
zig test src/root.zig
```

## License

See [LICENSE](LICENSE).
