# Agent Instructions

<!-- BEGIN project-kit session workflow - managed by project-kit/install.sh; do not edit by hand -->

## Collaboration conventions

The reusable working rules in [docs/agent-rules/general.md](docs/agent-rules/general.md)
apply to every project installed from this kit. They cover explaining mechanisms
before commands, preserving content when fixing presentation, quick-start
README structure, executable code blocks, clean change descriptions, and
accepting a reported fix at face value.

Optional organization overlays live in
[docs/agent-rules/README.md](docs/agent-rules/README.md). An overlay applies
only when this repository explicitly names its applicable modules in this file
or its own project instructions.

Repository workflow rules are split by their
strictness: the restrictive branch → PR → merge rule, the restrictive
branch → PR rule without automatic merging, the permissive direct-push and
CI-failure allowances, and a repository-specific overlay for local
exceptions. Each rule's scope is the bullet list inside it, which ships empty;
fill it in per project.
Use [docs/agent-rules/repository-rule-template.md](docs/agent-rules/repository-rule-template.md)
when creating another repository rule.

## Local session and TODO workflow

This repository keeps its private coordination board in `.local/TODO.md`.
On a vague or resumed task, read that board first. It is local and intentionally
not committed.

### Claim work before starting

Before researching, editing, or testing a TODO-tracked item, change its marker
from `[ ]` to `[-]` and append `in progress - <agent>, YYYY-MM-DD`. The `[-]`
marker is the exclusive ownership signal. When the task is complete, replace
it with `[x]` and remove the in-progress text; when it is released or blocked,
restore `[ ]` and record the reason. Do not leave stale claims behind.

### PR links on the TODO board

PR links live at the BOTTOM of a task entry, in a single flat `- PRs:` list
as the last sub-item. Status sub-items come first, then that list. One bare
URL per line, each suffixed with its state: `merged`, `merged, applied`, or
`OPEN` plus a few words on what it blocks.

**A NEW PR IS ALWAYS APPENDED AS THE LAST LINE OF THE LIST. NOWHERE ELSE.**

The list is append-only, in the order PRs were opened, so the newest is always
the bottom line - which is where the operator looks for work to review.
Concretely, when you open a PR:

- APPEND it to the end of the list. Do not insert it next to a PR from the
  same repository. Do not group by repository. Do not sort by state, number,
  or anything else. Repo grouping is the specific mistake that recurs: it
  buries a brand-new PR mid-list where the operator will never see it.
- Never reorder existing lines. The only edit to an existing line is its
  state suffix (`OPEN` -> `merged`).

```
- [-] repo: task description - in progress - <agent>, YYYY-MM-DD; session: <id>
  - step 1 - DONE, <evidence>
  - step 2 - PARTIAL, <what is left>
  - REMAINING: <the one next action>
  - PRs:
    - https://github.com/Org/repo/pull/11 merged, applied
    - https://github.com/Org/repo/pull/12 OPEN - blocks <thing>
```

Hard constraints:

- Never use bare `#NN` references anywhere in the board - always the full
  URL. A bare number is unclickable and ambiguous across repos.
- Never scatter PR links across the sub-items they relate to, and never
  group them under per-step headings.
- Never redesign this layout. Do not "improve" it, do not add an OPEN-PRs
  block at the top, do not reorder between updates.
- Update the state suffix on every pass so the list is never stale.

The operator scans one known place to find new PRs to review. Moving the
links between updates - even to somewhere arguably more prominent - means
hunting for them every time, which is worse than any layout gain. Stability
of position beats cleverness.

### Parallel-session IDs

Every concurrently running agent session needs a unique, durable session ID.
The ID identifies an execution session; it is not a work claim. Generate one
before claiming a task:

```sh
.local/scripts/new-session-id.sh codex
```

Use a lowercase agent-family prefix, such as `codex`, `claude`, `grok`, or
`clanker`. The command prints `<prefix>-<UTC timestamp>-<random suffix>`.
Do not reuse an ID. Add it to the claimed TODO line after the ownership text:

`[-] Example task - in progress - Codex, 2026-08-14; session: codex-20260814-120000-a1b2c3d4e5f6`

