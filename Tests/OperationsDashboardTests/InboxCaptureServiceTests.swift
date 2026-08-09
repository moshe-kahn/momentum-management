import XCTest
@testable import OperationsDashboard

final class InboxCaptureServiceTests: XCTestCase {
    func testMovesRegularFileAndPreservesApprovedBoundary() throws {
        let fixture = try MoveFixture()
        try fixture.write("source", at: fixture.first.appending(path: "report.txt"))
        let item = try fixture.item(named: "report.txt")

        let result = fixture.service.move(selected: [item], configuration: fixture.configuration)

        XCTAssertEqual(result.results, [IntakeMoveResult(item: item, outcome: .moved(destination: fixture.destination.appending(path: "report.txt")))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.first.appending(path: "report.txt").path))
        XCTAssertEqual(try String(contentsOf: fixture.destination.appending(path: "report.txt")), "source")
        XCTAssertEqual(try fixture.directNames(at: fixture.second), [])
    }

    func testMovesDirectoryAndPackageAsOpaqueItems() throws {
        let fixture = try MoveFixture()
        try FileManager.default.createDirectory(at: fixture.first.appending(path: "Folder"), withIntermediateDirectories: false)
        try fixture.write("nested", at: fixture.first.appending(path: "Folder/nested.txt"))
        try FileManager.default.createDirectory(at: fixture.second.appending(path: "Example.app"), withIntermediateDirectories: false)

        let items = try fixture.items(named: ["Folder", "Example.app"])
        let result = fixture.service.move(selected: items, configuration: fixture.configuration)

        XCTAssertEqual(result.results.count, 2)
        XCTAssertTrue(result.results.allSatisfy { if case .moved = $0.outcome { return true }; return false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "Folder/nested.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.appending(path: "Example.app").path))
    }

    func testCollisionSuffixPreservesFinalExtensionAndUnicode() throws {
        let fixture = try MoveFixture()
        try fixture.write("source", at: fixture.first.appending(path: "report.final.txt"))
        try fixture.write("existing", at: fixture.destination.appending(path: "report.final.txt"))
        try fixture.write("source", at: fixture.second.appending(path: "éclair.txt"))
        try fixture.write("existing", at: fixture.destination.appending(path: "éclair.txt"))
        try fixture.write("existing", at: fixture.destination.appending(path: "éclair (2).txt"))

        let report = try fixture.item(named: "report.final.txt", source: fixture.first)
        let eclair = try fixture.item(named: "éclair.txt", source: fixture.second)
        let result = fixture.service.move(selected: [report, eclair], configuration: fixture.configuration)

        XCTAssertEqual(result.results, [
            IntakeMoveResult(item: report, outcome: .moved(destination: fixture.destination.appending(path: "report.final (2).txt"))),
            IntakeMoveResult(item: eclair, outcome: .moved(destination: fixture.destination.appending(path: "éclair (3).txt")))
        ])
    }

    func testDirectoryCollisionUsesWholeDirectoryName() throws {
        let fixture = try MoveFixture()
        try FileManager.default.createDirectory(at: fixture.first.appending(path: "Folder"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: fixture.destination.appending(path: "Folder"), withIntermediateDirectories: false)

        let result = fixture.service.move(selected: [try fixture.item(named: "Folder")], configuration: fixture.configuration)

        XCTAssertEqual(result.results.first?.outcome, .moved(destination: fixture.destination.appending(path: "Folder (2)", directoryHint: .isDirectory)))
    }

    func testPartialFailureContinuesAfterSymlinkRejection() throws {
        let fixture = try MoveFixture()
        try fixture.write("good", at: fixture.first.appending(path: "good.txt"))
        try fixture.write("target", at: fixture.second.appending(path: "target.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.second.appending(path: "link.txt"), withDestinationURL: fixture.second.appending(path: "target.txt"))
        let good = try fixture.item(named: "good.txt")
        let link = IntakeItem(sourceID: "kahntra-downloads", sourceDisplayName: "Kahntra Downloads", sourceRootURL: fixture.second, itemURL: fixture.second.appending(path: "link.txt"), displayName: "link.txt", kind: .file, resourceIdentifier: nil)

        let result = fixture.service.move(selected: [good, link], configuration: fixture.configuration)

        XCTAssertEqual(result.results[0].outcome, .moved(destination: fixture.destination.appending(path: "good.txt")))
        XCTAssertEqual(result.results[1].outcome, .failed(category: .symlinkRejected, diagnostic: "Symbolic links cannot be moved through Enterprise Inbox Capture.", attemptedDestination: nil))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.second.appending(path: "link.txt").path))
    }

    func testRejectsFabricatedNestedAndMismatchedSourceItems() throws {
        let fixture = try MoveFixture()
        try FileManager.default.createDirectory(at: fixture.first.appending(path: "Folder"), withIntermediateDirectories: false)
        try fixture.write("nested", at: fixture.first.appending(path: "Folder/nested.txt"))
        let nested = IntakeItem(sourceID: "icloud-downloads", sourceDisplayName: "iCloud Drive Downloads", sourceRootURL: fixture.first, itemURL: fixture.first.appending(path: "Folder/nested.txt"), displayName: "nested.txt", kind: .file, resourceIdentifier: nil)
        let fabricated = IntakeItem(sourceID: "icloud-downloads", sourceDisplayName: "iCloud Drive Downloads", sourceRootURL: fixture.first, itemURL: URL(fileURLWithPath: "/tmp/arbitrary.txt"), displayName: "arbitrary.txt", kind: .file, resourceIdentifier: nil)
        let mismatched = IntakeItem(sourceID: "icloud-downloads", sourceDisplayName: "Kahntra Downloads", sourceRootURL: fixture.first, itemURL: fixture.first.appending(path: "Folder"), displayName: "Folder", kind: .directory, resourceIdentifier: nil)

        let result = fixture.service.move(selected: [nested, fabricated, mismatched], configuration: fixture.configuration)

        XCTAssertEqual(result.results.map { category(of: $0.outcome) }, [.sourceOutsideApprovedRoot, .sourceOutsideApprovedRoot, .sourceInvalid])
    }

    func testMissingDestinationIsGlobalFailureAndDoesNotMoveSources() throws {
        let fixture = try MoveFixture(createDestination: false)
        try fixture.write("source", at: fixture.first.appending(path: "report.txt"))
        let item = try fixture.item(named: "report.txt")

        let result = fixture.service.move(selected: [item], configuration: fixture.configuration)

        XCTAssertTrue(result.hasGlobalFailure)
        XCTAssertEqual(category(of: result.results[0].outcome), .destinationUnavailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.itemURL.path))
    }

    func testInjectedMoveFailureDoesNotUseFallbackAndLeavesSource() throws {
        let source = URL(fileURLWithPath: "/capture/icloud/report.txt")
        let root = source.deletingLastPathComponent()
        let second = URL(fileURLWithPath: "/capture/kahntra")
        let destination = URL(fileURLWithPath: "/enterprise/Dashboard/Inbox")
        let item = IntakeItem(sourceID: "icloud-downloads", sourceDisplayName: "iCloud Drive Downloads", sourceRootURL: root, itemURL: source, displayName: "report.txt", kind: .file, resourceIdentifier: "source")
        let fileSystem = FailingMoveFileSystem(source: source, root: root, second: second, destination: destination)
        let configuration = CaptureConfiguration(schemaVersion: 1, intakeSources: [
            IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: root.path),
            IntakeSource(id: "kahntra-downloads", displayName: "Kahntra Downloads", rootPath: second.path)
        ], enterpriseInboxPath: destination.path)

        let result = InboxCaptureService(fileSystem: fileSystem).move(selected: [item], configuration: configuration)

        XCTAssertEqual(category(of: result.results[0].outcome), .moveFailed)
        XCTAssertEqual(fileSystem.moveCalls, 1)
        XCTAssertTrue(fileSystem.exists(at: source))
    }

    func testPreparedItemsMoveOnlyDirectChildrenAndUseCollisionSafeDestination() throws {
        let fixture = try PreparedMoveFixture()
        try fixture.write("source", at: fixture.firstPrepared.appending(path: "report.txt"))
        try fixture.write("existing", at: fixture.destination.appending(path: "report.txt"))
        let item = try fixture.item(named: "report.txt")

        let result = fixture.service.move(selected: [item], configuration: fixture.configuration)

        XCTAssertEqual(result.results, [
            PreparedItemMoveResult(item: item, outcome: .moved(destination: fixture.destination.appending(path: "report (2).txt")))
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.firstPrepared.appending(path: "report.txt").path))
        XCTAssertEqual(try String(contentsOf: fixture.destination.appending(path: "report.txt")), "existing")
        XCTAssertEqual(try String(contentsOf: fixture.destination.appending(path: "report (2).txt")), "source")
    }

    func testPreparedItemsWithTheSameNameFromBothSourcesMoveSeriallyWithoutOverwrite() throws {
        let fixture = try PreparedMoveFixture()
        try fixture.write("icloud", at: fixture.firstPrepared.appending(path: "same.txt"))
        try fixture.write("kahntra", at: fixture.secondPrepared.appending(path: "same.txt"))
        let items = try PreparedItemsEnumerator().enumerate(configuration: fixture.configuration, fileSystem: LocalCaptureFileSystem()).items

        let result = fixture.service.move(selected: items, configuration: fixture.configuration)

        XCTAssertEqual(result.results.map(\.outcome), [
            .moved(destination: fixture.destination.appending(path: "same.txt")),
            .moved(destination: fixture.destination.appending(path: "same (2).txt"))
        ])
        XCTAssertEqual(try String(contentsOf: fixture.destination.appending(path: "same.txt")), "icloud")
        XCTAssertEqual(try String(contentsOf: fixture.destination.appending(path: "same (2).txt")), "kahntra")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.firstPrepared.appending(path: "same.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.secondPrepared.appending(path: "same.txt").path))
    }

    func testPreparedItemsRejectNestedOrMismatchedFolderItems() throws {
        let fixture = try PreparedMoveFixture()
        try FileManager.default.createDirectory(at: fixture.firstPrepared.appending(path: "Folder"), withIntermediateDirectories: false)
        try fixture.write("nested", at: fixture.firstPrepared.appending(path: "Folder/nested.txt"))
        let nested = PreparedIntakeItem(
            sourceID: "icloud-downloads",
            sourceDisplayName: "iCloud Drive Downloads",
            preparedFolderURL: fixture.firstPrepared,
            itemURL: fixture.firstPrepared.appending(path: "Folder/nested.txt"),
            displayName: "nested.txt",
            kind: .file,
            resourceIdentifier: nil
        )
        let mismatched = PreparedIntakeItem(
            sourceID: "icloud-downloads",
            sourceDisplayName: "iCloud Drive Downloads",
            preparedFolderURL: fixture.secondPrepared,
            itemURL: fixture.firstPrepared.appending(path: "Folder"),
            displayName: "Folder",
            kind: .directory,
            resourceIdentifier: nil
        )

        let result = fixture.service.move(selected: [nested, mismatched], configuration: fixture.configuration)

        XCTAssertEqual(result.results.map { preparedCategory(of: $0.outcome) }, [.sourceOutsideApprovedRoot, .sourceInvalid])
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.itemURL.path))
    }

