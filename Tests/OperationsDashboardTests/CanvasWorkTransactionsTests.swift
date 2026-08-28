import Foundation
import XCTest
@testable import OperationsDashboard

final class CanvasWorkTransactionsTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-13T18:30:00Z")!

    func testStartWorkPlacesThenEngagesAnInactiveTargetInOneReplacement() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas + "\n\n## Rules\n\nKeep history.")
        let journal = MemoryCanvasJournal()
        let result = try service(journal: journal).perform(
            action: .start,
            configuration: config(fixture),
            work: task(fixture),
            reason: "Approved work began.",
            context: "Implement the bounded transaction.",
            reload: { _ in fixture.load() }
        )

        XCTAssertEqual(result.appendedEvents, ["Placed", "Engaged"])
        let rows = try canvasRows(fixture)
        XCTAssertEqual(rows.map { $0["Event"]! }, ["Placed", "Engaged"])
        XCTAssertEqual(rows.map { $0["Occurred"]! }, ["2026-08-13T18:30:00Z", "2026-08-13T18:30:00Z"])
        XCTAssertEqual(rows.map { $0["Work ID"]! }, ["TASK-000001", "TASK-000001"])
        XCTAssertTrue(String(decoding: try fixture.data(at: "Office/Threads/Canvas.md"), as: UTF8.self).hasSuffix("## Rules\n\nKeep history."))
        XCTAssertTrue(fixture.load().canvasCurrentIDs.contains("TASK-000001"))
        XCTAssertEqual(journal.journals.last?.terminalState, .committed)
        XCTAssertEqual(journal.journals.last?.appendedEvents, ["Placed", "Engaged"])
    }

    func testStartWorkOnCurrentTargetAppendsOnlyEngaged() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try canvasRows(fixture)
        let result = try service().perform(action: .start, configuration: config(fixture), work: task(fixture), reason: "Resume.", context: "Continue current work.", reload: { _ in fixture.load() })
        let rows = try canvasRows(fixture)
        XCTAssertEqual(result.appendedEvents, ["Engaged"])
        XCTAssertEqual(rows.count, before.count + 1)
        XCTAssertEqual(rows.last?["Event"], "Engaged")
        XCTAssertTrue(fixture.load().canvasCurrentIDs.contains("TASK-000001"))
    }

    func testStopWorkAppendsClearedWithoutChangingRegistry() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let registryBefore = try fixture.data(at: "Office/Registry/Tasks.md")
        let result = try service().perform(action: .stop, configuration: config(fixture), work: task(fixture), reason: "Deferral.", context: "Resume after approval.", reload: { _ in fixture.load() })
        XCTAssertEqual(result.appendedEvents, ["Cleared"])
        XCTAssertEqual(try canvasRows(fixture).last?["Event"], "Cleared")
        XCTAssertFalse(fixture.load().canvasCurrentIDs.contains("TASK-000001"))
        XCTAssertEqual(try fixture.data(at: "Office/Registry/Tasks.md"), registryBefore)
    }

    func testStopWorkRejectsInactiveTargetWithoutWritingOrJournaling() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let before = try fixture.snapshot(); let journal = MemoryCanvasJournal()
        XCTAssertThrowsError(try service(journal: journal).perform(action: .stop, configuration: config(fixture), work: task(fixture), reason: "Deferral.", context: "Later.", reload: { _ in fixture.load() })) { error in
            XCTAssertEqual(error as? CanvasWorkTransactionError, .notCurrent)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(journal.journals.isEmpty)
    }

    @MainActor
    func testPassiveLoadingSelectionAndViewModelConstructionDoNotWriteCanvas() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        _ = fixture.load()
        let model = try makeViewModel(fixture)
        model.selectedID = "TASK-000001"
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    @MainActor
    func testViewModelRequiresExplicitActionAndReloadsVisibleMembership() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let model = try makeViewModel(fixture)
        let work = try XCTUnwrap(model.state?.work.first)
        model.performCanvasAction(.start, work: work, reason: "Approved work began.", context: "Explicit test action.")
        XCTAssertTrue(model.state?.canvasCurrentIDs.contains(work.id) == true)
        XCTAssertTrue(model.message?.hasPrefix("Focused TASK-000001. Operation ") == true)
        XCTAssertNil(model.sessionPackage)
    }

    func testInvalidFieldsAndUnregisteredTargetsAreRejectedBeforeJournal() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let journal = MemoryCanvasJournal(); let before = try fixture.snapshot()
        XCTAssertThrowsError(try service(journal: journal).perform(action: .start, configuration: config(fixture), work: task(fixture), reason: "bad|reason", context: "test", reload: { _ in fixture.load() }))
        let missing = WorkItem(id: "TASK-999999", kind: .task, title: "Missing", lifecycle: "Active / Current", priority: "High", lead: "Office", department: "", product: "", workspacePath: "Workspace/TASK-999999/TASK-999999.md", related: [], content: nil)
        XCTAssertThrowsError(try service(journal: journal).perform(action: .start, configuration: config(fixture), work: missing, reason: "Start.", context: "Test.", reload: { _ in fixture.load() }))
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(journal.journals.isEmpty)
    }

    func testMalformedBaselineStopsBeforeJournalAndWrite() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas("| not a Canvas table |")
        let before = try fixture.snapshot(); let journal = MemoryCanvasJournal()
        XCTAssertThrowsError(try service(journal: journal).perform(action: .start, configuration: config(fixture), work: WorkItem(id: "TASK-000001", kind: .task, title: "Synthetic task", lifecycle: "Active / Current", priority: "High", lead: "Office", department: "", product: "", workspacePath: "Workspace/TASK-000001/TASK-000001.md", related: [], content: nil), reason: "Start.", context: "Test.", reload: { _ in fixture.load() })) { error in
            guard case .conflict = error as? CanvasWorkTransactionError else { return XCTFail("Expected contract conflict, got \(error)") }
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(journal.journals.isEmpty)
    }

    func testFragmentedBaselineBlocksStartAndStopBeforeJournalAndWrite() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas + "\n| 2026-08-13T18:29:00Z | TASK-000001 | Placed | Earlier. | Test. |\n\n| 2026-08-13T18:29:30Z | TASK-000001 | Cleared | Later. | Fragmented. |")
        let before = try fixture.snapshot(); let journal = MemoryCanvasJournal()

        for action in [CanvasWorkAction.start, .stop] {
            XCTAssertThrowsError(try service(journal: journal).perform(action: action, configuration: config(fixture), work: task(fixture), reason: "Authorized action.", context: "Test.", reload: { _ in fixture.load() })) { error in
                guard case .conflict = error as? CanvasWorkTransactionError else { return XCTFail("Expected contract conflict, got \(error)") }
            }
        }

        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(journal.journals.isEmpty)
    }

    func testLockConflictStopsBeforeJournalAndWrite() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let journal = MemoryCanvasJournal(); let before = try fixture.snapshot()
        let denied = CanvasWorkTransactionService(journalStore: journal, locking: DeniedCanvasLock(), now: { self.date })
        XCTAssertThrowsError(try denied.perform(action: .start, configuration: config(fixture), work: task(fixture), reason: "Start.", context: "Test.", reload: { _ in fixture.load() })) { error in
            XCTAssertEqual(error as? CanvasWorkTransactionError, .lockUnavailable)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(journal.journals.isEmpty)
    }

    func testConcurrentMutationAfterJournalIsNotOverwritten() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let concurrent = emptyCanvas + "\n| 2026-08-13T18:29:00Z | TASK-000001 | Cleared | Concurrent. | External writer. |"
        let journal = MutatingCanvasJournal { fixture.replaceCanvas(concurrent) }
        XCTAssertThrowsError(try service(journal: journal).perform(action: .start, configuration: config(fixture), work: task(fixture), reason: "Start.", context: "Test.", reload: { _ in fixture.load() })) { error in
            guard case .conflict = error as? CanvasWorkTransactionError else { return XCTFail("Expected conflict, got \(error)") }
        }
        XCTAssertEqual(String(decoding: try fixture.data(at: "Office/Threads/Canvas.md"), as: UTF8.self), concurrent)
        XCTAssertEqual(journal.journals.last?.terminalState, .definiteNoCommit)
    }

    func testJournalAndReplacementFailuresLeaveCanvasUntouched() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let canvasBefore = try fixture.data(at: "Office/Threads/Canvas.md")
        let journalFailure = MemoryCanvasJournal(); journalFailure.failPersistence = true
        XCTAssertThrowsError(try service(journal: journalFailure).perform(action: .start, configuration: config(fixture), work: task(fixture), reason: "Start.", context: "Test.", reload: { _ in fixture.load() }))
        XCTAssertEqual(try fixture.data(at: "Office/Threads/Canvas.md"), canvasBefore)

        let replacementJournal = MemoryCanvasJournal()
        let replacementFailure = CanvasWorkTransactionService(journalStore: replacementJournal, replacer: FailingCanvasReplacer(), now: { self.date })
        XCTAssertThrowsError(try replacementFailure.perform(action: .start, configuration: config(fixture), work: task(fixture), reason: "Start.", context: "Test.", reload: { _ in fixture.load() }))
        XCTAssertEqual(try fixture.data(at: "Office/Threads/Canvas.md"), canvasBefore)
        XCTAssertEqual(replacementJournal.journals.last?.terminalState, .definiteNoCommit)
    }

    func testCommittedReloadFailureIsReportedForInvestigationWithoutRetry() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let journal = MemoryCanvasJournal()
        var reloadCount = 0
        XCTAssertThrowsError(try service(journal: journal).perform(action: .start, configuration: config(fixture), work: task(fixture), reason: "Start.", context: "Test.", reload: { configuration in
            reloadCount += 1
            if reloadCount == 1 { return fixture.load() }
            return ProductionsState(configuration: configuration, inbox: [], processing: [], work: [], canvas: [], crumbs: [], mementos: [], issues: [.malformed("simulated reload failure")])
        })) { error in
            guard case .reloadFailed = error as? CanvasWorkTransactionError else { return XCTFail("Expected reload failure, got \(error)") }
        }
        XCTAssertEqual(try canvasRows(fixture).map { $0["Event"]! }, ["Placed", "Engaged"])
        XCTAssertEqual(journal.journals.last?.terminalState, .committedReloadFailed)
        XCTAssertTrue(service(journal: journal).startupRecovery().isEmpty)
    }

    func testExistingRecoveryJournalBytesRemainDecodableAfterOperationIdentityExtension() throws {
        let legacy = LegacyCanvasJournal(
            transactionID: UUID(),
            timestamp: date,
            action: .start,
            workID: "TASK-000001",
            canvasHash: "hash",
            canvasPreimage: Data(emptyCanvas.utf8),
            appendedEvents: ["Placed", "Engaged"],
            terminalState: .preCommitFailure,
            diagnostic: "Legacy journal."
        )

        let decoded = try JSONDecoder().decode(CanvasWorkTransactionJournal.self, from: JSONEncoder().encode(legacy))

        XCTAssertEqual(decoded.transactionID, legacy.transactionID)
        XCTAssertNil(decoded.reason)
        XCTAssertNil(decoded.context)
        XCTAssertNil(decoded.targetHash)
        XCTAssertNil(decoded.expectedCanvasHash)
        XCTAssertTrue(decoded.terminalState?.isIncomplete == true, "Legacy preCommitFailure journals remain visible because older replacement exceptions were not outcome-safe.")
    }

    func testHistoricalCommitProofCannotBeDowngradedByAnyNonProvingTransition() {
        let provingStates: [CanvasWorkTransactionTerminalState] = [
            .committed,
            .reconciledCommit,
            .historicalCommitSuperseded,
            .historicallyCommittedWithCurrentStateUncertain,
            .committedReloadFailed,
            .journalFinalizationFailedCommittedAndCurrentlySatisfied,
            .journalFinalizationFailedHistoricallyCommittedAndSuperseded,
            .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain,
        ]
        let nonProvingStates: [CanvasWorkTransactionTerminalState] = [
            .preCommitFailure,
            .definiteNoCommit,
            .alreadyDesired,
            .uncertain,
        ]

        for current in provingStates {
            XCTAssertTrue(current.provesHistoricalCommit)
            for proposed in nonProvingStates {
                XCTAssertTrue(
                    CanvasWorkTransactionTerminalState.merging(current: current, proposed: proposed).provesHistoricalCommit,
                    "\(current.rawValue) was downgraded by \(proposed.rawValue)"
                )
            }
        }
    }

    private var emptyCanvas: String {
        "| Occurred | Work ID | Event | Reason | Context |\n| --- | --- | --- | --- | --- |"
    }

    private func config(_ fixture: SyntheticProductionsFixture) -> ProductionsConfiguration {
        ProductionsConfiguration(schemaVersion: 2, productionsRootPath: fixture.root.path)
    }

    private func task(_ fixture: SyntheticProductionsFixture) throws -> WorkItem {
        try XCTUnwrap(fixture.load().work.first { $0.id == "TASK-000001" })
    }

    private func canvasRows(_ fixture: SyntheticProductionsFixture) throws -> [[String: String]] {
        try MarkdownTable.parse(String(decoding: fixture.data(at: "Office/Threads/Canvas.md"), as: UTF8.self), required: ["Occurred", "Work ID", "Event", "Reason", "Context"])
    }

    private func service(journal: MemoryCanvasJournal = MemoryCanvasJournal()) -> CanvasWorkTransactionService {
        CanvasWorkTransactionService(journalStore: journal, now: { self.date })
    }

    @MainActor
    private func makeViewModel(_ fixture: SyntheticProductionsFixture) throws -> ProductionsDashboardViewModel {
        let journal = MemoryCanvasJournal()
        return ProductionsDashboardViewModel(reader: LocalFileSystem(), canvasWorkService: service(journal: journal), initialConfiguration: config(fixture))
    }
}

