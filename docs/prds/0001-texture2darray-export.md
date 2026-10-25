# PRD - Texture2DArray export

**Date:** 2026-10-25

## Status

Shipped. `src/texture.zig` (`fromGraphicsFormat`, `arrayLayerStride`),
`src/classes.zig` (`Texture2DArray`), and the class-187 branch of
`cmdExtract` in `src/main.zig` are the source of truth.

## Problem

`extract` decodes `Texture2D` (class 28) into an image but does nothing with
`Texture2DArray` (class 187). A game that packs its colour, normal and
specular atlases into texture arrays therefore extracts no pixels at all: the
container, the serialized object and its `.resS` payload all exist, and the
tool reports success with zero images. The 7 Days to Die block atlas is
exactly this case: nine arrays of 407 layers each.

## Goals

1. `extract` writes one image per layer of a `Texture2DArray`.
2. The serialized format field is translated correctly, so the output pixels
   match the source texture rather than a decode of the wrong codec.
3. A layer boundary is computed from the mip chain, so layer N decodes from
   its own bytes.
4. An array whose format or payload the tool cannot handle is reported with a
   reason instead of silently skipped or decoded speculatively.

## Non-goals

- Writing `.uasset`, DDS or any container that preserves the array as an
  array. The export is per-layer images; rebuilding an array is the consumer's
  job.
- Reconstructing a normal map's Z channel or converting colour spaces. Layers
  are exported as decoded RGBA8, like `Texture2D`.
- Guessing a graphics-format mapping for formats outside the block-compressed
  set. Those are reported undecodable.

## Design

`Texture2DArray` serializes `m_Format` as `GraphicsFormat`, while `Texture2D`
serializes `m_TextureFormat` as `TextureFormat`. The two number the same codecs
differently: graphics 96/100/101 are DXT1 sRGB, DXT5 sRGB and DXT5 linear,
against texture 10/12 for DXT1/DXT5. `fromGraphicsFormat` maps 96-109
(DXT1/DXT3/DXT5/BC4/BC5/BC6H/BC7, sRGB and linear) to the ids the decoder
already understands, and returns null for anything else.

The payload is layer-major, each layer carrying its full mip chain.
`arrayLayerStride` sums `expectedSize` over the mip levels, halving each
dimension down to 1, and refuses a mip count above 32 or a format whose size
is not fixed (the crunched formats). The offset of layer N is
`N * arrayLayerStride`; mip 0 is the first `expectedSize(width, height)` bytes
of it.

Each layer is decoded, flipped vertically and encoded inside its own arena, so
peak memory is one image rather than the array. Files are named
`texture_<path_id>_<width>x<height>_layer<N>.<ext>`; the array counts as one
extracted asset in the summary and in `manifest.json`.

## Failure modes

| Condition | Behavior |
|---|---|
| GraphicsFormat outside 96-109 | `texture array <id>: GraphicsFormat <n> is not decodable`, counted skipped |
| Stream not resolvable | The existing unresolved-stream report, counted skipped |
| Mip count above 32, or crunched format | `mip layout is not computable`, counted skipped |
| Payload shorter than `stride * depth` | Reports layer count, needed bytes and actual bytes; counted skipped |
| One layer fails to decode or encode | Reports the layer, stops that array, keeps the layers already written |

## Acceptance criteria

- [x] A 512x512, 407-layer DXT1 array (7 Days to Die `ta_opaque_0`),
      extracted with `--class 187 --name ta_opaque_0`, writes 407 PNGs.
- [x] Layer 0 decodes to a brick texture and layer 100 to a floor tile,
      matching the atlas entries whose `index` is 0 and 100.
- [x] `arrayLayerStride` reproduces the exact payload division for the three
      stock colour arrays and the normal arrays (174,776 / 43,704 / 10,936 /
      349,552 bytes), pinned in tests.
- [x] `fromGraphicsFormat` maps 96/100/101 and rejects TextureFormat numbers.
- [x] `zig build test` passes (627 tests).

## Known issues

None.

## Open questions / future work

- Export time is about two minutes per 512x512x407 array, almost all of it
  PNG encoding. A `--layers` filter would let a consumer ask for the layers it
  references, and a faster encoder path is possible. Neither is needed to
  unblock the consumer that prompted this.
- Uncompressed array formats are unmapped. Add them when a real asset needs
  one, with the payload sizes as the check.
