import Foundation
import XCTest
@testable import OperationsDashboard

final class CanvasAttentionOperationsTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-27T18:00:00Z")!
    private let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000076")!

    func testSessionStopReviewCheckpointAndRoutinePhaseCannotClearTaskAttention() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try fixture.data(at: ProductionsPath.canvas.rawValue)
        let journal = AttentionJournal()
        var generatedOperationID = false
        let service = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, now: { self.date }),
            makeOperationID: { generatedOperationID = true; return self.operationID }
        )

        for context in ["Session stopped.", "Independent review handoff.", "Checkpoint administration.", "Routine next phase."] {
            XCTAssertThrowsError(
                try service.perform(
                    desiredState: .clear,
                    configuration: fixture.configuration,
                    work: task(fixture),
                    reason: "Routine boundary.",
                    context: context,
                    reload: { _ in fixture.load() }
                )
            ) { error in
                XCTAssertEqual(error as? CanvasContinuityPolicyError, .clearBasisRequired)
            }
        }

        XCTAssertFalse(generatedOperationID)
        XCTAssertTrue(journal.journals.isEmpty)
        XCTAssertEqual(try fixture.data(at: ProductionsPath.canvas.rawValue), before)
        XCTAssertTrue(fixture.load().canvasCurrentIDs.contains("TASK-000001"))
    }

    func testActiveOwnerPursuitRemainsCurrentAcrossRoutinePhaseChain() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try rows(fixture)
        let journal = AttentionJournal()
        let service = attention(journal: journal)

        for context in ["Implementation.", "Independent review.", "Canonical checkpoint.", "Next routine phase."] {
            let result = try service.perform(
                desiredState: .focused,
                configuration: fixture.configuration,
                work: task(fixture),
                reason: "Continue active owner pursuit.",
                context: context,
                reload: { _ in fixture.load() }
            )
            XCTAssertEqual(result.disposition, .alreadyDesired)
            XCTAssertTrue(result.appendedEvents.isEmpty)
        }

        XCTAssertEqual(try rows(fixture), before)
        XCTAssertTrue(fixture.load().canvasCurrentIDs.contains("TASK-000001"))
        XCTAssertEqual(journal.journals.count, 4)
        XCTAssertTrue(journal.journals.allSatisfy { $0.terminalState == .alreadyDesired && $0.action == .start })
    }

    func testEveryAllowedClearBasisIsDurablyAuditable() throws {
        let cases: [(CanvasClearBasis, String)] = [
            (.ownerPause, "Active / Current"),
            (.ownerStop, "Active / Current"),
            (.completed, "Done / Complete"),
            (.obsolete, "Done / Obsolete"),
            (.indefiniteExternalWait, "Active / Blocked"),
        ]

        for (basis, lifecycle) in cases {
            let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
            try replaceLifecycle(lifecycle, fixture: fixture)
            let journal = AttentionJournal()
            let result = try attention(journal: journal).perform(
                desiredState: .clear,
                configuration: fixture.configuration,
                work: task(fixture),
                reason: "Owner-authorized task boundary.",
                context: "Continuity regression.",
                clearBasis: basis,
                reload: { _ in fixture.load() }
            )

            XCTAssertEqual(result.clearBasis, basis)
            XCTAssertEqual(result.appendedEvents, ["Cleared"])
            XCTAssertEqual(journal.journals.last?.clearBasis, basis)
            XCTAssertEqual(try rows(fixture).last?["Context"], "\(basis.auditContextPrefix) Continuity regression.")
        }
    }

    func testTerminalClearBasisMustMatchCanonicalLifecycleBeforeJournal() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try fixture.data(at: ProductionsPath.canvas.rawValue)
        let journal = AttentionJournal()
        var generatedOperationID = false
        let service = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, now: { self.date }),
            makeOperationID: { generatedOperationID = true; return self.operationID }
        )

        for basis in [CanvasClearBasis.completed, .obsolete] {
            XCTAssertThrowsError(
                try service.perform(
                    desiredState: .clear,
                    configuration: fixture.configuration,
                    work: task(fixture),
                    reason: "Invalid terminal boundary.",
                    context: "Continuity regression.",
                    clearBasis: basis,
                    reload: { _ in fixture.load() }
                )
            ) { error in
                XCTAssertEqual(error as? CanvasContinuityPolicyError, .lifecycleMismatch(basis, "Active / Current"))
            }
        }

        XCTAssertFalse(generatedOperationID)
        XCTAssertTrue(journal.journals.isEmpty)
        XCTAssertEqual(try fixture.data(at: ProductionsPath.canvas.rawValue), before)
    }

    func testFocusAndClearAreIdempotentDesiredStateOperations() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let journal = AttentionJournal()
        let service = attention(journal: journal)

        let focused = try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })
        let rowCount = try rows(fixture).count
        let focusedAgain = try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })

        XCTAssertEqual(focused.disposition, .changed)
        XCTAssertEqual(focused.appendedEvents, ["Placed", "Engaged"])
        XCTAssertEqual(focusedAgain.disposition, .alreadyDesired)
        XCTAssertEqual(try rows(fixture).count, rowCount)

        let cleared = try service.perform(desiredState: .clear, configuration: fixture.configuration, work: task(fixture), reason: "Clear.", context: "Test.", clearBasis: .ownerStop, reload: { _ in fixture.load() })
        let clearedCount = try rows(fixture).count
        let clearedAgain = try service.perform(desiredState: .clear, configuration: fixture.configuration, work: task(fixture), reason: "Clear.", context: "Test.", clearBasis: .ownerStop, reload: { _ in fixture.load() })

        XCTAssertEqual(cleared.disposition, .changed)
        XCTAssertEqual(cleared.appendedEvents, ["Cleared"])
        XCTAssertEqual(cleared.clearBasis, .ownerStop)
        XCTAssertEqual(journal.journals.last?.clearBasis, .ownerStop)
        XCTAssertTrue(journal.journals.last?.context?.hasPrefix("Canvas clear basis: owner-stop.") == true)
        XCTAssertEqual(clearedAgain.disposition, .alreadyDesired)
        XCTAssertEqual(try rows(fixture).count, clearedCount)
    }

    func testBoundedLockWaitRetriesOnlyDefinitePremutationContentionWithoutBusyLoop() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let lock = SequencedAttentionLock(failures: 2)
        let journal = AttentionJournal()
        var delays: [TimeInterval] = []
        let canvas = CanvasWorkTransactionService(journalStore: journal, locking: lock, now: { self.date })
        let service = CanvasAttentionOperationService(canvas: canvas, retryPolicy: .init(maximumAttempts: 3, delay: 0.25), sleep: { delays.append($0) }, makeOperationID: { self.operationID })

        let result = try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })

        XCTAssertEqual(result.disposition, .changed)
        XCTAssertEqual(lock.attempts, 3)
        XCTAssertEqual(delays, [0.25, 0.25])
        XCTAssertEqual(journal.journals.count, 1)
    }

    func testExhaustedLockWaitIsDefiniteAndDoesNotJournalOrWrite() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let before = try fixture.data(at: ProductionsPath.canvas.rawValue)
        let lock = SequencedAttentionLock(failures: 4)
        let journal = AttentionJournal()
        let canvas = CanvasWorkTransactionService(journalStore: journal, locking: lock, now: { self.date })
        let service = CanvasAttentionOperationService(canvas: canvas, retryPolicy: .init(maximumAttempts: 3, delay: 0), sleep: { _ in }, makeOperationID: { self.operationID })

        XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
            XCTAssertEqual($0 as? CanvasWorkTransactionError, .lockUnavailable)
        }
        XCTAssertEqual(lock.attempts, 3)
        XCTAssertTrue(journal.journals.isEmpty)
        XCTAssertEqual(try fixture.data(at: ProductionsPath.canvas.rawValue), before)
    }

    func testDefaultPolicyMakesExactlyFourLockAttemptsAndThreeBoundedDelays() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let lock = SequencedAttentionLock(failures: 10)
        var delays: [TimeInterval] = []
        let canvas = CanvasWorkTransactionService(journalStore: AttentionJournal(), locking: lock, now: { self.date })
        let service = CanvasAttentionOperationService(canvas: canvas, sleep: { delays.append($0) }, makeOperationID: { self.operationID })

        XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
            XCTAssertEqual($0 as? CanvasWorkTransactionError, .lockUnavailable)
        }
        XCTAssertEqual(lock.attempts, 4)
        XCTAssertEqual(delays, [0.15, 0.15, 0.15])
    }

    func testDefiniteReplacementFailureProvesNoCommitAndDoesNotRetry() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let before = try fixture.data(at: ProductionsPath.canvas.rawValue)
        let journal = AttentionJournal()
        let replacer = AlwaysFailingAttentionReplacer()
        let canvas = CanvasWorkTransactionService(journalStore: journal, replacer: replacer, now: { self.date })
        let service = CanvasAttentionOperationService(canvas: canvas, retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { self.operationID })

        XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
            XCTAssertEqual($0 as? CanvasOperationOutcomeError, .definiteNoCommit(self.operationID, journalFinalized: true))
        }
        XCTAssertEqual(try fixture.data(at: ProductionsPath.canvas.rawValue), before)
        XCTAssertEqual(journal.journals.count, 1)
        XCTAssertEqual(journal.journals.last?.terminalState, .definiteNoCommit)
        XCTAssertTrue(service.canvas.startupRecovery().isEmpty)
        XCTAssertEqual(replacer.attempts, 1)
        XCTAssertEqual(try service.reconcile(operationID: operationID, desiredState: .focused, configuration: fixture.configuration, work: task(fixture)), .notCommitted)
    }

    func testCommittedButResponseLostReconcilesFromCanonicalDesiredStateAndOperationIdentity() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let journal = AttentionJournal()
        let replacer = WriteThenThrowAttentionReplacer()
        let canvas = CanvasWorkTransactionService(journalStore: journal, replacer: replacer, now: { self.date })
        let service = CanvasAttentionOperationService(canvas: canvas, retryPolicy: .init(maximumAttempts: 2, delay: 0), sleep: { _ in }, makeOperationID: { self.operationID })

        let result = try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })

        XCTAssertEqual(result.operationID, operationID)
        XCTAssertEqual(result.disposition, .reconciled)
        XCTAssertTrue(fixture.load().canvasCurrentIDs.contains("TASK-000001"))
        XCTAssertEqual(replacer.attempts, 1)
        XCTAssertEqual(journal.journals.last?.terminalState, .reconciledCommit)
        XCTAssertTrue(service.canvas.startupRecovery().isEmpty)
        XCTAssertEqual(try service.reconcile(operationID: operationID, desiredState: .focused, configuration: fixture.configuration, work: task(fixture)), .committedAndCurrentlySatisfied)
    }

    func testMalformedPostFailureStateRemainsGenuinelyUncertain() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let journal = AttentionJournal()
        let replacer = MalformThenThrowAttentionReplacer()
        let canvas = CanvasWorkTransactionService(journalStore: journal, replacer: replacer, now: { self.date })
        let service = CanvasAttentionOperationService(canvas: canvas, retryPolicy: .init(maximumAttempts: 1, delay: 0), sleep: { _ in }, makeOperationID: { self.operationID })

        XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
            guard case let .uncertain(id, diagnostic) = $0 as? CanvasAttentionOperationError else { return XCTFail("Expected uncertain outcome, got \($0)") }
            XCTAssertEqual(id, self.operationID)
            XCTAssertTrue(diagnostic.contains("could not be inspected safely"))
        }
        guard case let .uncertain(diagnostic) = try service.reconcile(operationID: operationID, desiredState: .focused, configuration: fixture.configuration, work: task(fixture)) else {
            return XCTFail("Expected explicit reconciliation to remain uncertain.")
        }
        XCTAssertTrue(diagnostic.contains("could not be inspected safely"))
        XCTAssertEqual(replacer.attempts, 1)
        XCTAssertEqual(journal.journals.last?.terminalState, .uncertain)
        XCTAssertEqual(service.canvas.startupRecovery().map(\.transactionID), [operationID])
    }

    func testPartialFocusNeverReconcilesFromMembershipAloneAndWritesOnlyOnce() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let journal = AttentionJournal()
        let replacer = PartialFocusThenThrowAttentionReplacer()
        let canvas = CanvasWorkTransactionService(journalStore: journal, replacer: replacer, now: { self.date })
        let service = CanvasAttentionOperationService(canvas: canvas, retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { self.operationID })

        XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
            guard case .uncertain = $0 as? CanvasAttentionOperationError else { return XCTFail("Expected partial Focus uncertainty, got \($0)") }
        }
        XCTAssertTrue(fixture.load().canvasCurrentIDs.contains("TASK-000001"), "Placed alone creates matching membership, which is not sufficient reconciliation evidence.")
        XCTAssertEqual(replacer.attempts, 1)
        XCTAssertEqual(journal.journals.last?.terminalState, .uncertain)
        guard case .uncertain = try service.reconcile(operationID: operationID, desiredState: .focused, configuration: fixture.configuration, work: task(fixture)) else {
            return XCTFail("Partial Focus must remain uncertain during explicit reconciliation.")
        }
    }

    func testIndependentlyProducedMatchingFocusStateDoesNotProveThisOperation() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let journal = AttentionJournal()
        let replacer = IndependentFocusThenThrowAttentionReplacer()
        let canvas = CanvasWorkTransactionService(journalStore: journal, replacer: replacer, now: { self.date })
        let service = CanvasAttentionOperationService(canvas: canvas, retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { self.operationID })

        XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
            guard case .uncertain = $0 as? CanvasAttentionOperationError else { return XCTFail("Expected independent matching state to remain uncertain, got \($0)") }
        }
        XCTAssertTrue(fixture.load().canvasCurrentIDs.contains("TASK-000001"))
        XCTAssertEqual(replacer.attempts, 1)
        XCTAssertEqual(journal.journals.last?.terminalState, .uncertain)
    }

    func testHistoricalCommitWithLaterContraryBoundaryIsReportedAsSuperseded() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let journal = AttentionJournal()
        let replacer = WriteThenSupersedeAttentionReplacer()
        let canvas = CanvasWorkTransactionService(journalStore: journal, replacer: replacer, now: { self.date })
        let service = CanvasAttentionOperationService(canvas: canvas, retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { self.operationID })

        XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
            XCTAssertEqual($0 as? CanvasAttentionOperationError, .historicalCommitSuperseded(self.operationID))
        }
        XCTAssertFalse(fixture.load().canvasCurrentIDs.contains("TASK-000001"))
        XCTAssertEqual(replacer.attempts, 1)
        XCTAssertEqual(journal.journals.last?.terminalState, .historicalCommitSuperseded)
        XCTAssertTrue(service.canvas.startupRecovery().isEmpty)
        XCTAssertEqual(try service.reconcile(operationID: operationID, desiredState: .focused, configuration: fixture.configuration, work: task(fixture)), .historicallyCommittedAndSuperseded)
    }

    func testUnrelatedHistoricalIssueDoesNotBlockSafeTargetTransaction() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("# TASK-000002\n\n## Core Record\n\n```text\nTitle: Historical task\nID: TASK-000002\nType: Task\nObjective or question: Retain history.\nNext step: None.\nCompletion or resolution criterion: Retained.\nLast validated state: Historical.\nRelevant locations: \(fixture.root.path)\n```", at: "Workspace/TASK-000002/TASK-000002.md")
        let tasks = String(decoding: try fixture.data(at: ProductionsPath.tasks.rawValue), as: UTF8.self)
            + "\n| TASK-000002 | Historical task | Done / Complete | Unranked | Office | — | — | — | history | [task](../../Workspace/TASK-000002/TASK-000002.md) |"
        try fixture.add(tasks, at: ProductionsPath.tasks.rawValue)
        fixture.replaceCanvas(emptyCanvas + "\n| 2026-08-27T17:00:00Z | TASK-000002 | Cleared | Historical duplicate boundary. | Retained history. |")
        let journal = AttentionJournal()
        let service = attention(journal: journal)

        let result = try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { configuration in
            let loaded = fixture.load()
            return ProductionsState(configuration: configuration, inbox: loaded.inbox, processing: loaded.processing, work: loaded.work, products: loaded.products, departments: loaded.departments, canvas: loaded.canvas, crumbs: loaded.crumbs, mementos: loaded.mementos, issues: loaded.issues + [.malformed("historical transition defect for unrelated target")])
        })

        XCTAssertEqual(result.disposition, .changed)
        XCTAssertEqual(try rows(fixture).suffix(2).map { $0["Event"]! }, ["Placed", "Engaged"])
    }

    func testCanonicalTargetChangeStopsBeforeReplacement() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let before = try fixture.data(at: ProductionsPath.canvas.rawValue)
        let journal = AttentionJournal(afterPersist: {
            try? fixture.add(fixture.workspaceRecord + "\n\nChanged concurrently.", at: "Workspace/TASK-000001/TASK-000001.md")
        })
        let service = attention(journal: journal)

        XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
            guard case .conflict = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected target conflict, got \($0)") }
        }
        XCTAssertEqual(try fixture.data(at: ProductionsPath.canvas.rawValue), before)
    }

    func testLiveCanvasSchemaDefectStillStopsBeforeJournalOrWrite() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas + "\n| 2026-08-27T17:00:00Z | TASK-999999 | Placed | Unresolved. | Unsafe row. |")
        let before = try fixture.data(at: ProductionsPath.canvas.rawValue)
        let journal = AttentionJournal()
        let service = attention(journal: journal)

        XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
            guard case .conflict = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected live Canvas schema conflict, got \($0)") }
        }
        XCTAssertTrue(journal.journals.isEmpty)
        XCTAssertEqual(try fixture.data(at: ProductionsPath.canvas.rawValue), before)
    }

    func testRequestedTargetTransitionDefectsStopBeforeNoOpJournalOrMutation() throws {
        let histories = [
            ["Placed", "Placed"],
            ["Placed", "Cleared", "Cleared"],
            ["Engaged"]
        ]
        for events in histories {
            let fixture = try SyntheticProductionsFixture()
            let rows = events.enumerated().map { index, event in
                "| 2026-08-27T17:00:0\(index)Z | TASK-000001 | \(event) | Historical. | Invalid target transition. |"
            }.joined(separator: "\n")
            fixture.replaceCanvas(emptyCanvas + "\n" + rows)
            let before = try fixture.data(at: ProductionsPath.canvas.rawValue)
            let journal = AttentionJournal()
            let service = attention(journal: journal)

            XCTAssertThrowsError(try service.perform(desiredState: .focused, configuration: fixture.configuration, work: task(fixture), reason: "Focus.", context: "Test.", reload: { _ in fixture.load() })) {
                guard case .conflict = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected target-history conflict for \(events), got \($0)") }
            }
            XCTAssertTrue(journal.journals.isEmpty)
            XCTAssertEqual(try fixture.data(at: ProductionsPath.canvas.rawValue), before)
            fixture.remove()
        }
    }

    private var emptyCanvas: String { "| Occurred | Work ID | Event | Reason | Context |\n| --- | --- | --- | --- | --- |" }
    private func task(_ fixture: SyntheticProductionsFixture) throws -> WorkItem { try XCTUnwrap(fixture.load().work.first { $0.id == "TASK-000001" }) }
    private func rows(_ fixture: SyntheticProductionsFixture) throws -> [[String: String]] { try MarkdownTable.parse(String(decoding: fixture.data(at: ProductionsPath.canvas.rawValue), as: UTF8.self), required: CanvasMarkdown.headers) }
    private func attention(journal: AttentionJournal) -> CanvasAttentionOperationService {
        CanvasAttentionOperationService(canvas: CanvasWorkTransactionService(journalStore: journal, now: { self.date }), retryPolicy: .init(maximumAttempts: 1, delay: 0), sleep: { _ in }, makeOperationID: { self.operationID })
    }

    private func replaceLifecycle(_ lifecycle: String, fixture: SyntheticProductionsFixture) throws {
        let path = ProductionsPath.tasks.rawValue
        let current = String(decoding: try fixture.data(at: path), as: UTF8.self)
        try fixture.add(current.replacingOccurrences(of: "Active / Current", with: lifecycle), at: path)
    }
}