One ID may cover sequential tasks in one session. Concurrent sessions must
always use different IDs, even when they use the same agent family. Include
the ID in handover or blocker notes when it helps the next session, then remove
it together with the active claim when the work is finished or released.

### Durable design documentation

Keep documents current in the same turn as the behavior or decision they
describe. Make the smallest true update; replace stale wording instead of
stacking a second, contradictory note beside it.

Use a PRD in `docs/prds/` for a feature-sized contract: problem, goals,
boundaries, design, failure behavior, acceptance criteria, and open work. Use
an ADR in `docs/adrs/` for one durable technical choice with real alternatives
or consequences. A PRD says what must work; an ADR says why a consequential
choice was made. Link the two when both apply.

Create new numbered files from the templates, using the next unused four-digit
number. A Draft PRD must settle implementation blockers and name concrete
checkable phases; do not hide prerequisites under open questions. When code
changes a shipped feature, update the PRD's Status, Design, and Acceptance
criteria in that same change. When later work reverses an ADR, mark the old
record superseded and link to the replacement instead of rewriting history.

Use a report in `docs/reports/` for an observed failure: an investigation while
tracing a symptom, a bug report for a confirmed defect, and a postmortem for
an incident with real impact - started during the incident to capture the
timeline, handling, and communications live, and completed after it.

Postmortems are blameless: what, how, and when - never who; individuals
appear as roles or teams, and names, emails, and audit-log principals stay in
the linked internal investigation.

Create
them with `.local/scripts/project-kit.py new-doc <kind> <title>` (kinds `bug`,
`investigation`, `postmortem`), which names them `YYYY-MM-DD-<short-topic>.md`
in the matching subdirectory, and keep the inventory in
`docs/reports/README.md` and the record's `## Status` section in sync - the
generated index reads the status but the README inventory is maintained by
hand.

Timeline entries always carry an `hh:mm` UTC time (`docs-check` enforces
this); use `.local/scripts/report-time` to convert locally-quoted times to
UTC or to stamp "now" for events reported without one. See
`docs/reports/README.md` for the full lifecycle.

After adding, renaming, or changing PRDs, ADRs, or reports, regenerate the
inventory:

```sh
scripts/docs-index.sh
```

### Roadmap and reviews

`docs/ROADMAP.md` is the short navigation layer. Keep it honest: link a
feature's PRD or ADR, put active work in Current, proposed work in Planned,
and move completed work to Done only when its acceptance evidence exists. Do
not duplicate a PRD's detailed design there.

Record a review in `docs/reviews/` when its findings, evidence, or limits need
to survive the current conversation. Use `docs/reviews/TEMPLATE.md`. Put a
reusable review lens in `docs/prompts/`, not a single review's conclusion.
`docs/prompts/general-review.md` is the default: it requires evidence, a clear
distinction between defects and risks, and documented drift to be called out.

### Plan, fix, and review workflow

Follow `docs/WORKFLOW.md` for the full lifecycle: orient from durable context,
classify the work, establish a baseline, make the smallest causal change,
verify in layers, review, leave durable state, then publish through repository
policy. The reusable prompt versions are `continue`, `fix`, `plan`, `review`,
`handoff`, and `deliver` under `workflows/`.

For a non-trivial feature, migration, or cross-cutting change, create a dated
plan in `docs/plans/` from `docs/plans/TEMPLATE.md` before implementation. A
plan is the execution route; a PRD remains the product contract, and an ADR
remains the durable choice. Do not create paperwork for a clear one-file edit,
but do record material deviations from a plan in its Completion notes.

When one plan is too big to execute in one pass, split it into phase plans:
keep the parent plan as the contract with an "Execution phases" table (the
authoritative ordering: phase → doc → parent steps → status), and create each
phase with `new-doc plan --series <series-slug> <title>`. That names the doc
`<date>-<series>-phase-NN-<title>.md` with NN auto-numbered, so phases sort
and count deterministically; `docs-check` rejects duplicate or missing phase
numbers within a series. Link each phase doc back to its parent under
Related, and update the parent's table in the same change that adds a phase.

For a defect, establish the observed and expected behavior before changing
code. Add or identify a focused regression check where feasible, make the
smallest change that addresses the cause rather than its symptom, then run the
focused check and broader relevant verification. If behavior, a known issue, or
an acceptance criterion changes, update the owning PRD in the same change.

