# Headless command reference

`OperationsDashboard` provides confirmed, non-interactive command boundaries for canonical Operations work. These commands use the same services as the application; they are not alternate filesystem-writing adapters.

All examples below show the executable name as `OperationsDashboard`. Quote option values containing spaces or shell metacharacters. Use an explicit, validated Productions root for `--productions-root`.

## Confirmation workflow

Canonical mutations normally use a preview before execution. The owner-authorized,
complete-input `task checkpoint` transaction is the narrow exception described
below:

1. Run the command's preview form and retain its JSON output.
2. Review the preview and its bound paths, identities, hashes, action, and proposed result.
3. Execute with the same command inputs and the emitted `confirmationToken`.
4. If execution reports stale state or a confirmation mismatch, discard the old token and preview again.

Canvas, Memento, Flow, and capture-note previews emit a `preview` object and `confirmationToken`. Their execution forms repeat the previewed inputs and pass the token with `--confirm`.

Capture-copy and automatic capture also bind the exact canonical preview bytes. Their preview output includes a base64 `confirmedPreview`; execution must pass that original envelope with `--confirmed-preview` and its `confirmationToken` with `--confirm`. Do not edit or regenerate an envelope. Automatic observation has an earlier equivalent pair, `observationEnvelope` and `observationToken`, used to request the second observation/preview.

Confirmation tokens are state-bound, not reusable approvals. A changed source, destination, Productions contract, Inbox, Canvas, Memento, Flow, Identifier Ledger, or other previewed authority can invalidate execution.

## Office Task checkpoint and accepted handoff

This command is callable only after independently verified DOC-0016 version
1.12 adoption and with bounded owner authorization. Activation requires exact
adopted byte identities for immutable contract, role, policy, and template
members; exact adopted Document Registry metadata and rows; and exhaustive
structural validation of the mutable Registries and provisional-hook Workspace
migration, including exact fixed-record links, titles, H1s, record types, IDs,
canonical status/location fields, and Registry/Workspace agreement for
IDEA-0006 and TASK-0017. Every durable Registry row ID must also match its exact
`TASK-`, `IDEA-`, `PROJ-`, or `INIT-` prefix with at least four digits. Any
failure is `contractNotAdopted` before UUID, lock, journal, or write:

```text
OperationsDashboard task checkpoint \
  --productions-root <path> --task <TASK-ID> \
  --expected-workspace-sha256 <64-lowercase-hex> \
  --expected-registry-sha256 <64-lowercase-hex> \
  --unfinished-step <S##> \
  --evidence <one-line accepted evidence> [--evidence <value> ...] \
  --next-step <complete replacement text> \
  --last-validated-state <complete replacement text>

OperationsDashboard review accept-handoff \
  --productions-root <path> --source <TASK-ID> --dependent <TASK-ID> \
  --source-commit <40-lowercase-hex> --marker <marker> \
  --accepted-at <ISO-8601-with-explicit-offset-and-seconds> \
  --evidence <contained-canonical-location> \
  --expected-workspace-sha256 <64-lowercase-hex> \
  --expected-dependent-workspace-sha256 <64-lowercase-hex> \
  --expected-registry-sha256 <64-lowercase-hex>

OperationsDashboard office inspect \
  --productions-root <path> --operation <UUID>
```

The Office surface binds the supplied root spelling as exact UTF-8 bytes, not
Unicode-canonical-equivalent text. An exact
canonical `/private/tmp/...` fixture root remains `/private/tmp/...` even when
Foundation would standardize it to `/tmp/...`. Relative paths, dot segments,
repeated or trailing separators, case variants, symbolic-link aliases, and
other non-exact or escaping spellings are rejected; canonical containment and
non-followed regular-file checks still apply to every governed target and
reload.