private final class AttentionJournal: CanvasWorkTransactionJournalStore {
    var journals: [CanvasWorkTransactionJournal] = []
    let afterPersist: (() -> Void)?
    init(afterPersist: (() -> Void)? = nil) { self.afterPersist = afterPersist }
    func persist(_ journal: CanvasWorkTransactionJournal) throws { journals.append(journal); afterPersist?() }
    func update(_ journal: CanvasWorkTransactionJournal) throws {
        guard let index = journals.firstIndex(where: { $0.transactionID == journal.transactionID }) else { throw CocoaError(.fileNoSuchFile) }
        journals[index] = journal
    }
    func incomplete() throws -> [CanvasWorkTransactionJournal] { journals.filter { $0.terminalState?.isIncomplete ?? true } }
    func journal(transactionID: UUID) throws -> CanvasWorkTransactionJournal? { journals.first { $0.transactionID == transactionID } }
}

private final class SequencedAttentionLock: CanvasWorkTransactionLocking {
    private let failures: Int
    private(set) var attempts = 0
    init(failures: Int) { self.failures = failures }
    func acquire(canvasURL: URL) -> AnyObject? {
        attempts += 1
        return attempts <= failures ? nil : NSObject()
    }
}

private final class AlwaysFailingAttentionReplacer: AtomicFileReplacing {
    private(set) var attempts = 0
    func replace(data: Data, at target: URL) throws { attempts += 1; throw CocoaError(.fileWriteUnknown) }
}

