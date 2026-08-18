import XCTest
@testable import OperationsDashboard

final class HeadlessCanvasCommandsTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-17T21:00:00Z")!

    func testCommandAndDirectServiceProduceTheSameCanvasBytes() throws {
        let commandFixture = try SyntheticProductionsFixture(); defer { commandFixture.remove() }
        let serviceFixture = try SyntheticProductionsFixture(); defer { serviceFixture.remove() }
        commandFixture.replaceCanvas(emptyCanvas); serviceFixture.replaceCanvas(emptyCanvas)
        let commandResult = try adapter().execute(try confirmedCommand(.start, fixture: commandFixture), configuration: configuration(commandFixture))
        let service = CanvasWorkTransactionService(journalStore: CommandJournal(), now: { self.date })
        let directResult = try service.perform(action: .start, configuration: configuration(serviceFixture), work: try XCTUnwrap(serviceFixture.load().work.first), reason: "Approved action.", context: "Command test.", reload: { _ in serviceFixture.load() })
        guard case let .started(commandTransaction, package) = commandResult else { return XCTFail("Expected prepared start outcome") }
        XCTAssertEqual(commandTransaction, directResult); XCTAssertEqual(package.brief.workID, "TASK-000001")
        XCTAssertEqual(try commandFixture.data(at: "Office/Threads/Canvas.md"), try serviceFixture.data(at: "Office/Threads/Canvas.md"))
    }

    func testStopCommandMatchesServiceAndDoesNotChangeRegistry() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let registryBefore = try fixture.data(at: "Office/Registry/Tasks.md")

        let outcome = try adapter().execute(try confirmedCommand(.stop, fixture: fixture), configuration: configuration(fixture))

        guard case let .stopped(result) = outcome else { return XCTFail("Expected stop outcome") }
        XCTAssertEqual(result.appendedEvents, ["Cleared"])
        XCTAssertEqual(try MarkdownTable.parse(String(decoding: fixture.data(at: "Office/Threads/Canvas.md"), as: UTF8.self), required: ["Occurred", "Work ID", "Event", "Reason", "Context"]).last?["Event"], "Cleared")
        XCTAssertEqual(try fixture.data(at: "Office/Registry/Tasks.md"), registryBefore)
    }

    func testUnavailableTargetAndInactiveStopLeaveCanonicalRecordsUntouched() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let unavailableBefore = try fixture.snapshot()
        let unavailable = HeadlessCanvasCommand(action: .start, workID: "TASK-999999", reason: "Reason.", context: "Context.")
        XCTAssertThrowsError(try adapter().execute(unavailable, configuration: configuration(fixture))) { error in
            guard case .targetUnavailable = error as? HeadlessCanvasCommandError else { return XCTFail("Expected unavailable target") }
        }
        XCTAssertEqual(try fixture.snapshot(), unavailableBefore)

        fixture.replaceCanvas(emptyCanvas)
        let inactiveBefore = try fixture.snapshot()
        XCTAssertThrowsError(try adapter().execute(try confirmedCommand(.stop, fixture: fixture), configuration: configuration(fixture))) { error in
            XCTAssertEqual(error as? CanvasWorkTransactionError, .notCurrent)
        }
        XCTAssertEqual(try fixture.snapshot(), inactiveBefore)
    }

    func testPreviewBindsRootActionTargetReasonContextAndCanvasHash() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let draft = command(.start)
        let preview = try adapter().preview(for: draft, configuration: configuration(fixture))
        let token = try ConfirmedCommand.token(preview: preview)
        XCTAssertEqual(preview.productionsRoot, fixture.root.standardizedFileURL.path)
        XCTAssertEqual(preview.action, .start); XCTAssertEqual(preview.targetID, "TASK-000001")
        XCTAssertEqual(preview.reason, draft.reason); XCTAssertEqual(preview.context, draft.context)
        let variants = [
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot + "-other", action: preview.action, targetID: preview.targetID, targetTitle: preview.targetTitle, reason: preview.reason, context: preview.context, canvasSHA256: preview.canvasSHA256),
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot, action: .stop, targetID: preview.targetID, targetTitle: preview.targetTitle, reason: preview.reason, context: preview.context, canvasSHA256: preview.canvasSHA256),
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot, action: preview.action, targetID: "TASK-999999", targetTitle: preview.targetTitle, reason: preview.reason, context: preview.context, canvasSHA256: preview.canvasSHA256),
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot, action: preview.action, targetID: preview.targetID, targetTitle: preview.targetTitle, reason: preview.reason, context: "Changed context.", canvasSHA256: preview.canvasSHA256),
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot, action: preview.action, targetID: preview.targetID, targetTitle: preview.targetTitle, reason: preview.reason, context: preview.context, canvasSHA256: "changed")
        ]
        XCTAssertTrue(try variants.allSatisfy { try ConfirmedCommand.token(preview: $0) != token })
        let changedReason = HeadlessCanvasCommand(action: .start, workID: draft.workID, reason: "Changed reason.", context: draft.context, confirmation: ConfirmedCommand(confirmation: token))
        XCTAssertThrowsError(try adapter().execute(changedReason, configuration: configuration(fixture))) { guard case .confirmationRequired = $0 as? HeadlessCanvasCommandError else { return XCTFail("Expected changed-input rejection") } }
        fixture.replaceCanvas(emptyCanvas)
        let staleHash = HeadlessCanvasCommand(action: .start, workID: draft.workID, reason: draft.reason, context: draft.context, confirmation: ConfirmedCommand(confirmation: token))
        XCTAssertThrowsError(try adapter().execute(staleHash, configuration: configuration(fixture))) { guard case .confirmationRequired = $0 as? HeadlessCanvasCommandError else { return XCTFail("Expected changed-hash rejection") } }
    }

    func testMissingConfirmationAndInvalidFieldsDoNotWrite() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try adapter().execute(command(.start), configuration: configuration(fixture)))
        let invalidDraft = HeadlessCanvasCommand(action: .start, workID: "TASK-000001", reason: "bad|reason", context: "Context.")
        let invalidPreview = try adapter().preview(for: invalidDraft, configuration: configuration(fixture))
        let invalid = HeadlessCanvasCommand(action: invalidDraft.action, workID: invalidDraft.workID, reason: invalidDraft.reason, context: invalidDraft.context, confirmation: ConfirmedCommand(confirmation: try ConfirmedCommand.token(preview: invalidPreview)))
        XCTAssertThrowsError(try adapter().execute(invalid, configuration: configuration(fixture))) { guard case .invalidInput = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected Canvas validation error") } }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testCommandPreservesLockHashJournalReplacementAndMalformedStateFailures() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let denied = CanvasWorkTransactionService(journalStore: CommandJournal(), locking: CommandDeniedLock(), now: { self.date })
        XCTAssertThrowsError(try adapter(service: denied).execute(try confirmedCommand(.start, fixture: fixture), configuration: configuration(fixture))) { XCTAssertEqual($0 as? CanvasWorkTransactionError, .lockUnavailable) }
        let concurrent = CommandJournal { fixture.replaceCanvas(self.emptyCanvas + "\n| 2026-08-17T20:59:00Z | TASK-000001 | Cleared | Concurrent. | Other writer. |") }
        XCTAssertThrowsError(try adapter(journal: concurrent).execute(try confirmedCommand(.start, fixture: fixture), configuration: configuration(fixture))) { guard case .conflict = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected hash conflict") } }
        let replacement = CanvasWorkTransactionService(journalStore: CommandJournal(), replacer: CommandFailingReplacer(), now: { self.date })
        XCTAssertThrowsError(try adapter(service: replacement).execute(try confirmedCommand(.start, fixture: fixture), configuration: configuration(fixture))) { guard case .replacementFailed = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected replacement failure") } }
        let journalFailure = CommandJournal(failPersist: true)
        XCTAssertThrowsError(try adapter(journal: journalFailure).execute(try confirmedCommand(.start, fixture: fixture), configuration: configuration(fixture))) { guard case .journalFailed = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected journal failure") } }
        fixture.replaceCanvas("| malformed |")
        XCTAssertThrowsError(try adapter().preview(for: command(.start), configuration: configuration(fixture)))
    }

    func testSuccessfulStartEmitsStableFullSessionPackageJSON() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let command = command(.start)
        let token = try ConfirmedCommand.token(preview: try adapter().preview(for: command, configuration: configuration(fixture)))
        var output: [String] = []
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: arguments(for: command, root: fixture.root.path, confirmation: token), write: { output.append($0) }), 0)
        let rendered = try XCTUnwrap(output.first)
        let package = try JSONDecoder().decode(SessionPackage.self, from: try XCTUnwrap(rendered.data(using: .utf8)))
        XCTAssertEqual(package.brief.workID, "TASK-000001")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(rendered, String(decoding: try encoder.encode(package), as: UTF8.self), "Package JSON output is stable for the exact committed result.")
    }

    func testPartialOutcomeUsesDistinctExitCodeAndNoRetryDiagnostic() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let command = try confirmedCommand(.start, fixture: fixture)
        let partialAdapter = HeadlessCanvasCommandAdapter(canvas: CanvasWorkTransactionService(journalStore: CommandJournal(), now: { self.date }), recommendedModel: "")
        var output: [String] = []
        let exitCode = HeadlessCanvasCommandLine.runIfRequested(arguments: arguments(for: command, root: fixture.root.path, confirmation: try XCTUnwrap(command.confirmation).confirmation), adapter: partialAdapter, write: { output.append($0) })
        XCTAssertEqual(exitCode, HeadlessCanvasCommandLine.partialSuccessExitCode)
        XCTAssertTrue(output.joined().contains("Canvas must not be retried"))
    }

    func testPreviewOutputIncludesConfirmationTokenAndNoArgumentLaunchIsUntouched() throws {
        XCTAssertNil(HeadlessCanvasCommandLine.runIfRequested(arguments: ["OperationsDashboard"]))
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        var output: [String] = []
        let arguments = ["OperationsDashboard", "canvas", "preview", "start", "--productions-root", fixture.root.path, "--work", "TASK-000001", "--reason", "Approved action.", "--context", "Command test."]
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: arguments, write: { output.append($0) }), 0)
        XCTAssertTrue(output.joined().contains("confirmationToken")); XCTAssertTrue(output.joined().contains("canvasSHA256"))
    }

    private var emptyCanvas: String { "| Occurred | Work ID | Event | Reason | Context |\n| --- | --- | --- | --- | --- |" }
    private func configuration(_ fixture: SyntheticProductionsFixture) -> ProductionsConfiguration { ProductionsConfiguration(schemaVersion: 2, productionsRootPath: fixture.root.path) }
    private func command(_ action: CanvasWorkAction) -> HeadlessCanvasCommand { HeadlessCanvasCommand(action: action, workID: "TASK-000001", reason: "Approved action.", context: "Command test.") }
    private func confirmedCommand(_ action: CanvasWorkAction, fixture: SyntheticProductionsFixture) throws -> HeadlessCanvasCommand { let draft = command(action); let preview = try adapter().preview(for: draft, configuration: configuration(fixture)); return HeadlessCanvasCommand(action: draft.action, workID: draft.workID, reason: draft.reason, context: draft.context, confirmation: ConfirmedCommand(confirmation: try ConfirmedCommand.token(preview: preview))) }
    private func arguments(for command: HeadlessCanvasCommand, root: String, confirmation: String) -> [String] { ["OperationsDashboard", "canvas", command.action.rawValue, "--productions-root", root, "--work", command.workID, "--reason", command.reason, "--context", command.context, "--confirm", confirmation] }
    private func adapter(journal: CommandJournal = CommandJournal()) -> HeadlessCanvasCommandAdapter { adapter(service: CanvasWorkTransactionService(journalStore: journal, now: { self.date })) }
    private func adapter(service: CanvasWorkTransactionService) -> HeadlessCanvasCommandAdapter { HeadlessCanvasCommandAdapter(canvas: service) }
}

