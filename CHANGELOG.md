# Changelog

Notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); each section
matches a release tag, and the version is the one `build.zig.zon` declares
(`unityz --version` reads it from there).

This is a 0.x project: minor bumps (`0.Y.z`) may change CLI behavior or output
shape, patch bumps are expected not to. Releases are tag-driven; see the
"Releases" section of the README.

## [Unreleased]

### Changed

- `managed --trees`: MonoBehaviours that inherit through generic bases and
  across assemblies now decode. The CLR metadata reader sized the
  `HasFieldMarshal` and GenericParam coded indices as 2-bit tags (they are
  1-bit), which shifted every table after FieldMarshal and made all TypeSpec
  rows unreadable; TypeSpec `extends` rows (a base declared as
  `class X : Base<Arg>`) were never resolved, so Object-derived detection
  stopped at the first generic ancestor — Stranded Deep's netcode classes
  inherit through `Funlabs.MultiplayerBehaviour`1 : Photon.Bolt.
  EntityEventListener`1<...>`, and every `[SerializeField]` field typed to
  that family was silently dropped from its tree. Base-chain walks now use
  one name index over all parsed assemblies instead of a per-assembly
  linear scan (which also makes tree generation ~30x faster on multi-DLL
  games). Round trips: Stranded Deep resources.assets class-114 623→540
  failures while decoding 551 more objects (Beam.Crafting.Connector 489→0),
  The Forest 478→324, Raft 23→25 with 100 more objects passing, Green Hell
  unchanged (2617; residual flips are older-authored data per the
  documented data-age limit).
- `managed --trees`: MonoBehaviours now round-trip far more real game data.
  Three Unity serialization rules the generator got wrong are fixed: the
  `fdNotSerialized` field flag (the C# compiler's encoding of
  `[NonSerialized]`) now excludes a field even when public; primitive
  fields use the canonical wire names the typeless reader understands
  (`UInt8`/`SInt64`, not `byte`/`long`); and every sub-4-byte field
  (bool/char/byte/short) occupies its own 4-byte-aligned cell — including
  nested-record members and the object's final field — with array element
  runs still contiguous. Native engine structs whose C# fields are private
  (`LayerMask`, `Hash128`) get their fixed layouts instead of decoding as
  zero bytes and shifting every following field. Verified byte-exact
  round-trips on Raft (46→35 failures), Green Hell (13364→3546 on
  class-114), and The Forest (550→527).
- Object reader/writer: strings inside arrays are each 4-aligned, not
  packed into one run. A `string[]` (or `List<string>`) whose payload is
  not a multiple of 4 misread every following element — the second string's
  length landed in the first's padding, an out-of-bounds read on Green
  Hell's `ConstructionSlot.m_MatchingItems` and a class of byte-differ
  failures elsewhere. Round trips: Green Hell class-114 3546→2594, Raft
  level0 35→23, The Forest 527→478.
- Library: the typed views that build variable-length lists (`GameObject`,
  `Font`, `ComputeShader`, the audio mixer and animator families) take the
  caller's allocator and return `Allocator.Error!T`; they allocated through
  a hard-coded page allocator that was never freed and swallowed
  out-of-memory. Every typed view now carries a doc comment, the library
  root's status paragraph reflects the current module set, and
  `asset_extensions` includes `.resource`.

## [0.1.4] - 2026-09-05

Creation and built-in-tree release. Callers can now construct a UnityFS bundle
from empty state and obtain exact engine-class layouts without another Unity
asset or a separate type-tree package.

### Added

