# Architecture

`ConfigurationStore` owns validated local configuration loading and saving. `FileSystem` abstracts read-only filesystem operations. `InboxScanner` and `StatusParser` apply the fixed contract. `DashboardLoader` composes independent product states. The SwiftUI app uses `DashboardViewModel` to render the loaded synthetic configuration and manual refresh.

Tests use fixture directories and an injected filesystem failure to avoid the real user filesystem. No layer receives a real Kahntra path in Milestone 1.