    func testPreparedItemsMoveFailureLeavesSourceWithoutFallback() throws {
        let source = URL(fileURLWithPath: "/capture/icloud/Kahntra Enterprise/report.txt")
        let prepared = source.deletingLastPathComponent()
        let root = prepared.deletingLastPathComponent()
        let second = URL(fileURLWithPath: "/capture/kahntra")
        let destination = URL(fileURLWithPath: "/enterprise/Dashboard/Inbox")
        let item = PreparedIntakeItem(sourceID: "icloud-downloads", sourceDisplayName: "iCloud Drive Downloads", preparedFolderURL: prepared, itemURL: source, displayName: "report.txt", kind: .file, resourceIdentifier: "source")
        let fileSystem = FailingPreparedMoveFileSystem(source: source, prepared: prepared, root: root, second: second, destination: destination)
        let configuration = CaptureConfiguration(schemaVersion: 1, intakeSources: [
            IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: root.path),
            IntakeSource(id: "kahntra-downloads", displayName: "Kahntra Downloads", rootPath: second.path)
        ], enterpriseInboxPath: destination.path)

        let result = PreparedItemsCaptureService(fileSystem: fileSystem).move(selected: [item], configuration: configuration)

        XCTAssertEqual(preparedCategory(of: result.results[0].outcome), .moveFailed)
        XCTAssertEqual(fileSystem.moveCalls, 1)
        XCTAssertTrue(fileSystem.exists(at: source))
    }

    private func category(of outcome: IntakeMoveOutcome) -> IntakeMoveFailureCategory? {
        guard case let .failed(category, _, _) = outcome else { return nil }
        return category
    }

    private func preparedCategory(of outcome: IntakeMoveOutcome) -> IntakeMoveFailureCategory? {
        guard case let .failed(category, _, _) = outcome else { return nil }
        return category
    }
}

