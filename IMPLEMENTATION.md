# Implementation reference: Operations Dashboard

Detailed scope and configuration contracts for Operations Dashboard, the macOS
application and CLI within Momentum Management. This document preserves the
implementation-level details summarized in the main README.

## Scope

Operations Dashboard is a reusable operating-view capability owned by Momentum
Management. This repository implements its first Kahntra-specific macOS
instance: a read-only SwiftUI operating view plus explicitly confirmed
headless boundaries for canonical Operations commands. It establishes the
configuration, filesystem, parsing, aggregation, fixtures, services, and
restrained interface needed to validate that instance contract.

The dashboard viewing layer supports exactly two explicitly configured
products. It counts visible immediate Inbox entries and parses only the
documented `# Status` Markdown schema. The overview compares product name,
Inbox count, current Status, and warnings. Selection is in memory only. This
viewing layer is read-only and can ask macOS to open only an existing
configured product root, Inbox, or status record; it never discovers products
or sends network requests.

The separate Add Items capture UI can create notes and move configured intake
items into its authorized Inbox through the capture service. Recognized
headless commands dispatch canonical mutations through their specific
services. Owner-authorized Task checkpoint and accepted-handoff writers are
callable only after independently verified DOC-0016 v1.12 adoption; their
complete inputs and preimage hashes are the authorization boundary.

The Office reconciliation surface previews and atomically repairs recognized
lifecycle/priority mirrors. Task checkpoint and accepted-handoff writers
compose that repair plus display-only relationship reconciliation into their
bound Workspace replacement; semantic relationship changes block. Advisory
handoff review and reconciliation acknowledgement never start or focus work.

A separate local Manager-routing ledger gives every inter-task route a stable
operation UUID, acknowledgement/running/terminal history, monitored wait or
wake, and exactly one structured terminal handoff. It grants no standing or
implicit authority; writes remain separately authorized, hash-bound, and
command-bounded.

Canvas attention is task-level rather than session-level. An active owner
pursuit stays current through implementation, review, correction, checkpoint,
and routine phase handoffs. Task Clear and compatibility Stop require an exact
owner-level basis; a session ending or becoming idle is never one.

## Configuration

On first launch, the app enters setup instead of treating the bundled sample as
a completed user configuration. Setup displays exactly Momentum Management and
MomoMovies, lets the user choose or confirm one root for each with a native
folder panel, and derives `Dashboard/Inbox` plus
`Reference/Product/Operations Dashboard Status.md` beneath that root. It shows
missing Inbox and future-status-record warnings without creating either path.

`dashboard-config.sample.json` is a bundled synthetic schema example only. A
resolved `dashboard-config.json` belongs at
`~/Library/Application Support/Operations Dashboard/dashboard-config.json` and
is intentionally not source-controlled. The configuration loader validates
exactly two products, requires distinct accessible roots, and does not perform
automatic discovery. A malformed saved configuration stays untouched and
returns the app to setup with a visible error.

For development, reset setup by removing only the local resolved configuration
file above; do not modify selected product folders. The dashboard setup UI
writes only its own confirmed configuration. The Add Items capture UI has the
narrower authorized ability to create notes and move intake items into Inbox.
Confirmed headless canonical mutations are separate command workflows
documented in [COMMAND_REFERENCE.md](COMMAND_REFERENCE.md).
