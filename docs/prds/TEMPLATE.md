# PRD - <Feature name>

## Status

Draft / In progress / Shipped. Name the code, configuration, API, or user
surface that is the source of truth. If the document is known to disagree with
the implementation, say so here plainly.

## Problem

What is impossible, broken, or too costly today? State the real constraint,
not merely the proposed solution.

## Goals

Numbered and verifiable. Every goal must be covered by an acceptance criterion.

## Non-goals

What this deliberately does not do, and why. This prevents a later reader from
mistaking a boundary for unfinished work.

## Design

Explain the mechanism and the important reasons behind non-obvious choices.
For a Draft or partially shipped feature, name dependencies and list numbered,
independently checkable implementation phases with concrete files to create or
edit. Decide blockers here; do not leave a prerequisite decision for later.

## Failure modes

Use a condition → behavior table for outcomes a caller would otherwise need to
read source code to discover. Cross-reference known bugs rather than presenting
them as intended behavior.

## Acceptance criteria

Use checkboxes, each traceable to a Goal. Leave anything not currently true
unchecked; re-verify this section whenever implementation changes.

## Known issues

Include only confirmed design/implementation drift. For each issue, say what
was expected, what actually happens, and which file or component owns the fix.
Omit this section when there are none.

## Open questions / future work

Record genuine unresolved decisions that do not block implementation. A known
bug belongs in Known issues, not here.
