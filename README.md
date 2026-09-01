# Operations Dashboard

Operations Dashboard is a reusable operating-view capability owned by Momentum Management. This repository implements its first Kahntra-specific macOS instance: a read-only SwiftUI operating view plus explicitly confirmed headless boundaries for canonical Operations commands. It establishes the configuration, filesystem, parsing, aggregation, fixtures, services, and restrained interface needed to validate that instance contract.

## Scope

The dashboard viewing layer supports exactly two explicitly configured products. It counts visible immediate Inbox entries and parses only the documented `# Status` Markdown schema. The overview compares product name, Inbox count, current Status, and warnings. Selecting a product in the same window shows its complete operating detail: declared Last updated, Next actions, Blockers, source-role availability, and status-record filesystem modification time. Declared Last updated and file modification time are visibly distinct and neither is used to infer priority or freshness. Selection is in memory only. This viewing layer is read-only and can ask macOS to open only an existing configured product root, Inbox, or status record; it never discovers products or sends network requests. The separate Add Items capture UI can create notes and move configured intake items into its authorized Inbox through the capture service. Separately, recognized headless commands can dispatch canonical mutations through their specific services. The owner-authorized Task checkpoint and accepted-handoff writers are callable only after independently verified DOC-0016 v1.12 adoption; their complete inputs and preimage hashes are the authorization boundary. The Office reconciliation surface previews and atomically repairs recognized lifecycle/priority mirrors. Task checkpoint and accepted-handoff writers compose that repair plus display-only relationship reconciliation into their bound Workspace replacement; semantic relationship changes block. Every automatic repair stays in its originating durable journal as a pending review item exposed beside Inbox. Advisory handoff review and reconciliation acknowledgement never start or focus work. A separate local Manager-routing ledger gives every inter-task route a stable operation UUID, acknowledgement/running/terminal history, monitored wait or wake, exactly one structured terminal handoff, atomic already-authorized gate advancement, and a compact Waiting for Manager/target/owner status. A hash-bound standing continuation can carry bounded implementation, review, correction, accepted commit, canonical checkpoint, and explicitly scoped phase stages while rereading canonical Task context and predecessor receipts at every transition. Genuine decisions are consolidated in Architect Approvals; administrative queue items never synthesize Quick Notes. It never grants Productions mutation authority.

Canvas attention is task-level rather than session-level. An active owner
pursuit stays current through implementation, review, correction, checkpoint,
and routine phase handoffs. Task Clear and compatibility Stop require an exact
owner-level basis; a session ending or becoming idle is never one. Existing
Idea, Project, and Initiative attention remains basis-free. The in-app Task
Clear sheet requires the same accessible exact basis choice as the CLI.

## Build and test

Open `Package.swift` in Xcode when full Xcode is available, or use the Swift command-line toolchain:

```sh
swift build
swift test
swift run
```

The package targets macOS 14.0 and uses only SwiftUI and Foundation.

For the operator-facing syntax, confirmation workflow, exit codes, and recovery rules of the canonical headless commands, see [Headless command reference](COMMAND_REFERENCE.md).

## Configuration

On first launch, the app enters setup instead of treating the bundled sample as a completed user configuration. Setup displays exactly Momentum Management and MomoMovies, lets the user choose or confirm one root for each with a native folder panel, and derives `Dashboard/Inbox` plus `Reference/Product/Operations Dashboard Status.md` beneath that root. It shows missing Inbox and future-status-record warnings without creating either path.

`dashboard-config.sample.json` is a bundled synthetic schema example only. A resolved `dashboard-config.json` belongs at `~/Library/Application Support/Operations Dashboard/dashboard-config.json` and is intentionally not source-controlled. The configuration loader validates exactly two products, requires distinct accessible roots, and does not perform automatic discovery. A malformed saved configuration stays untouched and returns the app to setup with a visible error.

For development, reset setup by removing only the local resolved configuration file above; do not modify selected product folders. The dashboard setup UI writes only its own confirmed configuration. The Add Items capture UI has the narrower authorized ability to create notes and move intake items into Inbox. Confirmed headless canonical mutations are separate command workflows documented below.

## Fixtures

`Tests/OperationsDashboardTests/Fixtures/` contains only invented data. Tests copy fixtures to temporary locations before exercising them. The unreadable-source case uses an injected filesystem failure because permission-based failures are unreliable in automated macOS test runs.

## Privacy and read-only behavior

No real product folder, private record, or personal absolute path is bundled. Tests use synthetic fixtures and injected failures. The dashboard viewing filesystem layer remains read-only. GUI Add Items mutations are limited to its authorized note creation and intake moves through capture services; confirmed headless mutations are distinct and routed through the specific canonical transaction or capture service named by the command contract.
