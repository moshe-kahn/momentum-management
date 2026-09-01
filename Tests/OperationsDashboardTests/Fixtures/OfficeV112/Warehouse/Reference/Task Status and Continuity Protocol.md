# Task Status and Continuity Protocol

Document ID: DOC-0005
Status: Current
Revision date: 2026-08-29
Canonical owner: Office

## Purpose

Give every Task a clear commitment state while keeping planning lifecycle,
Canvas attention, Crumbs, and Mementos distinct.

## State authority

`Office/Registry/Tasks.md` owns Task state, priority, lead, relationships,
dependencies, short description, and Workspace link. The detailed record
remains at `Workspace/<TASK-ID>/<TASK-ID>.md`.

## Universal state model

```text
Active
├─ Current
├─ Paused
└─ Blocked

Pending
├─ Review
└─ Deferred

Done
├─ Complete
└─ Obsolete
```

Priority is independent of state. A Task may be placed on Canvas while Pending
without becoming Active. Canvas placement never changes Registry state.

## Canvas

Canvas is retained attention history, not a lifecycle.

- `Placed` selects a Task for possible immediate attention.
- `Engaged` records intentional work or resumption, not passive viewing.
- `Cleared` ends current Canvas membership without erasing its history.
- Backlog is a derived dashboard filter, not stored state.
- Completion or obsolescence appends `Cleared` with the reason while Registry
  remains the lifecycle authority.
- Canvas events do not alter Task state by themselves.
- Clearing Low- or Medium-priority work may offer an explicit one-level
  priority bump so it resurfaces later. No bump is automatic, and completion
  or obsolescence uses Unranked instead.
- A Task engagement may contribute to separately labeled inherited attention
  for its Project or Initiative, but only the Task receives the direct event.

### Ordinary Focus and Clear attention

Focus and Clear are the ordinary application actions that request desired
Canvas attention. Both are explicit; passive loading, opening, selection,
preview, refresh, search, discussion, session preparation, and administrative
updates remain read-only. Task execution is purpose-based. It includes read-only inventory, evidence
gathering, research, architecture, design, specification, substantive review,
validation, implementation, and any other action that advances the Task's
objective, Step, completion criterion, or accepted handoff. Passive viewing,
status discussion, general questions, and orientation remain read-only and
Canvas-exempt when they do not advance a chartered deliverable.

Task administration includes owner-directed scope, Step, note, link,
proposed-input, handoff, and Registry-metadata changes. It remains
Canvas-exempt, retains its own authority and write-safety requirements, and
must not disguise execution, silently approve a decision, or substitute for
substantive review or validation.

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
renders a session package, changes Registry lifecycle or priority, creates or
resolves a Crumb, or creates, resolves, or supersedes a Memento.

The existing preview-confirmed low-level Start and Stop commands remain
supported for compatibility and explicitly sensitive or manual workflows.
Start retains its existing `Placed`/`Engaged` behavior, including an `Engaged`
append for an already-current target; Stop retains its current-only
precondition. Their confirmation tokens, no-retry classifications, locking,
hashes, journaling, atomic replacement, reload validation, and recovery
guarantees are unchanged.

**Owner-authorized checkpoints.** A bounded Task phase may be checkpointed only from its exact unchecked Step, accepted evidence, complete replacement Next step, complete replacement Last validated state, and owner-supplied live Registry and Workspace hashes. The Office transaction may check only that Step, replace only those two continuity fields, and append only the operation's Checkpoint Evidence stanza. It must preserve Registry lifecycle, priority, lead, dependencies, relationships, Workspace location, Canvas, Crumbs, Mementos, and unrelated Workspace content. A product handoff is evidence, not Office authority.

A coordinator releases the next phase only after receiving literal `committed` from the Office checkpoint and binds the next authorization to its returned post-write Workspace SHA-256. `not-committed` does not release a phase. `uncertain`, a missing finalized journal, or any no-retry diagnostic requires inspection and owner review; it must never be retried automatically. Until the v1.12 transaction is independently accepted and live-enabled, the existing separately authorized direct Office checkpoint remains the sole fallback and may not coexist as a second automated mechanism afterward.

## Pausing and Mementos

Use `Active / Paused` only when the commitment remains active but work is
temporarily set aside. Capture:

- current validated state;
- what remains partial or uncertain;
- exact natural resume point;
- dependencies or decisions needed; and
- relevant locations.

When loss of the full stopping state would be costly, create the one current
Memento under DOC-0014. A Memento does not itself change Task state or Canvas
placement.

## Pending states

Use `Pending / Review` when the Task's future, scope, or commitment needs a
decision. Record the review question, owner, trigger, and options.

Use `Pending / Deferred` when the Task is deliberately later without current
commitment. Record the reason and revisit trigger.

## Done states and Workspace retention

Use `Done / Complete` only when the outcome and relevant dependencies are
verified. Use `Done / Obsolete` when continuation is no longer warranted.
Done Tasks use `Unranked` because Registry priority ranks work still available
for future attention.

Before closing:

- resolve or transfer open Crumbs;
- resolve the current Memento;
- append a Canvas `Cleared` event when the Task is current;
- record outcome, outputs, archive links, and follow-up work;
- keep useful Task-specific context in Workspace;
- archive only rarely needed history; and
- move material with no expected value to reversible Trash.

Reopening retains the same ID and Workspace folder. The useful material needed
for ordinary resumption should already be there.

## Switching work

Changing Canvas placement alone does not change Task state. When work actually
begins or stops, the user or Codex explicitly updates the Registry state if the
commitment state has also changed.
