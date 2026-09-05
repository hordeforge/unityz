# Roadmap

This is the short navigation view, not a second specification. Link each item
to its PRD or ADR; keep detailed design and acceptance criteria in those files.

## Current

Nothing in flight.

## Planned

- UnityArchive container parsing. The format is detected but not parsed;
  no real sample exists anywhere in the available games (verified by a
  full-library scan), so it needs an old Unity 4 game or a crafted
  fixture.
- PVRTC verification against real assets. Decoding exists; all available
  games are PC/console builds without PVRTC textures, so the path is
  verified only against synthetic inputs.

## Done

- Built-in engine-class type trees (2026-09-05): `src/builtin_trees.zig`
  embeds a release-indexed database packed from AssetRipper TypeTreeDumps
  (`scripts/structsdump-to-builtin.py`; 2022.3.62f2 shipped), `trees
  --builtin <release>` exports it in the `--trees` shape with byte sizes
  and versions, and `--builtin` decodes stripped files' built-in classes
  through it. Exact-release matching only. See "Built-in engine-class
  trees" in [features.md](features.md).
- MonoBehaviour serialization rules (PRs #160-#169, 2026-09-05):
  `managed --trees` matches Unity's field rules for real data:
  `[HideInInspector]`/`[NonSerialized]` handling, delegate skipping,
  per-field cells for sub-4-byte fields (top-level byte/char/short runs
  pack, nested-record bytes get cells), per-string array alignment,
  native engine structs (`LayerMask`, `Hash128`), and generic and
  cross-assembly base chains.
- Verify accuracy (PRs #168-#169): rewrites reproduce Unity's own bytes
  (nonzero padding, nonzero `true` bools) and NaN payloads compare
  equal, so `verify` bytes-differ is zero across all five test games.
  Remaining class-114 failures are read failures from data authored by
  older class layouts (Green Hell 1698, Stranded Deep 386, Raft 50,
  The Forest 20, Valheim 1): a documented data-age limit, not a tree
  bug (see features.md).
- Creation from empty state (2026-09-05): `create <spec.json> --out
  <file>` builds a format-22 SerializedFile and a UnityFS v8 bundle from
  declared type trees, JSON object values, and an optional `.resource`
  sidecar (stored or LZ4), re-verifying before it writes; the 7DTD
  pipeline's self-test bundle reproduces byte for byte. See "Creating
  files" in [features.md](features.md).
- CLI automation contract (PRs #139-#151, 2026-09-04): usage errors exit 2,
  read/decode/check failures exit 1, diagnostics on stderr only; batch
  `--json` wraps per-file results, directory `diff` compares every matched
  file and runs `--fields`, and `verify --path-id` fails on a missing
  object. Later PRs added the `trees` command, default bundle asset
  extraction, `edit --patch` atomicity, and `managed` exit codes.
  Handover:
  [2026-09-04-cli-contract-sweep.md](handovers/2026-09-04-cli-contract-sweep.md). See the "Batch mode" and
  "Exit codes" sections of [features.md](features.md).
- Managed trees and modern mesh export (PRs #110-#111, #115-#116):
  `managed --trees` auto-builds MonoBehaviour type trees from a game's
  assemblies (Raft, Stranded Deep, Green Hell), honoring
  `[SerializeField]` and `[NonSerialized]` so private serialized fields
  land in the trees (Raft level0 decode failures drop 814 -> 696);
  meshes export as glTF/GLB alongside OBJ, skinned meshes carrying the
  rig (JOINTS_0/WEIGHTS_0, rest pose round-trips to ~1e-7);
  `scripts/merge-trees.py` merges a version's class trees with a game's
  managed script trees so typeless Mono games export every built-in
  class (280 Raft meshes, 33 skinned).
- Post-capstone batch (PRs #102-#104): `managed` reads a Mono build's
  assemblies and lists every MonoBehaviour's serialized field layout
  (no external CLR); `edit --patch` accepts `--trees`; extract writes
  one consolidated `scripts.json` and a dry-run `--summary`; Shader
  objects export readable ShaderLab; VideoClips export their streamed
  video as MP4 (Green Hell cutscenes); TerrainData exports normalized
  heightmap PGM images (Raft, Stranded Deep, Green Hell) with a shipped
  2021.x tree. The earlier "sample-blocked" verdicts for VideoClip and
  TerrainData were class-ID bugs (329 and 156, not 333/334 and 27) and
  were resolved by the sample sweep.
- Beyond-parity CLI work: `diff --pixels`/`--audio`/`--fields` compare
  matched objects' decoded pixels, audio streams, and exact field paths;
  `extract` gains TGA/BMP/raw RGBA output, `--name` filtering, and
  structured JSON exports; FSB5 audio decodes to WAV in pure Zig and
  Vorbis banks remux to a playable Ogg; `fsb --json` validates every sample
  without writing and returns non-zero on failure; `find --any`,
  `info --objects`, and a `hierarchy` command.
- Multi-stream mesh export: Meshes whose vertex channels spread over
  `m_Streams_0_..3_` export an OBJ instead of silently nothing.
- Serialized format 4 parses and rewrites byte-exactly.
- The 3DS ETC variants (60/61) decode as ETC1 and ETC2_RGBA1 (46)
  decodes its punch-through alpha, pixel-identical to UnityPy.
- Crunch DXT variants decode through the vendored unitycrunch machinery.
- Shader sub-program blobs fully decode: record tables, parameter blobs,
  code blobs with DXBC chunk sets, ISGN/RDEF, bind channels, and
  skinning detection.
- Sprite export covers packed sprites: alpha merges, packing rotation,
  tight/polygon rendering through the sprite mesh, matching UnityPy.
- Clean-room UnityPy rewrite in Zig - format parsers, object reader,
  reserialize/edit, and extraction. See
  [the plan](plans/2026-08-30-clean-room-unitypy-rewrite-format-parsers.md),
  which is marked Complete with per-pass completion notes.
