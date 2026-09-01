# Canonical Work Record Template

Document ID: DOC-0004
Status: Current
Revision date: 2026-08-29
Canonical owner: Office
Governing filesystem contract: DOC-0016

## Scope and authority

Every Task, durable Idea, Project, and Initiative has:

`Workspace/<WORK-ID>/<WORK-ID>.md`

The same-ID folder and record are required. No other subfolder is required.
The Registry owns compact lifecycle, priority, lead, relationship, dependency,
description, and location fields. The Workspace record owns substantive plans,
steps, decisions, QA, continuity, and useful supporting context.

The user owns intent and decisions. Codex is the primary recordkeeper and may
edit the whole record to implement that intent. Momentum Management may display
the whole document but writes only fields and tables explicitly authorized by
DOC-0016.

## Core Record

```text
Title:
ID:
Type:
Current lead:
Associated product(s):
Primary department:
Secondary departments, if any:
Status source: Office/Registry/<TYPE>.md
Project:
Initiative:

Objective or question:
Next step:
Completion or resolution criterion:
Last validated state:
Relevant locations:
Depends on:
Related records:
```

Type-specific irrelevant fields may use an em dash. Do not duplicate the
Registry's current state or priority in this block.

## Optional substantive sections

Codex adds only sections the work needs. Common examples are:

- `## Plan`
- `## Steps`
- `## Decisions`
- `## QA`
- `## Working Notes`
- `## Outcome`
- `## Resulting Records and Artifacts`
- `## Archived Supporting Material`
- `## Follow-up Work`
- `## Checkpoint Evidence`
- `## Accepted Handoffs`
- `## Eligibility Reviews`

Momentum Management must preserve unrecognized sections.

## Steps

Use a Markdown checklist unless a step needs independent objective, lifecycle,
priority, dependencies, artifacts, or continuity. Such work becomes a linked
Task.

```markdown
## Steps

- [ ] First step
- [ ] Second step
```

## Checkpoint Evidence

### S03 - 00000000-0000-0000-0000-000000000000

Recorded: 2026-08-29T00:00:00Z

Accepted evidence:

- Exact accepted evidence

## Accepted Handoffs

| Marker | Accepted at | Evidence |
| --- | --- | --- |
| reusable-picker-v1 | 2026-08-29T00:00:00Z | `Workspace/TASK-0066/evidence.md` |

## Eligibility Reviews

| Hook | Review question | Disposition | Decided at | Reconsider after | Replacement |
| --- | --- | --- | --- | --- | --- |
| TASK-0017@done-complete | Confirm TASK-0015 remains stable enough for a bounded tool decision. | Pending | — | — | — |

These optional structures are machine-facing. Momentum Management may mutate them only through the owner-authorized DOC-0016 transactions and must preserve every other byte and unknown section.

## Open Crumbs

Create only when needed:

```markdown
## Open Crumbs

| Crumb ID | Kind | Priority | Summary | Created |
| --- | --- | --- | --- | --- |
| CRMB-000001 | Decision | Medium | Choose between two approaches. | 2026-08-11T12:00:00-07:00 |
```

Kinds are exactly Idea, Decision, and Action. Priority is Highest, High,
Medium, Low, or Unranked. Crumbs remain small; substantial content is promoted
into the record or a durable work item.

## Current Memento

A target has at most one current Memento:

```markdown
## Current Memento

Memento ID: MEM-000001
Created:
Current state:
Natural resume point:
Open Crumbs:
Extended payload:
```

Important resume information stays in the main record. Extended payload is
optional and, when used, points to `MEM-######.md` at the work-folder root.

## Supporting files

Keep useful work-specific context in the Workspace folder even after
completion. Create descriptive subfolders only when grouping several files
improves clarity. There are no mandatory Mementos, Materials, Processing,
Sources, Legacy, Archive, or Trash subfolders.

Historical material rarely needed to understand or reopen the work may move to
Warehouse Archive. Material with no expected future value moves to reversible
Trash. Code, repositories, worktrees, and datasets remain in their approved
external locations.
