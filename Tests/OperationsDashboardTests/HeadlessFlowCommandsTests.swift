import Foundation
import XCTest
@testable import OperationsDashboard

final class HeadlessFlowCommandsTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-19T18:00:00Z")!

    func testCommandAndDirectServiceProduceTheSameFlowAndLedgerBytes() throws {
        let commandFixture = try fixtureWithPayload(), directFixture = try fixtureWithPayload(); defer { commandFixture.remove(); directFixture.remove() }
        let command = try confirmed(fixture: commandFixture)
        try adapter().execute(command, configuration: config(commandFixture))
        let service = makeService()
        let item = try XCTUnwrap(directFixture.load().inbox.first { $0.location == command.payloadPath })
        let preview = try service.preview(configuration: config(directFixture), payload: item, metadata: command.metadata)
        try service.commit(configuration: config(directFixture), payload: item, metadata: command.metadata, preview: preview, expectedPayloadState: preview.payloadState, reload: { _ in directFixture.load() })
        XCTAssertEqual(try commandFixture.data(at: "Office/Flow.md"), try directFixture.data(at: "Office/Flow.md"))
        XCTAssertEqual(try commandFixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), try directFixture.data(at: "Warehouse/Reference/Identifier Ledger.md"))
    }

    func testPreviewBindsRootPayloadFilesystemMetadataFlowIDRowAndHashes() throws {
        let fixture = try fixtureWithPayload(); defer { fixture.remove() }
        let command = command(); let preview = try adapter().preview(for: command, configuration: config(fixture))
        XCTAssertEqual(preview.productionsRoot, fixture.root.standardizedFileURL.path)
        XCTAssertEqual(preview.payloadPath, command.payloadPath); XCTAssertNotEqual(preview.payloadState.inode, 0)
        XCTAssertEqual(preview.proposedFlowID, "FLOW-000002"); XCTAssertTrue(preview.proposedRow.contains("Flow command item"))
        let token = try preview.confirmationToken()
        let changedMetadata = FlowRegisterCommand(payloadPath: command.payloadPath, metadata: FlowRegistrationMetadata(label: "Changed", type: command.metadata.type, summary: command.metadata.summary, nextDisposition: command.metadata.nextDisposition, priority: command.metadata.priority, steward: command.metadata.steward, department: command.metadata.department, product: command.metadata.product, source: command.metadata.source, relatedWork: command.metadata.relatedWork), occurredAt: command.occurredAt, confirmation: token)
        XCTAssertThrowsError(try adapter().execute(changedMetadata, configuration: config(fixture))) { guard case .confirmationRequired = $0 as? HeadlessFlowCommandError else { XCTFail("Expected changed metadata rejection"); return } }
        try fixture.add("changed", at: command.payloadPath)
        XCTAssertThrowsError(try adapter().execute(FlowRegisterCommand(payloadPath: command.payloadPath, metadata: command.metadata, occurredAt: command.occurredAt, confirmation: token), configuration: config(fixture))) { guard case .confirmationRequired = $0 as? HeadlessFlowCommandError else { XCTFail("Expected changed filesystem rejection"); return } }

        let flowFixture = try fixtureWithPayload(); defer { flowFixture.remove() }
        let flowToken = try adapter().preview(for: command, configuration: config(flowFixture)).confirmationToken()
        flowFixture.replaceFlow(flowFixture.flow + "\n\nConcurrent prose.")
        XCTAssertThrowsError(try adapter().execute(FlowRegisterCommand(payloadPath: command.payloadPath, metadata: command.metadata, occurredAt: command.occurredAt, confirmation: flowToken), configuration: config(flowFixture))) { guard case .confirmationRequired = $0 as? HeadlessFlowCommandError else { XCTFail("Expected changed Flow hash rejection"); return } }

        let ledgerFixture = try fixtureWithPayload(); defer { ledgerFixture.remove() }
        let ledgerToken = try adapter().preview(for: command, configuration: config(ledgerFixture)).confirmationToken()
        ledgerFixture.replaceLedger(ledgerFixture.identifierLedger + "\n")
        XCTAssertThrowsError(try adapter().execute(FlowRegisterCommand(payloadPath: command.payloadPath, metadata: command.metadata, occurredAt: command.occurredAt, confirmation: ledgerToken), configuration: config(ledgerFixture))) { guard case .confirmationRequired = $0 as? HeadlessFlowCommandError else { XCTFail("Expected changed Ledger hash rejection"); return } }
    }

    func testConfirmationRejectsChangedRootPayloadPathTimestampReplacedAndDeletedPayload() throws {
        let fixture = try fixtureWithPayload(); defer { fixture.remove() }
        let value = command(), token = try adapter().preview(for: value, configuration: config(fixture)).confirmationToken()
        let other = try fixtureWithPayload(); defer { other.remove() }
        XCTAssertThrowsError(try adapter().execute(.init(payloadPath: value.payloadPath, metadata: value.metadata, occurredAt: value.occurredAt, confirmation: token), configuration: config(other)))
        try fixture.add("alternate", at: "Office/Inbox/alternate.txt")
        XCTAssertThrowsError(try adapter().execute(.init(payloadPath: "Office/Inbox/alternate.txt", metadata: value.metadata, occurredAt: value.occurredAt, confirmation: token), configuration: config(fixture)))
        XCTAssertThrowsError(try adapter().execute(.init(payloadPath: value.payloadPath, metadata: value.metadata, occurredAt: value.occurredAt.addingTimeInterval(1), confirmation: token), configuration: config(fixture)))
        try FileManager.default.removeItem(at: fixture.root.appending(path: value.payloadPath)); try fixture.add("payload", at: value.payloadPath)
        XCTAssertThrowsError(try adapter().execute(.init(payloadPath: value.payloadPath, metadata: value.metadata, occurredAt: value.occurredAt, confirmation: token), configuration: config(fixture)))
        try FileManager.default.removeItem(at: fixture.root.appending(path: value.payloadPath))
        XCTAssertThrowsError(try adapter().execute(.init(payloadPath: value.payloadPath, metadata: value.metadata, occurredAt: value.occurredAt, confirmation: token), configuration: config(fixture)))
    }

    func testServiceRejectsPayloadStateFlowAndLedgerChangesAfterLockBeforeIssuance() throws {
        for mutation in ["payload", "flow", "ledger"] {
            let fixture = try fixtureWithPayload(); defer { fixture.remove() }
            let beforeLedger = try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), beforeFlow = try fixture.data(at: "Office/Flow.md")
            let lock = FlowCommandMutationLock {
                switch mutation {
                case "payload": try! fixture.add("changed after lock", at: "Office/Inbox/flow-command.txt")
                case "flow": fixture.replaceFlow(fixture.flow + "\n\nConcurrent prose.")
                default: fixture.replaceLedger(fixture.identifierLedger + "\n")
                }
            }
            let service = FlowRegistrationService(journalStore: FlowCommandJournal(), locking: lock, now: { self.date })
            let headless = HeadlessFlowCommandAdapter(makeService: { _ in service })
            XCTAssertThrowsError(try headless.execute(try confirmed(fixture: fixture, adapter: headless), configuration: config(fixture)), mutation) { guard case .conflict = $0 as? FlowRegistrationError else { XCTFail("Expected locked commit conflict for \(mutation)"); return } }
            if mutation != "ledger" { XCTAssertEqual(try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), beforeLedger) }
            if mutation != "flow" { XCTAssertEqual(try fixture.data(at: "Office/Flow.md"), beforeFlow) }
        }
    }

    func testMissingConfirmationAndLockJournalAndReplacementFailuresPreserveServiceBehavior() throws {
        let fixture = try fixtureWithPayload(); defer { fixture.remove() }
        let before = try fixture.snapshot(); let command = command()
        XCTAssertThrowsError(try adapter().execute(command, configuration: config(fixture)))
        let denied = HeadlessFlowCommandAdapter(makeService: { _ in FlowRegistrationService(journalStore: FlowCommandJournal(), locking: FlowCommandDeniedLock(), now: { self.date }) })
        XCTAssertThrowsError(try denied.execute(try confirmed(fixture: fixture, adapter: denied), configuration: config(fixture))) { XCTAssertEqual($0 as? FlowRegistrationError, .lockUnavailable) }
        let journal = FlowCommandJournal(); journal.failPersist = true
        let failingJournal = HeadlessFlowCommandAdapter(makeService: { _ in FlowRegistrationService(journalStore: journal, now: { self.date }) })
        XCTAssertThrowsError(try failingJournal.execute(try confirmed(fixture: fixture, adapter: failingJournal), configuration: config(fixture))) { guard case .journalFailed = $0 as? FlowRegistrationError else { XCTFail("Expected journal failure"); return } }
        let replacement = HeadlessFlowCommandAdapter(makeService: { _ in FlowRegistrationService(journalStore: FlowCommandJournal(), replacer: FlowCommandFailingReplacer(), now: { self.date }) })
        XCTAssertThrowsError(try replacement.execute(try confirmed(fixture: fixture, adapter: replacement), configuration: config(fixture))) { guard case .ledgerWriteFailed = $0 as? FlowRegistrationError else { XCTFail("Expected ledger replacement failure"); return } }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testCommandLinePreviewIsStableConfirmedExecutionParsesAndNoArgumentsLeaveGUIUntouched() throws {
        let fixture = try fixtureWithPayload(); defer { fixture.remove() }
        let command = command(); var output: [String] = []
        let cliAdapter = adapter()
        XCTAssertEqual(HeadlessFlowCommandLine.runIfRequested(arguments: arguments(for: command, root: fixture.root.path, preview: true), adapter: cliAdapter, write: { output.append($0) }), 0)
        struct Output: Codable { let preview: FlowRegisterCommandPreview; let confirmationToken: String }
        let rendered = try XCTUnwrap(output.first), decoded = try JSONDecoder().decode(Output.self, from: try XCTUnwrap(rendered.data(using: .utf8)))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(rendered, String(decoding: try encoder.encode(decoded), as: UTF8.self)); XCTAssertEqual(decoded.confirmationToken, try decoded.preview.confirmationToken())
        output = []
        XCTAssertEqual(HeadlessFlowCommandLine.runIfRequested(arguments: arguments(for: command, root: fixture.root.path, confirmation: decoded.confirmationToken), adapter: cliAdapter, write: { output.append($0) }), 0)
        XCTAssertTrue(output.joined().contains("Flow registration committed"))
        XCTAssertNil(HeadlessFlowCommandLine.runIfRequested(arguments: ["OperationsDashboard"], adapter: cliAdapter))
    }

    func testCommandLineRejectsMalformedStructureAndInvalidMetadata() throws {
        var output: [String] = []
        XCTAssertEqual(HeadlessFlowCommandLine.runIfRequested(arguments: ["OperationsDashboard", "flow", "register"], write: { output.append($0) }), 2)
        XCTAssertTrue(output.joined().contains("required"))
        let fixture = try fixtureWithPayload(); defer { fixture.remove() }
        var invalid = command(); invalid = .init(payloadPath: invalid.payloadPath, metadata: FlowRegistrationMetadata(label: "bad|label", type: invalid.metadata.type, summary: invalid.metadata.summary, nextDisposition: invalid.metadata.nextDisposition, priority: invalid.metadata.priority, steward: invalid.metadata.steward, department: invalid.metadata.department, product: invalid.metadata.product, source: invalid.metadata.source, relatedWork: invalid.metadata.relatedWork), occurredAt: invalid.occurredAt, confirmation: nil)
        output = []
        XCTAssertEqual(HeadlessFlowCommandLine.runIfRequested(arguments: arguments(for: invalid, root: fixture.root.path, preview: true), adapter: adapter(), write: { output.append($0) }), 2)
        XCTAssertTrue(output.joined().contains("table-breaking"))
    }

    func testCommandLineReportsPartialCommitRecoveryAndReloadFailureWithExitThree() throws {
        let partialFixture = try fixtureWithPayload(); defer { partialFixture.remove() }
        let journal = FlowCommandRecordingJournal(); let partialAdapter = HeadlessFlowCommandAdapter(makeService: { _ in FlowRegistrationService(journalStore: journal, replacer: FlowCommandFailOnSecondReplacement(), now: { self.date }) })
        let partial = try confirmed(fixture: partialFixture, adapter: partialAdapter); var output: [String] = []
        XCTAssertEqual(HeadlessFlowCommandLine.runIfRequested(arguments: arguments(for: partial, root: partialFixture.root.path, confirmation: try XCTUnwrap(partial.confirmation)), adapter: partialAdapter, write: { output.append($0) }), 3)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(try XCTUnwrap(output.first).hasPrefix("Identifier Ledger committed; Flow replacement failed. Do not retry automatically. Service diagnostic: Identifier Ledger committed; Flow replacement failed."))
        XCTAssertEqual(journal.journals.last?.terminalState, .ledgerCommitted)
        XCTAssertTrue(FlowRegistrationService(journalStore: journal).startupRecovery().contains { $0.flowID == "FLOW-000002" })

        let reloadFixture = try fixtureWithPayload(); defer { reloadFixture.remove() }
        let reader = FlowCommandReloadFailingReader(); let replacer = FlowCommandReloadFailingReplacer(reader: reader)
        let reloadAdapter = HeadlessFlowCommandAdapter(reader: reader, makeService: { _ in FlowRegistrationService(journalStore: FlowCommandRecordingJournal(), replacer: replacer, now: { self.date }) })
        let reload = try confirmed(fixture: reloadFixture, adapter: reloadAdapter); output = []
        XCTAssertEqual(HeadlessFlowCommandLine.runIfRequested(arguments: arguments(for: reload, root: reloadFixture.root.path, confirmation: try XCTUnwrap(reload.confirmation)), adapter: reloadAdapter, write: { output.append($0) }), 3)
        XCTAssertEqual(output.count, 1)
        XCTAssertTrue(try XCTUnwrap(output.first).hasPrefix("Full Flow registration committed; only reload/verification failed. Do not retry automatically. Service diagnostic: Registration committed but contract reload needs investigation:"))
    }

    private func fixtureWithPayload() throws -> SyntheticProductionsFixture { let fixture = try SyntheticProductionsFixture(); try fixture.add("payload", at: "Office/Inbox/flow-command.txt"); return fixture }
    private func config(_ fixture: SyntheticProductionsFixture) -> ProductionsConfiguration { .init(schemaVersion: 2, productionsRootPath: fixture.root.path) }
    private func metadata() -> FlowRegistrationMetadata { .init(label: "Flow command item", type: "Note", summary: "Synthetic Flow command metadata", nextDisposition: "Review", priority: "High", steward: "Office", department: "Office", product: "—", source: "Synthetic test", relatedWork: "TASK-000001") }
    private func command() -> FlowRegisterCommand { .init(payloadPath: "Office/Inbox/flow-command.txt", metadata: metadata(), occurredAt: date, confirmation: nil) }
    private func makeService() -> FlowRegistrationService { .init(journalStore: FlowCommandJournal(), now: { self.date }) }
    private func adapter() -> HeadlessFlowCommandAdapter { .init(makeService: { _ in self.makeService() }) }
    private func confirmed(fixture: SyntheticProductionsFixture, adapter: HeadlessFlowCommandAdapter? = nil) throws -> FlowRegisterCommand { let value = command(); let token = try (adapter ?? self.adapter()).preview(for: value, configuration: config(fixture)).confirmationToken(); return .init(payloadPath: value.payloadPath, metadata: value.metadata, occurredAt: value.occurredAt, confirmation: token) }
    private func arguments(for command: FlowRegisterCommand, root: String, preview: Bool = false, confirmation: String? = nil) -> [String] {
        let dateText = ISO8601DateFormatter().string(from: command.occurredAt)
        var values = ["OperationsDashboard", "flow"]; if preview { values.append("preview") }
        values += ["register", "--productions-root", root, "--payload", command.payloadPath, "--occurred-at", dateText, "--label", command.metadata.label, "--type", command.metadata.type, "--summary", command.metadata.summary, "--next-disposition", command.metadata.nextDisposition, "--priority", command.metadata.priority, "--steward", command.metadata.steward, "--department", command.metadata.department, "--product", command.metadata.product, "--source", command.metadata.source, "--related-work", command.metadata.relatedWork]
        if let confirmation { values += ["--confirm", confirmation] }; return values
    }
}

