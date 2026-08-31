# Operational reports

This directory preserves the evidence, diagnosis, resolution, and verification
of bugs and investigations that would otherwise be lost in a run log or a pull
request discussion. It complements PRDs: a PRD describes intended product
behavior; a report explains an observed failure and the work that resolved it.

## Start here

- Use [bugs/TEMPLATE.md](bugs/TEMPLATE.md) for a confirmed defect that needs a
  durable record, including its resolution.
- Use [investigations/TEMPLATE.md](investigations/TEMPLATE.md) while tracing a
  symptom, even if the eventual result is "not a bug".
- Use [postmortems/TEMPLATE.md](postmortems/TEMPLATE.md) for an incident with
  real impact: a timeline, blameless root cause, and action items. Start it
  *during* the incident, not after - capture the big-picture timeline (lead-up,
  discovery, handling), the mitigation coordination on Slack, and the
  communications sent, as they happen. A postmortem covers the incident and
  the response; the defect behind it still gets its own bug report, linked
  both ways.
- Postmortems are blameless and shared broadly: what, how, and when - never
  who. Individuals appear as roles or teams ("an engineer"); names, emails,
  and audit-log principals stay in the linked internal investigation, where
  the follow-up with the person is tracked. `docs-check` rejects email
  addresses in postmortems.
- Every report starts with `## TL;DR`, then gives the detail needed to repeat
  the reasoning without reconstructing it from logs.
- Write for scanning: short paragraphs (one fact or step each) and bullet
  lists for enumerations. A wall-of-text paragraph that mixes discovery,
  timing, scope, and impact is a defect - split it. This rule is not specific
  to reports: `docs-check` flags overlong paragraphs in every document under
  `docs/`.
- Name reports `YYYY-MM-DD-<short-topic>.md`, keep the file in the matching
  subdirectory, and add it to the inventory below when it is created.
- Timestamps: UTC first, always with `hh:mm` in timeline tables (`docs-check`
  enforces this); the timezones your team works in may follow in parentheses.
  Use `.local/scripts/report-time` to convert (e.g.
  `report-time --from Europe 10:14`) or, when an event has no reported time,
  to stamp "now"; configure the zones in `[reports].timezones` of
  `.local/project-kit.toml`.
- When an investigation confirms a defect, link its bug report both ways. When
  the defect is resolved, keep the original evidence and add the fix commit,
  tests, and any remaining risk instead of rewriting the incident away.

## Workflow

Before diagnosing a failure, search this directory for the error text,
command, subsystem, or symptom. Read a matching report before choosing a fix;
its conclusion is evidence to verify against the current tree, not an
instruction that overrides the current task. Reuse a resolved report's
reproduction and checks where they still apply. If no report covers the issue,
create a TL;DR-first investigation while tracing it, then a bug report once
the defect is confirmed, and add each new record to the inventory below.

As the work proceeds, append new evidence rather than rewriting history. When
the work reaches a new state, update both the record's `## Status` section and
its inventory line here - the inventory is what the next reader skims, and a
record moved by hand in only one place leaves the index behind. Fill out the
scaffold with the evidence, resolution, and verification before calling it
complete.

## Inventory

### Bugs

<!-- inventory:bug:start -->
<!-- inventory:bug:end -->

### Investigations

<!-- inventory:investigation:start -->
<!-- inventory:investigation:end -->

### Postmortems

<!-- inventory:postmortem:start -->
<!-- inventory:postmortem:end -->

Each inventory line is a bullet with a markdown link to the record (its
title as the label, the `bugs/...` or `investigations/...` path as the
target), followed by ` - ` and the record's current status.

## Report lifecycle

An investigation may be open, resolved, or closed as not a bug. A bug report
is open until the fix is verified, then resolved; it may be reopened if the
symptom returns. A postmortem is a draft while being written, reviewed once
the people involved have read it, and closed once every action item is done
or explicitly dropped. Status is a summary for the index, not a replacement
for the report's evidence and verification sections.

The inventory above carries a second copy of each status. Keep the two in
sync: a status change edits both the record's `## Status` section and its
inventory line.

Reports are historical records. Amend them when new evidence changes the
conclusion, but do not delete failed hypotheses or the conditions that made a
bug possible.