Checkpoint inputs bind the complete Task Registry and Workspace preimages. The
transaction checks only the exact unfinished Step, replaces only complete
`Next step` and `Last validated state` values, and appends one UUID-bound
`Checkpoint Evidence` stanza inside that section before its next H2, or creates
the section at document end when absent. Later sections remain byte-identical.
The Workspace must contain exactly one non-fenced H1 equal to both Registry and
Core Title, and every target and reload must be a non-followed regular file. It
rejects any additional Step-like occurrence of the requested Step ID, even when
its checklist marker, brackets, bold delimiters, or spacing are malformed. It
never rewrites Registry. Before applying the checkpoint, it validates every
recognized lifecycle/priority mirror and, when stale, composes the exact
Registry-authoritative mirror repair into the same journal-bound Workspace
replacement and reconciliation queue entry. It otherwise never rewrites lifecycle, priority,
lead, dependencies, relationships, Canvas, Crumbs, Mementos, or Flow. The
complete replacement values, exact Step, ordered evidence, and both hashes are
the authorization boundary, so this command has no preview form.

Accepted-handoff inputs bind the complete Task Registry plus source and
dependent Task Workspace preimages. The command requires the dependent's
Registry and Workspace `Depends on` relationship to name the source exactly
once, the source Workspace `Related records` relationship to name the
dependent exactly once, and the contained evidence file to include the exact
authorized source commit. Its canonical edit is one immutable
`Marker | Accepted at | Evidence` row in the source's unique `Accepted
Handoffs` section, creating that optional section at document end when absent,
plus any exact Registry-authoritative repair of recognized stale
lifecycle/priority mirrors in that same source Workspace and durable queue
envelope. It never edits Registry, the dependent Workspace, Canvas,
or eligibility dispositions and never starts or activates the dependent.

Output is stable JSON. `committed` exit 0 includes the operation UUID,
completed Step, pre/post Workspace hashes, unchanged Registry hash, next gate,
observed `focused`, `clear`, or `unknown` Canvas state, and always-present
Boolean `historicalCommitProven`, `journalFinalized`, and `fallbackRecorded`.
Only literal `committed` releases a later phase, which must bind the returned
post-write Workspace hash.

Accepted-handoff success likewise returns stable JSON with the source,
dependent, source commit, marker, source pre/post hashes, unchanged dependent
and Registry hashes, and `discoveryOutcome: "complete"` with an exact
always-present `newlyEligibleHooks` array. Reverse discovery is read-only. If
it fails after the marker commit and normal journal finalization are proven,
the command returns `committed-with-discovery-failure` exit 3, preserves the
commit and its historical proof, returns the candidate array as `null`, and
states `Do not retry automatically.`

`not-committed` returns exit 2. `uncertain` returns exit 3. Every replacement
exception, reload failure, journal-read failure after replacement, or terminal
finalization failure names its UUID, supplies `office inspect`, and states
`Do not retry automatically.` A typed fallback marker is attempted exactly
once when normal terminal finalization fails; `fallbackRecorded` is true only
when that marker was durably recorded. Historical-commit proof is monotonic.
Failures before durable initial-journal creation never emit `inspectCommand`
and diagnose that no operation journal was created.
`office inspect` dispatches by the exact journal operation kind, then reads the
journal first and answers durable definite-no-commit
without consulting mutable canonical files, then requires the supplied
canonical Productions root to exactly equal the journal's immutable root before
any live read or journal reconciliation. A root mismatch freezes the journal
and reports current-state uncertainty. On the bound root it distinguishes an
exact current commit, a valid later superseding mutation, and current-state
uncertainty. Inspection identity accepts every valid Task lifecycle, including
a later `Done / Complete`, while checkpoint execution remains limited to
non-Done eligible states. Before proof, live reads, startup reporting, or any
update, the durable journal must bind its exact filename/requested UUID, payload
UUID, schema, operation kind, fixed paths/IDs, and pre/post hashes; mismatch is
`journal-read-failed` and never mutates the journal. Updates compare every
immutable operation-envelope field to the exact durable payload and accept only
the monotonic merged terminal state with consistent finalized/fallback flags;
fallback state and historical-commit proof are sticky. Startup recovery reports
incomplete operations and never replays or retries the authorized action. For a
lifecycle-priority journal stopped after exactly one of its two bound renames,
`office inspect` reacquires the writer lock and may restore only the exact known
postimage to its exact preimage, validate both complete preimages, and durably
classify definite no commit; any foreign or changing bytes remain uncertain.
If accepted-handoff inspection completely validates an expected postimage from
a formerly nonproving journal, that validation establishes monotonic historical
commit proof before terminal finalization. A finalization failure uses the same
typed committed fallback and no-retry outcome; it never returns to an unproven
classification.

## Lifecycle and priority mirror reconciliation

The bounded Office reconciliation surface supports Tasks, Ideas, Projects, and
Initiatives. Preview is read-only and binds the complete Registry and Workspace
preimages, exact durable identity, selected priority rule, optional explicit
owner decision, complete proposed postimages, and correction relationship:

```text
OperationsDashboard office reconcile preview \
  --productions-root <path> --work <DURABLE-ID> \
  --priority-rule <registry|maximum> \
  --expected-workspace-sha256 <64-lowercase-hex> \
  --expected-registry-sha256 <64-lowercase-hex> \
  [--state <exact-lifecycle-or-disposition>] [--priority <exact-priority>] \
  [--corrects-operation <UUID>]

