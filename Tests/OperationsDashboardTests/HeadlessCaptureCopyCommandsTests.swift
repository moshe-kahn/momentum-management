import Darwin
import Foundation
import XCTest
@testable import OperationsDashboard

final class HeadlessCaptureCopyCommandsTests: XCTestCase {
    func testRegularFileCloneSuccessPreservesSourceVerifiesDigestAndDoesNotTouchFlowOrLedger() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let source = try makeSource("clone payload", name: "clone.txt", fixture: fixture)
        let beforeContract = try contractSnapshot(fixture)
        var sourceStat = stat(); XCTAssertEqual(lstat(source.path, &sourceStat), 0)
        let adapter = HeadlessCaptureCopyAdapter()
        let preview = try adapter.preview(.init(source: source.path, confirmedPreview: nil, confirmation: nil), configuration: fixture.configuration)
        XCTAssertEqual(preview.supportPolicy, "regular files only; same clone-capable filesystem; directories and packages remain GUI-only")
        XCTAssertEqual(preview.sourceSHA256.count, 64)
        XCTAssertEqual(try CaptureCopyPreview.decodeConfirmedEnvelope(preview.confirmedEnvelope(), token: preview.confirmationToken()), preview)
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: try executeArguments(source, fixture: fixture, preview: preview), adapter: adapter, write: { output.append($0) }), 0)
        let destination = fixture.url(at: "Office/Inbox/clone.txt")
        XCTAssertEqual(output, ["Capture copy committed to \(destination.path); source preserved and destination SHA-256 verified (\(preview.sourceSHA256))."])
        XCTAssertEqual(try Data(contentsOf: source), Data("clone payload".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("clone payload".utf8))
        var destinationStat = stat(); XCTAssertEqual(lstat(destination.path, &destinationStat), 0)
        XCTAssertNotEqual(UInt64(sourceStat.st_ino), UInt64(destinationStat.st_ino))
        XCTAssertEqual(try contractSnapshot(fixture), beforeContract)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.url(at: "Office/Inbox").path).contains { $0.hasPrefix(".capture-") })
    }

    func testLiteralPreviewEnvelopeUsageAndNoArgumentGUIRouting() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let source = try makeSource("preview", name: "preview.txt", fixture: fixture)
        XCTAssertNil(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: ["OperationsDashboard"]))
        XCTAssertNil(HeadlessCaptureCommandLine.runIfRequested(arguments: ["OperationsDashboard"]))
        let malformedCaptures = [
            ["OperationsDashboard", "capture"],
            ["OperationsDashboard", "capture", "unknown"],
            ["OperationsDashboard", "capture", "preview", "unknown"]
        ]
        for arguments in malformedCaptures {
            XCTAssertNil(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: arguments))
            var malformedOutput: [String] = []
            XCTAssertEqual(HeadlessCaptureCommandLine.runIfRequested(arguments: arguments, write: { malformedOutput.append($0) }), 2)
            XCTAssertEqual(malformedOutput, ["Usage: OperationsDashboard capture [preview] note --productions-root <path> --text <note> --occurred-at <ISO-8601> [--confirm <token>]"])
        }
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: ["OperationsDashboard", "capture", "copy"], write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["Usage: OperationsDashboard capture [preview] copy --productions-root <path> --source <regular-file> [--confirmed-preview <base64>] [--confirm <token>]"])
        output = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: previewArguments(source, fixture: fixture), write: { output.append($0) }), 0)
        let json = try XCTUnwrap(output.first?.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNotNil(object["confirmedPreview"] as? String)
        XCTAssertTrue(try XCTUnwrap(object["confirmationToken"] as? String).hasPrefix("confirm:capture-copy:v2:"))
    }

    func testCollisionIsExitTwoAndNeverOverwrites() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let source = try makeSource("source", name: "collision.txt", fixture: fixture)
        let destination = fixture.url(at: "Office/Inbox/collision.txt")
        try Data("existing".utf8).write(to: destination)
        let preview = try ProductionsInboxCaptureService().previewFileCopy(source: source, productionsRoot: fixture.root)
        XCTAssertFalse(preview.destinationAbsent)
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: try executeArguments(source, fixture: fixture, preview: preview), write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["Office/Inbox already contains an item named collision.txt."])
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
    }

    func testStaleSourceInboxAndProductionsStateRejectBeforeClone() throws {
        try withPreview(name: "stale-source.txt") { fixture, source, preview in
            try Data("changed".utf8).write(to: source)
            try assertFailure("The capture source changed after preview. Re-run capture copy preview.", source: source, fixture: fixture, preview: preview)
        }
        try withPreview(name: "stale-inbox.txt") { fixture, source, preview in
            try Data("unrelated".utf8).write(to: fixture.url(at: "Office/Inbox/unrelated.txt"))
            try assertFailure("Office/Inbox changed after preview. Re-run capture copy preview.", source: source, fixture: fixture, preview: preview)
        }
        try withPreview(name: "stale-productions.txt") { fixture, source, preview in
            let departments = fixture.url(at: "Office/Registry/Departments.md")
            var data = try Data(contentsOf: departments); data.append(Data("\n".utf8)); try data.write(to: departments)
            try assertFailure("The Productions state changed after preview. Re-run capture copy preview.", source: source, fixture: fixture, preview: preview)
        }
    }

    func testDirectoryPackageSymlinkAndSpecialFileAreRejectedBeforeMutation() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let rawSources = fixture.url(at: "capture-sources")
        try FileManager.default.createDirectory(at: rawSources, withIntermediateDirectories: true)
        let sources = try canonicalURL(rawSources)
        let directory = sources.appending(path: "Folder"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let package = sources.appending(path: "Example.app"); try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let target = sources.appending(path: "target.txt"); try Data("target".utf8).write(to: target)
        let symlink = sources.appending(path: "alias.txt"); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let fifo = sources.appending(path: "pipe"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for source in [directory, package] {
            XCTAssertThrowsError(try ProductionsInboxCaptureService().previewFileCopy(source: source, productionsRoot: fixture.root)) {
                XCTAssertEqual($0.localizedDescription, "Phase 3D headless capture copy supports regular files only; directories and packages remain GUI-only.")
            }
        }
        XCTAssertThrowsError(try ProductionsInboxCaptureService().previewFileCopy(source: symlink, productionsRoot: fixture.root)) {
            XCTAssertEqual($0.localizedDescription, "Headless capture copy rejects symbolic links in every source path component.")
        }
        XCTAssertThrowsError(try ProductionsInboxCaptureService().previewFileCopy(source: fifo, productionsRoot: fixture.root)) {
            XCTAssertEqual($0.localizedDescription, "Phase 3D headless capture copy rejects symbolic links and special files.")
        }
        let realParent = sources.appending(path: "real-parent"); try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: realParent.appending(path: "nested.txt"))
        let linkedParent = sources.appending(path: "linked-parent"); try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        XCTAssertThrowsError(try ProductionsInboxCaptureService().previewFileCopy(source: linkedParent.appending(path: "nested.txt"), productionsRoot: fixture.root)) {
            XCTAssertEqual($0.localizedDescription, "Headless capture copy rejects symbolic links in every source path component.")
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: fixture.url(at: "Office/Inbox").path)), ["FLOW-000001.md"])
    }

    func testCrossVolumeAndCloneUnavailablePoliciesRejectBeforeMutation() throws {
        let crossFixture = try SyntheticProductionsFixture(); defer { crossFixture.remove() }
        let crossSource = try makeSource("cross", name: "cross.txt", fixture: crossFixture)
        let crossAdapter = adapter(runtime(sameFileSystem: false))
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: previewArguments(crossSource, fixture: crossFixture), adapter: crossAdapter, write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["Headless capture copy requires the source and Office/Inbox to be on the same filesystem."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: crossFixture.url(at: "Office/Inbox/cross.txt").path))

        let unsupportedFixture = try SyntheticProductionsFixture(); defer { unsupportedFixture.remove() }
        let unsupportedSource = try makeSource("unsupported", name: "unsupported.txt", fixture: unsupportedFixture)
        let unsupportedAdapter = adapter(runtime(supportsClone: false))
        output = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: previewArguments(unsupportedSource, fixture: unsupportedFixture), adapter: unsupportedAdapter, write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["Office/Inbox is on a filesystem that does not support atomic file cloning; no mutation was attempted."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unsupportedFixture.url(at: "Office/Inbox/unsupported.txt").path))
    }

    func testCloneFailureIsExitTwoWithNoDestinationAndNoStaging() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let source = try makeSource("failure", name: "failure.txt", fixture: fixture)
        let failingAdapter = adapter(runtime(clone: { _, _, _ in EIO }))
        let preview = try failingAdapter.preview(.init(source: source.path, confirmedPreview: nil, confirmation: nil), configuration: fixture.configuration)
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: try executeArguments(source, fixture: fixture, preview: preview), adapter: failingAdapter, write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["Atomic capture clone failed before publication (errno \(EIO)); no destination was published."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.destinationPath))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: fixture.url(at: "Office/Inbox").path).contains { $0.hasPrefix(".capture-") })
    }

    func testFstatFailureAfterSuccessfulCloneIsLiteralExitThreeWithOneNoRetryDiagnostic() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let source = try makeSource("published", name: "fstat-failure.txt", fixture: fixture)
        let adapter = adapter(runtime(afterDestinationOpen: { descriptor in close(descriptor) }))
        let preview = try adapter.preview(.init(source: source.path, confirmedPreview: nil, confirmation: nil), configuration: fixture.configuration)
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: try executeArguments(source, fixture: fixture, preview: preview), adapter: adapter, write: { output.append($0) }), 3)
        XCTAssertEqual(output, ["Capture copy committed or may have committed; do not retry automatically. Service diagnostic: Post-publication verification failed for \(preview.destinationPath)."])
        XCTAssertEqual(output[0].components(separatedBy: "do not retry automatically").count - 1, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: preview.destinationPath)), Data("published".utf8))
    }

    func testInboxNamespaceReplacementAfterPublicationIsExitThreeAndNoRetry() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let source = try makeSource("namespace", name: "namespace.txt", fixture: fixture)
        let originalInbox = fixture.url(at: "Office/Inbox")
        let displacedInbox = fixture.url(at: "Office/Inbox-displaced")
        let uncertainAdapter = adapter(runtime(afterPublication: {
            try? FileManager.default.moveItem(at: originalInbox, to: displacedInbox)
            try? FileManager.default.createDirectory(at: originalInbox, withIntermediateDirectories: false)
        }))
        let preview = try uncertainAdapter.preview(.init(source: source.path, confirmedPreview: nil, confirmation: nil), configuration: fixture.configuration)
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: try executeArguments(source, fixture: fixture, preview: preview), adapter: uncertainAdapter, write: { output.append($0) }), 3)
        XCTAssertEqual(output, ["Capture copy committed or may have committed; do not retry automatically. Service diagnostic: Post-publication verification failed for \(preview.destinationPath)."])
        XCTAssertEqual(try Data(contentsOf: displacedInbox.appending(path: "namespace.txt")), Data("namespace".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("namespace".utf8))
    }

    func testInboxNamespaceReplacementBeforePublicationStopsBeforeClone() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let source = try makeSource("before", name: "before-namespace.txt", fixture: fixture)
        let originalInbox = fixture.url(at: "Office/Inbox")
        let displacedInbox = fixture.url(at: "Office/Inbox-before-displaced")
        var cloneCalls = 0
        let live = CaptureFileCloneRuntime.live
        let guardedAdapter = adapter(runtime(clone: { sourceFD, inboxFD, name in
            cloneCalls += 1
            return live.clone(sourceFD, inboxFD, name)
        }, beforePublication: {
            try? FileManager.default.moveItem(at: originalInbox, to: displacedInbox)
            try? FileManager.default.createDirectory(at: originalInbox, withIntermediateDirectories: false)
        }))
        let preview = try guardedAdapter.preview(.init(source: source.path, confirmedPreview: nil, confirmation: nil), configuration: fixture.configuration)
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: try executeArguments(source, fixture: fixture, preview: preview), adapter: guardedAdapter, write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["Office/Inbox changed after preview. Re-run capture copy preview."])
        XCTAssertEqual(cloneCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: displacedInbox.appending(path: "before-namespace.txt").path))
    }

    func testForgedEnvelopeDestinationAndTokenCannotReachServiceMutation() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let source = try makeSource("authority", name: "authority.txt", fixture: fixture)
        let preview = try ProductionsInboxCaptureService().previewFileCopy(source: source, productionsRoot: fixture.root)
        var malformedToken = try preview.confirmationToken(); malformedToken.append("x")
        var output: [String] = []
        var arguments = try executeArguments(source, fixture: fixture, preview: preview)
        arguments[arguments.count - 1] = malformedToken
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: arguments, write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["The command does not match its confirmed capture-copy preview. Re-run capture copy preview."])

        let forged = CaptureCopyPreview(
            schema: preview.schema,
            actionDiscriminator: preview.actionDiscriminator,
            supportPolicy: preview.supportPolicy,
            productionsRoot: preview.productionsRoot,
            productionsRootResolvedPath: preview.productionsRootResolvedPath,
            officePath: preview.officePath,
            inboxPath: preview.inboxPath,
            sourcePath: preview.sourcePath,
            sourceResolvedPath: preview.sourceResolvedPath,
            sourceBasename: preview.sourceBasename,
            destinationPath: fixture.url(at: "Workspace/forged.txt").path,
            sourceSHA256: preview.sourceSHA256,
            productionsSHA256: preview.productionsSHA256,
            inboxSHA256: preview.inboxSHA256,
            postPublicationProductionsBaselineSHA256: preview.postPublicationProductionsBaselineSHA256,
            postPublicationInboxBaselineSHA256: preview.postPublicationInboxBaselineSHA256,
            rootState: preview.rootState,
            officeState: preview.officeState,
            inboxState: preview.inboxState,
            sourceParentState: preview.sourceParentState,
            sourceState: preview.sourceState,
            destinationAbsent: preview.destinationAbsent
        )
        output = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: ["OperationsDashboard", "capture", "copy", "--productions-root", fixture.root.path, "--source", source.path, "--confirmed-preview", try forged.confirmedEnvelope(), "--confirm", try forged.confirmationToken()], write: { output.append($0) }), 2)
        XCTAssertEqual(output, ["The command does not match its confirmed capture-copy preview. Re-run capture copy preview."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.destinationPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: forged.destinationPath))
    }

    func testDestinationReplacementAndSourceReplacementAfterPublicationAreCommittedUncertain() throws {
        let destinationFixture = try SyntheticProductionsFixture(); defer { destinationFixture.remove() }
        let destinationSource = try makeSource("destination", name: "destination-race.txt", fixture: destinationFixture)
        let destination = destinationFixture.url(at: "Office/Inbox/destination-race.txt")
        let destinationAdapter = adapter(runtime(afterPublication: {
            try? FileManager.default.removeItem(at: destination)
            try? Data("destination".utf8).write(to: destination)
        }))
        let destinationPreview = try destinationAdapter.preview(.init(source: destinationSource.path, confirmedPreview: nil, confirmation: nil), configuration: destinationFixture.configuration)
        try assertUncertain(adapter: destinationAdapter, source: destinationSource, fixture: destinationFixture, preview: destinationPreview)

        let sourceFixture = try SyntheticProductionsFixture(); defer { sourceFixture.remove() }
        let changedSource = try makeSource("source", name: "source-race.txt", fixture: sourceFixture)
        let sourceAdapter = adapter(runtime(afterPublication: {
            try? FileManager.default.removeItem(at: changedSource)
            try? Data("source".utf8).write(to: changedSource)
        }))
        let sourcePreview = try sourceAdapter.preview(.init(source: changedSource.path, confirmedPreview: nil, confirmation: nil), configuration: sourceFixture.configuration)
        try assertUncertain(adapter: sourceAdapter, source: changedSource, fixture: sourceFixture, preview: sourcePreview)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: sourcePreview.destinationPath)), Data("source".utf8))
    }

    private func runtime(supportsClone: Bool = true, sameFileSystem: Bool = true, clone: ((Int32, Int32, String) -> Int32)? = nil, beforePublication: @escaping () -> Void = {}, afterDestinationOpen: @escaping (Int32) -> Void = { _ in }, afterPublication: @escaping () -> Void = {}) -> CaptureFileCloneRuntime {
        let live = CaptureFileCloneRuntime.live
        return .init(supportsClone: { _ in supportsClone }, sameFileSystem: { _, _ in sameFileSystem }, clone: clone ?? live.clone, beforePublication: beforePublication, afterDestinationOpen: afterDestinationOpen, afterPublication: afterPublication)
    }

    private func adapter(_ runtime: CaptureFileCloneRuntime) -> HeadlessCaptureCopyAdapter {
        HeadlessCaptureCopyAdapter(makeService: { ProductionsInboxCaptureService(captureFileCloneRuntime: runtime) })
    }

    private func withPreview(name: String, body: (SyntheticProductionsFixture, URL, CaptureCopyPreview) throws -> Void) throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let source = try makeSource("original", name: name, fixture: fixture)
        let preview = try ProductionsInboxCaptureService().previewFileCopy(source: source, productionsRoot: fixture.root)
        try body(fixture, source, preview)
    }

    private func assertFailure(_ diagnostic: String, source: URL, fixture: SyntheticProductionsFixture, preview: CaptureCopyPreview, file: StaticString = #filePath, line: UInt = #line) throws {
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: try executeArguments(source, fixture: fixture, preview: preview), write: { output.append($0) }), 2, file: file, line: line)
        XCTAssertEqual(output, [diagnostic], file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preview.destinationPath), file: file, line: line)
    }

    private func assertUncertain(adapter: HeadlessCaptureCopyAdapter, source: URL, fixture: SyntheticProductionsFixture, preview: CaptureCopyPreview, file: StaticString = #filePath, line: UInt = #line) throws {
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureCopyCommandLine.runIfRequested(arguments: try executeArguments(source, fixture: fixture, preview: preview), adapter: adapter, write: { output.append($0) }), 3, file: file, line: line)
        XCTAssertEqual(output, ["Capture copy committed or may have committed; do not retry automatically. Service diagnostic: Post-publication verification failed for \(preview.destinationPath)."], file: file, line: line)
    }

    private func makeSource(_ contents: String, name: String, fixture: SyntheticProductionsFixture) throws -> URL {
        let rawDirectory = fixture.url(at: "capture-sources")
        try FileManager.default.createDirectory(at: rawDirectory, withIntermediateDirectories: true)
        let directory = try canonicalURL(rawDirectory)
        let source = directory.appending(path: name); try Data(contents.utf8).write(to: source); return source
    }

    private func canonicalURL(_ url: URL) throws -> URL {
        guard let pointer = realpath(url.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    private func previewArguments(_ source: URL, fixture: SyntheticProductionsFixture) -> [String] {
        ["OperationsDashboard", "capture", "preview", "copy", "--productions-root", fixture.root.path, "--source", source.path]
    }

    private func executeArguments(_ source: URL, fixture: SyntheticProductionsFixture, preview: CaptureCopyPreview) throws -> [String] {
        ["OperationsDashboard", "capture", "copy", "--productions-root", fixture.root.path, "--source", source.path, "--confirmed-preview", try preview.confirmedEnvelope(), "--confirm", try preview.confirmationToken()]
    }

    private func contractSnapshot(_ fixture: SyntheticProductionsFixture) throws -> [Data] {
        [try fixture.data(at: "Office/Flow.md"), try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md")]
    }
}
