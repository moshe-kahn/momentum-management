import Foundation
import XCTest
@testable import OperationsDashboard

final class FlowRegistrationTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-11T18:00:00Z")!

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
        try service.commit(configuration: config(fixture), payload: payload, metadata: metadata(), preview: preview, reload: { _ in fixture.load() })
        XCTAssertEqual(try fixture.data(at: "Office/Inbox/new.txt"), originalPayload)
        XCTAssertTrue(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("FLOW-000002"))
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("| FLOW | 6 | 2 | `FLOW-000003` |"))
        XCTAssertEqual(journal.journals.last?.terminalState, .bothFilesCommitted)
        XCTAssertTrue(fixture.load().issues.isEmpty)
    }

    func testSharedTimestampIsUsedForCreatedUpdatedAndJournal() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/time.txt")
        let journal = MemoryJournal(); let service = service(journal: journal)
        let item = try payload(fixture, "time.txt")
        let preview = try service.preview(configuration: config(fixture), payload: item, metadata: metadata())
        try service.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, reload: { _ in fixture.load() })
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
        XCTAssertThrowsError(try service.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, reload: { _ in fixture.load() }))
        XCTAssertFalse(String(decoding: try fixture.data(at: "Office/Flow.md"), as: UTF8.self).contains("conflict.txt"))
    }

    func testConcurrentAttemptAndDuplicateRegistrationAreRejected() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/duplicate.txt")
        let item = try payload(fixture, "duplicate.txt"); let cfg = config(fixture)
        let preview = try service(journal: MemoryJournal()).preview(configuration: cfg, payload: item, metadata: metadata())
        let held = LocalFlowRegistrationLocking().acquire(ledgerURL: cfg.url("Warehouse/Reference/Identifier Ledger.md"))
        XCTAssertNotNil(held)
        XCTAssertThrowsError(try service(journal: MemoryJournal()).commit(configuration: cfg, payload: item, metadata: metadata(), preview: preview, reload: { _ in fixture.load() }))
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
        XCTAssertThrowsError(try service.commit(configuration: cfg, payload: item, metadata: metadata(), preview: preview, reload: { _ in fixture.load() }))
        XCTAssertEqual(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self), fixture.identifierLedger)
    }

    func testJournalPersistenceFailureLeavesBothFilesUntouched() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/journal.txt")
        let journal = MemoryJournal(); journal.failPersistence = true
        let item = try payload(fixture, "journal.txt"); let svc = service(journal: journal)
        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: metadata())
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try svc.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, reload: { _ in fixture.load() }))
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
        XCTAssertThrowsError(try service(journal: ledgerFailure, replacer: firstFailure).commit(configuration: cfg, payload: item, metadata: metadata(), preview: preview, reload: { _ in fixture.load() }))
        XCTAssertEqual(ledgerFailure.journals.last?.terminalState, .preCommitFailure)
        XCTAssertEqual(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self), fixture.identifierLedger)

        let flowFailure = MemoryJournal(); let secondFailure = ControlledReplacer(failOn: 2)
        let secondPreview = try service(journal: flowFailure, replacer: secondFailure).preview(configuration: cfg, payload: item, metadata: metadata())
        XCTAssertThrowsError(try service(journal: flowFailure, replacer: secondFailure).commit(configuration: cfg, payload: item, metadata: metadata(), preview: secondPreview, reload: { _ in fixture.load() }))
        XCTAssertEqual(flowFailure.journals.last?.terminalState, .ledgerCommitted)
        XCTAssertTrue(service(journal: flowFailure).startupRecovery().contains { $0.flowID == "FLOW-000002" })
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("| FLOW | 6 | 2 |"))
    }

    func testReloadFailureIsCommittedInvestigationNotRetryable() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add("new", at: "Office/Inbox/reload.txt")
        let journal = MemoryJournal(); let svc = service(journal: journal); let item = try payload(fixture, "reload.txt")
        let preview = try svc.preview(configuration: config(fixture), payload: item, metadata: metadata())
        XCTAssertThrowsError(try svc.commit(configuration: config(fixture), payload: item, metadata: metadata(), preview: preview, reload: { configuration in
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
    private func service(journal: MemoryJournal, replacer: (any AtomicFileReplacing)? = nil) -> FlowRegistrationService { FlowRegistrationService(journalStore: journal, replacer: replacer, now: { self.date }) }
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
