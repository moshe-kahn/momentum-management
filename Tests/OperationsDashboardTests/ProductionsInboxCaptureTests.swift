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
    func testTypedNoteInterruptionBeforePublicationQuarantinesTemporaryInodeWithoutPayload() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let before = try fixture.contractSnapshot()
        var service = ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in },
            beforePublication: { _ in throw NSError(domain: "TypedNoteInterruption", code: 1) },
            afterPublication: { _ in },
            cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        ))

        let outcome = service.createTypedNote(text: "interrupted idea", productionsRoot: fixture.root, now: Date(timeIntervalSince1970: 4))

        guard case let .rejected(message) = outcome else { return XCTFail("Expected a proven pre-publication recovery state, got \(outcome)") }
        XCTAssertTrue(message.contains("preserved as .quick-capture-quarantine-")); XCTAssertTrue(message.contains("nothing was deleted")); XCTAssertTrue(message.contains("do not retry automatically"))
        let entries = try fixture.manager.contentsOfDirectory(atPath: fixture.inbox.path)
        XCTAssertEqual(entries.count, 1); XCTAssertTrue(try XCTUnwrap(entries.first).hasPrefix(".quick-capture-quarantine-"))
        XCTAssertEqual(try fixture.contractSnapshot(), before)
    }
    func testOrdinaryTemporaryCleanupPreservesPostValidationReplacement() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 42), text = "ordinary cleanup race secret"
        let outside = fixture.root.appending(path: "outside-cleanup.txt")
        try Data("outside cleanup bytes".utf8).write(to: outside)
        let inbox = fixture.inbox
        let runtime = TypedNotePublicationRuntime(
            beforeTemporaryCreation: { _ in },
            beforePublication: { _ in throw NSError(domain: "StopBeforePublication", code: 1) },
            afterPublication: { _ in },
            cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate,
            afterCleanupValidation: { fingerprint in
                let current = inbox.appending(path: ".capture-note-\(fingerprint).tmp")
                try FileManager.default.moveItem(at: current, to: inbox.appending(path: ".preserved-cleanup-\(fingerprint)"))
                try FileManager.default.createSymbolicLink(at: current, withDestinationURL: outside)
            }
        )
        let service = ProductionsInboxCaptureService(typedNotePublicationRuntime: runtime)
        let preview = try service.previewTypedNote(text: text, productionsRoot: fixture.root, timestamp: date)

        XCTAssertThrowsError(try service.commitTypedNote(text: text, productionsRoot: fixture.root, timestamp: date, preview: preview)) { error in
            guard case let TypedNoteCaptureError.namespaceUncertain(message) = error else { return XCTFail("Expected cleanup uncertainty, got \(error)") }
            XCTAssertTrue(message.contains(preview.operationFingerprint)); XCTAssertTrue(message.contains("post-validation replacement")); XCTAssertTrue(message.contains("Nothing was deleted")); XCTAssertTrue(message.contains("do not retry automatically")); XCTAssertFalse(message.contains(text))
        }
        let temporary = fixture.inbox.appending(path: ".capture-note-\(preview.operationFingerprint).tmp")
        XCTAssertEqual(try temporary.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink, true)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside cleanup bytes".utf8))
        XCTAssertTrue(fixture.manager.fileExists(atPath: fixture.inbox.appending(path: ".preserved-cleanup-\(preview.operationFingerprint)").path))
        XCTAssertFalse(try fixture.manager.contentsOfDirectory(atPath: fixture.inbox.path).contains { $0.hasPrefix(".quick-capture-quarantine-") })
    }
    func testTypedNoteInterruptionSurfacesTemporaryCleanupFailureAndLeavesGovernedResidue() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 41), text = "cleanup must not echo this note"
        let transitionAttempts = CleanupTransitionAttemptCounter()
        let runtime = TypedNotePublicationRuntime(
            beforeTemporaryCreation: { _ in },
            beforePublication: { _ in throw NSError(domain: text, code: 1) },
            afterPublication: { _ in },
            cleanupTransitionGate: { _, _ in transitionAttempts.fail() }
        )
        let service = ProductionsInboxCaptureService(typedNotePublicationRuntime: runtime)
        let preview = try service.previewTypedNote(text: text, productionsRoot: fixture.root, timestamp: date)
        XCTAssertThrowsError(try service.commitTypedNote(text: text, productionsRoot: fixture.root, timestamp: date, preview: preview)) { error in
            guard case let TypedNoteCaptureError.recoveryRequired(message) = error else { return XCTFail("Expected governed recovery, got \(error)") }
            XCTAssertTrue(message.contains(preview.operationFingerprint)); XCTAssertTrue(message.contains("errno \(EACCES)")); XCTAssertTrue(message.contains("automatic retry is prohibited")); XCTAssertFalse(message.contains(text))
        }
        XCTAssertEqual(transitionAttempts.count, 1)
        XCTAssertEqual(try fixture.manager.contentsOfDirectory(atPath: fixture.inbox.path), [".capture-note-\(preview.operationFingerprint).tmp"])
    }
    func testTypedNotePostPublicationInterruptionPreservesExactPayloadAndBlocksDuplicateRecovery() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 5)
        var interrupted = ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in },
            beforePublication: { _ in },
            afterPublication: { _ in throw NSError(domain: "TypedNoteInterruption", code: 2) },
            cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        ))

        let outcome = interrupted.createTypedNote(text: "recover this idea", productionsRoot: fixture.root, now: date)

        guard case let .verificationRequired(diagnostic) = outcome else { return XCTFail("Expected published recovery state, got \(outcome)") }
        XCTAssertTrue(diagnostic.contains(fixture.inbox.path))
        XCTAssertTrue(diagnostic.contains("do not retry automatically"))
        let entries = try fixture.manager.contentsOfDirectory(at: fixture.inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].lastPathComponent.hasPrefix("."))
        XCTAssertEqual(try String(contentsOf: entries[0], encoding: .utf8), "# Quick Capture\n\nCreated: 1970-01-01T00:00:05Z\nSource: Operations Dashboard\n\nrecover this idea\n")

        var recoveryAttempt = ProductionsInboxCaptureService()
        let repeated = recoveryAttempt.createTypedNote(text: "recover this idea", productionsRoot: fixture.root, now: date)
        guard case let .rejected(reason) = repeated else { return XCTFail("Expected duplicate recovery to stop, got \(repeated)") }
        XCTAssertTrue(reason.contains("Inbox already contains"))
        XCTAssertEqual(try fixture.manager.contentsOfDirectory(atPath: fixture.inbox.path).count, 1)
    }
    func testConcurrentTypedNotePublicationReportsActiveOperationAndAllowsExactlyOneWinner() throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        let gate = CapturePublicationGate(), results = ConcurrentCaptureResults()
        let preview = try ProductionsInboxCaptureService().previewTypedNote(text: "concurrent idea", productionsRoot: fixture.root, timestamp: Date(timeIntervalSince1970: 6))
        let attempt = ConcurrentTypedNoteAttempt(preview: preview, root: fixture.root, gate: gate, results: results)
        DispatchQueue.global().async { attempt.run() }
        XCTAssertEqual(gate.ready.wait(timeout: .now() + 5), .success)
        XCTAssertThrowsError(try ProductionsInboxCaptureService().previewTypedNote(text: "second idea", productionsRoot: fixture.root, timestamp: Date(timeIntervalSince1970: 7))) {
            XCTAssertEqual($0 as? TypedNoteCaptureError, .activeConcurrency)
        }
        gate.release.signal()
        XCTAssertEqual(results.finished.wait(timeout: .now() + 5), .success)

        XCTAssertEqual(results.capturedCount, 1)
        XCTAssertEqual(results.rejectedCount, 0)
        let entries = try fixture.manager.contentsOfDirectory(at: fixture.inbox, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 1)
        XCTAssertFalse(entries[0].lastPathComponent.hasPrefix("."))
        XCTAssertEqual(try String(contentsOf: entries[0], encoding: .utf8).components(separatedBy: "concurrent idea").count, 2)
    }
    @MainActor
    func testTypedNoteFeedbackPostsExplicitAccessibleSuccessAndRecoveryAnnouncements() {
        var announcements: [String] = []
        let presenter = ProductionsInboxCaptureFeedbackPresenter { announcements.append($0) }
        let destination = URL(fileURLWithPath: "/Productions/Office/Inbox/Quick Capture.md")

        let success = presenter.present(.captured(destination))
        let recovery = presenter.present(.verificationRequired("Inspect the published payload; do not retry automatically."))

        XCTAssertTrue(success.succeeded)
        XCTAssertTrue(success.published)
        XCTAssertEqual(success.accessibilityAnnouncement, "Quick Capture succeeded. Captured Quick Capture.md as an unregistered Inbox payload.")
        XCTAssertFalse(recovery.succeeded)
        XCTAssertTrue(recovery.published)
        XCTAssertTrue(recovery.accessibilityAnnouncement.hasPrefix("Quick Capture needs recovery review."))
        XCTAssertEqual(announcements, [success.accessibilityAnnouncement, recovery.accessibilityAnnouncement])
    }
    private func assertExactTypedNote(input: String, expectedBody: String, date: Date, file: StaticString = #filePath, line: UInt = #line) throws {
        let fixture = try CaptureFixture(); defer { fixture.remove() }
        var service = ProductionsInboxCaptureService()
        let outcome = service.createTypedNote(text: input, productionsRoot: fixture.root, now: date)
        guard case let .captured(url) = outcome else { return XCTFail("Expected typed note, got \(outcome)", file: file, line: line) }
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
    init() throws { let testRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/test-temp", directoryHint: .isDirectory); root = testRoot.appending(path: "TASK0043-\(UUID().uuidString)", directoryHint: .isDirectory); source = root.appending(path: "source", directoryHint: .isDirectory); inbox = root.appending(path: "Office/Inbox", directoryHint: .isDirectory); try manager.createDirectory(at: source, withIntermediateDirectories: true); try manager.createDirectory(at: inbox, withIntermediateDirectories: true); try Data("flow".utf8).write(to: root.appending(path: "Office/Flow.md")); try manager.createDirectory(at: root.appending(path: "Warehouse/Reference", directoryHint: .isDirectory), withIntermediateDirectories: true); try Data("ledger".utf8).write(to: root.appending(path: "Warehouse/Reference/Identifier Ledger.md")) }
    func contractSnapshot() throws -> [Data] { [try Data(contentsOf: root.appending(path: "Office/Flow.md")), try Data(contentsOf: root.appending(path: "Warehouse/Reference/Identifier Ledger.md"))] }
    func remove() { try? manager.removeItem(at: root) }
}

private final class CaptureClock { var value = Date(timeIntervalSince1970: 0); func advance(_ seconds: TimeInterval) { value = value.addingTimeInterval(seconds) } }

private final class CleanupTransitionAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    var count: Int { lock.withLock { attempts } }
    func fail() -> Int32 { lock.withLock { attempts += 1 }; errno = EACCES; return -1 }
}

