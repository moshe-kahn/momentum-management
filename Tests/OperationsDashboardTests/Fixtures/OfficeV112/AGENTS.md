# Productions Codex Instructions

Canonical Productions records are authoritative. Read the governing contract
and the directly affected records before acting. When mentioning an identifier
to the user, write the record name followed by its identifier in parentheses.

When the owner gives a clear approval or authorization, execute or route the authorized action without a separate acknowledgement. Respond only when a new decision, blocker, material outcome, or requested status requires the owner’s attention.

## Canvas work preflight

Canvas records actual task-execution work, not task administration.
Owner-directed updates to scope, steps, notes, links, proposed inputs,
handoffs, or Registry metadata do not require a Canvas event, provided they do
not silently approve a decision or perform the item's actual research, design,
implementation, validation, or other chartered deliverable work. They still
require normal authority and write safety.

Before the first task-execution action on an existing durable Task, Idea,
Project, or Initiative:

1. Read `Warehouse/Reference/Task Status and Continuity Protocol.md`, the
   Canvas contract in `Warehouse/Reference/Momentum Management Filesystem
   Contract.md`, the target Registry row, the target Workspace record, and
   `Office/Threads/Canvas.md`.
2. Confirm the durable item directly engaged. Do not create direct events for
   parent Projects or Initiatives; their attention is derived.
3. Use ordinary `canvas focus` for routine task-execution attention. It
   requires a concise, nonblank Reason and a concise, nonblank Context and
   rechecks the live Canvas under the current expected hash. If the item is not
   current, Focus appends `Placed` followed by `Engaged`; if it is already
   current, Focus succeeds as an explicit no-op and appends no event.
4. Do not append Canvas rows manually for routine attention. Preserve
   preview-confirmed low-level `canvas start` and `canvas stop` only for an
   explicitly sensitive or manual workflow. Use current ISO 8601 timestamps
   with timezone and second precision and never backdate a missing event.
5. Treat every Canvas command as a scoped, concurrency-safe, atomic
   transaction. Stop on a lock, hash, schema, target, replacement, or
   validation mismatch. Preserve literal partial or uncertain outcomes and
   never automatically retry a transaction that committed or may have
   committed.

Canvas classification follows the purpose of the action, not whether the
action writes files. Substantive work on an existing durable Task, Idea,
Project, or Initiative includes read-only inventory, evidence gathering,
research, architecture, design, specification, review performed as a
chartered deliverable, validation, and implementation when the action advances
that item's objective, Step, completion criterion, or accepted handoff. Use
ordinary `canvas focus` before the first such action and keep the directly
engaged item current while that work continues.

Passive viewing, opening, locating, reading, previewing, or searching is
Canvas-exempt only when it serves a status discussion, general question,
orientation, or task administration and does not itself advance a chartered
deliverable. Pure status discussion and owner-directed administration of
scope, Steps, notes, links, proposed inputs, handoffs, or Registry metadata
remain exempt, subject to their own authority and write-safety rules.
Architectural review and validation-only inspection are not blanket
exemptions: they use Focus when they are the durable item's substantive
review or validation work, and remain exempt only when they are passive or
administrative in the preceding sense.

An owner-authorized phase checkpoint is administration, not standing
authority. After Momentum Management Filesystem Contract (DOC-0016) version
1.12 is adopted and the accepted command is live, use `task checkpoint` only
for one exact unfinished Task Step and the exact hash-bound Workspace fields
authorized by the owner. Require the Task ID, expected Task Registry and
Workspace SHA-256 values, exact unfinished Step key, accepted evidence, new
Next step, and new Last validated state. The transaction may check only that
Step, replace only those two Core Record fields, and append only the matching
Checkpoint Evidence stanza. It must preserve Registry bytes and every
unrelated Workspace byte.

Treat only a literal `committed` result as a completed checkpoint. Preserve
the operation UUID, pre/post Workspace hashes, unchanged Registry hash, next
gate, Canvas observation, and journal status. `not-committed` is not automatic
retry authority; `uncertain`, any possible/proven commit with failed
validation, or any journal-read/finalization failure prohibits retry and
requires `office inspect`. Product sessions may propose structured handoffs
but receive no Office mutation authority. The coordinator must wait for the
committed result and bind the next phase to its post-write Workspace hash.

Status discussions, general questions, passive viewing, and task
administration do not create Canvas events. Inventory, research,
architecture, design, specification, substantive review, validation, and
implementation do create ordinary Task attention when they advance the
durable item's charter, even when they are read-only.

When authorized work stops, use ordinary `canvas clear` with a concise,
nonblank Reason that records the actual stopping cause and a concise, nonblank
Context. If the item is current, Clear appends `Cleared`; if it is already off
Canvas, Clear succeeds as an explicit no-op and appends no event. A Canvas
event never changes Registry lifecycle or priority by itself. Completion,
obsolescence, and any optional priority bump require their separately
authorized Registry transaction.
