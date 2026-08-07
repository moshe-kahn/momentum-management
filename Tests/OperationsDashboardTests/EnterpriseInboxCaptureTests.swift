import XCTest
@testable import OperationsDashboard

final class EnterpriseInboxCaptureTests: XCTestCase {
    func testConfigurationRoundTripsAndRequiresExpectedSources() throws {
        let configuration = makeConfiguration()
        let data = try JSONEncoder().encode(configuration)
        let store = CaptureConfigurationStore(storage: MemoryCaptureConfigurationStorage(data: data))

        XCTAssertEqual(try store.loadConfiguration(), configuration)
        XCTAssertEqual(store.launchState(), .configured(configuration))
    }

    func testConfigurationRejectsUnsupportedVersionWrongCountDuplicateIDsAndInvalidPaths() {
        XCTAssertThrowsError(try CaptureConfiguration(schemaVersion: 2, intakeSources: makeConfiguration().intakeSources, enterpriseInboxPath: "/enterprise/Dashboard/Inbox").validated())
        XCTAssertThrowsError(try CaptureConfiguration(schemaVersion: 1, intakeSources: [makeConfiguration().intakeSources[0]], enterpriseInboxPath: "/enterprise/Dashboard/Inbox").validated())
        XCTAssertThrowsError(try CaptureConfiguration(schemaVersion: 1, intakeSources: [
            IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: "/capture/one"),
            IntakeSource(id: "icloud-downloads", displayName: "Kahntra Downloads", rootPath: "/capture/two")
        ], enterpriseInboxPath: "/enterprise/Dashboard/Inbox").validated())
        XCTAssertThrowsError(try CaptureConfiguration(schemaVersion: 1, intakeSources: [
            IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: "relative"),
            IntakeSource(id: "kahntra-downloads", displayName: "Kahntra Downloads", rootPath: "/capture/two")
        ], enterpriseInboxPath: "/enterprise/Dashboard/Inbox").validated())
        XCTAssertThrowsError(try CaptureConfiguration(schemaVersion: 1, intakeSources: makeConfiguration().intakeSources, enterpriseInboxPath: "").validated())
        XCTAssertThrowsError(try CaptureConfiguration(schemaVersion: 1, intakeSources: makeConfiguration().intakeSources, enterpriseInboxPath: "/enterprise/Inbox").validated())
    }

    func testConfigurationStoreReportsMissingAndMalformedData() {
        XCTAssertEqual(CaptureConfigurationStore(storage: MemoryCaptureConfigurationStorage(data: nil)).launchState(), .setupRequired)
        let malformed = CaptureConfigurationStore(storage: MemoryCaptureConfigurationStorage(data: Data("not json".utf8))).launchState()
        guard case .malformed = malformed else {
            return XCTFail("Expected malformed capture configuration.")
        }
    }

    func testValidatorRejectsMissingDestinationAndNestedSource() {
        let source = URL(fileURLWithPath: "/capture/icloud")
        let second = URL(fileURLWithPath: "/capture/kahntra")
        let destination = URL(fileURLWithPath: "/capture/icloud/Dashboard/Inbox")
        let fileSystem = StubCaptureFileSystem(
            existing: [source, second],
            readable: [source, second],
            writable: [],
            directories: [source, second],
            symbolicLinks: [],
            entries: [:]
        )
        let result = CaptureConfigurationValidator(fileSystem: fileSystem).validate(
            makeConfiguration(first: source.path, second: second.path, destination: destination.path)
        )

        XCTAssertEqual(result.destinationState, .missing)
        XCTAssertFalse(result.canSave)
        XCTAssertEqual(result.sourceStates["icloud-downloads"], .available)
        XCTAssertEqual(result.sourceStates["kahntra-downloads"], .available)
        XCTAssertEqual(result.errors.count, 2)
    }

    func testLocalEnumeratorCombinesSourcesPreservesAttributionAndDoesNotMutate() throws {
        let fixture = try TemporaryCaptureFixture()
        try fixture.write("a" , at: fixture.first.appending(path: "a.txt"))
        try fixture.write("one", at: fixture.first.appending(path: "same.txt"))
        try fixture.write("two", at: fixture.second.appending(path: "same.txt"))
        try fixture.write("b", at: fixture.second.appending(path: "b.txt"))
        try fixture.write("hidden", at: fixture.first.appending(path: ".hidden"))
        try FileManager.default.createDirectory(at: fixture.first.appending(path: "Folder"), withIntermediateDirectories: false)
        try fixture.write("nested", at: fixture.first.appending(path: "Folder/nested.txt"))
        try FileManager.default.createDirectory(at: fixture.first.appending(path: ".hidden-folder"), withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: fixture.first.appending(path: "linked.txt"), withDestinationURL: fixture.first.appending(path: "a.txt"))

        let before = try fixture.directNames()
        let result = try IntakeEnumerator().enumerate(configuration: fixture.configuration, fileSystem: LocalCaptureFileSystem())
        let after = try fixture.directNames()

        XCTAssertEqual(before, after)
        XCTAssertEqual(result.sources.map(\.availability), [.available, .available])
        XCTAssertEqual(result.items.map(\.displayName), ["a.txt", "b.txt", "Folder", "same.txt", "same.txt"])
        XCTAssertEqual(result.items.filter { $0.displayName == "same.txt" }.map(\.sourceID), ["icloud-downloads", "kahntra-downloads"])
        XCTAssertEqual(Set(result.items.filter { $0.displayName == "same.txt" }.map(\.id)).count, 2)
        XCTAssertEqual(result.items.first { $0.displayName == "Folder" }?.kind, .directory)
        XCTAssertFalse(result.items.contains { $0.displayName == ".hidden" || $0.displayName == ".hidden-folder" || $0.displayName == "linked.txt" || $0.displayName == "nested.txt" })
    }

    func testEnumeratorRepresentsEmptyMissingAndUnreadableSourcesIndependently() throws {
        let first = URL(fileURLWithPath: "/capture/icloud")
        let second = URL(fileURLWithPath: "/capture/kahntra")
        let configuration = makeConfiguration(first: first.path, second: second.path)
        let missing = StubCaptureFileSystem(existing: [second], readable: [second], writable: [URL(fileURLWithPath: "/enterprise/Dashboard/Inbox")], directories: [second, URL(fileURLWithPath: "/enterprise/Dashboard/Inbox")], symbolicLinks: [], entries: [second: []])
        let missingResult = try IntakeEnumerator().enumerate(configuration: configuration, fileSystem: missing)
        XCTAssertEqual(missingResult.sources.map(\.availability), [.missing, .empty])

        let unreadable = StubCaptureFileSystem(existing: [first, second], readable: [first, second], writable: [], directories: [first, second], symbolicLinks: [], entries: [second: [entry("valid.txt", in: second, regular: true)]], enumerationErrors: [first])
        let unreadableResult = try IntakeEnumerator().enumerate(configuration: configuration, fileSystem: unreadable)
        XCTAssertEqual(unreadableResult.sources[0].availability, .unreadable("Synthetic enumeration failure"))
        XCTAssertEqual(unreadableResult.sources[1].items.map(\.displayName), ["valid.txt"])
    }

    func testEnumeratorClassifiesPackageAndTreatsAliasMetadataAsOpaqueRegularFile() throws {
        let first = URL(fileURLWithPath: "/capture/icloud")
        let second = URL(fileURLWithPath: "/capture/kahntra")
        let package = entry("Example.app", in: first, directory: true, package: true)
        let alias = entry("Reference alias", in: second, regular: true)
        let destination = URL(fileURLWithPath: "/enterprise/Dashboard/Inbox")
        let fileSystem = StubCaptureFileSystem(existing: [first, second, destination], readable: [first, second, destination], writable: [destination], directories: [first, second, destination], symbolicLinks: [], entries: [first: [package], second: [alias]])

        let result = try IntakeEnumerator().enumerate(configuration: makeConfiguration(first: first.path, second: second.path, destination: destination.path), fileSystem: fileSystem)

        XCTAssertEqual(result.items.map(\.kind), [.package, .file])
        XCTAssertEqual(result.items.map(\.displayName), ["Example.app", "Reference alias"])
    }

    private func makeConfiguration(
        first: String = "/capture/icloud",
        second: String = "/capture/kahntra",
        destination: String = "/enterprise/Dashboard/Inbox"
    ) -> CaptureConfiguration {
        CaptureConfiguration(
            schemaVersion: 1,
            intakeSources: [
                IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: first),
                IntakeSource(id: "kahntra-downloads", displayName: "Kahntra Downloads", rootPath: second)
            ],
            enterpriseInboxPath: destination
        )
    }

    private func entry(
        _ name: String,
        in root: URL,
        regular: Bool = false,
        directory: Bool = false,
        package: Bool = false,
        symbolicLink: Bool = false
    ) -> CaptureDirectoryEntry {
        CaptureDirectoryEntry(
            url: root.appending(path: name),
            name: name,
            isRegularFile: regular,
            isDirectory: directory,
            isPackage: package,
            isSymbolicLink: symbolicLink,
            resourceIdentifier: name
        )
    }
}