private final class MoveFixture {
    let root: URL
    let first: URL
    let second: URL
    let destination: URL
    let configuration: CaptureConfiguration
    let service = InboxCaptureService(fileSystem: LocalCaptureMutationFileSystem())

    init(createDestination: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "InboxCaptureServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        first = root.appending(path: "iCloud", directoryHint: .isDirectory)
        second = root.appending(path: "Kahntra", directoryHint: .isDirectory)
        destination = root.appending(path: "Enterprise/Dashboard/Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        if createDestination { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        configuration = CaptureConfiguration(schemaVersion: 1, intakeSources: [
            IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: first.path),
            IntakeSource(id: "kahntra-downloads", displayName: "Kahntra Downloads", rootPath: second.path)
        ], enterpriseInboxPath: destination.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, at url: URL) throws { try text.data(using: .utf8)!.write(to: url) }
    func directNames(at url: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }

    func item(named name: String, source: URL? = nil) throws -> IntakeItem {
        let source = source ?? first
        guard let item = try IntakeEnumerator().enumerate(configuration: configuration, fileSystem: LocalCaptureFileSystem()).items.first(where: { $0.sourceRootURL == source.standardizedFileURL && $0.displayName == name }) else {
            throw NSError(domain: "MoveFixture", code: 1)
        }
        return item
    }

    func items(named names: [String]) throws -> [IntakeItem] {
        let all = try IntakeEnumerator().enumerate(configuration: configuration, fileSystem: LocalCaptureFileSystem()).items
        return try names.map { name in
            guard let item = all.first(where: { $0.displayName == name }) else { throw NSError(domain: "MoveFixture", code: 2) }
            return item
        }
    }
}