private struct LegacyCanvasJournal: Codable {
    let transactionID: UUID
    let timestamp: Date
    let action: CanvasWorkAction
    let workID: String
    let canvasHash: String
    let canvasPreimage: Data
    let appendedEvents: [String]
    let terminalState: CanvasWorkTransactionTerminalState?
    let diagnostic: String?
}

private class MemoryCanvasJournal: CanvasWorkTransactionJournalStore {
    var journals: [CanvasWorkTransactionJournal] = []
    var failPersistence = false

    func persist(_ journal: CanvasWorkTransactionJournal) throws {
        if failPersistence { throw NSError(domain: "CanvasWorkTransactionsTests", code: 1) }
        journals.append(journal)
    }

    func update(_ journal: CanvasWorkTransactionJournal) throws {
        guard let index = journals.firstIndex(where: { $0.transactionID == journal.transactionID }) else {
            throw NSError(domain: "CanvasWorkTransactionsTests", code: 2)
        }
        journals[index] = journal
    }

    func incomplete() throws -> [CanvasWorkTransactionJournal] {
        journals.filter { $0.terminalState?.isIncomplete ?? true }
    }
}

private final class MutatingCanvasJournal: MemoryCanvasJournal {
    let mutate: () -> Void
    init(mutate: @escaping () -> Void) { self.mutate = mutate }
    override func persist(_ journal: CanvasWorkTransactionJournal) throws {
        try super.persist(journal)
        mutate()
    }
}

private struct DeniedCanvasLock: CanvasWorkTransactionLocking {
    func acquire(canvasURL: URL) -> AnyObject? { nil }
}

private struct FailingCanvasReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { throw NSError(domain: "CanvasWorkTransactionsTests", code: 3) }
}
