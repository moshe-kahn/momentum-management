import Foundation
import XCTest
@testable import OperationsDashboard

final class HeadlessMementoCommandsTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-17T22:30:00Z")!

    func testCreateAndDirectServiceProduceTheSameCanonicalBytes() throws {
        let commandFixture = try cleanFixture(), serviceFixture = try cleanFixture(); defer { commandFixture.remove(); serviceFixture.remove() }
        let command = try confirmed(.create, fixture: commandFixture)
        let outcome = try adapter().execute(command, configuration: commandFixture.configuration)
        let direct = try service().create(configuration: serviceFixture.configuration, targetID: "TASK-000001", draft: draft(), reload: { _ in serviceFixture.load() })
        XCTAssertEqual(outcome, direct)
        for path in ["Warehouse/Reference/Identifier Ledger.md", "Office/Threads/Mementos.md"] { XCTAssertEqual(try commandFixture.data(at: path), try serviceFixture.data(at: path), path) }
        XCTAssertEqual(commandFixture.load().mementos, serviceFixture.load().mementos)
    }

    func testSupersedeAndResolveDelegateToService() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let superseded = try adapter().execute(try confirmed(.supersede, fixture: fixture), configuration: fixture.configuration)
        XCTAssertEqual(superseded.action, .supersede)
        let resolved = try adapter().execute(try confirmed(.resolve, fixture: fixture), configuration: fixture.configuration)
        XCTAssertEqual(resolved.mementoID, superseded.mementoID)
        XCTAssertTrue(fixture.load().mementos.isEmpty)
    }

    func testPreviewBindsRootActionLiveStateDraftPayloadAndHashes() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let command = command(.create), preview = try adapter().preview(for: command, configuration: fixture.configuration)
        XCTAssertNil(preview.liveMementoID); XCTAssertEqual(preview.draft?.extendedPayload, "Payload.")
        let token = try preview.confirmationToken()
        let changed = MementoCommand(action: .create, targetID: command.targetID, draft: MementoDraft(summary: "Changed", currentState: draft().currentState, naturalResumePoint: draft().naturalResumePoint, openCrumbs: draft().openCrumbs, extendedPayload: "Payload."), confirmation: token)
        XCTAssertThrowsError(try adapter().execute(changed, configuration: fixture.configuration)) { guard case .confirmationRequired = $0 as? HeadlessMementoCommandError else { XCTFail("Expected changed input rejection"); return } }
        try fixture.add("\n", at: "Workspace/TASK-000001/TASK-000001.md")
        XCTAssertThrowsError(try adapter().execute(MementoCommand(action: command.action, targetID: command.targetID, draft: command.draft, confirmation: token), configuration: fixture.configuration)) { guard case .confirmationRequired = $0 as? HeadlessMementoCommandError else { XCTFail("Expected stale preview rejection"); return } }
    }

    func testMissingConfirmationAndServiceFailurePathsDoNotBypassService() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try adapter().execute(command(.create), configuration: fixture.configuration))
        let denied = MementoTransactionService(journalStore: MementoCommandJournal(), locking: MementoCommandDeniedLock(), now: { self.date })
        XCTAssertThrowsError(try adapter(service: denied).execute(try confirmed(.create, fixture: fixture, adapter: adapter(service: denied)), configuration: fixture.configuration)) { XCTAssertEqual($0 as? MementoTransactionError, .lockUnavailable) }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testResolveRejectsEveryDraftOnlyFlag() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        for flag in ["--summary", "--current-state", "--resume-point", "--open-crumbs", "--extended-payload"] {
            var output: [String] = []
            let arguments = ["OperationsDashboard", "memento", "resolve", "--productions-root", fixture.root.path, "--target", "TASK-000001", flag, "discarded", "--confirm", "confirm:any"]
            XCTAssertEqual(HeadlessMementoCommandLine.runIfRequested(arguments: arguments, write: { output.append($0) }), 2, flag)
            XCTAssertTrue(output.joined().contains("does not accept"), flag)
        }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testCommandLineProducesStablePreviewJSON() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        var output: [String] = []
        XCTAssertEqual(HeadlessMementoCommandLine.runIfRequested(arguments: arguments(for: command(.create), root: fixture.root.path, preview: true), write: { output.append($0) }), 0)
        struct PreviewOutput: Codable { let preview: MementoCommandPreview; let confirmationToken: String }
        let rendered = try XCTUnwrap(output.first)
        let decoded = try JSONDecoder().decode(PreviewOutput.self, from: try XCTUnwrap(rendered.data(using: .utf8)))
        XCTAssertEqual(decoded.confirmationToken, try decoded.preview.confirmationToken())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(rendered, String(decoding: try encoder.encode(decoded), as: UTF8.self))
    }

    func testCommandLineParsesConfirmedExecution() throws {
        let fixture = try cleanFixture(); defer { fixture.remove() }
        let value = command(.create), preview = try adapter().preview(for: value, configuration: fixture.configuration)
        var output: [String] = []
        XCTAssertEqual(HeadlessMementoCommandLine.runIfRequested(arguments: arguments(for: value, root: fixture.root.path, confirmation: try preview.confirmationToken()), write: { output.append($0) }), 0)
        XCTAssertTrue(output.joined().contains("Memento create committed for TASK-000001: MEM-000002."))
    }

    func testNoArgumentLeavesGUIRoutingUntouched() {
        XCTAssertNil(HeadlessMementoCommandLine.runIfRequested(arguments: ["OperationsDashboard"]))
    }

    private func cleanFixture() throws -> SyntheticProductionsFixture { let fixture = try SyntheticProductionsFixture(); try fixture.add(try WorkspaceSectionEditing.removeCurrentMemento(from: fixture.workspaceRecord), at: "Workspace/TASK-000001/TASK-000001.md"); fixture.replaceMementos("| Memento ID | Target | Summary | Resume point | Created | Location |\n| --- | --- | --- | --- | --- | --- |"); return fixture }
    private func draft() -> MementoDraft { .init(summary: "Pause", currentState: "Captured state.", naturalResumePoint: "Resume", openCrumbs: ["CRMB-000001"], extendedPayload: "Payload.") }
    private func command(_ action: MementoTransactionAction) -> MementoCommand { .init(action: action, targetID: "TASK-000001", draft: action == .resolve ? nil : draft(), confirmation: nil) }
    private func service() -> MementoTransactionService { .init(journalStore: MementoCommandJournal(), now: { self.date }) }
    private func adapter(service: MementoTransactionService? = nil) -> HeadlessMementoCommandAdapter { .init(service: service ?? self.service()) }
    private func confirmed(_ action: MementoTransactionAction, fixture: SyntheticProductionsFixture, adapter: HeadlessMementoCommandAdapter? = nil) throws -> MementoCommand { let value = command(action); let token = try (adapter ?? self.adapter()).preview(for: value, configuration: fixture.configuration).confirmationToken(); return .init(action: value.action, targetID: value.targetID, draft: value.draft, confirmation: token) }
    private func arguments(for command: MementoCommand, root: String, preview: Bool = false, confirmation: String? = nil) -> [String] {
        var values = ["OperationsDashboard", "memento"]
        if preview { values.append("preview") }
        values += [command.action.rawValue, "--productions-root", root, "--target", command.targetID]
        if let draft = command.draft { values += ["--summary", draft.summary, "--current-state", draft.currentState, "--resume-point", draft.naturalResumePoint, "--open-crumbs", draft.openCrumbs.joined(separator: ",")]; if let payload = draft.extendedPayload { values += ["--extended-payload", payload] } }
        if let confirmation { values += ["--confirm", confirmation] }
        return values
    }
}

private final class MementoCommandJournal: MementoTransactionJournalStore {
    func persist(_ journal: MementoTransactionJournal) throws {}
    func update(_ journal: MementoTransactionJournal) throws {}
    func incomplete() throws -> [MementoTransactionJournal] { [] }
}
private struct MementoCommandDeniedLock: MementoTransactionLocking { func acquire(ledgerURL: URL) -> AnyObject? { nil } }
