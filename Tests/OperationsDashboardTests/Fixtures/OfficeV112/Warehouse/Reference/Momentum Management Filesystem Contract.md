# Momentum Management Filesystem Contract

Document ID: DOC-0016
Contract version: 1.12
Status: Current
Effective date: 2026-08-29
Canonical owners: Office and Momentum Management

## Purpose

This is the authoritative machine-facing contract between Productions and
Momentum Management. Application code must not infer a competing hierarchy
from legacy product folders, Status files, arbitrary filenames, or optional
subfolders.

## Configured root

Configure one user-selected Productions root. The current root is:

`/Users/kahntra/Productions`

Resolve every contract path relative to that root so it may be relocated.

## Required paths

| Purpose | Path |
| --- | --- |
| Flow | `Office/Flow.md` |
| Inbox payloads | `Office/Inbox/` |
| Processing bundles | `Office/Processing/` |
| Task Registry | `Office/Registry/Tasks.md` |
| Idea Registry | `Office/Registry/Ideas.md` |
| Project Registry | `Office/Registry/Projects.md` |
| Initiative Registry | `Office/Registry/Initiatives.md` |
| Product Registry | `Office/Registry/Products.md` |
| Department Registry | `Office/Registry/Departments.md` |
| Canvas | `Office/Threads/Canvas.md` |
| Crumb ledger | `Office/Threads/Crumbs.md` |
| Memento ledger | `Office/Threads/Mementos.md` |
| Work records | `Workspace/<ID>/<ID>.md` |
| Identifier ledger | `Warehouse/Reference/Identifier Ledger.md` |
| Document registry | `Warehouse/Reference/Document Registry.md` |
| Recoverable debris | `Warehouse/Trash/<scoped collection>/` |

Outbox and Inbox/Mementos are not contract paths.

## Encoding and parsing

- Markdown is UTF-8.
- Parse tables by exact header names, not column position.
- Trim surrounding cell whitespace.
- An em dash means unknown or not applicable.
- Semicolon separates multiple IDs or values in one cell.
- Resolve Markdown links against the containing file.
- Resolve code-form root paths against the configured Productions root.
- Separate any optional Markdown anchor from its file path, resolve and
  validate the file first, then validate the anchor within that file.
- Preserve unknown columns and unrecognized prose during application writes.
- Missing required paths, duplicate IDs, malformed rows, or unresolved
  canonical locations are visible errors.

## Identifier contract

DOC-0001 and DOC-0011 govern issuance.

- Durable identifiers use their existing minimum widths.
- `FLOW`, `BND`, `CRMB`, and `MEM` use at least six digits.
- All identifiers are unique and never reused.
- Parsers must accept additional digits without migration.
- Failed issuance retires the number.

## Flow contract

`Office/Flow.md` contains one table:

`Entry ID | Label | Type | Stage | Priority | Steward | Department | Product |
Source | Related work | Location | Summary | Next disposition | Created |
Updated`

Rules:

- Stage is exactly Inbox or Processing.
- Inbox entries use `FLOW-######`.
- Processing bundles use `BND-######` directly.
- Every registered unresolved payload has exactly one row and one resolving
  location.
- Each immediate non-hidden child of `Office/Inbox/` is one independently
  routable payload. Descendants of an Inbox folder belong to that payload and
  are not separately registered.
- An Inbox payload without an Inbox-stage Flow reference is a valid temporary
  `Unregistered` item. It has no synthetic ID, priority, steward, or other
  canonical Flow metadata.
- Applications may enumerate and display Unregistered Inbox items but must not
  issue an ID, create a Flow row, rename a payload, or otherwise write merely
  because they read or launch.
- Registration is the separate TASK-0040 intake transaction that issues a
  unique `FLOW-######` and writes its matching row. Capture only creates or
  transfers a complete payload into Inbox; it never creates a Flow row or
  participates in identifier issuance.
