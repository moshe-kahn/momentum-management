# Momentum Management

Momentum Management is a local-first system for managing work across projects,
preserving task context, and coordinating execution between a person and AI
agents. This repository contains its macOS application and command-line
interface, Operations Dashboard.

The graphical dashboard provides a read-only view of active work, while the
CLI provides controlled canonical operations. Canonical task records are
ordinary local files and folders, so they remain inspectable, portable, and
independent of a hosted task-management service.

## Key concepts

- **Canvas** — the current working set: tasks selected from the larger project
  backlog that are actively being pursued.
- **Memento** — a durable resume note that records a concise summary, current
  state, resume point, and optional open crumbs so work can continue without
  reconstructing context.
- **Task checkpoint** — a separate, narrow canonical-record update. It checks
  one exact unfinished Step and replaces only the Task Workspace's `Next step`
  and `Last validated state` fields, with accepted evidence bound to the
  reviewed preimages.

## How it works

1. **Capture.** Incoming material lands in a product's Inbox through capture
   commands, rather than being lost in a downloads folder.
2. **Triage and select.** In ordinary Operations use, focus the selected task
   on Canvas:

   ```sh
   OperationsDashboard canvas focus \
     --productions-root <path> --work <TASK-ID> \
     --reason <text> --context <text>
   ```

   The explicitly sensitive or manual low-level Canvas workflow uses a bound
   preview and confirmation token:

   ```sh
   OperationsDashboard canvas preview start \
     --productions-root <path> --work <ID> \
     --reason <text> --context <text>

   OperationsDashboard canvas start \
     --productions-root <path> --work <ID> \
     --reason <text> --context <text> --confirm <preview-token>
   ```

3. **Pause with state intact.** A Memento is a durable resume note. Its
   mutation flow previews the complete draft, then repeats it with the
   state-bound confirmation token:

   ```sh
   OperationsDashboard memento preview create \
     --productions-root <path> --target <ID> \
     --summary <text> --current-state <text> --resume-point <text>

   OperationsDashboard memento create \
     --productions-root <path> --target <ID> \
     --summary <text> --current-state <text> --resume-point <text> \
     --confirm <preview-token>
   ```

   When an owner has authorized a narrow canonical Task update, `task
   checkpoint` instead takes all of its real, hash-bound inputs directly. It
   has no preview form and no confirmation token:

   ```sh
   OperationsDashboard task checkpoint \
     --productions-root <path> --task <TASK-ID> \
     --expected-workspace-sha256 <64-lowercase-hex> \
     --expected-registry-sha256 <64-lowercase-hex> \
     --unfinished-step <S##> \
     --evidence <one-line-accepted-evidence> \
     --next-step <complete-replacement-text> \
     --last-validated-state <complete-replacement-text>
   ```

4. **Resume or hand off.** Work resumes from the Memento, or is routed to
   another session through the Manager-routing ledger. See
   [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md) for the full canonical syntax,
   confirmation rules, exit codes, and recovery behavior.

## Components

- **Local files** — task records, registries, and project folders are the
  system itself. An editor, script, or AI can work with them directly.
- **Dashboard (this repo)** — a read-only SwiftUI operating view over
  configured products: Inbox counts, current status, next actions, and
  blockers. The current implementation is configured for Momentum Management
  and MomoMovies.
- **CLI (this repo)** — the operating interface for inbox capture, Canvas
  attention, Mementos, task checkpoints, lifecycle/priority changes, Office
  inspection, and inter-session routing.

## Engineering safeguards

State-bound confirmation tokens, preimage hashes, durable journals, and
idempotent operations protect filesystem changes against stale assumptions,
interrupted writes, and uncertain outcomes. Unknown outcomes are surfaced; they
are not retried automatically.

## Documentation

- [Architecture](ARCHITECTURE.md) — services, the Manager-routing ledger,
  Canvas continuity, and checkpoint/handoff transaction design.
- [Headless command reference](COMMAND_REFERENCE.md) — the full CLI,
  including confirmation workflow, exit codes, and recovery rules.
- [Implementation reference](IMPLEMENTATION.md) — detailed scope and
  configuration contracts summarized here.

## Status and authorship

Momentum Management is a personal system in daily use, designed by Moshe Kahn;
implementation was developed with AI assistance under his direction and
specifications. Production records are excluded from this repository, while
some Kahntra-specific example paths remain. Tests run on synthetic fixtures.

## Build and test

Open `Package.swift` in Xcode when full Xcode is available, or use the Swift
command-line toolchain:

```sh
swift build
swift test
swift run
```

The package targets macOS 14.0 and uses only SwiftUI and Foundation.

## Fixtures

`Tests/OperationsDashboardTests/Fixtures/` contains invented data. Tests copy
fixtures to temporary locations before exercising them. The unreadable-source
case uses an injected filesystem failure because permission-based failures are
unreliable in automated macOS test runs.

## Privacy and read-only behavior

Production records are excluded; some Kahntra-specific example paths remain.
Tests use synthetic fixtures and injected failures. The dashboard viewing
filesystem layer remains read-only. GUI Add Items mutations are limited to its
authorized note creation and intake moves through capture services; confirmed
headless mutations are distinct and routed through the specific canonical
transaction or capture service named by the command contract.