OperationsDashboard office reconcile apply \
  --productions-root <path> --work <DURABLE-ID> \
  --priority-rule <registry|maximum> \
  --expected-workspace-sha256 <64-lowercase-hex> \
  --expected-registry-sha256 <64-lowercase-hex> \
  [--state <exact-lifecycle-or-disposition>] [--priority <exact-priority>] \
  [--corrects-operation <UUID>] --confirm <preview-token>
```

Only two Workspace mirror forms are repairable: unique exact `State`,
`Disposition`, `Lifecycle`, or `Priority` fields in the fenced Core record;
and one exact Task/Idea/Project/Initiative lifecycle-and-priority sentence in a
unique `Lifecycle and Attention` section. Missing mirrors stay absent.
Unknown values, malformed or duplicate mirrors, ambiguous identity, a
noncanonical path, invalid Registry rows, and nondeterministic replacements are
pre-mutation failures.

Lifecycle uses the Registry value unless the reviewed request contains an
explicit new lifecycle. It never infers reactivation, greater activity, or
completion from Workspace prose. `--priority-rule registry` identifies an
owner-authorized Registry decision and preserves it. `--priority-rule maximum`
is for a recognized conflict without provenance and chooses the deterministic
maximum `Highest > High > Medium > Low > Unranked`. An explicit `--priority`
is the reviewed owner decision. Terminal durable work must remain `Unranked`.

Apply takes the shared Registry-and-Workspace lock, creates one durable journal,
revalidates both complete preimages and the confirmation token, prepares all
postimages before replacement, replaces only the exact Registry cells and
recognized Workspace mirrors, reloads complete agreement, and finalizes the
journal. A partial replacement is restored only when exact known postimages can
be returned to exact preimages under the lock; otherwise the result is
`uncertain`. Literal outcomes, historical-proof monotonicity, typed fallback,
`office inspect`, and “Do not retry automatically” rules match the other Office
writers. Lifecycle, priority, and Canvas remain independent; reconciliation
never focuses, starts, pauses, completes, activates, or reprioritizes work beyond
the values shown in the confirmed preview.

Every committed discrepancy repair remains a pending administrative queue row
in its originating lifecycle-priority, checkpoint, or accepted-handoff journal.
It contains the work ID and title, field, prevalues,
chosen value, rule/provenance, operation UUID, and time. The Dashboard surfaces
these rows in **Reconciliation Review** beside Inbox. Headless review is:

```text
OperationsDashboard office reconciliation list --productions-root <path>
OperationsDashboard office reconciliation acknowledge \
  --productions-root <path> --operation <UUID>
