# Architecture

`ConfigurationStore` owns validated local configuration loading and atomic saving through `ConfigurationStorage`. `SetupDraft`, `SetupValidator`, and `SetupCoordinator` keep first-run root confirmation, path derivation, warnings, and persistence testable. `FileSystem` abstracts read-only filesystem operations, including status-record modification metadata. `InboxScanner` and `StatusParser` apply the fixed contract. `DashboardLoader` composes independent product states and retains status-record metadata even when status parsing fails. `SourceAction` derives only configured root, Inbox, and status-record targets; `SourceOpening` injects `NSWorkspace` opening so availability and failure behavior are testable. The SwiftUI app uses `DashboardViewModel` to present setup when a resolved configuration is absent or malformed, then render an overview plus an in-memory selected-product detail. Selection is never persisted. The detail labels declared status recency separately from filesystem modification metadata.

Tests use fixture directories, in-memory configuration storage, and injected filesystem failures to avoid the real user filesystem. No layer receives a real Kahntra path during development or validation.

`TaskCheckpointService` owns the v1.12 Task-checkpoint write boundary. It runs
the global adoption gate before issuing an operation UUID, acquires the shared
root-scoped Task Registry-and-Workspace lock, parses exact Registry and
Workspace structures (including one Registry/Core-matching, non-fenced H1),
requires every target and reload to be a non-followed regular file, prepares
only the authorized Workspace ranges, persists
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