- Normal Inbox intake is automatic. On startup scan, Refresh, or an Inbox
  filesystem-watcher notification, applications identify unreferenced immediate
  non-hidden Inbox payloads and process them serially in deterministic path
  order, with one complete atomic transaction per payload.
- Before automatic registration, a payload must be quiescent: two observations
  at least two seconds apart must agree on filesystem kind, inode, byte size,
  and modification timestamp. New or changed payloads remain visibly
  Unregistered and may be reconsidered when unchanged; this avoids repeated ID
  retirement while a copy is in progress.
- Startup performs observation one and schedules observation two no earlier than
  two seconds later without depending on Refresh, a filesystem event, or user
  action. At most one lifecycle-owned recheck may be pending; startup, Refresh,
  and watcher notifications coalesce into it. A changed second observation is a
  new first observation and schedules another full interval. Scheduling stops
  after successful registration, blocked/suspended intake, investigation-needed
  state, or no candidates; lifecycle destruction cancels pending work.
- Automatic registration generates the exact payload basename as Label;
  `Unclassified file` or `Unclassified folder` as Type; `Inbox`; `Unranked`;
  `Office`; `Unassigned`; `Unassigned`; `Inbox filesystem intake`; `—`; the
  exact immediate Inbox path; `Unclassified Inbox payload awaiting review.`;
  and `Review and route to Processing or a durable destination.`
- Hidden items, symlinks, unsupported filesystem objects, duplicate/live
  references, unsettled payloads, contract conflicts, and concurrent-writer
  conflicts do not issue an ID. They remain visibly Unregistered with a reason.
  A shared-contract or concurrent-writer conflict suspends the entire intake
  pass rather than mutating later records.
- Applications never move, rename, edit, delete, or otherwise alter an Inbox
  payload during registration. A transaction that may have retired an ID is
  never automatically retried. Only a visible **Retry registration** action,
  used after resolution, may start a new transaction; it never reuses an ID.
- Applications must not infer whether a filesystem payload came from a human or
  Codex. An authorized caller may create a payload and rich Flow row together
  through the same transaction mechanism. Otherwise triage enriches the
  default row; defaults never replace an existing Flow row.
- Resolved rows leave Flow.
- Crumbs and Mementos never appear in Flow.

## Inbox capture contract

Capture and Flow registration are distinct transactions. A capture operation
places one complete payload in `Office/Inbox/`; TASK-0040 may subsequently
observe and register that immediate Inbox child. Capture never issues a Flow
ID or reads, writes, replaces, or otherwise modifies `Office/Flow.md` or the
Identifier Ledger.

Applications may support exactly these capture modes:

- **Manual file or folder capture:** a human selects one eligible file or
  folder through a system picker. The application copies it to an exact-name
  destination in `Office/Inbox/`; the manual source remains unchanged. The
  destination is completed atomically or remains absent.
- **Typed note capture:** a human supplies nonblank text. The application
  atomically creates one typed Markdown or text payload directly in
  `Office/Inbox/`.
- **Configured automatic capture:** the user explicitly configures one source
  folder in app-local configuration. A retained dashboard/ViewModel-owned
  monitor runs while the configured dashboard is alive, including after the
  capture sheet closes. It owns one idempotent polling task, starts or resumes
  when a valid root is loaded or saved, safely replaces that task when the
  source changes, and cancels it when its owner is released. The application
  considers only immediate non-hidden eligible children, waits until a
  candidate has two matching observations at least two seconds apart, then
  moves that source item to `Office/Inbox/`.

For every capture mode, symbolic links, hidden children, unreadable sources,
unsupported filesystem objects, incomplete or changing automatic candidates,
and destinations outside the configured Inbox are rejected. An existing exact
Inbox name is a visible conflict: capture never overwrites or silently renames
an item. A rejected or failed operation leaves its source unchanged. Automatic
capture processes candidates serially in deterministic path order and suspends
the remaining pass on a boundary-threatening conflict or failure. No live
capture is performed until synthetic contract and failure-path tests pass and
its scope is explicitly approved.