```

Acknowledgement changes only the durable queue disposition to `confirmed`; it
does not change Registry, Workspace, lifecycle, priority, or Canvas. A reviewed
owner correction uses another hash-bound `office reconcile` transaction with
explicit values and `--corrects-operation`; only its proven commit changes the
older queue disposition to `corrected`. Queue and terminal-proof updates are
monotonic and byte-bind every immutable journal field. A failed acknowledgement
update returns exit 3 with `office inspect` and no-retry guidance. A proven
correction's `correctsOperation` is consumed by inspection/list recovery if its
post-commit update of the older queue entry was interrupted.

## Durable Manager routing lifecycle

Manager routing state is local Operations Dashboard Application Support data,
not a Productions record. It grants no Office mutation authority. Every route
binds one stable operation UUID, exact Task and thread identities, bounded
action, authority reference, timeout, and optional already-authorized next
route. The complete state vocabulary is `queued`, `delivered/acknowledged`,
`running`, `terminal-completed`, `terminal-blocked`, `terminal-uncertain`,
`forwarded`, and `owner-decision-required`.

Every timeout argument is an exact whole-second ISO-8601 value. A supplied but
unparsable or fractional `--next-timeout-at` is rejected before UUID generation
or storage. Generated parent and preauthorized-child operation UUIDs must be
distinct. A preauthorized child UUID is a global durable reservation: later
parents and reservations cannot claim any existing route or reservation ID.
Reload rejects every collision except the intentional child-route overlap after
that reservation's exact parent has forwarded the exact bound child.

A standing continuation is one base64-encoded JSON envelope using schema 1. It
contains a stable envelope UUID, exact Task/Manager/Architect thread IDs,
bounded scope, created time, initial stage, complete typed stage graph, the
complete genuine-owner-gate set, and an initial canonical-context binding. The
binding contains the exact Productions-root spelling plus current Task Registry,
Workspace, Canvas, and governing-instruction SHA-256 values, Registry lifecycle
and priority, and `canvasCurrent: true`. It cannot be combined with the legacy
single embedded next route. Every destination terminal supplies exactly one
continuation disposition: `advance`, `in-scope-correction`, `owner-decision`,
or `safe-stop`.

```text
OperationsDashboard manager routing context \
  --productions-root <path> --task <TASK-ID>
OperationsDashboard manager route create \
  --task <TASK-ID> --manager-thread <thread-id> --target-thread <thread-id> \
  --action <text> --authority <text> --timeout-at <ISO-8601> \
  [--next-target-thread <thread-id> --next-action <text> \
   --next-authority <text> --next-timeout-at <ISO-8601>] \
  [--standing-continuation-base64 <base64-json>]

OperationsDashboard manager route acknowledge \
  --operation <UUID> --target-thread <thread-id>
OperationsDashboard manager route running \
  --operation <UUID> --target-thread <thread-id>
OperationsDashboard manager route terminal \
  --operation <UUID> --target-thread <thread-id> \
  --classification <completed|blocked|uncertain> --summary <text> \
  --evidence <text> [--evidence <text> ...] --next-gate <text> \
  --unperformed <text> [--unperformed <text> ...] \
  [--continuation-disposition <advance|in-scope-correction|owner-decision|safe-stop>] \
  [--owner-gate <material-scope-or-product-choice|credentials-or-private-data|external-or-public-mutation|destructive-action|deployment-or-promotion|requested-visual-review|uncertain-or-possible-commit>] \
  [--resulting-context-base64 <base64-json>]
```

`manager routing context` is read-only. It validates adopted v1.12, exact Task
Registry/Workspace identity, Canvas integrity/currentness, and governing role
files, then emits the complete hash binding used in an envelope. It creates no
UUID, ledger, journal, or canonical mutation.

The destination acknowledges the supplied operation UUID and returns exactly
one structured terminal handoff. An identical duplicate is idempotent and does
not rewrite the ledger. A different duplicate is inspection-required and must
not be retried automatically. Completed terminal handoffs atomically publish an
embedded already-authorized next route and mark the source forwarded. If that
child deadline is already reached, the valid parent receipt remains committed,
no child is created, and the parent becomes an explicit Manager/owner decision.
Blocked or uncertain terminal handoffs become the same explicit decision gate.
Standing routes reread canonical context before advancing. Drift,
unavailability, a cleared Task, or a genuine owner gate preserves the receipt,
publishes no child, and returns no-retry `owner-decision-required` for the
envelope's Architect recipient. Only a canonical-checkpoint stage may bind a
changed Workspace hash, and its complete resulting context must match the live
postimage while every non-Workspace binding stays exact.
No state changes Productions lifecycle, priority, Canvas, or Office records.

```text
OperationsDashboard manager routing status
OperationsDashboard manager routing inspect --operation <UUID>
OperationsDashboard manager routing idle-check
OperationsDashboard manager routing reconcile preview \
  --operation <UUID> \
  --observation <silent-completion|empty-final-output|target-interrupted|destination-unloaded|expired-task-context|missing-receipt|timeout>