private final class MemoryCaptureConfigurationStorage: CaptureConfigurationStorage {
    var data: Data?

    init(data: Data?) {
        self.data = data
    }

    func loadData() throws -> Data? { data }
    func saveData(_ data: Data) throws { self.data = data }
}

private struct StubCaptureFileSystem: CaptureFileSystem {
    let existing: Set<URL>
    let readable: Set<URL>
    let writable: Set<URL>
    let directories: Set<URL>
    let symbolicLinks: Set<URL>
    let entries: [URL: [CaptureDirectoryEntry]]
    var enumerationErrors: Set<URL> = []

    func exists(at url: URL) -> Bool { contains(existing, url) }
    func isReadable(at url: URL) -> Bool { contains(readable, url) }
    func isWritable(at url: URL) -> Bool { contains(writable, url) }
    func isDirectory(at url: URL) throws -> Bool { contains(directories, url) }
    func isSymbolicLink(at url: URL) throws -> Bool { contains(symbolicLinks, url) }

    func directoryEntries(at url: URL) throws -> [CaptureDirectoryEntry] {
        if contains(enumerationErrors, url) { throw StubCaptureError.enumeration }
        return entries.first(where: { standardizedPath($0.key) == standardizedPath(url) })?.value ?? []
    }

    func entry(at url: URL) throws -> CaptureDirectoryEntry {
        guard let entry = entries.values.flatMap({ $0 }).first(where: { standardizedPath($0.url) == standardizedPath(url) }) else {
            throw StubCaptureError.enumeration
        }
        return entry
    }

    private func contains(_ urls: Set<URL>, _ url: URL) -> Bool {
        urls.contains { standardizedPath($0) == standardizedPath(url) }
    }

    private func standardizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }
}

private enum StubCaptureError: LocalizedError {
    case enumeration

    var errorDescription: String? { "Synthetic enumeration failure" }
}

private final class TemporaryCaptureFixture {
    let root: URL
    let first: URL
    let second: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "EnterpriseInboxCaptureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        first = root.appending(path: "iCloud", directoryHint: .isDirectory)
        second = root.appending(path: "Kahntra", directoryHint: .isDirectory)
        destination = root.appending(path: "Enterprise/Dashboard/Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var configuration: CaptureConfiguration {
        CaptureConfiguration(
            schemaVersion: 1,
            intakeSources: [
                IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: first.path),
                IntakeSource(id: "kahntra-downloads", displayName: "Kahntra Downloads", rootPath: second.path)
            ],
            enterpriseInboxPath: destination.path
        )
    }

    func write(_ text: String, at url: URL) throws {
        try text.data(using: .utf8)!.write(to: url)
    }

    func directNames() throws -> [[String]] {
        try [first, second, destination].map {
            try FileManager.default.contentsOfDirectory(atPath: $0.path).sorted()
        }
    }
}
