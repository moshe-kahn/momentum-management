import Foundation
import XCTest
@testable import OperationsDashboard

final class FlowRegistrationTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-11T18:00:00Z")!

    @MainActor
    func testViewModelInstalledStartupSchedulesAndExecutesProductionCallbackWithoutRefresh() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("view", at: "Office/Inbox/viewmodel.txt")
        let clock = TestClock(date); let scheduler = ManualIntakeScheduler(); let journal = MemoryJournal()
        let registration = service(journal: journal, clock: clock)
        let intake = InboxAutomaticIntake(registration: registration, quiescenceInterval: 2, now: { clock.value })
        let before = try fixture.snapshot()
        let model = ProductionsDashboardViewModel(reader: LocalFileSystem(), registrationService: registration, automaticIntake: intake, intakeScheduler: scheduler, now: { clock.value }, initialConfiguration: config(fixture))
        XCTAssertEqual(try fixture.snapshot(), before, "Construction must be read-only.")
        XCTAssertNil(model.intakeDiagnostics.firstObservation)
        model.startAutomaticIntake()
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertNotNil(model.intakeDiagnostics.firstObservation)
        XCTAssertNotNil(model.intakeDiagnostics.scheduledDeadline)
        model.startAutomaticIntake(); XCTAssertEqual(scheduler.pendingCount, 1)
        clock.advance(2); scheduler.runNext()
        XCTAssertTrue(model.intakeDiagnostics.callbackFired)
        XCTAssertTrue(model.intakeDiagnostics.secondObservationOutcome?.contains("Registered automatically.") == true)
        XCTAssertTrue(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("viewmodel.txt"))
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("| FLOW | 6 | 2 |"))
        model.startAutomaticIntake(); XCTAssertEqual(scheduler.pendingCount, 0)
        let registeredRows = String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).split(separator: "\n").filter { $0.contains("`Office/Inbox/viewmodel.txt`") }
        XCTAssertEqual(registeredRows.count, 1)
    }

    @MainActor
    func testViewModelDeallocationCancelsPendingScheduledWork() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("view", at: "Office/Inbox/destroy.txt")
        let scheduler = ManualIntakeScheduler(); let cfg = config(fixture)
        weak var weakModel: ProductionsDashboardViewModel?
        do {
            var model: ProductionsDashboardViewModel? = ProductionsDashboardViewModel(reader: LocalFileSystem(), automaticIntake: InboxAutomaticIntake(quiescenceInterval: 2), intakeScheduler: scheduler, initialConfiguration: cfg)
            weakModel = model; model?.startAutomaticIntake()
            XCTAssertEqual(scheduler.pendingCount, 1)
            model = nil
        }
        XCTAssertNil(weakModel)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testStartupLifecycleSchedulesSecondObservationAndRegistersWithoutRefresh() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("file", at: "Office/Inbox/startup.txt")
        let clock = TestClock(date); let scheduler = ManualIntakeScheduler()
        let intake = InboxAutomaticIntake(registration: service(journal: MemoryJournal(), clock: clock), quiescenceInterval: 2, now: { clock.value })
        let lifecycle = InboxAutomaticIntakeLifecycle(scheduler: scheduler, delay: 2) {
            intake.scan(configuration: self.config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        }
        XCTAssertEqual(lifecycle.observe().first?.outcome, .deferred)
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertFalse(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("startup.txt"))
        clock.advance(1)
        XCTAssertFalse(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("startup.txt"), "Registration cannot occur before the two-second scheduled observation.")
        XCTAssertEqual(scheduler.pendingCount, 1)
        clock.advance(1); scheduler.runNext()
        XCTAssertTrue(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("startup.txt"))
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testScheduledObservationAfterChangeRestartsFullInterval() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("one", at: "Office/Inbox/change.txt")
        let clock = TestClock(date); let scheduler = ManualIntakeScheduler()
        let intake = InboxAutomaticIntake(registration: service(journal: MemoryJournal(), clock: clock), quiescenceInterval: 2, now: { clock.value })
        let lifecycle = InboxAutomaticIntakeLifecycle(scheduler: scheduler, delay: 2) { intake.scan(configuration: self.config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() }) }
        _ = lifecycle.observe()
        try fixture.add("changed", at: "Office/Inbox/change.txt")
        clock.advance(2); scheduler.runNext()
        XCTAssertEqual(scheduler.pendingCount, 1)
        XCTAssertFalse(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("change.txt"))
        clock.advance(2); scheduler.runNext()
        XCTAssertTrue(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("change.txt"))
    }

    func testRepeatedStartupRefreshAndNotificationsCoalesceOneTimer() {
        let scheduler = ManualIntakeScheduler()
        var calls = 0
        let lifecycle = InboxAutomaticIntakeLifecycle(scheduler: scheduler, delay: 2) {
            calls += 1
            return [InboxIntakeResult(payloadPath: "Office/Inbox/item", outcome: calls < 4 ? .deferred : .registered("FLOW-000002"), reason: "test")]
        }
        _ = lifecycle.observe(); _ = lifecycle.observe(); _ = lifecycle.observe()
        XCTAssertEqual(scheduler.pendingCount, 1)
        scheduler.runNext()
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testBlockedAndRetiredStatesStopLifecycleScheduling() {
        let scheduler = ManualIntakeScheduler()
        var state: InboxIntakeResult.Outcome = .deferred
        let lifecycle = InboxAutomaticIntakeLifecycle(scheduler: scheduler, delay: 2) {
            [InboxIntakeResult(payloadPath: "Office/Inbox/item", outcome: state, reason: "test")]
        }
        _ = lifecycle.observe(); XCTAssertEqual(scheduler.pendingCount, 1)
        state = .investigationRequired; scheduler.runNext(); XCTAssertEqual(scheduler.pendingCount, 0)
        state = .suspended; _ = lifecycle.observe(); XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testNoCandidatesDoesNotScheduleRecheckAndDeinitCancelsWork() {
        let scheduler = ManualIntakeScheduler()
        var lifecycle: InboxAutomaticIntakeLifecycle? = InboxAutomaticIntakeLifecycle(scheduler: scheduler, delay: 2) { [] }
        _ = lifecycle?.observe(); XCTAssertEqual(scheduler.pendingCount, 0)
        lifecycle = InboxAutomaticIntakeLifecycle(scheduler: scheduler, delay: 2) { [InboxIntakeResult(payloadPath: "Office/Inbox/item", outcome: .deferred, reason: "test")] }
        _ = lifecycle?.observe(); XCTAssertEqual(scheduler.pendingCount, 1)
        lifecycle = nil; XCTAssertEqual(scheduler.pendingCount, 0)
    }

    func testAutomaticStartupDiscoveryDefersThenRefreshRegistersFileDefaults() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("file", at: "Office/Inbox/Automatic.txt")
        let clock = TestClock(date)
        let journal = MemoryJournal()
        let intake = InboxAutomaticIntake(registration: service(journal: journal, clock: clock), quiescenceInterval: 2, now: { clock.value })
        let initial = fixture.load()
        let first = intake.scan(configuration: config(fixture), candidates: initial.inbox, reload: { _ in fixture.load() })
        XCTAssertEqual(first.first?.outcome, .deferred)
        XCTAssertFalse(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("Automatic.txt"))
        clock.advance(2)
        let second = intake.scan(configuration: config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        XCTAssertEqual(second.first?.outcome, .registered("FLOW-000002"))
        let row = try XCTUnwrap(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).split(separator: "\n").last.map(String.init))
        let cells = MarkdownTable.cells(row)
        XCTAssertEqual(Array(cells[1...12]), ["Automatic.txt", "Unclassified file", "Inbox", "Unranked", "Office", "Unassigned", "Unassigned", "Inbox filesystem intake", "—", "`Office/Inbox/Automatic.txt`", "Unclassified Inbox payload awaiting review.", "Review and route to Processing or a durable destination."])
    }

    func testAutomaticFolderDefaultsAndPayloadImmutability() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("child", at: "Office/Inbox/Automatic Folder/child.txt")
        let before = try fixture.snapshot(); let clock = TestClock(date)
        let intake = InboxAutomaticIntake(registration: service(journal: MemoryJournal(), clock: clock), quiescenceInterval: 1, now: { clock.value })
        _ = intake.scan(configuration: config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        clock.advance(1)
        _ = intake.scan(configuration: config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        XCTAssertEqual(try fixture.data(at: "Office/Inbox/Automatic Folder/child.txt"), before["Office/Inbox/Automatic Folder/child.txt"])
        XCTAssertTrue(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("| Automatic Folder | Unclassified folder | Inbox |"))
    }

    func testQuiescenceDefersChangingPayloadUntilStable() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("one", at: "Office/Inbox/copying.txt")
        let clock = TestClock(date); let intake = InboxAutomaticIntake(registration: service(journal: MemoryJournal(), clock: clock), quiescenceInterval: 2, now: { clock.value })
        _ = intake.scan(configuration: config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        clock.advance(2); try fixture.add("one plus more", at: "Office/Inbox/copying.txt")
        XCTAssertEqual(intake.scan(configuration: config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() }).first?.outcome, .deferred)
        clock.advance(2)
        XCTAssertEqual(intake.scan(configuration: config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() }).first?.outcome, .registered("FLOW-000002"))
    }

    func testAutomaticIntakeIsDeterministicAndSerial() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("b", at: "Office/Inbox/b.txt"); try fixture.add("a", at: "Office/Inbox/a.txt")
        let clock = TestClock(date); let intake = InboxAutomaticIntake(registration: service(journal: MemoryJournal(), clock: clock), quiescenceInterval: 1, now: { clock.value })
        _ = intake.scan(configuration: config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        clock.advance(1)
        let results = intake.scan(configuration: config(fixture), candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        XCTAssertEqual(results.map(\.payloadPath), ["Office/Inbox/a.txt", "Office/Inbox/b.txt"])
        XCTAssertEqual(results.map(\.outcome), [.registered("FLOW-000002"), .registered("FLOW-000003")])
    }

    func testUnsupportedAndDuplicatePayloadsDoNotIssueIDs() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let fifo = fixture.root.appending(path: "Office/Inbox/unsupported")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let unsupported = FlowItem(viewIdentity: "unsupported", flowID: nil, label: "unsupported", type: "Unregistered", stage: "Inbox", priority: "", location: "Office/Inbox/unsupported", summary: "", bundleContent: nil)
        let beforeLedger = try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md")
        let intake = InboxAutomaticIntake(registration: service(journal: MemoryJournal()), quiescenceInterval: 0)
        XCTAssertEqual(intake.scan(configuration: config(fixture), candidates: [unsupported], reload: { _ in fixture.load() }).first?.outcome, .problem)
        XCTAssertEqual(try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), beforeLedger)
        let duplicate = try payload(fixture, "Inbox item")
        XCTAssertTrue(intake.scan(configuration: config(fixture), candidates: [duplicate], reload: { _ in fixture.load() }).isEmpty)
    }

    func testConcurrentWriterAndContractConflictSuspendPassWithoutLaterWrites() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("a", at: "Office/Inbox/a.txt"); try fixture.add("b", at: "Office/Inbox/b.txt")
        let clock = TestClock(date); let cfg = config(fixture)
        let intake = InboxAutomaticIntake(registration: service(journal: MemoryJournal(), clock: clock), quiescenceInterval: 0, now: { clock.value })
        _ = intake.scan(configuration: cfg, candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        let held = LocalFlowRegistrationLocking().acquire(ledgerURL: cfg.url("Warehouse/Reference/Identifier Ledger.md"))
        let locked = intake.scan(configuration: cfg, candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        XCTAssertEqual(locked.first?.outcome, .suspended); XCTAssertEqual(locked.count, 1)
        withExtendedLifetime(held) {}
        fixture.replaceFlow("| Entry ID | Label | Type | Stage | Priority | Steward | Department | Product | Source | Related work | Location | Summary | Next disposition | Created |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        let conflicted = intake.scan(configuration: cfg, candidates: fixture.load().inbox, reload: { _ in fixture.load() })
        XCTAssertEqual(conflicted.first?.outcome, .suspended); XCTAssertEqual(conflicted.count, 1)
        XCTAssertFalse(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("a.txt"))
    }

    func testRetiredIDFailureDoesNotLoopAutomaticallyAndManualRetryUsesNewID() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("one", at: "Office/Inbox/retired.txt")
        let clock = TestClock(date); let journal = MemoryJournal(); let failing = ControlledReplacer(failOn: 2)
        let intake = InboxAutomaticIntake(registration: service(journal: journal, replacer: failing, clock: clock), quiescenceInterval: 0, now: { clock.value })
        let item = try payload(fixture, "retired.txt")
        _ = intake.scan(configuration: config(fixture), candidates: [item], reload: { _ in fixture.load() })
        XCTAssertEqual(intake.scan(configuration: config(fixture), candidates: [item], reload: { _ in fixture.load() }).first?.outcome, .investigationRequired)
        let ledgerAfterFailure = try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md")
        XCTAssertTrue(String(decoding: ledgerAfterFailure, as: UTF8.self).contains("| FLOW | 6 | 2 |"))
        XCTAssertEqual(intake.scan(configuration: config(fixture), candidates: [item], reload: { _ in fixture.load() }).first?.outcome, .investigationRequired)
        XCTAssertEqual(try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), ledgerAfterFailure)
        let recovered = InboxAutomaticIntake(registration: service(journal: MemoryJournal(), clock: clock), quiescenceInterval: 0, now: { clock.value })
        XCTAssertEqual(recovered.retry(configuration: config(fixture), payload: item, reload: { _ in fixture.load() }).outcome, .registered("FLOW-000003"))
    }

    func testAutomaticDefaultsRegisterAFileWithExactBasename() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("file", at: "Office/Inbox/Exact Name.txt")
        let svc = service(journal: MemoryJournal()); let item = try payload(fixture, "Exact Name.txt")
        let defaults = try svc.automaticDefaults(configuration: config(fixture), payload: item)
        XCTAssertEqual(defaults.label, "Exact Name.txt")
        XCTAssertEqual(defaults.type, "Unclassified file")
        XCTAssertEqual(defaults.priority, "Unranked")
        XCTAssertEqual(defaults.steward, "Office")
        XCTAssertEqual(defaults.department, "Unassigned")
        XCTAssertEqual(defaults.product, "Unassigned")
        XCTAssertEqual(defaults.source, "Inbox filesystem intake")
        XCTAssertEqual(defaults.relatedWork, "—")
        XCTAssertEqual(defaults.summary, "Unclassified Inbox payload awaiting review.")
        XCTAssertEqual(defaults.nextDisposition, "Review and route to Processing or a durable destination.")
        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: defaults)
        XCTAssertTrue(preview.row.contains("| Exact Name.txt | Unclassified file | Inbox |"))
    }

    func testAutomaticDefaultsRegisterAFolderWithExactBasename() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("child", at: "Office/Inbox/Research Folder/child.md")
        let svc = service(journal: MemoryJournal()); let item = try payload(fixture, "Research Folder")
        let defaults = try svc.automaticDefaults(configuration: config(fixture), payload: item)
        XCTAssertEqual(defaults.label, "Research Folder")
        XCTAssertEqual(defaults.type, "Unclassified folder")
        let before = try fixture.snapshot()
        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: defaults)
        XCTAssertEqual(try fixture.snapshot(), before, "Preview/cancellation must not mutate the folder or descendants.")
        XCTAssertEqual(MarkdownTable.cells(preview.row).count, 15)
    }

    func testAuthorizedMetadataOverrideRemainsSupported() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("file", at: "Office/Inbox/override.txt")
        let svc = service(journal: MemoryJournal()); let item = try payload(fixture, "override.txt")
        var metadata = try svc.automaticDefaults(configuration: config(fixture), payload: item)
        metadata.label = "Codex-enriched intake"; metadata.type = "Research note"; metadata.priority = "High"
        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: metadata)
        XCTAssertTrue(preview.row.contains("| Codex-enriched intake | Research note | Inbox | High |"))
    }

    func testPreviewAndCancellationBoundariesDoNotWrite() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/new.txt")
        let before = try fixture.snapshot()
        let service = service(journal: MemoryJournal())
        _ = try service.preview(configuration: config(fixture), payload: try payload(fixture, "new.txt"), metadata: metadata())
        // Both form cancellation and final-preview cancellation intentionally do not call commit.
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testSuccessfulRegistrationCommitsLedgerThenFlowAndReloads() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/new.txt")
        let journal = MemoryJournal()
        let service = service(journal: journal)
        let payload = try payload(fixture, "new.txt")
        let originalPayload = try fixture.data(at: "Office/Inbox/new.txt")
        let preview = try service.preview(configuration: config(fixture), payload: payload, metadata: metadata())
        XCTAssertEqual(preview.flowID, "FLOW-000002")
        XCTAssertEqual(MarkdownTable.cells(preview.row).count, 15)
        try service.commit(configuration: config(fixture), payload: payload, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in fixture.load() })
        XCTAssertEqual(try fixture.data(at: "Office/Inbox/new.txt"), originalPayload)
        XCTAssertTrue(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("FLOW-000002"))
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("| FLOW | 6 | 2 | `FLOW-000003` |"))
        XCTAssertEqual(journal.journals.last?.terminalState, .bothFilesCommitted)
        XCTAssertTrue(fixture.load().issues.isEmpty)
    }

    func testRegistrationInsertsBeforeTrailingProseAndFullReloadRecognizesExactRow() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/trailing.txt")
        let originalFlow = "# Flow\n\n" + fixture.flow + "\n\n## Rules\n\nUnknown content must survive.\n"
        fixture.replaceFlow(originalFlow)
        let originalLedger = try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md")
        let originalPayload = try fixture.data(at: "Office/Inbox/trailing.txt")
        let journal = MemoryJournal(); let svc = service(journal: journal)
        let item = try payload(fixture, "trailing.txt")

        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: metadata())
        try svc.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in fixture.load() })

        let replacement = String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self)
        XCTAssertEqual(replacement.replacingOccurrences(of: preview.row + "\n", with: ""), originalFlow)
        XCTAssertEqual(replacement.split(separator: "\n", omittingEmptySubsequences: false).filter { String($0) == preview.row }.count, 1)
        XCTAssertLessThan(try XCTUnwrap(replacement.range(of: preview.row)?.lowerBound), try XCTUnwrap(replacement.range(of: "## Rules")?.lowerBound))
        XCTAssertEqual(replacement.components(separatedBy: "| FLOW-000001 | Inbox item |").count - 1, 1)
        XCTAssertEqual(replacement.components(separatedBy: "| BND-000001 | Bundle |").count - 1, 1)

        let state = fixture.load()
        let registered = try XCTUnwrap(state.inbox.first { $0.location == "Office/Inbox/trailing.txt" })
        XCTAssertEqual(registered.flowID, preview.flowID)
        XCTAssertFalse(registered.isUnregistered)
        XCTAssertTrue(state.issues.isEmpty, state.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(try fixture.data(at: "Office/Inbox/trailing.txt"), originalPayload)
        XCTAssertEqual(journal.journals.count, 1)
        XCTAssertEqual(journal.journals.first?.flowPreimage, Data(originalFlow.utf8))
        XCTAssertEqual(journal.journals.first?.ledgerPreimage, originalLedger)
        XCTAssertEqual(journal.journals.first?.terminalState, .bothFilesCommitted)
    }

    func testRegistrationInsertsAtEndOfFlowWithoutChangingTerminalNewlinePolicy() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/end.txt")
        let originalFlow = fixture.flow
        XCTAssertFalse(originalFlow.hasSuffix("\n"))
        let svc = service(journal: MemoryJournal()); let item = try payload(fixture, "end.txt")

        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: metadata())
        try svc.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in fixture.load() })

        let replacement = String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self)
        XCTAssertEqual(replacement, originalFlow + "\n" + preview.row)
        XCTAssertFalse(replacement.hasSuffix("\n"))
        XCTAssertEqual(fixture.load().inbox.first { $0.location == "Office/Inbox/end.txt" }?.flowID, preview.flowID)
    }

    func testRegistrationPreservesCRLFLineEndingsAndTrailingContent() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/crlf.txt")
        let originalFlow = fixture.flow.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n## Rules\r\nPreserve this.\r\n"
        fixture.replaceFlow(originalFlow)
        let item = FlowItem(viewIdentity: "crlf", flowID: nil, label: "crlf.txt", type: "Unregistered", stage: "Inbox", priority: "", location: "Office/Inbox/crlf.txt", summary: "", bundleContent: nil)
        let svc = service(journal: MemoryJournal())

        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: metadata())
        try svc.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { configuration in
            ProductionsState(configuration: configuration, inbox: [], processing: [], work: [], canvas: [], crumbs: [], mementos: [], issues: [])
        })

        let replacement = String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self)
        XCTAssertEqual(replacement.replacingOccurrences(of: preview.row + "\r\n", with: ""), originalFlow)
        XCTAssertFalse(replacement.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        XCTAssertLessThan(try XCTUnwrap(replacement.range(of: preview.row)?.lowerBound), try XCTUnwrap(replacement.range(of: "## Rules")?.lowerBound))
    }

    func testMissingDuplicateAmbiguousMalformedAndNoncanonicalTableBoundariesAreRejectedBeforeJournal() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/boundary.txt")
        let item = FlowItem(viewIdentity: "boundary", flowID: nil, label: "boundary.txt", type: "Unregistered", stage: "Inbox", priority: "", location: "Office/Inbox/boundary.txt", summary: "", bundleContent: nil)
        let fixtureLines = fixture.flow.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = fixtureLines[0]
        let orphan = "| FLOW-999999 | Orphan | Note | Inbox | Low | Office | Office | — | test | — | `Office/Inbox/orphan.txt` | Orphan | Review | 2026-08-11 | 2026-08-11 |"
        let cases: [(String, String)] = [
            ("missing", "# Flow\n\nNo canonical table."),
            ("duplicate", fixture.flow + "\n\n" + fixture.flow),
            ("ambiguous orphan", fixture.flow + "\n\n## Rules\n" + orphan),
            ("malformed separator", header + "\n| --- |"),
            ("noncanonical boundary", fixture.flow + "\n " + orphan)
        ]

        for (name, flow) in cases {
            fixture.replaceFlow(flow)
            let before = try fixture.snapshot()
            let journal = MemoryJournal()
            XCTAssertThrowsError(try service(journal: journal).preview(configuration: config(fixture), payload: item, metadata: metadata()), name) { error in
                guard case FlowRegistrationError.invalidMetadata = error else {
                    return XCTFail("Expected invalid Flow schema for \(name), got \(error)")
                }
            }
            XCTAssertTrue(journal.journals.isEmpty, name)
            XCTAssertEqual(try fixture.snapshot(), before, name)
        }
    }

    func testSharedTimestampIsUsedForCreatedUpdatedAndJournal() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/time.txt")
        let journal = MemoryJournal(); let service = service(journal: journal)
        let item = try payload(fixture, "time.txt")
        let preview = try service.preview(configuration: config(fixture), payload: item, metadata: metadata())
        try service.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in fixture.load() })
        let row = try XCTUnwrap(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).split(separator: "\n").last.map(String.init))
        let cells = MarkdownTable.cells(row)
        XCTAssertEqual(cells[13], cells[14])
        XCTAssertEqual(cells[13], ISO8601DateFormatter().string(from: date))
        XCTAssertEqual(journal.journals.last?.timestamp, date)
    }

    func testHashAndHighWaterChangesBeforeCommitAreRejectedWithoutWrites() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/conflict.txt")
        let service = service(journal: MemoryJournal()); let item = try payload(fixture, "conflict.txt")
        let preview = try service.preview(configuration: config(fixture), payload: item, metadata: metadata())
        fixture.replaceLedger(fixture.identifierLedger.replacingOccurrences(of: "| 1 |", with: "| 2 |"))
        XCTAssertThrowsError(try service.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in fixture.load() }))
        XCTAssertFalse(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("conflict.txt"))
    }

    func testConcurrentAttemptAndDuplicateRegistrationAreRejected() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/duplicate.txt")
        let item = try payload(fixture, "duplicate.txt"); let cfg = config(fixture)
        let preview = try service(journal: MemoryJournal()).preview(configuration: cfg, payload: item, metadata: metadata())
        let held = LocalFlowRegistrationLocking().acquire(ledgerURL: cfg.url("Warehouse/Reference/Identifier Ledger.md"))
        XCTAssertNotNil(held)
        XCTAssertThrowsError(try service(journal: MemoryJournal()).commit(configuration: cfg, payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in fixture.load() }))
        withExtendedLifetime(held) {}
        fixture.replaceFlow(fixture.flow + "\n| FLOW-000002 | Duplicate | Note | Inbox | Low | Office | Office | — | test | — | `Office/Inbox/duplicate.txt` | duplicate | Review | 2026-08-11 | 2026-08-11 |")
        XCTAssertThrowsError(try service(journal: MemoryJournal()).preview(configuration: cfg, payload: item, metadata: metadata()))
    }

    func testMissingHiddenNestedAndSymlinkPayloadsAreRejected() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let cfg = config(fixture); let service = service(journal: MemoryJournal())
        let missing = FlowItem(viewIdentity: "missing", flowID: nil, label: "missing", type: "Inbox payload", stage: "Inbox", priority: "", location: "Office/Inbox/missing.txt", summary: "", bundleContent: nil)
        XCTAssertThrowsError(try service.preview(configuration: cfg, payload: missing, metadata: metadata()))
        try fixture.add("hidden", at: "Office/Inbox/.hidden")
        let hidden = FlowItem(viewIdentity: "hidden", flowID: nil, label: ".hidden", type: "Inbox payload", stage: "Inbox", priority: "", location: "Office/Inbox/.hidden", summary: "", bundleContent: nil)
        XCTAssertThrowsError(try service.preview(configuration: cfg, payload: hidden, metadata: metadata()))
        let nested = FlowItem(viewIdentity: "nested", flowID: nil, label: "nested", type: "Inbox payload", stage: "Inbox", priority: "", location: "Office/Inbox/folder/child.txt", summary: "", bundleContent: nil)
        XCTAssertThrowsError(try service.preview(configuration: cfg, payload: nested, metadata: metadata()))
        let link = fixture.root.appending(path: "Office/Inbox/link")
        XCTAssertEqual(symlink("/tmp", link.path), 0)
        let symlinkItem = FlowItem(viewIdentity: "link", flowID: nil, label: "link", type: "Inbox payload", stage: "Inbox", priority: "", location: "Office/Inbox/link", summary: "", bundleContent: nil)
        XCTAssertThrowsError(try service.preview(configuration: cfg, payload: symlinkItem, metadata: metadata()))
    }

    func testPayloadDeletionOrRenameAfterPreviewIsRejectedWithoutWrites() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/vanishing.txt")
        let cfg = config(fixture); let item = try payload(fixture, "vanishing.txt"); let service = service(journal: MemoryJournal())
        let preview = try service.preview(configuration: cfg, payload: item, metadata: metadata())
        try FileManager.default.moveItem(at: fixture.root.appending(path: "Office/Inbox/vanishing.txt"), to: fixture.root.appending(path: "Office/Inbox/renamed.txt"))
        XCTAssertThrowsError(try service.commit(configuration: cfg, payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in fixture.load() }))
        XCTAssertEqual(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self), fixture.identifierLedger)
    }

    func testJournalPersistenceFailureLeavesBothFilesUntouched() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/journal.txt")
        let journal = MemoryJournal(); journal.failPersistence = true
        let item = try payload(fixture, "journal.txt"); let svc = service(journal: journal)
        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: metadata())
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try svc.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in fixture.load() }))
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testInvalidMetadataAndMalformedReplacementAreRejectedBeforeJournal() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/invalid.txt")
        let item = try payload(fixture, "invalid.txt"); let journal = MemoryJournal()
        XCTAssertThrowsError(try service(journal: journal).preview(configuration: config(fixture), payload: item, metadata: FlowRegistrationMetadata(label: "bad|label", type: "Note", summary: "summary", nextDisposition: "Review")))
        XCTAssertThrowsError(try service(journal: journal).preview(configuration: config(fixture), payload: item, metadata: FlowRegistrationMetadata(label: "label", type: "Note", summary: "line\nbreak", nextDisposition: "Review")))
        fixture.replaceFlow("| Entry ID | Label | Type | Stage | Priority | Steward | Department | Product | Source | Related work | Location | Summary | Next disposition | Created |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
        XCTAssertThrowsError(try service(journal: journal).preview(configuration: config(fixture), payload: item, metadata: metadata()))
        XCTAssertTrue(journal.journals.isEmpty)
    }

    func testLedgerFailureIsPreCommitAndFlowFailureRetiresIdentifier() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/fail.txt")
        let cfg = config(fixture); let item = try payload(fixture, "fail.txt")
        let ledgerFailure = MemoryJournal(); let firstFailure = ControlledReplacer(failOn: 1)
        let preview = try service(journal: ledgerFailure, replacer: firstFailure).preview(configuration: cfg, payload: item, metadata: metadata())
        XCTAssertThrowsError(try service(journal: ledgerFailure, replacer: firstFailure).commit(configuration: cfg, payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in fixture.load() }))
        XCTAssertEqual(ledgerFailure.journals.last?.terminalState, .preCommitFailure)
        XCTAssertEqual(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self), fixture.identifierLedger)

        let flowFailure = MemoryJournal(); let secondFailure = ControlledReplacer(failOn: 2)
        let secondPreview = try service(journal: flowFailure, replacer: secondFailure).preview(configuration: cfg, payload: item, metadata: metadata())
        XCTAssertThrowsError(try service(journal: flowFailure, replacer: secondFailure).commit(configuration: cfg, payload: item, metadata: metadata(), preview: secondPreview, expectedPayloadState: secondPreview.payloadState, reload: { _ in fixture.load() }))
        XCTAssertEqual(flowFailure.journals.last?.terminalState, .ledgerCommitted)
        XCTAssertTrue(service(journal: flowFailure).startupRecovery().contains { $0.flowID == "FLOW-000002" })
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("| FLOW | 6 | 2 |"))
    }

    func testReloadFailureIsCommittedInvestigationNotRetryable() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/reload.txt")
        let journal = MemoryJournal(); let svc = service(journal: journal); let item = try payload(fixture, "reload.txt")
        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: metadata())
        XCTAssertThrowsError(try svc.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, expectedPayloadState: preview.payloadState, reload: { configuration in
            ProductionsState(configuration: configuration, inbox: [], processing: [], work: [], canvas: [], crumbs: [], mementos: [], issues: [.malformed("simulated reload failure")])
        }))
        XCTAssertEqual(journal.journals.last?.terminalState, .bothCommittedReloadFailed)
        XCTAssertFalse(svc.startupRecovery().contains { $0.flowID == "FLOW-000002" })
    }

    func testDurableReplacementPreservesPermissionsAndLeavesNoTemporaryFile() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "DurableReplacementTests-\(UUID())", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "target.md")
        try Data("before".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)
        try DurableReplacement().replace(data: Data("after".utf8), at: target)
        XCTAssertEqual(try Data(contentsOf: target), Data("after".utf8))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.contains(".tmp-") }, [])
    }

    private func config(_ fixture: SyntheticProductionsFixture) -> ProductionsConfiguration { ProductionsConfiguration(schemaVersion: 2, productionsRootPath: fixture.root.path) }
    private func metadata() -> FlowRegistrationMetadata { FlowRegistrationMetadata(label: "New Inbox Item", type: "Note", summary: "Synthetic summary", nextDisposition: "Review") }
    private func payload(_ fixture: SyntheticProductionsFixture, _ name: String) throws -> FlowItem { try XCTUnwrap(fixture.load().inbox.first { $0.label == name }) }
    private func service(journal: MemoryJournal, replacer: (any AtomicFileReplacing)? = nil, clock: TestClock? = nil) -> FlowRegistrationService { FlowRegistrationService(journalStore: journal, replacer: replacer, now: { clock?.value ?? self.date }) }
}

