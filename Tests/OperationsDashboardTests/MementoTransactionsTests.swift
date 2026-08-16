import Foundation
import XCTest
@testable import OperationsDashboard

final class MementoTransactionsTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-15T22:30:00Z")!

    func testCreationIssuesUniqueIDAndCommitsMatchingTargetLedgerAndPayload() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let crumbBefore = try fixture.data(at: "Office/Threads/Crumbs.md")
        let journal = MemoryMementoJournal()
        let result = try service(journal: journal).create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(payload: "Supplementary captured file hash."), reload: { _ in fixture.load() })

        XCTAssertEqual(result.mementoID, "MEM-000002")
        let state = fixture.load(), memento = try XCTUnwrap(state.mementos.first)
        XCTAssertTrue(state.issues.isEmpty, state.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(memento.id, result.mementoID)
        XCTAssertEqual(memento.currentState, "Repository tests passed at captured commit.")
        XCTAssertEqual(memento.extendedPayloadContent, "Supplementary captured file hash.")
        XCTAssertEqual(try fixture.data(at: "Office/Threads/Crumbs.md"), crumbBefore)
        XCTAssertEqual(journal.journals.last?.terminalState, .committed)
    }

    func testSupersessionRetiresNewIDAndLeavesExactlyOneCurrentMemento() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let result = try service().supersede(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() })
        let state = fixture.load()
        XCTAssertEqual(result.mementoID, "MEM-000002")
        XCTAssertEqual(state.mementos.map(\.id), ["MEM-000002"])
        XCTAssertFalse(String(decoding: try fixture.data(at: "Office/Threads/Mementos.md"), as: UTF8.self).contains("MEM-000001"))
    }

    func testResolutionRemovesLiveStateButRetainsPayloadAndCrumbs() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        _ = try service().create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(payload: "Keep this history."), reload: { _ in fixture.load() })
        let payload = "Workspace/TASK-000001/MEM-000002.md", crumbs = try fixture.data(at: "Office/Threads/Crumbs.md")
        let result = try service().resolve(configuration: fixture.configuration, targetID: "TASK-000001", reload: { _ in fixture.load() })
        XCTAssertEqual(result.mementoID, "MEM-000002")
        XCTAssertTrue(fixture.load().mementos.isEmpty)
        XCTAssertFalse(String(decoding: try fixture.data(at: "Workspace/TASK-000001/TASK-000001.md"), as: UTF8.self).contains("## Current Memento"))
        XCTAssertEqual(String(decoding: try fixture.data(at: payload), as: UTF8.self), "Keep this history.")
        XCTAssertEqual(try fixture.data(at: "Office/Threads/Crumbs.md"), crumbs)
    }

    func testFailedPostIssuanceWriteRestoresBeforeCopiesAndNeverReusesID() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let targetBefore = try fixture.data(at: "Workspace/TASK-000001/TASK-000001.md"), ledgerBefore = try fixture.data(at: "Office/Threads/Mementos.md")
        let journal = MemoryMementoJournal(), replacer = FailOnceReplacer(failOn: 2)
        XCTAssertThrowsError(try service(journal: journal, replacer: replacer).create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() }))
        XCTAssertEqual(try fixture.data(at: "Workspace/TASK-000001/TASK-000001.md"), targetBefore)
        XCTAssertEqual(try fixture.data(at: "Office/Threads/Mementos.md"), ledgerBefore)
        XCTAssertEqual(journal.journals.last?.terminalState, .identifierRetiredRolledBack)
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("| 2 | `MEM-000003` |"))

        let next = try service().create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() })
        XCTAssertEqual(next.mementoID, "MEM-000003")
    }

    func testFirstReplacementFailureCompletesRetirementAndNeverReusesID() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let targetBefore = try fixture.data(at: "Workspace/TASK-000001/TASK-000001.md")
        let ledgerBefore = try fixture.data(at: "Office/Threads/Mementos.md")
        let journal = MemoryMementoJournal()

        XCTAssertThrowsError(try service(journal: journal, replacer: FailOnceReplacer(failOn: 1)).create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() }))

        XCTAssertEqual(try fixture.data(at: "Workspace/TASK-000001/TASK-000001.md"), targetBefore)
        XCTAssertEqual(try fixture.data(at: "Office/Threads/Mementos.md"), ledgerBefore)
        XCTAssertEqual(journal.journals.last?.terminalState, .identifierRetiredRolledBack)
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("| 2 | `MEM-000003` |"))
        let next = try service().create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() })
        XCTAssertEqual(next.mementoID, "MEM-000003")
    }

    func testRetirementRecoveryFailureRequiresRecoveryAndBlocksIDReuse() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        let journal = MemoryMementoJournal()
        let replacer = FailOnCallsReplacer(failOn: [1, 4])

        XCTAssertThrowsError(try service(journal: journal, replacer: replacer).create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() })) { error in
            guard case .recoveryRequired = error as? MementoTransactionError else { return XCTFail("Expected recoveryRequired, got \(error)") }
        }

        XCTAssertEqual(journal.journals.last?.terminalState, .recoveryRequired)
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(service(journal: journal).startupRecovery().contains { $0.mementoID == "MEM-000002" })
        XCTAssertThrowsError(try service(journal: journal).create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() })) { error in
            guard case .recoveryRequired = error as? MementoTransactionError else { return XCTFail("Expected pending recovery to block reuse, got \(error)") }
        }
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("| 1 | `MEM-000002` |"))
    }

    func testStableLockExcludesConcurrentTransactionAfterIdentifierReplacement() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let lockDirectory = FileManager.default.temporaryDirectory.appending(path: "memento-locks-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: lockDirectory) }
        let locking = LocalMementoTransactionLocking(directory: lockDirectory)
        let blocker = BlockingAfterFirstReplacement()
        let outcome = ThreadOutcome()
        let attempt = ConcurrentMementoAttempt(fixture: fixture, blocker: blocker, locking: locking, outcome: outcome, date: date)

        DispatchQueue.global().async { attempt.run() }

        XCTAssertEqual(blocker.replaced.wait(timeout: .now() + 5), .success, "First transaction did not reach the post-identifier boundary.")
        XCTAssertThrowsError(try service(locking: locking).create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() })) {
            XCTAssertEqual($0 as? MementoTransactionError, .lockUnavailable)
        }
        blocker.release.signal()
        XCTAssertEqual(outcome.finished.wait(timeout: .now() + 5), .success)
        XCTAssertNil(outcome.error)
        XCTAssertEqual(fixture.load().mementos.map(\.id), ["MEM-000002"])
    }

    func testLockConflictAndConcurrentHashChangeStopWithoutIssuance() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot(), deniedJournal = MemoryMementoJournal()
        XCTAssertThrowsError(try MementoTransactionService(journalStore: deniedJournal, locking: DeniedMementoLock(), now: { self.date }).create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() })) { XCTAssertEqual($0 as? MementoTransactionError, .lockUnavailable) }
        XCTAssertEqual(try fixture.snapshot(), before)

        let mutating = MutatingMementoJournal { fixture.replaceMementos(self.emptyMementos + "\n\nConcurrent prose.") }
        XCTAssertThrowsError(try service(journal: mutating).create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in fixture.load() })) { error in
            guard case .conflict = error as? MementoTransactionError else { return XCTFail("Expected conflict, got \(error)") }
        }
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("MEM-000002"), "Hash conflict occurs before issuance.")
    }

    func testInvalidTargetAndUnresolvedCrumbCannotIssue() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try service().create(configuration: fixture.configuration, targetID: "TASK-999999", draft: draft(), reload: { _ in fixture.load() }))
        let bad = MementoDraft(summary: "Pause", currentState: "State", naturalResumePoint: "Continue", openCrumbs: ["CRMB-999999"], extendedPayload: nil)
        XCTAssertThrowsError(try service().create(configuration: fixture.configuration, targetID: "TASK-000001", draft: bad, reload: { _ in fixture.load() }))
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    private func cleanFixture() throws -> SyntheticProductionsFixture {
        let fixture = try SyntheticProductionsFixture()
        try fixture.add(try WorkspaceSectionEditing.removeCurrentMemento(from: fixture.workspaceRecord), at: "Workspace/TASK-000001/TASK-000001.md")
        fixture.replaceMementos(emptyMementos)
        return fixture
    }
    private func draft(payload: String? = nil) -> MementoDraft { MementoDraft(summary: "Implementation pause", currentState: "Repository tests passed at captured commit.", naturalResumePoint: "Continue transaction tests", openCrumbs: ["CRMB-000001"], extendedPayload: payload) }
    private func service(journal: MemoryMementoJournal = MemoryMementoJournal(), replacer: (any AtomicFileReplacing)? = nil, locking: any MementoTransactionLocking = LocalMementoTransactionLocking()) -> MementoTransactionService { MementoTransactionService(journalStore: journal, replacer: replacer, locking: locking, now: { self.date }) }
    private var emptyMementos: String { "| Memento ID | Target | Summary | Resume point | Created | Location |\n| --- | --- | --- | --- | --- | --- |" }
}

