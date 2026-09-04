# Bug - package and cli versions diverged

## TL;DR

- **What failed:** The package manifest declared unityz 0.1.2 while
  `unityz --version` still reported 0.1.1 from a separate source literal.
- **Impact:** Downstream capability probes correctly rejected the binary that
  was meant to publish the new FSB5 machine contract.
- **Resolution:** The public library and CLI version now derive from the
  package manifest during every build.

## Status

Resolved

One of Open / Resolved / Reopened on the line above; it is what the index
shows. Link the investigation that established the cause, if one exists.

## Blocked on

## Symptom and impact

The FSB5 JSON/status change advanced `build.zig.zon` to 0.1.2. A ReleaseSafe
build of the merged commit still printed `unityz 0.1.1`. Shamway's minimum
version probe therefore reported `MISS` and could not distinguish the new
contract from the older binary, despite the implementation being present.

## Reproduction

Build merged unityz PR 138 and compare the manifest to the binary:

```bash
zig build -Doptimize=ReleaseSafe
zig-out/bin/unityz --version
```

The manifest says 0.1.2; the observed CLI output was `unityz 0.1.1`. The
expected output is `unityz 0.1.2`.

## Root cause

`build.zig.zon` and `src/lib.zig` each held a manually maintained version.
The CLI prints the library constant, so changing only the package manifest
compiled and passed every existing test while publishing the older value.

## Resolution

`build.zig` imports the package manifest's version and exposes it to the public
library as a generated options module. The library parses that generated value
for its public `version`, which the CLI prints. There is now one source value
instead of two values requiring manual sync.

## Verification

The complete Zig suite passed. A ReleaseSafe build then printed `unityz 0.1.2`.
Formatting, shell lint, and the documentation check also passed before merge.

## Follow-up

None. Future manifest version changes automatically flow into the library and
CLI build.

## References

- Investigation: none; the downstream version probe and two source literals
  established the cause directly
- Code: `build.zig`, `build.zig.zon`, `src/lib.zig`
- Fix: this report's change; pull request linked from the local task board
