# Architecture

`ConfigurationStore` owns validated local configuration loading and atomic saving through `ConfigurationStorage`. `SetupDraft`, `SetupValidator`, and `SetupCoordinator` keep first-run root confirmation, path derivation, warnings, and persistence testable. `FileSystem` abstracts read-only filesystem operations. `InboxScanner` and `StatusParser` apply the fixed contract. `DashboardLoader` composes independent product states. `SourceAction` derives only configured root, Inbox, and status-record targets; `SourceOpening` injects `NSWorkspace` opening so availability and failure behavior are testable. The SwiftUI app uses `DashboardViewModel` to present setup when a resolved configuration is absent or malformed, then render the configured dashboard and manual refresh.

Tests use fixture directories, in-memory configuration storage, and injected filesystem failures to avoid the real user filesystem. No layer receives a real Kahntra path during development or validation.