private final class FlowCommandJournal: FlowRegistrationJournalStore {
    var failPersist = false
    func persist(_ journal: FlowRegistrationJournal) throws { if failPersist { throw NSError(domain: "HeadlessFlowCommandsTests", code: 1) } }
    func update(_ journal: FlowRegistrationJournal) throws {}
    func incomplete() throws -> [FlowRegistrationJournal] { [] }
}
private struct FlowCommandDeniedLock: FlowRegistrationLocking { func acquire(ledgerURL: URL) -> AnyObject? { nil } }
private struct FlowCommandFailingReplacer: AtomicFileReplacing { func replace(data: Data, at target: URL) throws { throw NSError(domain: "HeadlessFlowCommandsTests", code: 2) } }

private final class FlowCommandRecordingJournal: FlowRegistrationJournalStore {
    var journals: [FlowRegistrationJournal] = []
    func persist(_ journal: FlowRegistrationJournal) throws { journals.append(journal) }
    func update(_ journal: FlowRegistrationJournal) throws { if let index = journals.firstIndex(where: { $0.transactionID == journal.transactionID }) { journals[index] = journal } }
    func incomplete() throws -> [FlowRegistrationJournal] { journals.filter { $0.terminalState != .bothFilesCommitted && $0.terminalState != .bothCommittedReloadFailed } }
}