OperationsDashboard manager routing reconcile apply \
  --operation <UUID> --observation <value> \
  --expected-ledger-sha256 <64-lowercase-hex> --confirm <preview-token>
```

Status groups every unresolved route as **Waiting for Manager**, **Waiting for
target**, or **Waiting for owner**, includes route age and unresolved age, and
marks overdue wakes. Before Manager idleness, `idle-check` requires every open
route to have a live monitored target, scheduled wake, terminal already
forwarded, or explicit owner decision. Silent completion, empty output,
interruption, timeout, restart, or suspected duplication begins with read-only
inspection/reconciliation. Apply is bound to the exact ledger hash and preview
token; timeout preview and apply both reject a time before the exact route
deadline. Monitor wakes equal the bound timeout (or exact terminal transition),
and acknowledgement/running timestamps equal their durable transitions.
Blocker or uncertainty never authorizes an automatic retry.

The Dashboard's **Architect Approvals** section consolidates pending
reconciliation acknowledgements with routing entries genuinely **Waiting for
owner**. Typed operation IDs are its deduplication keys; the view creates no
Flow row and does not copy or process Inbox payloads or Quick Notes.

The first durable route also publishes a sibling initialization marker. After
that point, a missing or unavailable ledger directory/file is storage-uncertain
or corrupt in status and idle checks, never an empty queue. If create publication
or reload is uncertain, the result retains the generated operation UUID and an
exact `manager routing inspect --operation <UUID>` command; do not retry it.

The Manager owns routing only. The destination owns acknowledgement and its one
terminal handoff. The Office Administrator retains write authority only through
separately owner-authorized governed commands, and the Coordinator retains
owner-facing strategy and decisions.

## Canvas

### Ordinary desired-state Focus and Clear (adopted)

The repository implements a compact one-action ordinary-attention surface:

```text
OperationsDashboard canvas focus --productions-root <path> --work <ID> --reason <text> --context <text>
OperationsDashboard canvas clear --productions-root <path> --work <TASK-ID> --clear-basis <owner-pause|owner-stop|completed|obsolete|indefinite-external-wait> --reason <text> --context <text>
OperationsDashboard canvas clear --productions-root <path> --work <IDEA|PROJ|INIT-ID> --reason <text> --context <text>
OperationsDashboard canvas inspect --productions-root <path> --operation <UUID>
```

`focus` appends `Placed` and `Engaged` only when the target is off Canvas. If
the target is already current, it succeeds as an explicit no-op. `clear`
appends `Cleared` only when the target is current and otherwise succeeds as an
explicit no-op. Both actions wait through at most four nonblocking lock
attempts with 150 milliseconds between attempts, retain a unique operation
identity and operation journal, and reconcile an interrupted response only
when the exact journal-bound event sequence is present and that operation's
boundary remains current. Membership alone, partial Focus, and independently
produced matching state do not prove success. Historical commit evidence is
reported separately when a later boundary supersedes the operation. Before a
no-op or mutation, the complete requested-target transition history is
validated. They never render a session package. Normal output is one compact
sentence containing the discoverable operation ID; `canvas inspect` exposes
hashes, intended events, terminal state, historical evidence, current-boundary
proof, and reconciliation diagnostics without mutating Productions.

Canvas attention is task-level: an active owner pursuit remains current across
implementation, review, correction, checkpoint, integration, acceptance, and a
routine next phase. Session idleness or a routine terminal handoff is not a
Clear basis. Task Clear requires one exact owner-level basis before UUID, lock,
journal, or write. `completed` requires `Done / Complete`; `obsolete` requires
`Done / Obsolete`. Focus rejects a supplied basis. The basis is recorded in the
journal, inspection result, compact output, and event Context. Legacy journals
remain readable, but new Task Clear operations cannot omit the basis.

This continuity correction is deliberately Task-only. Existing Idea, Project,
and Initiative attention keeps its accepted basis-free Clear behavior and
rejects a supplied Task clear basis. It receives no task-lifecycle inference or
migration.

The in-app Task Clear sheet exposes the same five exact basis values as a
required accessible picker, explains that Task attention survives routine
session and phase handoffs, and keeps Clear disabled until a basis is selected.
The selected basis reaches the same service, journal, and audit Context as the
headless surface. Focus and non-Task Clear show no basis picker.

At canonical adoption, current Tasks are reconciled read-only first. A Task
already current receives no event. A proven routine-boundary Clear is never
rewritten or backdated; after owner confirmation, one ordinary Focus restores
attention. A legitimate owner/terminal/indefinite-wait Clear is preserved, and
ambiguous evidence is an owner decision with no mutation.

This surface remains adopted for live ordinary Productions attention by Momentum
Management Filesystem Contract (DOC-0016) version 1.12. The independently
accepted root `AGENTS.md` correction likewise directs routine task-execution
attention to `canvas focus` and `canvas clear`, while retaining
preview-confirmed low-level Start and Stop for explicitly sensitive or manual
compatibility workflows.

### Preview-confirmed low-level Start and Stop

Preview either action:

```text
OperationsDashboard canvas preview start --productions-root <path> --work <ID> --reason <text> --context <text>
OperationsDashboard canvas preview stop --productions-root <path> --work <TASK-ID> --clear-basis <owner-pause|owner-stop|completed|obsolete|indefinite-external-wait> --reason <text> --context <text>
OperationsDashboard canvas preview stop --productions-root <path> --work <IDEA|PROJ|INIT-ID> --reason <text> --context <text>
```

Execute the reviewed action:

```text
OperationsDashboard canvas start --productions-root <path> --work <ID> --reason <text> --context <text> --confirm <preview-token>
OperationsDashboard canvas stop --productions-root <path> --work <TASK-ID> --clear-basis <owner-pause|owner-stop|completed|obsolete|indefinite-external-wait> --reason <text> --context <text> --confirm <preview-token>
OperationsDashboard canvas stop --productions-root <path> --work <IDEA|PROJ|INIT-ID> --reason <text> --context <text> --confirm <preview-token>
```

`start` prints the prepared session package as canonical JSON. `stop` prints the committed Canvas events. If a Canvas mutation commits but canonical reload or verification fails, or if Canvas start commits but later session-package preparation fails, the command returns exit 3: Canvas has changed and the action must not be retried automatically.

These commands retain their confirmation-bound behavior for compatibility and
explicitly sensitive or manual workflows. Stop binds the same typed owner-level
Clear basis into a Task preview token and journal; Start rejects that option.
The optional `clearBasis` JSON member is omitted for Start and for basis-free
Idea, Project, and Initiative Stop previews; it is present for Task Stop.
Ordinary focus and clear do not replace or reinterpret preview tokens.

## Memento

Create and supersede require a complete draft:

```text
OperationsDashboard memento preview <create|supersede> --productions-root <path> --target <ID> --summary <text> --current-state <text> --resume-point <text> [--open-crumbs <comma-separated-values>] [--extended-payload <text>]