private final class CapturePublicationGate: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

private final class ConcurrentCaptureResults: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcomes: [ProductionsInboxCaptureOutcome] = []
    var capturedCount: Int { lock.withLock { outcomes.filter { if case .captured = $0 { true } else { false } }.count } }
    var rejectedCount: Int { lock.withLock { outcomes.filter { if case .rejected = $0 { true } else { false } }.count } }
    func record(_ outcome: ProductionsInboxCaptureOutcome) { lock.withLock { outcomes.append(outcome) }; finished.signal() }
}

private final class ConcurrentTypedNoteAttempt: @unchecked Sendable {
    private let preview: TypedNoteCapturePreview
    private let root: URL
    private let gate: CapturePublicationGate
    private let results: ConcurrentCaptureResults
    init(preview: TypedNoteCapturePreview, root: URL, gate: CapturePublicationGate, results: ConcurrentCaptureResults) { self.preview = preview; self.root = root; self.gate = gate; self.results = results }
    func run() {
        let runtime = TypedNotePublicationRuntime(
            beforeTemporaryCreation: { _ in },
            beforePublication: { [gate] _ in gate.ready.signal(); guard gate.release.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "ConcurrentCapture", code: 1) } },
            afterPublication: { _ in },
            cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        )
        do { let url = try ProductionsInboxCaptureService(typedNotePublicationRuntime: runtime).commitTypedNote(text: "concurrent idea", productionsRoot: root, timestamp: Date(timeIntervalSince1970: 6), preview: preview); results.record(.captured(url)) }
        catch { results.record(.rejected(error.localizedDescription)) }
    }
}
