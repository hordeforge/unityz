# unityz

A Zig library and CLI for reading, extracting, and editing Unity assets.

## Quick start

Requires [Zig](https://ziglang.org/) 0.16.0.

```bash
git clone https://github.com/hordeforge/unityz
cd unityz
zig build test
zig build
```

Run the CLI:

```bash
./zig-out/bin/unityz --help
./zig-out/bin/unityz info path/to/asset
```

## What it is

`unityz` is two things:

- a **library** (`src/lib.zig`, imported as `@import("unityz")`) with parsers
  for Unity's asset formats, and
- a **CLI** (`src/main.zig`, `unityz`) with `info`, `extract`, and `edit`
  subcommands for inspecting, pulling out, and modifying assets.

Targeted formats: SerializedFile (`.assets`), asset bundles (`.unity3d` /
`.bundle`), and `.resources` / `.resS` sidecar files.

## Status

Scaffolding. No format support has landed yet: the CLI prints a
not-implemented error for every subcommand until the first parser ships.
The API and the repo layout are the stable parts for now.

## Layout

- `src/lib.zig` — library root: public API surface
- `src/main.zig` — CLI entry point and subcommand dispatch
- `build.zig`, `build.zig.zon` — package metadata and build steps
