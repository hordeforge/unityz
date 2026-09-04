# Bug - show exits zero on failure

## TL;DR

- **What failed:** `unityz show` prints target, option, container, and object
  decode failures but exits zero.
- **Impact:** Shell automation and downstream JSON adapters can mistake a
  missing or undecodable object for a successful inspection.
- **Resolution:** `show` now distinguishes shown, absent, and undecodable
  objects and propagates failures through the CLI's command status without
  changing successful JSON or raw output.

## Status

Resolved

One of Open / Resolved / Reopened on the line above; it is what the index
shows. Link the investigation that established the cause, if one exists.

## Blocked on


## Symptom and impact

The pipeline's `inspect --deep` migration called `show` for its class-142
AssetBundle object. A nonexistent path ID printed `object 999999999 not found`
but returned status 0. Source inspection found the same print-and-return shape
for a missing selector, invalid selector, unknown option, container parse
failure, wrong container kind, missing object data or type tree, and object
decode failure.

The effect is limited to `show` and its `shader` alias. Commands whose failures
already propagate as errors, plus `verify`'s explicit finding status, keep
their existing contracts.

## Reproduction

Run `show` against any readable SerializedFile or bundle with an absent path
ID, then inspect the shell status:

```bash
unityz show asset.unity3d 999999999
echo $?
```

The command reliably prints `object 999999999 not found`. The observed status
is 0; the expected status is non-zero because no object value was produced.

## Root cause

`cmdShow` in `src/main.zig` returns `!void`. Its handled failure paths print a
diagnostic and return normally, so `runCommand` sees success. The process exit
path checks `verify_failed_flag` for a single file and therefore has no failure
signal to return.

`showSerializedBytes` also uses one boolean for both "object not found" and
several decode prerequisites. Its object-reader failure returns true merely to
avoid a second not-found message. That boolean is insufficient to distinguish
shown, absent, and found-but-undecodable outcomes.

## Resolution

`showSerializedBytes` now returns an internal three-state result: shown, not
found, or failed. `cmdShow` preserves the targeted diagnostics and returns
whether the overall command succeeded. `runCommand` sets the existing
`command_failed_flag` when it did not, and the single-file exit path honors
that flag just as directory batches already do.

An object found without an embedded or injected type tree will name both
supported routes: supply `--trees` for decoded JSON or use `--raw` for bytes.
This is a diagnostic improvement, not a built-in type-tree implementation.

## Verification

The focused regression covers an absent ID, a typeless object, and a successful
raw read through `runCommand`. The complete Zig suite passed with a task-local
global build cache.

A ReleaseSafe CLI build then reproduced all three process outcomes against the
pipeline self-test bundle: absent ID status 1, invalid selector status 1, and
successful class-142 JSON status 0.

## Follow-up

The release-indexed built-in type-tree database remains separate open work.
UnityPy covers that case; `--trees` remains unityz's explicit external-tree
route.

## References

- Investigation: none; the direct reproduction and source path establish the
  defect
- Code: `src/main.zig` (`cmdShow`, `showSerializedBytes`, single-file exit)
- Fix: this report's change; pull request linked from the local task board