Before completing a substantial change or releasing a claim, review the diff
against its plan, PRD, ADR, and stated boundaries. Use
`docs/prompts/change-review.md` for an implementation-focused pass. Persist a
dated review record when the findings, evidence, or remaining coverage limits
matter after the current session; turn accepted follow-up into a TODO, plan,
roadmap entry, PRD, or ADR immediately.

When a task crosses sessions or may be handed to another agent, create a dated
record in `docs/handovers/` from its template. Include the current Git state,
evidence, one smallest next action, blockers, and the owning session ID. Update
the TODO claim at the same time; a chat-only handoff is not durable state.

### Exclusive resource leases

Before launching or attaching to a shared live resource, use
`.local/scripts/lease-lock.py` with the current session ID. A resource lease is
not a TODO claim: the TODO owns a task, while the lease protects a client,
deployment, device, migration, or other singleton resource. The `run` command
acquires, heartbeats, and releases automatically. If a prior holder's lease is
stale, reclaim it only with a documented `--probe` that confirms the resource
is no longer live. Never clear a fresh foreign lease, and never release a lease
owned by another session. See `docs/locks.md` for the exact contract.

### Project-kit operations

Project-specific commands, the default branch, optional agent CLI, resource
probe, and optional backup destination live in `.local/project-kit.toml`.
Before a substantial delivery, run `.local/scripts/project-kit.py doctor`; run
`.local/scripts/project-kit.py verify` to execute configured checks and preserve
their outcome for the next session. `status` is the preferred resume snapshot:
it shows Git changes, active TODO claims, the resource lease, recent handovers,
and the latest recorded verification.

Create durable records with `.local/scripts/project-kit.py new-doc <kind> <title>`
instead of guessing a PRD/ADR/RFC number or a dated filename. Kinds: `prd`,
`adr`, `rfc`, `research`, `plan`, `review`, `handover`, `bug`,
`investigation`, `postmortem` - the last three land under `docs/reports/`;
`rfc` and `research` are numbered like `prd`/`adr`; search the record's
directory before diagnosing a failure and add each new record to its
inventory in `docs/<store>/README.md`.

Run
`.local/scripts/project-kit.py docs-check` before closing documentation-heavy work.
It validates required PRD/ADR/RFC sections, local Markdown links, numbering, the
generated index, and readability: an overlong wall-of-text paragraph in any
document under `docs/` is flagged for splitting into shorter paragraphs or a
list.

Use `.local/scripts/project-kit.py worktree <name> --agent <agent>` only when an
isolated checkout helps. It creates a session branch/worktree under
`.local/worktrees/` and a handover, then shares the hub's `.local/`
coordination directory intentionally. Use
`.local/scripts/project-kit.py backup` only after configuring an external backup
destination; it is opt-in and never creates a scheduler by itself.

### Automated agent loops

`.local/scripts/agent-loop.sh` and `.local/scripts/review-loop.sh` can invoke
one configured `codex`, `claude`, `grok`, or `clanker` agent on an interval.
The task loop itself does not commit, push, open PRs, merge, claim resources,
or bypass repository instructions; the invoked agent remains responsible for
those actions. The review loop writes timestamped output under `.local/reviews`.
It changes no tracked files unless the operator explicitly passes `--record`,
which permits one review record and a regenerated docs index only.

`agent-automerge-git.sh` opens a pull request after an agent change but leaves
it open by default. Passing `--merge` is the explicit opt-in to merge it.

### Isolated task launcher

For one substantial task, prefer `.local/scripts/agent-worktree-task.sh` over
manually restating the standard preamble. It creates a session worktree, pulls
the configured default branch with `--ff-only` before the agent runs, asks the
agent to fix clearly related issues and update the appropriate docs, and keeps
the worktree plus its log for review. Use `--no-pull` only for a local-only
repository or when deliberately keeping the exact local base revision.

Whether a successful pass is published is configured per repository: when
`publish = true` is set in the `[worktree_task]` table of
`.local/project-kit.toml`, the launcher pushes the session branch and opens a
pull request for review after the agent finishes - it never merges. Do not
pass `--publish` ad hoc when the repository has configured a default;
`--no-publish` remains available to keep one specific pass local.

<!-- END project-kit session workflow -->
