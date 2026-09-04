# Handover - CLI contract sweep and trees export

**Date:** 2026-09-04  
**Session:** claude-20260904-cli-contract  
**Owner / next owner:** next agent session  
**Related:**

Directory diff fix, usage errors exit 2  
https://github.com/hordeforge/unityz/pull/139

Batch --json wrapping, non-Unity input rejected everywhere  
https://github.com/hordeforge/unityz/pull/140

edit/extract failures on stderr, batch extract subdirectories  
https://github.com/hordeforge/unityz/pull/141

verify --path-id on a missing object fails, show accepts --json  
https://github.com/hordeforge/unityz/pull/142

diff --trees for typeless Mono objects  
https://github.com/hordeforge/unityz/pull/143

unityz --version derived from build.zig.zon  
https://github.com/hordeforge/unityz/pull/144

fsb batch subdirectories  
https://github.com/hordeforge/unityz/pull/145

trees command: export embedded type trees  
https://github.com/hordeforge/unityz/pull/146

edit/trees --out rejected over a directory  
https://github.com/hordeforge/unityz/pull/147

extract recurses into bundles by default, parse failures exit 1  
https://github.com/hordeforge/unityz/pull/148

Every CLI flag documented  
https://github.com/hordeforge/unityz/pull/149

edit --patch atomic on a missing object  
https://github.com/hordeforge/unityz/pull/150

managed exit codes  
https://github.com/hordeforge/unityz/pull/151

## Current state

All thirteen PRs above are merged into origin/main; nothing is in flight.
The session worked from a `/tmp/unityz-review` worktree with the Zig cache
on disk (`ZIG_LOCAL_CACHE_DIR`), because `/tmp` is a shared tmpfs that
filled up mid-session.

The CLI now follows one exit-code contract (features.md "Exit codes"):
usage errors exit 2, read/decode/check failures exit 1, diagnostics on
stderr, nothing on stdout for a failing run. Batch mode wraps `--json`
output per file ("Batch mode" section) and `extract`/`fsb` write each
batch member under its own subdirectory. A new `trees` command exports a
file's embedded type trees in the `--trees` shape.

## Evidence

- `zig build test --summary all`: 431/431 on the final main (CI green on
  every PR, Linux and macOS, plus fmt and shellcheck lint).
- `zig build -Doptimize=ReleaseSafe` builds and `verify` passes on the
  legacy v6 fixture.
- Every command was probed by hand against the legacy v6 bundle fixture,
  a minimal UnityFS fixture, an FSB5 bank, and junk input, for exit code,
  stdout/stderr placement, and batch behaviour.
- Not run: real-game sweeps (no Unity game data on this machine). The
  `trees` script-tree path (MonoBehaviour trees keyed by MonoScript) is
  covered by a unit round-trip only; no fixture here carries a
  MonoBehaviour with embedded trees plus its MonoScript.

## Next action

Run `unityz trees` against a real game's AssetBundle that holds
MonoBehaviours, then feed the result to `show --trees` on that game's
stripped `.assets` to confirm the script-tree keying end to end.

## Blockers and risks

- `/tmp` on this machine is a 31 GB tmpfs shared by many sessions and sat
  at 95 percent after cleanup; build worktrees there with
  `ZIG_LOCAL_CACHE_DIR` pointing at a disk path.
- The roadmap's two Planned items (UnityArchive, PVRTC verification)
  remain sample-blocked.