## Registry contracts

Tasks:

`Task ID | Title | State | Priority | Current lead | Initiative | Project | Depends on | Review after | Short description | Workspace`

Ideas:

`Idea ID | Title | Disposition | Priority | Current lead | Related records | Review after | Source artifacts | Short description | Workspace`

Projects:

`Project ID | Title | State | Priority | Current lead | Related records | Depends on | Review after | Short description | Workspace`

Initiatives:

`Initiative ID | Title | State | Priority | Current lead | Related records | Depends on | Review after | Short description | Workspace`

Products:

`Product ID | Product | Lifecycle | Current lead |
Related initiatives / products | Canonical workspace`

Departments:

`Department | Function`

Task, Idea, Project, and Initiative Workspace links resolve to matching
`Workspace/<ID>/<ID>.md` records. Registry fields are authoritative for lists,
filters, and lifecycle. The dashboard need not expose a separate Registry view.

`Depends on` is a hard execution prerequisite. `Review after` is an advisory owner-review hook and never blocks or authorizes work. `Related records` is thematic, structural, provenance, or navigational association only. Applications must parse these columns independently and must never infer one from another or from prose. `Review after` is an em dash or a semicolon-separated set of unique `<DURABLE-ID>@done-complete` and `<DURABLE-ID>@accepted-handoff:<marker>` tokens. `done-complete` sources are Tasks, Projects, or Initiatives and satisfy only at exact `Done / Complete`. `accepted-handoff` sources are Tasks, Ideas, Projects, or Initiatives and satisfy only from the exact immutable `Accepted Handoffs` row. The marker grammar is `[a-z0-9][a-z0-9-]{0,63}`. Date triggers do not exist in version 1.12. Narrative text has no trigger semantics.

## Lifecycle values

Task, Project, and Initiative State:

- Active / Current
- Active / Paused
- Active / Blocked
- Pending / Review
- Pending / Deferred
- Done / Complete
- Done / Obsolete

Idea Disposition is Open, Promoted, Archived, or Discarded. Priority is
independent of lifecycle and Canvas placement.

## Priority vocabulary

Registry work, Flow entries, and Crumbs use exactly `Highest`, `High`,
`Medium`, `Low`, or `Unranked`. The shared scale enables sorting, but context
controls meaning:

- Registry priority is durable-work importance.
- Flow priority is intake or bundle-processing urgency.
- Crumb priority is unresolved-thought salience.

Priority never substitutes for lifecycle, Canvas attention, or chronology.
For durable work, priority is operational: it ranks work still available for
future attention. Tasks, Projects, and Initiatives in a Done state use
`Unranked`. Ideas whose disposition is Promoted, Archived, or Discarded also
use `Unranked`. Historical importance belongs in outcomes and retained records,
not the current sortable Priority field.

## Workspace contract

Only `Workspace/<ID>/<ID>.md` is structurally required. Momentum Management
may display the whole document and recognize the standard sections defined by
DOC-0004. It must not require optional subfolders.

A source may have one optional `## Accepted Handoffs` table with exact columns `Marker | Accepted at | Evidence`. Marker is unique and immutable; Accepted at is an ISO-8601 timestamp with explicit numeric offset or `Z` and second precision; Evidence resolves to a contained, nonsymlinked, readable regular file under Productions and may include a validated Markdown anchor. A candidate whose Registry `Review after` is not an em dash must have one `## Eligibility Reviews` table with exact columns `Hook | Review question | Disposition | Decided at | Reconsider after | Replacement`. Registry hooks and Workspace rows agree as exact sets. Disposition is `Pending`, `Proceed`, `Decline`, `Defer`, or `Replace`. Pending has em dashes in all control fields. Proceed and Decline require Decided at and are terminal. Defer requires Decided at and one different normal hook token in Reconsider after; it is suppressed until that source fact is satisfied, then becomes actionable again. Replace requires Decided at and exact `<candidate-ID>@<hook>` in Replacement; it is terminal, does not mutate or transfer state to the replacement hook, and rejects self-edges and every directed replacement cycle. Terminal candidate lifecycles are `Done / Complete` and `Done / Obsolete` for Tasks, Projects, and Initiatives, and `Promoted`, `Archived`, and `Discarded` for Ideas. Eligible nonterminal values are `Active / Current`, `Active / Paused`, `Active / Blocked`, `Pending / Review`, and `Pending / Deferred` for Tasks, Projects, and Initiatives, and `Open` for Ideas. Unknown values are contract errors. Every exact hook is exposed and dispositioned independently; coalescing by candidate never coalesces hook state.