private final class PreparedMoveFixture {
    let root: URL
    let first: URL
    let second: URL
    let firstPrepared: URL
    let secondPrepared: URL
    let destination: URL
    let configuration: CaptureConfiguration
    let service = PreparedItemsCaptureService(fileSystem: LocalCaptureMutationFileSystem())

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "PreparedItemsCaptureServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        first = root.appending(path: "iCloud", directoryHint: .isDirectory)
        second = root.appending(path: "Kahntra", directoryHint: .isDirectory)
        firstPrepared = first.appending(path: PreparedItemsEnumerator.folderName, directoryHint: .isDirectory)
        secondPrepared = second.appending(path: PreparedItemsEnumerator.folderName, directoryHint: .isDirectory)
        destination = root.appending(path: "Enterprise/Dashboard/Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: firstPrepared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPrepared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        configuration = CaptureConfiguration(schemaVersion: 1, intakeSources: [
            IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: first.path),
            IntakeSource(id: "kahntra-downloads", displayName: "Kahntra Downloads", rootPath: second.path)
        ], enterpriseInboxPath: destination.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(_ text: String, at url: URL) throws { try text.data(using: .utf8)!.write(to: url) }

    func item(named name: String) throws -> PreparedIntakeItem {
        guard let item = try PreparedItemsEnumerator().enumerate(configuration: configuration, fileSystem: LocalCaptureFileSystem()).items.first(where: { $0.displayName == name }) else {
            throw NSError(domain: "PreparedMoveFixture", code: 1)
        }
        return item
    }
}

private final class FailingMoveFileSystem: CaptureMutationFileSystem {
    let source: URL
    let root: URL
    let second: URL
    let destination: URL
    private(set) var moveCalls = 0

    init(source: URL, root: URL, second: URL, destination: URL) {
        self.source = source
        self.root = root
        self.second = second
        self.destination = destination
    }

    func exists(at url: URL) -> Bool { [source, root, second, destination].contains { $0.standardizedFileURL.path == url.standardizedFileURL.path } }
    func isReadable(at url: URL) -> Bool { exists(at: url) }
    func isWritable(at url: URL) -> Bool { url.standardizedFileURL.path == destination.standardizedFileURL.path }
    func isDirectory(at url: URL) throws -> Bool { [root, second, destination].contains { $0.standardizedFileURL.path == url.standardizedFileURL.path } }
    func isSymbolicLink(at url: URL) throws -> Bool { false }
    func directoryEntries(at url: URL) throws -> [CaptureDirectoryEntry] { [] }
    func entry(at url: URL) throws -> CaptureDirectoryEntry {
        CaptureDirectoryEntry(url: source, name: "report.txt", isRegularFile: true, isDirectory: false, isPackage: false, isSymbolicLink: false, resourceIdentifier: "source")
    }
    func moveItem(at source: URL, to destination: URL) throws {
        moveCalls += 1
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
    }
}

private final class FailingPreparedMoveFileSystem: CaptureMutationFileSystem {
    let source: URL
    let prepared: URL
    let root: URL
    let second: URL
    let destination: URL
    private(set) var moveCalls = 0

    init(source: URL, prepared: URL, root: URL, second: URL, destination: URL) {
        self.source = source
        self.prepared = prepared
        self.root = root
        self.second = second
        self.destination = destination
    }

    func exists(at url: URL) -> Bool {
        [source, prepared, root, second, destination].contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }
    func isReadable(at url: URL) -> Bool { exists(at: url) }
    func isWritable(at url: URL) -> Bool { url.standardizedFileURL.path == destination.standardizedFileURL.path }
    func isDirectory(at url: URL) throws -> Bool {
        [prepared, root, second, destination].contains { $0.standardizedFileURL.path == url.standardizedFileURL.path }
    }
    func isSymbolicLink(at url: URL) throws -> Bool { false }
    func directoryEntries(at url: URL) throws -> [CaptureDirectoryEntry] { [] }
    func entry(at url: URL) throws -> CaptureDirectoryEntry {
        CaptureDirectoryEntry(url: source, name: "report.txt", isRegularFile: true, isDirectory: false, isPackage: false, isSymbolicLink: false, resourceIdentifier: "source")
    }
    func moveItem(at source: URL, to destination: URL) throws {
        moveCalls += 1
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError)
    }
}
