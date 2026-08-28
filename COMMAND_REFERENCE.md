# Headless command reference

`OperationsDashboard` provides confirmed, non-interactive command boundaries for canonical Operations work. These commands use the same services as the application; they are not alternate filesystem-writing adapters.

All examples below show the executable name as `OperationsDashboard`. Quote option values containing spaces or shell metacharacters. Use an explicit, validated Productions root for `--productions-root`.

## Confirmation workflow

Canonical mutations use a preview before execution:

1. Run the command's preview form and retain its JSON output.
2. Review the preview and its bound paths, identities, hashes, action, and proposed result.
3. Execute with the same command inputs and the emitted `confirmationToken`.
4. If execution reports stale state or a confirmation mismatch, discard the old token and preview again.

Canvas, Memento, Flow, and capture-note previews emit a `preview` object and `confirmationToken`. Their execution forms repeat the previewed inputs and pass the token with `--confirm`.

Capture-copy and automatic capture also bind the exact canonical preview bytes. Their preview output includes a base64 `confirmedPreview`; execution must pass that original envelope with `--confirmed-preview` and its `confirmationToken` with `--confirm`. Do not edit or regenerate an envelope. Automatic observation has an earlier equivalent pair, `observationEnvelope` and `observationToken`, used to request the second observation/preview.

Confirmation tokens are state-bound, not reusable approvals. A changed source, destination, Productions contract, Inbox, Canvas, Memento, Flow, Identifier Ledger, or other previewed authority can invalidate execution.

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

This surface is adopted for live ordinary Productions attention by Momentum
Management Filesystem Contract (DOC-0016) version 1.11. The independently
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

The timestamp and note text are confirmation-bound. Exit 3 means the note was created but post-write verification failed. Do not retry automatically.

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

Not every command emits every code. Canvas, Memento, Flow, capture-note, capture-copy, and automatic capture emit `3` for their documented committed, partial, recovery-required, or uncertain outcomes. Exit `2` is not a blanket statement that an unchanged retry is appropriate.

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

A malformed invocation owned by the `canvas`, `memento`, `flow`, or `capture` command family remains headless: it prints usage or a diagnostic and exits 2 instead of opening the GUI. This includes incomplete forms such as `capture`, `capture unknown`, and `capture preview unknown`.

Launching `OperationsDashboard` with no arguments does not select a headless command. It retains the normal Operations Dashboard GUI launch.