private final class CommandJournal: CanvasWorkTransactionJournalStore {
    var journals: [CanvasWorkTransactionJournal] = []
    let afterPersist: (() -> Void)?
    let failPersist: Bool
    init(afterPersist: (() -> Void)? = nil, failPersist: Bool = false) { self.afterPersist = afterPersist; self.failPersist = failPersist }
    func persist(_ journal: CanvasWorkTransactionJournal) throws { if failPersist { throw NSError(domain: "HeadlessCanvasCommandsTests", code: 1) }; journals.append(journal); afterPersist?() }
    func update(_ journal: CanvasWorkTransactionJournal) throws { guard let index = journals.firstIndex(where: { $0.transactionID == journal.transactionID }) else { throw NSError(domain: "HeadlessCanvasCommandsTests", code: 1) }; journals[index] = journal }
    func incomplete() throws -> [CanvasWorkTransactionJournal] { journals.filter { $0.terminalState != .committed && $0.terminalState != .committedReloadFailed } }
}
private struct CommandDeniedLock: CanvasWorkTransactionLocking { func acquire(canvasURL: URL) -> AnyObject? { nil } }
private struct CommandFailingReplacer: AtomicFileReplacing { func replace(data: Data, at target: URL) throws { throw NSError(domain: "HeadlessCanvasCommandsTests", code: 2) } }
