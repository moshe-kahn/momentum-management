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
    func testTypedNoteIsMarkdownAndRejectsBlankAndExactCollision() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        var service = ProductionsInboxCaptureService(); let date = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(service.createTypedNote(text: "  ", productionsRoot: fixture.root, now: date), .rejected("Enter a nonblank note."))
        let first = service.createTypedNote(text: "hello", productionsRoot: fixture.root, now: date)
        guard case let .captured(url) = first else { return XCTFail("Expected note") }
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("# Quick Capture"))
        XCTAssertTrue(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("hello"))
        XCTAssertEqual(service.createTypedNote(text: "again", productionsRoot: fixture.root, now: date), .rejected("Inbox already contains \(url.lastPathComponent)."))
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
