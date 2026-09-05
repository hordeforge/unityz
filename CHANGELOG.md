# Changelog

Notable changes to this project are documented in this file. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); each section
matches a release tag, and the version is the one `build.zig.zon` declares
(`unityz --version` reads it from there).

This is a 0.x project: minor bumps (`0.Y.z`) may change CLI behavior or output
shape, patch bumps are expected not to. Releases are tag-driven; see the
"Releases" section of the README.

## [Unreleased]

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
