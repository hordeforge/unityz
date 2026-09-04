# Bug - fsb exits zero on parse and decode failures

## TL;DR

- **What failed:** `unityz fsb` printed parse, option, and per-sample decode
  failures but returned process status 0.
- **Impact:** Automation could accept an invalid bank or an incomplete audio
  export, and the command had no read-only validation contract.
- **Resolution:** `fsb` now propagates every handled failure and `--json`
  validates samples in memory without writing output files.

## Status

Resolved

One of Open / Resolved / Reopened on the line above; it is what the index
shows. Link the investigation that established the cause, if one exists.

## Blocked on

## Symptom and impact

The raw-bank command catches an invalid FSB5 header, an output-directory
failure, and individual sample decode/rebuild failures so it can print a useful
diagnostic. Before this change, every one of those paths then returned normally.
The top-level CLI therefore exited 0 even though it had produced no audio or
only a subset of the bank's samples.

The pipeline needs to make two separate decisions: whether a bank is readable,
and whether to export it. The old command only coupled inspection to extraction,
so merely asking whether all samples decode also wrote `bank.json` and audio
files into the current directory.

## Reproduction

Run `fsb` against any non-FSB file and inspect the shell status:

```bash
unityz fsb invalid.fsb
echo $?
```

The command reliably prints `not an FSB5 bank`. Before the fix, the observed
status was 0; the expected status is non-zero. A syntactically valid PCM16 bank
whose declared sample data is truncated had the same success status after
printing its decode failure.

## Root cause

`cmdFsb` returned `!void`. Handled errors printed a diagnostic and returned
normally, while per-sample failures used `continue`; neither path communicated
failure to `runCommand`. The process-level status only consulted the verify and
general command failure flags, and `fsb` never set either one.

## Resolution

`cmdFsb` now returns whether the whole requested operation succeeded, and
`runCommand` maps false to the CLI's existing failure flag. Extraction succeeds
only when every sample was written; unsupported codecs, malformed banks, invalid
options, and output-directory failures return false.

The new mutually exclusive `--json` mode parses the bank and decodes or rebuilds
each sample in memory. It reports per-sample `decodable` and top-level `valid`
fields without calling any extraction path, including whether a Vorbis setup CRC
is present in the embedded catalogue.

## Verification

The focused Zig regression covers a valid PCM16 bank, the same bank with its
sample payload removed, and a non-FSB input through `runCommand`. The complete
Zig test suite passed, including the exported Vorbis setup-catalogue query.

A ReleaseSafe binary was exercised against an FSB5 bank emitted by shamway's
independent writer. Read-only validation returned 0 with `valid: true` and made
no output directory. Removing the declared PCM payload returned 1 with
`decodable: false` and `valid: false`. Extraction of the complete bank returned
0 and wrote `audio_sample.wav` plus `bank.json`; extraction of the truncated
bank returned 1 after reporting zero decoded samples. Combining `--json` and
`--outdir` returned 1 without creating the directory.

## Follow-up

The embedded Vorbis setup catalogue is finite. `setupKnown: false`,
`decodable: false`, and process status 1 deliberately expose an unknown setup
instead of treating the bank header alone as success.

## References

- Investigation: none; the direct reproduction and source path establish the
  defect
- Code: `src/main.zig` (`cmdFsb`, `fsb5MetadataJson`, `runCommand`),
  `src/vorbis.zig` (`setupKnown`)
- Fix: this report's change; pull request will be linked from the local task
  board