The user owns intent. Codex is the primary semantic editor. Application code
may write only explicitly supported Core Record fields, Steps, Open Crumbs, and
Current Memento transactions while preserving every other section.

Useful work-specific material may remain with completed work. Completion does
not require an empty folder.

## Processing bundle contract

Each Flow BND row resolves to:

`Office/Processing/<BND-ID> - <Label>/<BND-ID>.md`

The record contains:

- `## Bundle Record` exact key/value fields;
- `## Processing State`;
- `## Contents` with
  `Item | Disposition | Destination`;
- optional `## Open Crumbs`; and
- optional `## Current Memento`.

Bundle processing priority exists only in the corresponding Flow row. A BND
record must not maintain a competing Priority field.

Allowed final dispositions are Integrated, Promoted, Archived, Trashed, and
Sent. Unresolved content prevents closure.

## Canvas contract

`Office/Threads/Canvas.md` contains:

`Occurred | Work ID | Event | Reason | Context`

Canvas is append-only attention history for Tasks, Ideas, Projects, and
Initiatives. Event is Placed, Engaged, or Cleared. A target is currently on
Canvas when its most recent boundary event among Placed and Cleared is Placed.
Engaged records intentional work, not passive viewing. Completion or
obsolescence appends Cleared while Registry remains lifecycle authority.

Canvas rows have no IDs. Backlog is not stored; it is derived from Registry
work and Canvas history. Candidate eligibility and named backlog presets are
application policy and may change without filesystem migration. Exposure,
engagement, recency, neglect, and concentration are derived from the event
history. Placement and engagement never change Registry state by themselves.

Occurred uses ISO 8601 with timezone and second precision; row order breaks a
timestamp tie. Record an event only for the durable item directly engaged.
Parent Project and Initiative attention may be rolled up through Registry
relationships, but direct and inherited metrics must remain distinguishable.

When clearing Low- or Medium-priority work for a reason other than completion
or obsolescence, Momentum Management may offer an explicit one-level bump:
Low to Medium or Medium to High. No change is the default. Clearing never
changes priority automatically, and completion or obsolescence instead sets
operational priority to Unranked.

Focus and Clear are the ordinary application actions that request desired
Canvas attention. Both are explicit; passive loading, opening, selection,
preview, refresh, search, discussion, session preparation, and administrative
updates remain read-only.

Attention is classified by purpose rather than write behavior. Read-only
inventory, evidence gathering, research, architecture, design, specification,
substantive review, validation, and implementation use ordinary Focus when
they advance a durable item's charter. Passive viewing, status discussion,
general questions, orientation, and task administration remain exempt when
they do not advance a chartered deliverable. Architectural review and
validation-only inspection therefore are not blanket exemptions.

Focus requires nonblank Reason and Context and rereads the live Canvas while
holding the scoped write lock. If the target is not current, one atomic
transaction appends `Placed` followed by `Engaged`. If the target is already
current, Focus succeeds as an explicit no-op and appends no event.

Clear requires nonblank Reason and Context and rereads live Canvas while
holding the scoped write lock. If the target is current, one atomic
transaction appends `Cleared`. If the target is already off Canvas, Clear
succeeds as an explicit no-op and appends no event.

