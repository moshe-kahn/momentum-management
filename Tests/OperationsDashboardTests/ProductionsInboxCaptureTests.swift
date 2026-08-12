import Foundation
import XCTest
@testable import OperationsDashboard

final class ProductionsInboxCaptureTests: XCTestCase {
    func testManualFileCopyPreservesSourceAndNeverTouchesFlowOrLedger() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let source = fixture.source.appending(path: "manual.txt"); try Data("manual".utf8).write(to: source)
        let before = try fixture.contractSnapshot()
        var service = ProductionsInboxCaptureService()
        let result = service.copyManual(source: source, productionsRoot: fixture.root)
        XCTAssertEqual(result, .captured(fixture.inbox.appending(path: "manual.txt")))
        XCTAssertEqual(try Data(contentsOf: source), Data("manual".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.inbox.appending(path: "manual.txt")), Data("manual".utf8))
        XCTAssertEqual(try fixture.contractSnapshot(), before)
    }
    func testManualFolderCopyPreservesDescendantsAndExactNameConflictDoesNotRename() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let folder = fixture.source.appending(path: "folder", directoryHint: .isDirectory); try fixture.manager.createDirectory(at: folder, withIntermediateDirectories: true); try Data("child".utf8).write(to: folder.appending(path: "child.txt"))
        var service = ProductionsInboxCaptureService()
        _ = service.copyManual(source: folder, productionsRoot: fixture.root)
        XCTAssertEqual(try Data(contentsOf: folder.appending(path: "child.txt")), Data("child".utf8))
        XCTAssertEqual(try Data(contentsOf: fixture.inbox.appending(path: "folder/child.txt")), Data("child".utf8))
        XCTAssertEqual(service.copyManual(source: folder, productionsRoot: fixture.root), .rejected("Inbox already contains an item named folder."))
        XCTAssertFalse(fixture.manager.fileExists(atPath: fixture.inbox.appending(path: "folder (2)").path))
    }
    func testTypedNoteWithoutTerminalNewlineAppendsOneRealNewline() throws {
        try assertExactTypedNote(input: "no terminal newline", expectedBody: "no terminal newline\n", date: Date(timeIntervalSince1970: 0))
    }
    func testTypedNoteWithOneTerminalNewlinePreservesIt() throws {
        try assertExactTypedNote(input: "one terminal newline\n", expectedBody: "one terminal newline\n", date: Date(timeIntervalSince1970: 1))
    }
    func testTypedNotePreservesMultipleLinesVerbatimAndAppendsTerminalNewline() throws {
        try assertExactTypedNote(input: "first line\nsecond line\nthird line", expectedBody: "first line\nsecond line\nthird line\n", date: Date(timeIntervalSince1970: 2))
    }
    func testTypedNoteRejectsBlankInputWithoutCreatingPayload() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        var service = ProductionsInboxCaptureService()
        XCTAssertEqual(service.createTypedNote(text: "  \n\t ", productionsRoot: fixture.root, now: .distantPast), .rejected("Enter a nonblank note."))
        XCTAssertTrue(try fixture.manager.contentsOfDirectory(atPath: fixture.inbox.path).isEmpty)
    }
    private func assertExactTypedNote(input: String, expectedBody: String, date: Date, file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        var service = ProductionsInboxCaptureService()
        guard case let .captured(url) = service.createTypedNote(text: input, productionsRoot: fixture.root, now: date) else { return XCTFail("Expected typed note", file: file, line: line) }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let expected = "# Quick Capture\n\nCreated: \(formatter.string(from: date))\nSource: Operations Dashboard\n\n\(expectedBody)"
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes, Data(expected.utf8), file: file, line: line)
        XCTAssertNotEqual(Array(bytes.suffix(2)), [0x5C, 0x6E], "Quick Capture must not end with literal \\n.", file: file, line: line)
    }
    func testAutomaticCaptureDefersThenMovesStableItemsInPathOrderWithoutFlowWrites() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        try Data("b".utf8).write(to: fixture.source.appending(path: "b.txt")); try Data("a".utf8).write(to: fixture.source.appending(path: "a.txt"))
        let before = try fixture.contractSnapshot(); let clock = CaptureClock(); var service = ProductionsInboxCaptureService(now: { clock.value })
        let first = service.observeAutomatic(sourceFolder: fixture.source, productionsRoot: fixture.root)
        XCTAssertEqual(first.count, 2); XCTAssertTrue(first.allSatisfy { if case .deferred = $0 { true } else { false } })
        XCTAssertTrue(service.observeAutomatic(sourceFolder: fixture.source, productionsRoot: fixture.root).allSatisfy { if case .deferred = $0 { true } else { false } })
        clock.advance(2)
        let second = service.observeAutomatic(sourceFolder: fixture.source, productionsRoot: fixture.root)
        XCTAssertEqual(second, [.captured(fixture.inbox.appending(path: "a.txt")), .captured(fixture.inbox.appending(path: "b.txt"))])
        XCTAssertFalse(fixture.manager.fileExists(atPath: fixture.source.appending(path: "a.txt").path))
        XCTAssertEqual(try fixture.contractSnapshot(), before)
    }
    @MainActor
    func testMonitorIsIdempotentPersistsItsOneConfiguredSourceAndStopsSafely() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let suite = "TASK0043-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        let monitor = ProductionsAutomaticCaptureMonitor(storage: defaults, pollInterval: .seconds(60))
        monitor.configure(source: fixture.source, productionsRootPath: fixture.root.path)
        XCTAssertEqual(monitor.sourcePath, fixture.source.path)
        XCTAssertTrue(monitor.isMonitoring)
        monitor.start(productionsRootPath: fixture.root.path)
        XCTAssertTrue(monitor.isMonitoring)
        monitor.stop()
        XCTAssertFalse(monitor.isMonitoring)
    }
    @MainActor
    func testMonitorDoesNotOutliveItsOwnerWhenStopped() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let suite = "TASK0043-release-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!; defer { defaults.removePersistentDomain(forName: suite) }
        weak var released: ProductionsAutomaticCaptureMonitor?
        do {
            var monitor: ProductionsAutomaticCaptureMonitor? = ProductionsAutomaticCaptureMonitor(storage: defaults, pollInterval: .seconds(60))
            monitor?.configure(source: fixture.source, productionsRootPath: fixture.root.path)
            released = monitor
            monitor = nil
        }
        XCTAssertNil(released)
    }
    func testAutomaticConflictAndSymlinkLeaveSourcesUntouched() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let source = fixture.source.appending(path: "conflict.txt"); try Data("source".utf8).write(to: source); try Data("dest".utf8).write(to: fixture.inbox.appending(path: "conflict.txt"))
        let link = fixture.source.appending(path: "link"); try fixture.manager.createSymbolicLink(at: link, withDestinationURL: source)
        let clock = CaptureClock(); var service = ProductionsInboxCaptureService(now: { clock.value }); _ = service.observeAutomatic(sourceFolder: fixture.source, productionsRoot: fixture.root); clock.advance(2)
        let results = service.observeAutomatic(sourceFolder: fixture.source, productionsRoot: fixture.root)
        XCTAssertTrue(results.contains(.rejected("Inbox already contains an item named conflict.txt.")))
        XCTAssertTrue(fixture.manager.fileExists(atPath: source.path)); XCTAssertTrue(fixture.manager.fileExists(atPath: link.path))
    }
}