- A release-indexed built-in engine-class type-tree database, initially for
  Unity 2022.3.62f2; `trees --builtin <release>` exports it and `--builtin`
  lets reading commands decode stripped built-in classes (#156).
- `create <spec.json> --out <file>` builds a format-22 SerializedFile and
  UnityFS archive from declared trees, object values, and an optional resource
  sidecar, then verifies the result before its atomic write (#157).

## [0.1.3] - 2026-09-04

CLI contract release. Every command now shares one exit-code and output
contract, so scripts can branch on the status without parsing text.

### Added

- `trees` command: exports the type trees embedded in a bundle, WebFile, or
  serialized file as a `--trees` JSON table, MonoBehaviour trees keyed by
  their script via the container's MonoScripts (#146).
- `diff --trees` decodes typeless Mono objects for `--fields` (#143).
- Directory `--json` batches wrap each file's output as
  `{"file":...,"results":[...]}`, with `"error"` on a failing member (#140).
- `show` accepts `--json` as a no-op, so scripts can pass the flag uniformly
  (#142).
- Tag-driven release workflow, this changelog, and prebuilt Linux x86_64 and
  macOS arm64 binaries on each GitHub Release.

### Changed

- Usage errors (unknown flag, missing argument, malformed id) exit 2; read,
  decode, and check failures exit 1; the diagnostic always goes to stderr and
  a failing run writes nothing to stdout (#139, #141, #148, #151).
- A file that is not a Unity asset is an error for every command instead of
  a per-command empty success (#140).
- `extract` on a bundle or WebFile extracts the assets inside its nodes by
  default; `--recursive` is accepted as a no-op (#148).
- Batch `extract` and `fsb` write each input under `<outdir>/<file name>/`
  so bundles sharing node names cannot overwrite each other (#141, #145).
- `edit --out` and `trees --out` are rejected over a directory instead of
  overwriting one output file (#147).
- Every CLI flag is documented in README.md and docs/features.md (#149).

### Fixed

- Directory `diff` stopped after the first matched file and ignored
  `--fields` (#139).
- `verify --path-id N` on a missing object reported success (#142).
- `edit --patch` silently dropped entries naming missing objects on bundles
  and WebFiles; the patch now fails before writing (#150).
- `unityz --version` reported 0.1.1 while the package declared 0.1.2; the
  version is now derived from `build.zig.zon` (#144).
- `managed` exited 0 with no assemblies found or an unparseable assembly
  (#151).

## [0.1.2] - 2026-09-04

### Added

- `fsb --json`: read-only FSB5 validation contract that decodes every sample
  in memory, reports codec, rate, channels, loop points, and Vorbis setup CRC,
  and exits non-zero if any sample cannot be reconstructed (#138).

### Fixed

- `show` returns failure status when the object is absent or undecodable
  (#137).
- `hierarchy --json` counts undecodable children instead of emitting
  unparseable JSON, and reports per-subtree omissions (#134, #135).
- `verify --json` keeps stdout a single parseable document (#124).
- Sidecar stream ranges that wrap are rejected instead of slicing out of
  bounds (#125); silent WAV/GLB/Vorbis conversion failures are reported
  (#127).

## [0.1.1] - 2026-09-03

### Added

- `info --json` reports the metadata of every embedded SerializedFile:
  format and Unity versions, platform, endianness, type-tree state, counts,
  class ids (#121, #123). `info` exits non-zero on unreadable input (#126).
- `managed --trees`: MonoBehaviour type trees built from a Mono game's own
  assemblies, honoring `[SerializeField]` and `[NonSerialized]` (#110, #122).
- `stats --trees` per-script breakdown; mesh glTF/GLB export including
  skinned rigs and legacy `m_Skin` data; SkinnedMeshRenderer export as a GLB
  with named bones (#111, #115, #118, #119).
- `scripts/merge-trees.py` to join class trees with managed script trees
  (#116).

## [0.1.0] - 2026-08-30

Initial release: clean-room Zig parsers for SerializedFile, UnityFS, legacy
UnityWeb/UnityRaw, and WebFile containers; type-tree object reader and
byte-exact writer; `info`, `extract`, `edit`, `verify`, `stats`, `find`,
`show`, `diff`, `hash`, `skin`, `hierarchy`, `shader`, `fsb`, and `managed`
commands; texture, sprite, mesh, audio, video, terrain, font, shader, and
JSON exports.