An ordinary Focus or Clear operation may make at most four nonblocking lock
attempts, separated by 150 milliseconds, and only while every failed attempt
is proven to precede mutation. It never busy-loops and never retries a write,
partial outcome, committed outcome, or uncertain outcome.

Every ordinary operation, including an already-desired no-op, has a unique
operation identity recorded in its operation journal together with the exact
target identity, Canvas preimage hash and bytes, intended event rows, expected
replacement hash, Reason, Context, and target fingerprint. After interruption,
reconciliation may report a mutating operation as successful only when
canonical Canvas contains the exact journal-bound preimage prefix and complete
intended event sequence and that operation's `Placed` or `Cleared` boundary
remains the requested target's latest boundary. Desired membership alone never
proves a commit: a partial Focus containing only `Placed`, or independently
produced matching membership, remains uncertain. It may classify no commit
after a replacement exception only when immediate canonical inspection proves
the bound preimage; that durable definite-no-commit terminal state remains
inspectable if Canvas later changes.

An exact journal-bound event sequence followed by a later target boundary is
reported as a historical commit that has been superseded, separately from
current desired-state satisfaction. It is never reported as current success,
even if another later operation independently restores matching membership.
Target changes, malformed or fragmented Canvas, partial rows, contract defects
affecting the live Canvas or target, and all other ambiguous outcomes stop
visibly without automatic retry.

Historical defects unrelated to the live Canvas schema and requested target
do not by themselves block a valid ordinary transaction. The writer still
rejects malformed or fragmented Canvas, invalid events, unresolved or
duplicate requested targets, target changes, unsafe replacement, failed reload
validation of the requested target or desired membership, and hash or lock
conflicts. Before either a no-op or mutation, it validates the requested
target's complete transition history: `Placed` is valid only while off Canvas,
`Engaged` only while current, and `Cleared` only while current. Duplicate
`Placed`, duplicate or off-Canvas `Cleared`, off-Canvas `Engaged`, and every
other invalid requested-target transition stop the operation.

Replacement exceptions are not presumed to precede a write. Immediate
inspection records definite no-commit only for the exact preimage; exact
reconciliation records a reconciled commit; partial, malformed, or otherwise
unproved outcomes remain uncertain and visible to startup recovery. A
reconciled commit, definite no-commit, already-desired no-op, or proven
historical-but-superseded commit is terminal and is not reported as an
incomplete startup recovery item.

If a proven commit cannot be written to its correct terminal journal state,
the operation returns an exit-3 outcome containing its operation identity,
states exactly one of three classifications—committed and currently satisfied,
historically committed and superseded, or historically committed with current
state uncertain—states that journal finalization failed, and prohibits retry.
The writer records a typed terminal journal-finalization-failure marker for
that classification when the fallback write is available; if even the
fallback write fails, the diagnostic states that startup recovery may still
show the operation as incomplete. Every journal-finalization-failure marker
semantically proves a historical commit. If live Canvas later equals the
journal preimage, reconciliation reports historically committed with current
state uncertain, flags the append-only inconsistency, and prohibits retry; it
never reclassifies the operation as not committed. Historical-commit proof is
monotonic across every journal transition. Once a terminal state proves a
historical commit, later inspection failure, target mismatch or unavailability,
Canvas validation failure, return to the preimage, or other reclassification
may only preserve that proof and report current state uncertain; it may never
downgrade the operation to a terminal state that does not prove the historical
commit. Definite no-commit replacement failures retain exit 2, include their
operation identity and journal-finalization status, and direct the operator to
the non-mutating operation inspection command. A durable `definiteNoCommit`
terminal state is authoritative journal-only proof. Operation inspection
returns that classification before loading or validating mutable Canvas or
target state, so later malformed Canvas, unavailable or removed targets,
duplicate target resolution, and other live defects cannot erase the stored
no-commit result. Other classifications keep their stricter live-state
inspection requirements.