private class MemoryMementoJournal: MementoTransactionJournalStore {
    var journals: [MementoTransactionJournal] = []
    func persist(_ journal: MementoTransactionJournal) throws { journals.append(journal) }
    func update(_ journal: MementoTransactionJournal) throws { if let index = journals.firstIndex(where: { $0.transactionID == journal.transactionID }) { journals[index] = journal } }
    func incomplete() throws -> [MementoTransactionJournal] { journals.filter { ![.committed, .rolledBack, .identifierRetiredRolledBack, .committedReloadFailed].contains($0.terminalState) } }
}

private final class MutatingMementoJournal: MemoryMementoJournal {
    let mutation: () -> Void
    init(mutation: @escaping () -> Void) { self.mutation = mutation }
    override func persist(_ journal: MementoTransactionJournal) throws { try super.persist(journal); mutation() }
}

private struct DeniedMementoLock: MementoTransactionLocking { func acquire(ledgerURL: URL) -> AnyObject? { nil } }

private final class FailOnceReplacer: AtomicFileReplacing {
    private var count = 0
    private let failOn: Int
    private let durable = DurableReplacement()
    init(failOn: Int) { self.failOn = failOn }
    func replace(data: Data, at target: URL) throws {
        count += 1
        if count == failOn { throw NSError(domain: "MementoTransactionsTests", code: count) }
        try durable.replace(data: data, at: target)
    }
}