private final class CaptureFixture {
    let manager = FileManager.default; let root: URL; let source: URL; let inbox: URL
    init() throws { root = manager.temporaryDirectory.appending(path: "TASK0043-\(UUID().uuidString)", directoryHint: .isDirectory); source = root.appending(path: "source", directoryHint: .isDirectory); inbox = root.appending(path: "Office/Inbox", directoryHint: .isDirectory); try manager.createDirectory(at: source, withIntermediateDirectories: true); try manager.createDirectory(at: inbox, withIntermediateDirectories: true); try Data("flow".utf8).write(to: root.appending(path: "Office/Flow.md")); try manager.createDirectory(at: root.appending(path: "Warehouse/Reference", directoryHint: .isDirectory), withIntermediateDirectories: true); try Data("ledger".utf8).write(to: root.appending(path: "Warehouse/Reference/Identifier Ledger.md")) }
    func contractSnapshot() throws -> [Data] { [try Data(contentsOf: root.appending(path: "Office/Flow.md")), try Data(contentsOf: root.appending(path: "Warehouse/Reference/Identifier Ledger.md"))] }
    func remove() { try? manager.removeItem(at: root) }
}

private final class CaptureClock { var value = Date(timeIntervalSince1970: 0); func advance(_ seconds: TimeInterval) { value = value.addingTimeInterval(seconds) } }