If the recovery journal cannot be read after `replacementFailed`, the
operation returns exit 3 with its UUID, a possible-commit classification,
current Canvas and journal state marked uncertain, inspection guidance for
when journal access is restored, and an explicit prohibition on retry. If the
journal cannot be read after `reloadFailed`, the operation instead preserves
that a historical commit is proven, marks current Canvas and journal state
uncertain, returns exit 3, and prohibits retry. Neither post-mutation
journal-read failure may fall through to a generic exit-2 result.

Focus and Clear report compact success or no-op outcomes that include the
discoverable operation identity. `canvas inspect --productions-root <path>
--operation <UUID>` is a non-mutating diagnostic surface that reports the
journal hashes, intended events, terminal state, historical commit evidence,
current-boundary proof, and reconciliation classification. Confirmation
material and recovery detail otherwise remain diagnostic. Neither action
renders a session package, changes Registry lifecycle or priority, or creates,
resolves, or supersedes a Memento.

The existing preview-confirmed low-level Start and Stop commands remain
supported for compatibility and explicitly sensitive or manual workflows.
Start retains its existing `Placed`/`Engaged` behavior, including an `Engaged`
append for an already-current target; Stop retains its current-only
precondition. Their confirmation tokens, no-retry classifications, locking,
hashes, journaling, atomic replacement, reload validation, and recovery
guarantees are unchanged.

## Crumb contract

`Office/Threads/Crumbs.md` contains:

`Crumb ID | Kind | Target | Priority | Summary | Created | Location`

Kind is Idea, Decision, or Action. Priority is Highest, High, Medium, Low, or
Unranked and expresses attention salience rather than target lifecycle. Every
target and location resolves. Canonical content is in the target record or
bundle. Resolved Crumbs leave the ledger without releasing their IDs.
Useful outcomes remain in the target record; no central resolved-Crumb history
is required.

## Memento contract

DOC-0014 governs Mementos.

`Office/Threads/Mementos.md` contains:

`Memento ID | Target | Summary | Resume point | Created | Location`

Every Memento is attached, every target has at most one current Memento, and
important resume content appears in the target record. An optional extended
payload may sit at the target folder root. Mementos never appear in Inbox or
Flow.

## Session preparation contract

Prepare session is a read-only application action that renders one compact
human Brief and one complete agent Context from current canonical sources.
Selecting, previewing, regenerating, or copying a session package never appends
Canvas, creates or resolves a Memento, changes Registry lifecycle or priority,
or writes any Productions file.

Session mode is determined by validated Memento presence, not Canvas
membership:

- one matching ledger row and Current Memento section selects `resume` mode;
- clean absence from both selects the bounded canonical-record `start` mode;
- partial, duplicate, conflicting, malformed, or unresolved Memento state
  blocks presentation rather than degrading to start mode.

Registry metadata supplies identity, lifecycle, relationships, dependencies,
and Workspace location. The Workspace record supplies substantive objective,
boundaries, completion criterion, next step, last validated state, locations,
plan, and other work context. A valid Memento overlays current state and the
natural resume point but does not override canonical work authority. An
optional extended payload is supplementary.

The renderer resolves code-form root paths against the configured Productions
root, resolves relative Markdown links against their containing file, and
validates anchors only after their file target resolves. Root ambiguity blocks
copying until the user selects one validated candidate.

The authorization mode and model recommendation are explicit ephemeral inputs
and are not written to Productions. Authorization never overrides narrower
canonical boundaries. Captured repository, branch, worktree, process, file,
hash, and test facts must be labeled for revalidation.

Copy rechecks every source hash and invalidates a stale preview. Clipboard
writes are outside Productions and contain only the displayed session package.

Ordinary Focus never renders a session package. Prepare session remains a
separate read-only action. The compatibility low-level Start command may
retain its existing post-commit renderer composition, and a committed Canvas
transaction is never retried when later package generation fails.

The no-Memento fallback is initially limited to Registry-backed durable work.
A Processing bundle may use a validated Memento-backed Prepare session, but
cannot receive a Canvas Start work action.