private final class MemoryJournal: FlowRegistrationJournalStore {
    var journals: [FlowRegistrationJournal] = []
    var failPersistence = false
    func persist(_ journal: FlowRegistrationJournal) throws { if failPersistence { throw NSError(domain: "test", code: 1) }; journals.append(journal) }
    func update(_ journal: FlowRegistrationJournal) throws { guard let index = journals.firstIndex(where: { $0.transactionID == journal.transactionID }) else { throw NSError(domain: "test", code: 2) }; journals[index] = journal }
    func incomplete() throws -> [FlowRegistrationJournal] { journals.filter { $0.terminalState != .bothFilesCommitted && $0.terminalState != .bothCommittedReloadFailed } }
}

private final class ControlledReplacer: AtomicFileReplacing {
    private let failOn: Int
    private var count = 0
    init(failOn: Int) { self.failOn = failOn }
    func replace(data: Data, at target: URL) throws {
        count += 1
        if count == failOn { throw NSError(domain: "test", code: 3, userInfo: [NSLocalizedDescriptionKey: "simulated replacement interruption"]) }
        try DurableReplacement().replace(data: data, at: target)
    }
}

private final class TestClock { var value: Date; init(_ value: Date) { self.value = value }; func advance(_ seconds: TimeInterval) { value = value.addingTimeInterval(seconds) } }


final class DispatchInboxIntakeSchedulerTests: XCTestCase {
    func testExecutesRetainedCallbackOnMainRunLoop() {
        let fired = expectation(description: "dispatch scheduler callback")
        let scheduler = DispatchInboxIntakeScheduler()
        let work = scheduler.schedule(after: 0.05) {
            XCTAssertTrue(Thread.isMainThread)
            fired.fulfill()
        }
        withExtendedLifetime(work) {
            wait(for: [fired], timeout: 1)
        }
    }
}

private final class ManualIntakeScheduler: InboxIntakeScheduling {
    private final class Work: InboxIntakeScheduledWork {
        var cancelled = false
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        func cancel() { cancelled = true }
    }
    private var work: [Work] = []
    var pendingCount: Int { work.filter { !$0.cancelled }.count }
    func schedule(after delay: TimeInterval, action: @escaping () -> Void) -> any InboxIntakeScheduledWork {
        let next = Work(action); work.append(next); return next
    }
    func runNext() {
        guard let index = work.firstIndex(where: { !$0.cancelled }) else { return }
        let next = work.remove(at: index)
        if !next.cancelled { next.action() }
    }
}
