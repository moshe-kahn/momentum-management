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
        XCTAssertFalse(preview.contents.contains("Task")); XCTAssertFalse(preview.contents.contains("Crumb")); XCTAssertFalse(preview.contents.contains("Priority"))
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

    func testCommitRejectsInboxDirectoryReplacementRaceBeforePublication() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let manager = FileManager.default
        let displaced = fixture.root.appending(path: "displaced-inbox", directoryHint: .isDirectory)
        let inbox = fixture.inbox
        let draft = command()
        let service = ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in },
            beforePublication: { _ in try FileManager.default.moveItem(at: inbox, to: displaced); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true) },
            afterPublication: { _ in },
            cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        ))
        let preview = try service.previewTypedNote(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp)

        XCTAssertThrowsError(try service.commitTypedNote(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp, preview: preview)) {
            guard case let TypedNoteCaptureError.recoveryRequired(message) = $0 else { return XCTFail("Expected quarantined recovery, got \($0)") }
            XCTAssertTrue(message.contains(preview.operationFingerprint)); XCTAssertTrue(message.contains("nothing was deleted")); XCTAssertTrue(message.contains("do not retry automatically"))
        }
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: fixture.inbox.path), [])
        let displacedEntries = try manager.contentsOfDirectory(atPath: displaced.path)
        XCTAssertEqual(displacedEntries.count, 1); XCTAssertTrue(try XCTUnwrap(displacedEntries.first).hasPrefix(".quick-capture-quarantine-"))
        XCTAssertEqual(try fixture.contractSnapshot(), try HeadlessCaptureFixture.contractBaseline())
    }

    func testPostPublicationInboxReplacementReportsIdentityWithoutFalseConfiguredPath() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let displaced = fixture.root.appending(path: "displaced-after-publication", directoryHint: .isDirectory)
        let inbox = fixture.inbox
        let service = ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in }, beforePublication: { _ in },
            afterPublication: { _ in try FileManager.default.moveItem(at: inbox, to: displaced); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true) },
            cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        ))
        let draft = command(text: "post publication secret")
        let preview = try service.previewTypedNote(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp)
        XCTAssertThrowsError(try service.commitTypedNote(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp, preview: preview)) { error in
            guard case let TypedNoteCaptureError.namespaceUncertain(message) = error else { return XCTFail("Expected namespace uncertainty, got \(error)") }
            XCTAssertTrue(message.contains(preview.operationFingerprint)); XCTAssertTrue(message.contains("No reliable pathname")); XCTAssertTrue(message.contains("automatic retry is prohibited"))
            XCTAssertFalse(message.contains(fixture.inbox.path)); XCTAssertFalse(message.contains(draft.text))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.inbox.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: displaced.path), [preview.filename])
    }

    func testTemporarySourceEntryReplacementBeforeRenameCannotPublishOrDeleteReplacement() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let inbox = fixture.inbox
        let service = ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in },
            beforePublication: { fingerprint in
                let temporary = inbox.appending(path: ".capture-note-\(fingerprint).tmp")
                let preserved = inbox.appending(path: ".preserved-source-\(fingerprint)")
                try FileManager.default.moveItem(at: temporary, to: preserved)
                try Data("replacement source bytes".utf8).write(to: temporary)
            },
            afterPublication: { _ in },
            cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        ))
        let draft = command(text: "source inode secret")
        let preview = try service.previewTypedNote(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp)

        XCTAssertThrowsError(try service.commitTypedNote(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp, preview: preview)) { error in
            guard case let TypedNoteCaptureError.namespaceUncertain(message) = error else { return XCTFail("Expected inode uncertainty, got \(error)") }
            XCTAssertTrue(message.contains(preview.operationFingerprint)); XCTAssertTrue(message.contains("temporary source entry")); XCTAssertTrue(message.contains("do not retry automatically")); XCTAssertFalse(message.contains(draft.text))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.inbox.appending(path: preview.filename).path))
        XCTAssertEqual(try Data(contentsOf: fixture.inbox.appending(path: ".capture-note-\(preview.operationFingerprint).tmp")), Data("replacement source bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.inbox.appending(path: ".preserved-source-\(preview.operationFingerprint)").path))
    }

    func testFinalEntrySymlinkReplacementDuringAfterPublicationCannotReportSuccess() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let inbox = fixture.inbox
        let outside = fixture.root.appending(path: "outside-final.txt")
        try Data("outside final bytes".utf8).write(to: outside)
        let service = ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in }, beforePublication: { _ in },
            afterPublication: { fingerprint in
                let final = inbox.appending(path: "Quick Capture 2023-11-14T22-13-20Z.md")
                try FileManager.default.moveItem(at: final, to: inbox.appending(path: ".preserved-final-\(fingerprint)"))
                try FileManager.default.createSymbolicLink(at: final, withDestinationURL: outside)
            },
            cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        ))
        let draft = command(text: "final inode secret")
        let preview = try service.previewTypedNote(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp)

        XCTAssertThrowsError(try service.commitTypedNote(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp, preview: preview)) { error in
            guard case let TypedNoteCaptureError.namespaceUncertain(message) = error else { return XCTFail("Expected inode uncertainty, got \(error)") }
            XCTAssertTrue(message.contains(preview.operationFingerprint)); XCTAssertTrue(message.contains("final entry")); XCTAssertTrue(message.contains("do not retry automatically")); XCTAssertFalse(message.contains(draft.text))
        }
        let values = try fixture.inbox.appending(path: preview.filename).resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside final bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.inbox.appending(path: ".preserved-final-\(preview.operationFingerprint)").path))
    }

    func testParentAndFinalInboxSymlinksAreNeverFollowed() throws {
        let manager = FileManager.default
        let testRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/test-temp", directoryHint: .isDirectory)
        let container = testRoot.appending(path: "TASK0076-symlink-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? manager.removeItem(at: container) }
        let realRoot = container.appending(path: "real", directoryHint: .isDirectory)
        try manager.createDirectory(at: realRoot.appending(path: "Office/Inbox", directoryHint: .isDirectory), withIntermediateDirectories: true)
        let linkedRoot = container.appending(path: "linked-root", directoryHint: .isDirectory)
        try manager.createSymbolicLink(at: linkedRoot, withDestinationURL: realRoot)
        XCTAssertThrowsError(try ProductionsInboxCaptureService().previewTypedNote(text: "parent escape", productionsRoot: linkedRoot, timestamp: timestamp))

        let nestedParent = container.appending(path: "nested-parent", directoryHint: .isDirectory)
        try manager.createDirectory(at: nestedParent, withIntermediateDirectories: true)
        let linkedComponent = nestedParent.appending(path: "linked-component", directoryHint: .isDirectory)
        try manager.createSymbolicLink(at: linkedComponent, withDestinationURL: container)
        XCTAssertThrowsError(try ProductionsInboxCaptureService().previewTypedNote(text: "nested parent escape", productionsRoot: linkedComponent.appending(path: "real"), timestamp: timestamp))

        let finalRoot = container.appending(path: "final-root", directoryHint: .isDirectory)
        let outside = container.appending(path: "outside", directoryHint: .isDirectory)
        try manager.createDirectory(at: finalRoot.appending(path: "Office", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: finalRoot.appending(path: "Office/Inbox"), withDestinationURL: outside)
        XCTAssertThrowsError(try ProductionsInboxCaptureService().previewTypedNote(text: "final escape", productionsRoot: finalRoot, timestamp: timestamp))
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: outside.path), [])
    }

    func testCollisionAndCreationFailureLeaveFlowAndLedgerUntouched() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let draft = command(); let preview = try HeadlessCaptureCommandAdapter().preview(for: draft, configuration: fixture.configuration)
        try Data("collision".utf8).write(to: fixture.inbox.appending(path: preview.filename))
        let collision = try HeadlessCaptureCommandAdapter().preview(for: draft, configuration: fixture.configuration)
        XCTAssertFalse(collision.destinationAbsent); XCTAssertEqual(collision.collisionOutcome, "Inbox already contains \(preview.filename).")
        XCTAssertThrowsError(try HeadlessCaptureCommandAdapter().execute(.init(text: draft.text, timestamp: timestamp, confirmation: try collision.confirmationToken()), configuration: fixture.configuration))
        let failing = HeadlessCaptureCommandAdapter(makeService: { ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in throw CocoaError(.fileWriteNoPermission) }, beforePublication: { _ in }, afterPublication: { _ in }, cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        )) })
        let clean = try HeadlessCaptureFixture(); defer { clean.remove() }; let cleanPreview = try failing.preview(for: draft, configuration: clean.configuration); var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: clean.root.path, confirmation: try cleanPreview.confirmationToken()), adapter: failing, write: { output.append($0) }), 2)
        XCTAssertEqual(output.count, 1)
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
        XCTAssertEqual(output, ["Quick Capture committed to \(fixture.inbox.appending(path: preview.filename).path). No identifier was issued; the payload is Unregistered and awaits Office processing."])

        let failedFixture = try HeadlessCaptureFixture(); defer { failedFixture.remove() }
        let failing = HeadlessCaptureCommandAdapter(makeService: { ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in }, beforePublication: { _ in }, afterPublication: { _ in throw CocoaError(.fileReadCorruptFile) }, cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        )) })
        let failingPreview = try failing.preview(for: draft, configuration: failedFixture.configuration); output = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: failedFixture.root.path, confirmation: try failingPreview.confirmationToken()), adapter: failing, write: { output.append($0) }), 3)
        XCTAssertEqual(output.count, 1); XCTAssertTrue(try XCTUnwrap(output.first).contains(failedFixture.inbox.appending(path: failingPreview.filename).path))
        XCTAssertTrue(try XCTUnwrap(output.first).contains("do not retry automatically"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: failedFixture.inbox.appending(path: failingPreview.filename).path))
        XCTAssertFalse(try failing.preview(for: draft, configuration: failedFixture.configuration).destinationAbsent)
    }

    func testCommandLinePreviewIsRedactedAndStillBindsSecretContent() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let secret = "PRIVATE-NOTE-7f93ce never echo"
        let draft = command(text: secret); var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: fixture.root.path, preview: true), write: { output.append($0) }), 0)
        let rendered = try XCTUnwrap(output.first)
        XCTAssertFalse(rendered.contains(secret)); XCTAssertFalse(rendered.contains("# Quick Capture")); XCTAssertFalse(rendered.contains("Source: Operations Dashboard")); XCTAssertFalse(rendered.contains("contents"))
        let redacted = try JSONDecoder().decode(RedactedPreviewEnvelope.self, from: Data(rendered.utf8))
        XCTAssertEqual(redacted.preview.contentByteCount, Data("# Quick Capture\n\nCreated: 2023-11-14T22:13:20Z\nSource: Operations Dashboard\n\n\(secret)\n".utf8).count)
        let changed = try HeadlessCaptureCommandAdapter().preview(for: command(text: secret + " changed"), configuration: fixture.configuration)
        XCTAssertNotEqual(redacted.confirmationToken, try changed.confirmationToken())

        let failing = HeadlessCaptureCommandAdapter(makeService: { ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in throw NSError(domain: secret, code: 17, userInfo: [NSLocalizedDescriptionKey: secret]) }, beforePublication: { _ in }, afterPublication: { _ in }, cleanupTransitionGate: TypedNotePublicationRuntime.live.cleanupTransitionGate
        )) })
        output = []
        let preview = try failing.preview(for: draft, configuration: fixture.configuration)
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: fixture.root.path, confirmation: try preview.confirmationToken()), adapter: failing, write: { output.append($0) }), 2)
        XCTAssertFalse(try XCTUnwrap(output.first).contains(secret))
    }

    func testStaleProcessResidueRequiresConfirmedCleanupOnlyThenFreshPreview() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let adapter = HeadlessCaptureCommandAdapter(); let draft = command(text: "interrupted private note")
        let original = try adapter.preview(for: draft, configuration: fixture.configuration)
        let residue = fixture.inbox.appending(path: ".capture-note-\(original.operationFingerprint).tmp")
        try Data("partial private bytes".utf8).write(to: residue)
        let recoveryPreview = try adapter.preview(for: draft, configuration: fixture.configuration)
        XCTAssertTrue(recoveryPreview.requiresRecovery)
        let outcome = try adapter.executeConfirmed(command(text: draft.text, confirmation: try recoveryPreview.confirmationToken()), configuration: fixture.configuration)
        guard case let .recovered(recovery) = outcome else { return XCTFail("Expected cleanup-only recovery") }
        XCTAssertEqual(recovery.removedOperationFingerprints, [original.operationFingerprint])
        XCTAssertEqual(recovery.quarantineNames.count, 1); XCTAssertTrue(try XCTUnwrap(recovery.quarantineNames.first).hasPrefix(".quick-capture-quarantine-"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.inbox.path), recovery.quarantineNames)
        XCTAssertFalse(try adapter.preview(for: draft, configuration: fixture.configuration).requiresRecovery)
    }

    func testResidueCleanupFailureIsLiteralPrivateAndNeverPublishesOrRetries() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let draft = command(text: "cleanup secret 9411")
        let original = try HeadlessCaptureCommandAdapter().preview(for: draft, configuration: fixture.configuration)
        let residueName = ".capture-note-\(original.operationFingerprint).tmp"
        try Data("partial cleanup secret 9411".utf8).write(to: fixture.inbox.appending(path: residueName))
        let failing = HeadlessCaptureCommandAdapter(makeService: { ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in }, beforePublication: { _ in }, afterPublication: { _ in }, cleanupTransitionGate: { _, _ in errno = EACCES; return -1 }
        )) })
        let recoveryPreview = try failing.preview(for: draft, configuration: fixture.configuration); var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: fixture.root.path, confirmation: try recoveryPreview.confirmationToken()), adapter: failing, write: { output.append($0) }), 3)
        let diagnostic = try XCTUnwrap(output.first)
        XCTAssertTrue(diagnostic.contains(original.operationFingerprint)); XCTAssertTrue(diagnostic.contains("errno \(EACCES)")); XCTAssertTrue(diagnostic.contains("automatic retry is prohibited")); XCTAssertFalse(diagnostic.contains(draft.text))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.inbox.path), [residueName])
    }

    func testConfirmedResidueReplacementAfterFinalValidationBeforeQuarantineIsRestoredAndUncertain() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let draft = command(text: "residue binding secret")
        let initial = try HeadlessCaptureCommandAdapter().preview(for: draft, configuration: fixture.configuration)
        let residue = fixture.inbox.appending(path: ".capture-note-\(initial.operationFingerprint).tmp")
        try Data("stale private bytes".utf8).write(to: residue)
        let confirmed = try HeadlessCaptureCommandAdapter().preview(for: draft, configuration: fixture.configuration)
        XCTAssertEqual(confirmed.temporaryResidues.count, 1)
        XCTAssertTrue(try XCTUnwrap(confirmed.temporaryResidues.first).identity.isOwnedRegularFile)

        let inbox = fixture.inbox
        let outside = fixture.root.appending(path: "outside-residue.txt")
        try Data("outside residue bytes".utf8).write(to: outside)
        let transitionCalls = SendableInvocationCounter()
        let service = ProductionsInboxCaptureService(typedNotePublicationRuntime: .init(
            beforeTemporaryCreation: { _ in }, beforePublication: { _ in }, afterPublication: { _ in },
            cleanupTransitionGate: { _, _ in transitionCalls.record(); return 0 },
            afterCleanupValidation: { fingerprint in
                let current = inbox.appending(path: ".capture-note-\(fingerprint).tmp")
                try FileManager.default.moveItem(at: current, to: inbox.appending(path: ".preserved-residue-\(fingerprint)"))
                try FileManager.default.createSymbolicLink(at: current, withDestinationURL: outside)
            }
        ))

        XCTAssertThrowsError(try service.recoverTypedNoteResidue(text: draft.text, productionsRoot: fixture.root, timestamp: timestamp, preview: confirmed)) { error in
            guard case let TypedNoteCaptureError.namespaceUncertain(message) = error else { return XCTFail("Expected residue inode uncertainty, got \(error)") }
            XCTAssertTrue(message.contains(initial.operationFingerprint)); XCTAssertTrue(message.contains("post-validation replacement")); XCTAssertTrue(message.contains("Nothing was deleted")); XCTAssertTrue(message.contains("do not retry automatically")); XCTAssertFalse(message.contains(draft.text))
        }
        XCTAssertEqual(transitionCalls.count, 1)
        let values = try residue.resourceValues(forKeys: [.isSymbolicLinkKey])
        XCTAssertEqual(values.isSymbolicLink, true)
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside residue bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.inbox.appending(path: ".preserved-residue-\(initial.operationFingerprint)").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.inbox.path).contains { $0.hasPrefix(".quick-capture-quarantine-") })
    }

    func testUnsafeResidueSymlinkIsReportedAndNeverFollowedOrRemoved() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let draft = command(text: "unsafe residue note"), adapter = HeadlessCaptureCommandAdapter()
        let outside = fixture.root.appending(path: "outside-private.txt")
        try Data("outside bytes".utf8).write(to: outside)
        let name = ".capture-note-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tmp"
        try FileManager.default.createSymbolicLink(at: fixture.inbox.appending(path: name), withDestinationURL: outside)
        let preview = try adapter.preview(for: draft, configuration: fixture.configuration)
        XCTAssertTrue(preview.requiresRecovery); XCTAssertEqual(preview.unsafeTemporaryResidueCount, 1); XCTAssertEqual(preview.temporaryResidueOperationFingerprints, [])
        XCTAssertThrowsError(try adapter.executeConfirmed(command(text: draft.text, confirmation: try preview.confirmationToken()), configuration: fixture.configuration)) {
            guard case let TypedNoteCaptureError.recoveryRequired(message) = $0 else { return XCTFail("Expected manual recovery requirement") }
            XCTAssertTrue(message.contains("unsafe residue count: 1")); XCTAssertFalse(message.contains(draft.text))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside bytes".utf8)); XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.inbox.appending(path: name).path))
    }

    func testDuplicateConfirmedSubmissionCreatesExactlyOneUnregisteredPayload() throws {
        let fixture = try HeadlessCaptureFixture(); defer { fixture.remove() }
        let adapter = HeadlessCaptureCommandAdapter(), draft = command()
        let preview = try adapter.preview(for: draft, configuration: fixture.configuration)
        let token = try preview.confirmationToken()
        var firstOutput: [String] = [], duplicateOutput: [String] = []

        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: fixture.root.path, confirmation: token), adapter: adapter, write: { firstOutput.append($0) }), 0)
        XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments(for: draft, root: fixture.root.path, confirmation: token), adapter: adapter, write: { duplicateOutput.append($0) }), 2)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.inbox.path), [preview.filename])
        XCTAssertTrue(try XCTUnwrap(firstOutput.first).contains("No identifier was issued"))
        XCTAssertTrue(try XCTUnwrap(duplicateOutput.first).contains("no longer matches its preview"))
        XCTAssertEqual(try fixture.contractSnapshot(), try HeadlessCaptureFixture.contractBaseline())
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

private struct RedactedPreviewEnvelope: Decodable {
    let preview: TypedNoteCaptureRedactedPreview
    let confirmationToken: String
}

private final class SendableInvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func record() { lock.withLock { value += 1 } }
}

private final class HeadlessCaptureFixture {
    let root: URL; let inbox: URL; let configuration: ProductionsConfiguration
    init() throws {
        let testRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: ".build/test-temp", directoryHint: .isDirectory)
        root = testRoot.appending(path: "TASK0054-capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        inbox = root.appending(path: "Office/Inbox", directoryHint: .isDirectory); try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Warehouse/Reference", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data("flow".utf8).write(to: root.appending(path: "Office/Flow.md")); try Data("ledger".utf8).write(to: root.appending(path: "Warehouse/Reference/Identifier Ledger.md"))
        configuration = .init(schemaVersion: 2, productionsRootPath: root.path)
    }
    func contractSnapshot() throws -> [Data] { [try Data(contentsOf: root.appending(path: "Office/Flow.md")), try Data(contentsOf: root.appending(path: "Warehouse/Reference/Identifier Ledger.md"))] }
    static func contractBaseline() throws -> [Data] { [Data("flow".utf8), Data("ledger".utf8)] }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