## Authority and write boundaries

Read authority:

1. Registry for compact lifecycle and discovery metadata.
2. Flow for intake and Processing routing.
3. Canvas for retained attention history and its derived current view.
4. Crumb and Memento ledgers for live cross-work discovery.
5. Workspace and bundle records for substantive content.
6. Warehouse for identifiers, durable documents, artifacts, and history.

Initial application implementation is read-only. Write capability is enabled
in separately tested phases:

1. Canvas Placed, Engaged, and Cleared event appends, including an optional
   explicitly confirmed Registry priority bump when clearing eligible work.
2. Crumb creation and resolution.
3. Memento creation, resume, supersession, and resolution.
4. Explicit supported Registry-field changes.

Task formation, plan rewriting, semantic integration, completion cleanup,
archive judgment, and multi-record restructuring remain Codex-led.

## Conflict and recovery

- Read and hash every affected file before writing.
- Recheck hashes immediately before replacement.
- On mismatch, stop and reconcile.
- Use atomic replacement for one-file changes.
- Multi-file changes retain before-copies, apply all changes, and validate as
  one transaction.
- Restore before-copies or emit an explicit Warehouse Trash recovery bundle on
  failure.
- Never silently overwrite or choose between competing versions.

## External and legacy exclusions

Do not mutate repositories, code, worktrees, datasets, or external product
roots. Do not parse legacy product Status files or treat
`/Users/kahntra/Kahntra Productions` as a second current management root.
Those sources are reconciled through separately authorized Productions work.

## Validation requirements

**Task checkpoint transaction.** `task checkpoint` is an Office-only, bounded owner-authorized transaction. Inputs are exact Task ID, expected complete Task Registry and Workspace SHA-256 hashes, exact unfinished Step ID, one or more ordered accepted-evidence values, complete replacement Next step, and complete replacement Last validated state. Under the root-keyed Task Registry-and-Workspace lock it validates canonical contained nonsymlinked paths; exact Registry identity and unique row; non-Done lifecycle; valid priority and lead; Workspace link and same-ID record; Registry/Workspace Initiative, Project, Depends on, identity, lead, and source agreement; both expected hashes; one unique unchecked Step; complete inputs; prepared replacement; authorized-byte ranges; and an unchanged Registry hash immediately before replacement.

The only permitted Workspace edits are changing that Step's `[ ]` to `[x]` without altering wording, replacing complete Next step, replacing complete Last validated state, and appending one operation-UUID stanza to `## Checkpoint Evidence`, creating that section only at document end. The transaction generates one UUID; persists a durable `TaskCheckpointJournal` with complete preimage, expected postimage, hashes, target fingerprint, inputs, and terminal state before replacement; rereads both files; durably replaces only Workspace; completely reloads and validates Workspace and unchanged Registry; observes but never changes Canvas; then finalizes the journal. Registry, Canvas, lifecycle, priority, lead, dependencies, relationships, identifiers, Crumbs, Mementos, and Flow are outside the edit allowlist.

Literal outcomes are `committed` exit 0, `not-committed` exit 2, and `uncertain` exit 3. A committed result includes operation UUID, completed Step, pre/post Workspace hashes, unchanged Registry hash, resulting Next gate, Canvas state, and journal proof flags. Only committed permits coordinator phase release, and the next phase must bind the returned post-write Workspace hash. Product sessions may return structured handoffs but receive no Office mutation authority; Office requires fresh bounded owner authorization.