private final class FlowCommandMutationLock: FlowRegistrationLocking {
    private let mutation: () -> Void
    init(mutation: @escaping () -> Void) { self.mutation = mutation }
    func acquire(ledgerURL: URL) -> AnyObject? { mutation(); return NSObject() }
}

private final class FlowCommandFailOnSecondReplacement: AtomicFileReplacing {
    private let durable = DurableReplacement(); private var count = 0
    func replace(data: Data, at target: URL) throws { count += 1; if count == 2 { throw NSError(domain: "HeadlessFlowCommandsTests", code: count) }; try durable.replace(data: data, at: target) }
}

private final class FlowCommandReloadFailingReader: ProductionsReading {
    var failFlow = false
    private let local = LocalFileSystem()
    func exists(at url: URL) -> Bool { local.exists(at: url) }
    func isReadable(at url: URL) -> Bool { local.isReadable(at: url) }
    func isSymbolicLink(at url: URL) throws -> Bool { try local.isSymbolicLink(at: url) }
    func isDirectory(at url: URL) throws -> Bool { try local.isDirectory(at: url) }
    func directoryEntries(at url: URL) throws -> [FileSystemEntry] { try local.directoryEntries(at: url) }
    func readData(at url: URL) throws -> Data { failFlow && url.path.hasSuffix("/Office/Flow.md") ? Data("| malformed |".utf8) : try local.readData(at: url) }
}

private final class FlowCommandReloadFailingReplacer: AtomicFileReplacing {
    private let durable = DurableReplacement(); private var count = 0; private let reader: FlowCommandReloadFailingReader
    init(reader: FlowCommandReloadFailingReader) { self.reader = reader }
    func replace(data: Data, at target: URL) throws { count += 1; try durable.replace(data: data, at: target); if count == 2 { reader.failFlow = true } }
}