private final class FailOnCallsReplacer: AtomicFileReplacing {
    private var count = 0
    private let failures: Set<Int>
    private let durable = DurableReplacement()
    init(failOn: Set<Int>) { failures = failOn }
    func replace(data: Data, at target: URL) throws {
        count += 1
        if failures.contains(count) { throw NSError(domain: "MementoTransactionsTests", code: count) }
        try durable.replace(data: data, at: target)
    }
}

private final class BlockingAfterFirstReplacement: AtomicFileReplacing, @unchecked Sendable {
    let replaced = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let durable = DurableReplacement()
    private var count = 0

    func replace(data: Data, at target: URL) throws {
        count += 1
        try durable.replace(data: data, at: target)
        if count == 1 {
            replaced.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "MementoTransactionsTests", code: 99) }
        }
    }
}

private final class ThreadOutcome: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var storedError: Error?
    var error: Error? { lock.withLock { storedError } }
    func record(_ error: Error) { lock.withLock { storedError = error } }
}

private final class ConcurrentMementoAttempt: @unchecked Sendable {
    private let fixture: SyntheticProductionsFixture
    private let blocker: BlockingAfterFirstReplacement
    private let locking: LocalMementoTransactionLocking
    private let outcome: ThreadOutcome
    private let date: Date

    init(fixture: SyntheticProductionsFixture, blocker: BlockingAfterFirstReplacement, locking: LocalMementoTransactionLocking, outcome: ThreadOutcome, date: Date) {
        self.fixture = fixture; self.blocker = blocker; self.locking = locking
        self.outcome = outcome; self.date = date
    }

    func run() {
        let journal = MemoryMementoJournal()
        let service = MementoTransactionService(journalStore: journal, replacer: blocker, locking: locking, now: { self.date })
        let draft = MementoDraft(summary: "Implementation pause", currentState: "Repository tests passed at captured commit.", naturalResumePoint: "Continue transaction tests", openCrumbs: ["CRMB-000001"], extendedPayload: nil)
        do {
            _ = try service.create(configuration: fixture.configuration, targetID: "TASK-000001", draft: draft, reload: { _ in self.fixture.load() })
        } catch {
            outcome.record(error)
        }
        outcome.finished.signal()
    }
}
