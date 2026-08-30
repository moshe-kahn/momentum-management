# Architecture

`ConfigurationStore` owns validated local configuration loading and atomic saving through `ConfigurationStorage`. `SetupDraft`, `SetupValidator`, and `SetupCoordinator` keep first-run root confirmation, path derivation, warnings, and persistence testable. `FileSystem` abstracts read-only filesystem operations, including status-record modification metadata. `InboxScanner` and `StatusParser` apply the fixed contract. `DashboardLoader` composes independent product states and retains status-record metadata even when status parsing fails. `SourceAction` derives only configured root, Inbox, and status-record targets; `SourceOpening` injects `NSWorkspace` opening so availability and failure behavior are testable. The SwiftUI app uses `DashboardViewModel` to present setup when a resolved configuration is absent or malformed, then render an overview plus an in-memory selected-product detail. Selection is never persisted. The detail labels declared status recency separately from filesystem modification metadata.

`ManagerRoutingService` owns a separate local Application Support ledger; it never writes Productions. One atomically replaced ledger serializes every route transition under a cross-process lock and exact durable-byte hash guard. A durable initialization marker outside the ledger directory distinguishes a never-used store from deleted or unavailable initialized storage; status and idle checks fail uncertain rather than inventing an empty queue. Each immutable route binds its stable UUID, Task, Manager and destination thread IDs, bounded action, authority reference, whole-second timeout, and optional already-authorized next gate. Every child UUID is a ledger-global durable reservation: parent and child IDs are distinct, reservations are unique and disjoint from all route IDs, and the sole overlap allowed on reload is the exact child route created when that reservation's parent durably forwarded it. The state history is monotonic across `queued`, `delivered/acknowledged`, `running`, the three typed terminal receipts, `forwarded`, and `owner-decision-required`. The destination must acknowledge the UUID before reporting running and may durably provide exactly one complete terminal handoff. An identical duplicate is a read-only idempotent result; a conflicting duplicate is inspection-required and never rewrites history.

Terminal completion and publication of an embedded already-authorized next route occur in one ledger replacement, so routine gates do not wait for owner observation. If that child deadline is already reached, the parent receipt still commits but no invalid child is created; the parent moves to an explicit Manager/owner decision. A blocker or uncertain terminal likewise becomes one explicit owner-decision requirement. Silent completion, empty final output, interruption, and timeout first produce a hash-bound read-only reconciliation plan; timeout is eligible only at or after the exact deadline and is checked again inside apply. Every acknowledgement/running timestamp and monitor wake is exactly bound to its transition and route timeout. Applying a plan records blocker/uncertainty without retrying the routed action. Every unresolved route carries a live-target monitor, scheduled wake, or explicit owner-decision marker, and `manager routing idle-check` enforces that invariant before Manager idleness. The administrative presentation exposes unresolved route age under **Waiting for Manager**, **Waiting for target**, or **Waiting for owner**. Manager routes only, the Office Administrator writes governed records only with bounded authority, and the Coordinator remains the owner-facing strategy role.

Tests use fixture directories, in-memory configuration storage, and injected filesystem failures to avoid the real user filesystem. No layer receives a real Kahntra path during development or validation.

`LifecyclePriorityService` owns the hash-bound Registry/Workspace consistency
boundary for durable work. It recognizes only exact legacy Core mirrors and the
exact Lifecycle-and-Attention sentence, treats Registry lifecycle as authority,
and uses either an explicit Registry decision or the deterministic priority
maximum. Preview binds complete pre/post bytes. Apply shares the root-scoped
writer lock, persists a full two-file recovery envelope, uses all-or-restore
replacement, reloads complete agreement, and preserves monotonic historical
proof. An incomplete exact one-file publication is surfaced at startup and can
be restored to both complete preimages only under the writer lock by explicit
inspection. The originating lifecycle-priority, checkpoint, or accepted-handoff
journal is the administrative reconciliation-queue entry, so no parallel
canonical or unregistered payload mechanism exists.
Pending entries are loaded read-only and presented in Reconciliation Review
beside Inbox; acknowledgement changes only the queue disposition. Every
lifecycle-priority, checkpoint, and accepted-handoff journal creation,
finalization, fallback, inspection reconciliation, and queue update uses one
re-entrant cross-process recovery-directory lock plus an exact durable-byte
compare-and-swap. A correction reserves its proven pending target under that
same lock through canonical commit and the final corrected disposition.

`TaskCheckpointService` owns the v1.12 Task-checkpoint write boundary. It runs
the global adoption gate before issuing an operation UUID, acquires the shared
root-scoped Task Registry-and-Workspace lock, parses exact Registry and
Workspace structures (including one Registry/Core-matching, non-fenced H1),
requires every target and reload to be a non-followed regular file, composes an
exact Registry-authoritative repair of any recognized stale lifecycle/priority
mirror into its authorized Workspace replacement, persists
the full pre/post journal outside Productions, rechecks both preimages, uses
durable same-directory replacement, reloads the complete target agreement, and
observes Canvas without changing it. `OfficeWorkspaceTerminalState` centralizes
exhaustive proof semantics, monotonic state merging, typed terminal fallbacks,
and startup filtering. The durable store validates exact filename/requested and
payload UUID agreement, schema, operation kind, fixed paths/IDs, and bound
pre/post hashes before read, update, or startup reporting. Each update also
requires byte-identical immutable envelope fields and the exact monotonic merged
terminal/flag transition, preserving sticky fallback and historical proof.
`office inspect` is
journal-first: definite no commit is
answered before live reads; every other inspection binds the supplied canonical
root to the journal's immutable Productions root before live reads or
reconciliation; and every proven commit remains proven through a later
superseding mutation, target failure, or return-to-preimage inconsistency.
Inspection uses a lifecycle-independent identity resolver so a later valid
Done/Complete transition is superseding history, while `perform` alone applies
the stricter non-Done checkpoint-eligibility rule.
The headless adapter owns only parsing, stable JSON, and exit-code mapping; it
does not provide a second filesystem mutation path.

`AcceptedHandoffService` reuses that shared root-scoped lock, terminal proof
state, canonical-root and no-follow primitives while retaining a distinct
typed operation journal. It binds the Task Registry, source and dependent Task
Workspaces, reciprocal relationship, source commit, and contained evidence;
its canonical replacement appends one immutable accepted-handoff row and any
exact Registry-authoritative repair of recognized stale lifecycle/priority
mirrors to the source Workspace. Normal finalization precedes read-only reverse discovery,
so a discovery failure cannot roll back or weaken a proven marker commit.
`ApplicationSupportOfficeWorkspaceInspector` reads the exact journal envelope
and dispatches `office inspect` through exactly three transaction paths:
checkpoint, accepted-handoff, or lifecycle-priority reconciliation. Lifecycle
inspection can acquire the shared writer lock and restore an exact incomplete
split publication to both exact preimages after revalidating both no-follow
regular-file descriptors under that lock;
no inspection path retries an authorized Workspace operation.