OperationsDashboard memento <create|supersede> --productions-root <path> --target <ID> --summary <text> --current-state <text> --resume-point <text> [--open-crumbs <comma-separated-values>] [--extended-payload <text>] --confirm <preview-token>
```

Resolve accepts no draft fields:

```text
OperationsDashboard memento preview resolve --productions-root <path> --target <ID>

OperationsDashboard memento resolve --productions-root <path> --target <ID> --confirm <preview-token>
```

`create` requires no current Memento for the target. `supersede` and `resolve` require an existing current Memento. Usage, confirmation, availability, conflict, validation, lock, and journal-admission failures return exit 2 when no mutation has begun. Replacement failure, explicit recovery requirements, and post-mutation reload or verification failure conservatively return exit 3 with state-specific inspection and no-automatic-retry guidance.

## Flow registration

Preview:

```text
OperationsDashboard flow preview register --productions-root <path> --payload <Office/Inbox/name> --occurred-at <ISO-8601> --label <text> --type <text> --summary <text> --next-disposition <text> --priority <text> --steward <text> --department <text> --product <text> --source <text> --related-work <text>
```

Execute by repeating every previewed value:

```text
OperationsDashboard flow register --productions-root <path> --payload <Office/Inbox/name> --occurred-at <ISO-8601> --label <text> --type <text> --summary <text> --next-disposition <text> --priority <text> --steward <text> --department <text> --product <text> --source <text> --related-work <text> --confirm <preview-token>
```

`--payload` is the exact root-relative Inbox payload path. Exit 3 means either the Identifier Ledger committed before Flow replacement failed, or the full registration committed before reload/verification failed. Do not retry automatically.

## Capture note

Preview:

```text
OperationsDashboard capture preview note --productions-root <path> --text <note> --occurred-at <ISO-8601>
```

Execute:

```text
OperationsDashboard capture note --productions-root <path> --text <note> --occurred-at <ISO-8601> --confirm <preview-token>
```

Capture note accepts untargeted nonblank text and never requires a Task or
other durable target. The timestamp, note text, configured root, exact Inbox
destination, content hash, destination absence, and Inbox directory identity
are confirmation-bound. Preview JSON is deliberately redacted: it reports the
content hash, byte count, timestamp, destination path and identity, operation
fingerprint, recovery state, and confirmation token, but never the note or
rendered Markdown body. Publication opens every configured namespace component
without following symbolic links, writes and syncs a hidden same-directory
operation file, revalidates the live Office/Inbox identity, then publishes the
exact filename exclusively. Success creates one Unregistered Inbox payload
only: it issues no identifier, creates no Flow row or Crumb, and infers no
classification, priority, lifecycle, approval, relationship, or Canvas state.
The textual success response states that the payload is Unregistered and awaits
Office processing.

A repeated or concurrent submission never overwrites or silently renames a
payload. A live cooperating operation is reported as active concurrency.
Process interruption can leave a `.capture-note-*` operation file: a fresh
preview reports only its operation fingerprint, and the matching confirmed
execution exclusively moves the exact confirmed inode to an operation-owned
`.quick-capture-quarantine-*` name without deletion, publishes nothing, and
requires a new preview before capture. A raced-in replacement is restored or
preserved for manual recovery and never deleted. Unsafe residue, quarantine
failure, or uncertain replacement is an explicit exit-3 recovery condition and
is never silently removed or retried. Exit 3 identifies the exact
published destination only while the configured Inbox identity is still
confirmed; if that identity changed, it reports the opened identity and
operation fingerprint with no reliable pathname. Inspect the stated operation
and do not retry automatically.

## Capture copy: regular files only

Preview and retain both `confirmedPreview` and `confirmationToken`:

```text
OperationsDashboard capture preview copy --productions-root <path> --source <regular-file>
```

Execute with the original envelope:

```text
OperationsDashboard capture copy --productions-root <path> --source <regular-file> --confirmed-preview <base64> --confirm <token>
```

Headless capture-copy is intentionally narrower than GUI capture:

- It accepts one visible regular file only. Directories, packages, symbolic links, and special files are rejected before mutation; directory and package capture remain GUI-only.
- The source and `Office/Inbox` must be on the same filesystem, and that filesystem must support atomic file cloning.
- Publication uses an exclusive clone to the authoritative destination `Office/Inbox/<exact-source-basename>`; callers cannot choose another destination.
- Success preserves the source and verifies the destination SHA-256 digest.
- Clone unavailability, cross-filesystem input, collisions, stale state, and failures proven to precede publication return exit 2 without publishing a destination.
- Any failure after clone publication, or any namespace outcome that cannot be proven, returns exit 3. The copy may already exist; do not retry automatically.

## Automatic capture

Automatic capture moves eligible immediate children from the configured source. It preserves the GUI's shallow, opaque-item behavior for files, directories, and packages; it does not recursively hash their contents. The source and Inbox must be on the same filesystem.

First observation:

```text
OperationsDashboard capture automatic observe --productions-root <path>
```

Retain `observationEnvelope` and `observationToken`. After at least two seconds, request the matching second observation and move preview:

```text
OperationsDashboard capture automatic preview --productions-root <path> --observation <base64> --observe-token <token>
```

The complete stability tuple must match: filesystem kind, device and inode identity, byte size, and modification timestamp. A replacement inode resets stability even when other metadata matches. The preview reports deterministic immediate-child order and per-item dispositions such as planned, deferred, ineligible, collision, and not attempted.

Execute with the exact `confirmedPreview` and `confirmationToken` emitted by preview:

```text
OperationsDashboard capture automatic execute --productions-root <path> --confirmed-preview <base64> --confirm <token>
```

Execution durably claims the receipt before the first move. Receipts cannot be concurrently executed or automatically replayed. Exit 2 represents a definite failure with no published item. Once any item is published, every later failure returns exit 3 with per-item results and a batch-level no-retry diagnostic. Treat partial, previously claimed, crash-recovery, and uncertain outcomes as manual-recovery cases; do not retry automatically.

## Exit codes

| Code | Meaning | Operator action |
| --- | --- | --- |
| `0` | Preview/observation completed, or the requested mutation completed successfully. | Consume the output. For preview or observation, continue only after review. |
| `2` | Usage, validation, confirmation, eligibility, collision, stale-state, or another failure classified by that command as pre-mutation. | Do not infer retry safety from the code alone. Follow the state-specific diagnostic; retry only when it establishes that no mutation occurred, after resolving the cause and obtaining a fresh preview when required. |
| `3` | Mutation committed, partially committed, or may have committed; verification, reload, journaling, or later work failed. | Do not retry automatically. Inspect the diagnostic and canonical state, then recover manually. |

Not every command emits every code. Task checkpoint, Canvas, Memento, Flow, capture-note, capture-copy, and automatic capture emit `3` for their documented committed, partial, recovery-required, or uncertain outcomes. Exit `2` is not a blanket statement that an unchanged retry is appropriate.

For ordinary Canvas focus/clear, exit `2` is a definite pre-mutation failure
or exhausted pre-mutation lock wait. Exit `3` includes the operation identity
needed to inspect the recovery journal and canonical Canvas without blindly
duplicating events.

A definite-no-commit replacement failure also returns exit `2`, names the
operation UUID, and directs the operator to `canvas inspect`. Failure to write
the correct terminal journal state after a proven commit returns exit `3`,
names the UUID, reports exactly one of three classifications—committed and
currently satisfied, historically committed and superseded, or historically
committed with current state uncertain—reports whether a typed terminal
fallback marker was recorded, and states that the operation must not be
retried. Every journal-finalization-failure marker proves a historical commit.
If Canvas later equals the operation preimage, `canvas inspect` reports an
append-only inconsistency with the historical commit proven and current state
uncertain; it never reports that operation as not committed.

Historical-commit proof is monotonic across journal transitions. Once any
terminal state proves a historical commit, later inspection failure, target
mismatch or unavailability, Canvas validation failure, return to the preimage,
or other reclassification preserves that proof and reports current state
uncertain; it never writes or reports a non-proving terminal classification.

After an interrupted ordinary Canvas mutation, failure to read its recovery
journal returns exit `3`, names the operation UUID, and forbids retry. A
`replacementFailed` path reports a possible commit with current Canvas and
journal state uncertain. A `reloadFailed` path preserves a proven historical
commit while reporting current Canvas and journal state uncertain. Both direct
the operator to `canvas inspect` once journal access is available; neither is
reported through the generic exit-`2` failure path.

`canvas inspect` answers a durable `definiteNoCommit` terminal state from the
journal before loading or validating mutable Canvas or target records. That
stored classification remains authoritative if Canvas later becomes malformed
or the target becomes unavailable, removed, or ambiguous. Inspections without
such journal-only terminal proof retain strict live Canvas and target
validation.

## Routing and GUI launch

A malformed invocation owned by the `manager`, `task`, `review`, `office`, `canvas`, `memento`, `flow`, or `capture` command family remains headless: it prints stable JSON, usage, or a diagnostic and exits 2 instead of opening the GUI. This includes incomplete forms such as `manager`, `manager route`, `task`, `review`, `office`, `capture`, `capture unknown`, and `capture preview unknown`.

Launching `OperationsDashboard` with no arguments does not select a headless command. It retains the normal Operations Dashboard GUI launch.
