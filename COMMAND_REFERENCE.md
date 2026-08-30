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
never rewrites Registry, lifecycle, priority,
lead, dependencies, relationships, Canvas, Crumbs, Mementos, or Flow. The
complete replacement values, exact Step, ordered evidence, and both hashes are
the authorization boundary, so this command has no preview form.

Accepted-handoff inputs bind the complete Task Registry plus source and
dependent Task Workspace preimages. The command requires the dependent's
Registry and Workspace `Depends on` relationship to name the source exactly
once, the source Workspace `Related records` relationship to name the
dependent exactly once, and the contained evidence file to include the exact
authorized source commit. Its sole canonical edit is one immutable
`Marker | Accepted at | Evidence` row in the source's unique `Accepted
Handoffs` section, creating that optional section at document end when absent.
It never edits Registry, the dependent Workspace, lifecycle, priority, Canvas,
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
incomplete operations but never replays,
retries, restores, deletes, or finalizes one.
If accepted-handoff inspection completely validates an expected postimage from
a formerly nonproving journal, that validation establishes monotonic historical
commit proof before terminal finalization. A finalization failure uses the same
typed committed fallback and no-retry outcome; it never returns to an unproven
classification.

## Canvas

### Ordinary desired-state Focus and Clear (adopted)

The repository implements a compact one-action ordinary-attention surface:

```text
OperationsDashboard canvas focus --productions-root <path> --work <ID> --reason <text> --context <text>
OperationsDashboard canvas clear --productions-root <path> --work <ID> --reason <text> --context <text>
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

This surface remains adopted for live ordinary Productions attention by Momentum
Management Filesystem Contract (DOC-0016) version 1.12. The independently
accepted root `AGENTS.md` correction likewise directs routine task-execution
attention to `canvas focus` and `canvas clear`, while retaining
preview-confirmed low-level Start and Stop for explicitly sensitive or manual
compatibility workflows.

### Preview-confirmed low-level Start and Stop

Preview either action:

```text
OperationsDashboard canvas preview <start|stop> --productions-root <path> --work <ID> --reason <text> --context <text>
```

Execute the reviewed action:

```text
OperationsDashboard canvas <start|stop> --productions-root <path> --work <ID> --reason <text> --context <text> --confirm <preview-token>
```

`start` prints the prepared session package as canonical JSON. `stop` prints the committed Canvas events. If a Canvas mutation commits but canonical reload or verification fails, or if Canvas start commits but later session-package preparation fails, the command returns exit 3: Canvas has changed and the action must not be retried automatically.

These commands retain their original confirmation-bound behavior for
compatibility and explicitly sensitive or manual workflows. Ordinary focus and
clear do not replace or reinterpret their preview tokens.

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

A malformed invocation owned by the `task`, `review`, `office`, `canvas`, `memento`, `flow`, or `capture` command family remains headless: it prints stable JSON, usage, or a diagnostic and exits 2 instead of opening the GUI. This includes incomplete forms such as `task`, `review`, `office`, `capture`, `capture unknown`, and `capture preview unknown`.

Launching `OperationsDashboard` with no arguments does not select a headless command. It retains the normal Operations Dashboard GUI launch.
