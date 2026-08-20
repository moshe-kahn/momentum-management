import Foundation
import XCTest
@testable import OperationsDashboard

final class HeadlessCaptureCommandsTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testCommandAndDirectServiceProduceTheSameBytesWithoutFlowOrLedgerWrites() throws {
        let commandFixture = try HeadlessCaptureFixture(); defer { commandFixture.remove() }
        let directFixture = try HeadlessCaptureFixture(); defer { directFixture.remove() }
        let draft = command(); let adapter = HeadlessCaptureCommandAdapter()
        let preview = try adapter.preview(for: draft, configuration: commandFixture.configuration)
        _ = try adapter.execute(.init(text: draft.text, timestamp: draft.timestamp, confirmation: try preview.confirmationToken()), configuration: commandFixture.configuration)
        let directPreview = try ProductionsInboxCaptureService().previewTypedNote(text: draft.text, productionsRoot: directFixture.root, timestamp: timestamp)
        _ = try ProductionsInboxCaptureService().commitTypedNote(text: draft.text, productionsRoot: directFixture.root, timestamp: timestamp, preview: directPreview)
        XCTAssertEqual(try Data(contentsOf: commandFixture.inbox.appending(path: preview.filename)), try Data(contentsOf: directFixture.inbox.appending(path: directPreview.filename)))
        XCTAssertEqual(try commandFixture.contractSnapshot(), try HeadlessCaptureFixture.contractBaseline())
    }

    func testPreviewBindsRootInboxContentHashFilenameTimestampCollisionAndInboxState() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let preview = try HeadlessCaptureCommandAdapter().preview(for: command(text: "alpha"), configuration: fixture.configuration)
        XCTAssertEqual(preview.productionsRoot, fixture.root.path); XCTAssertEqual(preview.inboxPath, fixture.inbox.path)
        XCTAssertEqual(preview.contents, "# Quick Capture\n\nCreated: 2023-11-14T22:13:20Z\nSource: Operations Dashboard\n\nalpha\n")
        XCTAssertEqual(preview.contentByteCount, Data(preview.contents.utf8).count); XCTAssertEqual(preview.contentSHA256.count, 64)
        XCTAssertEqual(preview.filename, "Quick Capture 2023-11-14T22-13-20Z.md"); XCTAssertTrue(preview.destinationAbsent); XCTAssertEqual(preview.collisionOutcome, "destination absent")
        XCTAssertEqual(preview.timestampPolicy, "ISO-8601 UTC; filename replaces colons with hyphens")
    }

    func testConfirmationRejectsChangedContentRootAndFilenameTimestampAndServiceRejectsChangedInboxState() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let adapter = HeadlessCaptureCommandAdapter(); let draft = command(); let preview = try adapter.preview(for: draft, configuration: fixture.configuration); let token = try preview.confirmationToken()
        XCTAssertThrowsError(try adapter.execute(command(text: "changed", confirmation: token), configuration: fixture.configuration))
        let other = try HeadlessCaptureFixture(); defer { other.remove() }
        XCTAssertThrowsError(try adapter.execute(.init(text: draft.text, timestamp: timestamp, confirmation: token), configuration: other.configuration))
        XCTAssertThrowsError(try adapter.execute(.init(text: draft.text, timestamp: timestamp.addingTimeInterval(1), confirmation: token), configuration: fixture.configuration))
        try Data("unrelated".utf8).write(to: fixture.inbox.appending(path: "unrelated.txt"))
        XCTAssertThrowsError(try ProductionsInboxCaptureService().commitTypedNote(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp, preview: preview)) { XCTAssertEqual($0 as? TypedNoteCaptureError, .stalePreview) }
    }

    func testCollisionAndCreationFailureLeaveFlowAndLedgerUntouched() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let draft = command(); let preview = try HeadlessCaptureCommandAdapter().preview(for: draft, configuration: fixture.configuration)
        try Data("collision".utf8).write(to: fixture.inbox.appending(path: preview.filename))
        let collision = try HeadlessCaptureCommandAdapter().preview(for: draft, configuration: fixture.configuration)
        XCTAssertFalse(collision.destinationAbsent); XCTAssertEqual(collision.collisionOutcome, "Inbox already contains \(preview.filename).")
        XCTAssertThrowsError(try HeadlessCaptureCommandAdapter().execute(.init(text: draft.text, timestamp: timestamp, confirmation: try collision.confirmationToken()), configuration: fixture.configuration))
        let failing = HeadlessCaptureCommandAdapter(makeService: { ProductionsInboxCaptureService(typedNoteWriter: { _, _ in throw CocoaError(.fileWriteNoPermission) }) })
        let clean = try HeadlessCaptureFixture(); defer { clean.remove() }; let cleanPreview = try failing.preview(for: draft, configuration: clean.configuration); var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: clean.root.path, confirmation: try cleanPreview.confirmationToken()), adapter: failing, write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["Quick Capture failed: The file couldn’t be saved because you don’t have permission."])
        XCTAssertEqual(try clean.contractSnapshot(), try HeadlessCaptureFixture.contractBaseline())
    }

    func testCommandLinePreviewOutputConfirmedExecutionVerificationFailureAndNoArgumentGUIRouting() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let adapter = HeadlessCaptureCommandAdapter(); let draft = command(); var output: [String] = []
        XCTAssertNil(HeadlessCaptureCommandLine.runIfRequested(arguments: ["OperationsDashboard"], adapter: adapter, write: { output.append($0) }))
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: fixture.root.path, preview: true), adapter: adapter, write: { output.append($0) }), 0)
        XCTAssertEqual(output.count, 1); XCTAssertTrue(try XCTUnwrap(output.first).contains("\"filename\":\"Quick Capture 2023-11-14T22-13-20Z.md\""))
        let preview = try adapter.preview(for: draft, configuration: fixture.configuration); output = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: fixture.root.path, confirmation: try preview.confirmationToken()), adapter: adapter, write: { output.append($0) }), 0)
        XCTAssertEqual(output, ["Quick Capture committed to \(fixture.inbox.appending(path: preview.filename).path)."])

        let failedFixture = try HeadlessCaptureFixture(); defer { failedFixture.remove() }
        let failing = HeadlessCaptureCommandAdapter(makeService: { ProductionsInboxCaptureService(typedNoteVerifier: { _, _ in throw CocoaError(.fileReadCorruptFile) }) })
        let failingPreview = try failing.preview(for: draft, configuration: failedFixture.configuration); output = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: failedFixture.root.path, confirmation: try failingPreview.confirmationToken()), adapter: failing, write: { output.append($0) }), 3)
        XCTAssertEqual(output.count, 1); XCTAssertTrue(try XCTUnwrap(output.first).hasPrefix("Quick Capture was created; only post-write verification failed. Do not retry automatically. Service diagnostic:"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedFixture.inbox.appending(path: failingPreview.filename).path))
        XCTAssertFalse(try failing.preview(for: draft, configuration: failedFixture.configuration).destinationAbsent)
    }

    func testCommandLineRejectsMalformedInputBlankNoteAndMissingConfirmation() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: ["OperationsDashboard", "capture", "note", "--productions-root", fixture.root.path], write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["A root, note text, and valid occurred-at timestamp are required."])
        output = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: command(text: "   "), root: fixture.root.path, preview: true), write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["Enter a nonblank note."])
        output = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: command(), root: fixture.root.path), write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["A preview confirmation token is required."])
    }

    private func command(text: String = "hello", confirmation: String? = nil) -> CaptureNoteCommand { .init(text: text, timestamp: timestamp, confirmation: confirmation) }
    private func arguments(for command: CaptureNoteCommand, root: String, preview: Bool = false, confirmation: String? = nil) -> [String] {
        var values = ["OperationsDashboard", "capture"]; if preview { values.append("preview") }; values += ["note", "--productions-root", root, "--text", command.text, "--occurred-at", "2023-11-14T22:13:20Z"]
        if let confirmation { values += ["--confirm", confirmation] }; return values
    }
}

private final class HeadlessCaptureFixture {
    let root: URL; let inbox: URL; let configuration: ProductionsConfiguration
    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "TASK0054-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        inbox = root.appending(path: "Office/Inbox", directoryHint: .isDirectory); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Warehouse/Reference", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data("flow".utf8).write(to: root.appending(path: "Office/Flow.md")); try Data("ledger".utf8).write(to: root.appending(path: "Warehouse/Reference/Identifier Ledger.md"))
        configuration = .init(schemaVersion: 2, productionsRootPath: root.path)
    }
    func contractSnapshot() throws -> [Data] { [try Data(contentsOf: root.appending(path: "Office/Flow.md")), try Data(contentsOf: root.appending(path: "Warehouse/Reference/Identifier Ledger.md"))] }
    static func contractBaseline() throws -> [Data] { [Data("flow".utf8), Data("ledger".utf8)] }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