private final class WriteThenThrowAttentionReplacer: AtomicFileReplacing {
    private(set) var attempts = 0
    func replace(data: Data, at target: URL) throws {
        attempts += 1
        try DurableReplacement().replace(data: data, at: target)
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class MalformThenThrowAttentionReplacer: AtomicFileReplacing {
    private(set) var attempts = 0
    func replace(data: Data, at target: URL) throws {
        attempts += 1
        try DurableReplacement().replace(data: Data("| malformed |".utf8), at: target)
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class PartialFocusThenThrowAttentionReplacer: AtomicFileReplacing {
    private(set) var attempts = 0
    func replace(data: Data, at target: URL) throws {
        attempts += 1
        let partial = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("| Engaged |") }
            .joined(separator: "\n")
        try DurableReplacement().replace(data: Data(partial.utf8), at: target)
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class WriteThenSupersedeAttentionReplacer: AtomicFileReplacing {
    private(set) var attempts = 0
    func replace(data: Data, at target: URL) throws {
        attempts += 1
        var superseded = String(decoding: data, as: UTF8.self)
        if !superseded.hasSuffix("\n") { superseded += "\n" }
        superseded += "| 2026-08-27T18:00:01Z | TASK-000001 | Cleared | Later action. | Supersede the interrupted Focus. |\n"
        try DurableReplacement().replace(data: Data(superseded.utf8), at: target)
        throw CocoaError(.fileWriteUnknown)
    }
}

private final class IndependentFocusThenThrowAttentionReplacer: AtomicFileReplacing {
    private(set) var attempts = 0
    func replace(data: Data, at target: URL) throws {
        attempts += 1
        let independent = "| Occurred | Work ID | Event | Reason | Context |\n| --- | --- | --- | --- | --- |\n| 2026-08-27T18:00:02Z | TASK-000001 | Placed | Independent action. | Not this operation. |\n| 2026-08-27T18:00:02Z | TASK-000001 | Engaged | Independent action. | Not this operation. |"
        try DurableReplacement().replace(data: Data(independent.utf8), at: target)
        throw CocoaError(.fileWriteUnknown)
    }
}