**Office Workspace writer recovery.** The exhaustive terminal states are `definiteNoCommit`, `committedAndCurrent`, `reconciledCommittedAndCurrent`, `historicallyCommittedAndSuperseded`, `historicallyCommittedWithCurrentStateUncertain`, `committedReloadFailed`, `uncertain`, `journalFinalizationFailedCommittedAndCurrent`, `journalFinalizationFailedHistoricallyCommittedAndSuperseded`, `journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain`, and `journalFinalizationFailedDefiniteNoCommit`. Historical commit is proven by the five ordinary committed states including `committedReloadFailed` and by the three committed fallback states. It is not proven by `definiteNoCommit`, `uncertain`, or the definite-no-commit fallback. Definite no commit is immutable. For proven commit, current-state classes join monotonically in order current, superseded, current-state-uncertain; proof and a journal-finalization-failure marker are sticky. Non-proving uncertain may reconcile to current only through exact postimage plus complete validation.

`review accept-handoff` is an Office-only, hash-bound one-Workspace transaction whose sole edit is appending one exact immutable row to the source's unique `Accepted Handoffs` table, creating that optional section at document end when absent. It validates all source identity and Registry/Workspace agreement, unique marker, timestamp, evidence containment and kind, expected hashes, exact prepared row, unrelated-byte preservation, journal, replacement, reload, and shared recovery rules before reporting the mutation committed. It never dispositions candidates. `review disposition` is an Office-only, hash-bound one-Workspace transaction whose sole edit is changing Disposition, Decided at, Reconsider after, and Replacement in one exact existing candidate-hook row. It validates Registry/Workspace hook agreement, the required candidate `Eligibility Reviews` table, current Pending or satisfied-Defer state, requested field grammar, lifecycle eligibility, expected hashes, replacement target and hook, full replacement graph acyclicity, authorized-byte preservation, journal, replacement, reload, and shared recovery rules. Relationship creation/removal and lifecycle closeout are separate transactions.

Reverse discovery indexes exact source ID, trigger, candidate ID, and candidate hook. It is read-only, stable-sorted by candidate ID then hook, and recomputed on startup, Refresh, validated lifecycle/closeout reload, committed checkpoint, committed accepted handoff, and committed disposition. Multiple satisfied hooks remain separate child rows. Dispositioning one hides only that hook; other satisfied Pending or released-Defer hooks keep the candidate visible. Proceed, Decline, and Replace stop that exact hook from resurfacing. No discovery or disposition promotes, activates, reprioritizes, Focuses, prepares, starts, or authorizes work.

Activation uses two levels. Globally incomplete v1.12 Productions adoption—wrong DOC-0016 version, Document Registry/revision mismatch, any nonadopted durable Registry header, nonadopted role/policy/template package, or incomplete provisional migration—is pre-mutation `contractNotAdopted`, with no journal or write. After that gate passes, absent optional Checkpoint Evidence is valid for checkpoint creation and absent optional Accepted Handoffs is valid for handoff creation. Missing, malformed, duplicate, or Registry-mismatched candidate Eligibility Reviews is `targetContractInvalid`, not global non-adoption. A repository implementation, build, commit, or integration never makes these commands callable before independently verified Productions adoption.

- Every required path exists.
- All IDs are type-correct, unique, and at or above minimum width.
- Every Registry Workspace link resolves to a matching same-ID record.
- Every Flow path resolves to exactly one payload or bundle; a missing target,
  duplicate live reference, or Stage/location mismatch is a contract error.
- Every immediate non-hidden Inbox child is either referenced by exactly one
  Inbox-stage Flow row or surfaced as an Unregistered Inbox item. An
  Unregistered item is not a contract error.
- Every BND directory has a matching BND record and Flow row.
- Every Canvas Work ID is a resolving durable-work Registry ID; event values
  and membership transitions are valid.
- Canvas contains no BND targets and no stored Backlog state.
- Crumb and Memento targets and locations resolve.
- No target has two current Mementos.
- Every live Memento ledger row agrees with its target's Current Memento ID,
  target, Created time, and continuation; the concise ledger Resume point does
  not contradict the substantive natural resume point.
- Session presentation blocks conflicting Memento state and leaves Productions
  unchanged during selection, preview, regeneration, and Copy.
- Unknown sections survive application rewrites.
- Successful test cleanup leaves no fixture in a live ledger.
