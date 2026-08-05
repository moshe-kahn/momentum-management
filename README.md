# Operations Dashboard

Operations Dashboard is a reusable operating-view capability owned by Momentum Management. This repository implements its first Kahntra-specific, read-only macOS instance. Milestone 1 establishes the configuration, filesystem, parsing, aggregation, fixtures, and minimal SwiftUI list needed to validate that instance contract.

## Scope

The app supports exactly two explicitly configured products. It counts visible immediate Inbox entries and parses only the documented `# Status` Markdown schema. It never discovers products, edits files, sends network requests, or connects to real Kahntra folders during Milestone 1.

## Build and test

Open `Package.swift` in Xcode when full Xcode is available, or use the Swift command-line toolchain:

```sh
swift build
swift test
swift run
```

The package targets macOS 14.0 and uses only SwiftUI and Foundation.

## Configuration

On first launch, the app enters setup instead of treating the bundled sample as a completed user configuration. Setup displays exactly Momentum Management and MomoMovies, lets the user choose or confirm one root for each with a native folder panel, and derives `Dashboard/Inbox` plus `Reference/Product/Operations Dashboard Status.md` beneath that root. It shows missing Inbox and future-status-record warnings without creating either path.

`dashboard-config.sample.json` is a bundled synthetic schema example only. A resolved `dashboard-config.json` belongs at `~/Library/Application Support/Operations Dashboard/dashboard-config.json` and is intentionally not source-controlled. The configuration loader validates exactly two products, requires distinct accessible roots, and does not perform automatic discovery. A malformed saved configuration stays untouched and returns the app to setup with a visible error.

For development, reset setup by removing only the local resolved configuration file above; do not modify selected product folders. The application writes only its own confirmed configuration and never creates, edits, moves, or deletes files in a selected product root.

## Fixtures

`Tests/OperationsDashboardTests/Fixtures/` contains only invented data. Tests copy fixtures to temporary locations before exercising them. The unreadable-source case uses an injected filesystem failure because permission-based failures are unreliable in automated macOS test runs.

## Privacy and read-only behavior

No real product folder, private record, or personal absolute path is bundled. The filesystem layer enumerates and reads configured paths only; it has no source-file mutation API. Real-folder confirmation and operational status records are deferred to later approved work.
