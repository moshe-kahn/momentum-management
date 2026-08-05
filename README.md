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

`dashboard-config.sample.json` is bundled with synthetic placeholder roots. A resolved `dashboard-config.json` belongs in the app's Application Support directory and is intentionally not source-controlled. The configuration loader validates exactly two products and does not perform automatic discovery.

## Fixtures

`Tests/OperationsDashboardTests/Fixtures/` contains only invented data. Tests copy fixtures to temporary locations before exercising them. The unreadable-source case uses an injected filesystem failure because permission-based failures are unreliable in automated macOS test runs.

## Privacy and read-only behavior

No real product folder, private record, or personal absolute path is bundled. The filesystem layer enumerates and reads configured paths only; it has no source-file mutation API. Real-folder confirmation and operational status records are deferred to later approved work.
