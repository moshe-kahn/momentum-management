import Foundation
import XCTest
@testable import OperationsDashboard

final class SetupConfigurationTests: XCTestCase {
    func testAbsentResolvedConfigurationEntersSetupState() {
        let storage = MemoryConfigurationStorage(data: nil)
        XCTAssertEqual(ConfigurationStore(storage: storage).launchState(), .setupRequired)
    }

    func testValidExistingConfigurationBypassesSetup() throws {
        let configuration = try validConfiguration()
        let storage = MemoryConfigurationStorage(data: try JSONEncoder().encode(configuration))
        XCTAssertEqual(ConfigurationStore(storage: storage).launchState(), .configured(configuration))
    }

    func testSelectedRootDerivesApprovedPaths() throws {
        let root = try copiedFixture("SetupValidMomentum")
        let draft = SetupProductDraft(id: "momentum-management", displayName: "Momentum Management", productRootPath: root.path)
        XCTAssertEqual(draft.derivedInboxURL?.path, root.appending(path: "Dashboard/Inbox").path)
        XCTAssertEqual(draft.derivedStatusRecordURL?.path, root.appending(path: "Reference/Product/Operations Dashboard Status.md").path)
    }

    func testDuplicateRootsAreRejected() throws {
        let root = try copiedFixture("SetupValidMomentum")
        var draft = SetupDraft.initial()
        draft.products[0].productRootPath = root.path
        draft.products[1].productRootPath = root.path
        let result = SetupValidator(fileSystem: LocalFileSystem()).validate(draft)
        XCTAssertFalse(result.canSave)
        XCTAssertTrue(result.errors.contains("Product roots must be distinct."))
    }

    func testNonexistentRootIsRejected() {
        var draft = SetupDraft.initial()
        draft.products[0].productRootPath = "/synthetic/nonexistent-root"
        let result = SetupValidator(fileSystem: LocalFileSystem()).validate(draft)
        XCTAssertFalse(result.canSave)
        XCTAssertTrue(result.errors.contains { $0.contains("does not exist") })
    }

    func testMissingInboxProducesWarning() throws {
        let missingInbox = try copiedFixture("SetupMissingInbox")
        let valid = try copiedFixture("SetupValidMomoMovies")
        let result = SetupValidator(fileSystem: LocalFileSystem()).validate(draft(first: missingInbox, second: valid))
        XCTAssertTrue(result.canSave)
        XCTAssertTrue(result.warnings.contains { $0.contains("Inbox is missing") })
    }

    func testMissingStatusRecordProducesWarning() throws {
        let valid = try copiedFixture("SetupValidMomentum")
        let missingStatus = try copiedFixture("SetupMissingStatus")
        let result = SetupValidator(fileSystem: LocalFileSystem()).validate(draft(first: valid, second: missingStatus))
        XCTAssertTrue(result.canSave)
        XCTAssertTrue(result.warnings.contains { $0.contains("status record is missing") })
    }

    func testInaccessibleRootIsRejectedThroughInjectedFileSystem() {
        var draft = SetupDraft.initial()
        draft.products[0].productRootPath = "/synthetic/inaccessible"
        draft.products[1].productRootPath = "/synthetic/other"
        let result = SetupValidator(fileSystem: InaccessibleRootFileSystem()).validate(draft)
        XCTAssertFalse(result.canSave)
        XCTAssertTrue(result.errors.contains { $0.contains("inaccessible") })
    }

    func testMalformedExistingConfigurationProducesMalformedState() {
        let storage = MemoryConfigurationStorage(data: Data("{}".utf8))
        guard case .malformed = ConfigurationStore(storage: storage).launchState() else {
            return XCTFail("Expected malformed configuration state")
        }
    }

    func testCancelPreservesExistingConfiguration() throws {
        let configuration = try validConfiguration()
        let originalData = try JSONEncoder().encode(configuration)
        let storage = MemoryConfigurationStorage(data: originalData)
        let store = ConfigurationStore(storage: storage)
        let coordinator = SetupCoordinator(store: store, validator: SetupValidator(fileSystem: LocalFileSystem()))
        _ = coordinator.initialDraft(for: store.launchState())
        XCTAssertEqual(storage.data, originalData)
    }

    func testSuccessfulSaveWritesApprovedSchema() throws {
        let first = try copiedFixture("SetupValidMomentum")
        let second = try copiedFixture("SetupValidMomoMovies")
        let storage = MemoryConfigurationStorage(data: nil)
        let store = ConfigurationStore(storage: storage)
        let result = try SetupCoordinator(store: store, validator: SetupValidator(fileSystem: LocalFileSystem())).save(draft(first: first, second: second))
        XCTAssertTrue(result.canSave)
        let saved = try XCTUnwrap(storage.data)
        XCTAssertEqual(try store.decode(data: saved).schemaVersion, 1)
    }

    func testFailedSavePreservesPriorValidConfiguration() throws {
        let previous = try JSONEncoder().encode(validConfiguration())
        let storage = MemoryConfigurationStorage(data: previous, shouldFailSave: true)
        let first = try copiedFixture("SetupValidMomentum")
        let second = try copiedFixture("SetupValidMomoMovies")
        let store = ConfigurationStore(storage: storage)
        XCTAssertThrowsError(try SetupCoordinator(store: store, validator: SetupValidator(fileSystem: LocalFileSystem())).save(draft(first: first, second: second)))
        XCTAssertEqual(storage.data, previous)
    }

    func testInvalidProductDoesNotProduceCompletedSetup() throws {
        let valid = try copiedFixture("SetupValidMomentum")
        var invalid = draft(first: valid, second: valid)
        invalid.products[1].productRootPath = ""
        let result = SetupValidator(fileSystem: LocalFileSystem()).validate(invalid)
        XCTAssertFalse(result.canSave)
    }

    private func draft(first: URL, second: URL) -> SetupDraft {
        SetupDraft(products: [
            SetupProductDraft(id: "momentum-management", displayName: "Momentum Management", productRootPath: first.path),
            SetupProductDraft(id: "momomovies", displayName: "MomoMovies", productRootPath: second.path)
        ])
    }

    private func validConfiguration() throws -> DashboardConfiguration {
        try DashboardConfiguration(schemaVersion: 1, products: [
            ConfiguredProduct(id: "momentum-management", displayName: "Momentum Management", productRootPath: "/synthetic/momentum", inboxRelativePath: SetupProductDraft.inboxRelativePath, statusRecordRelativePath: SetupProductDraft.statusRecordRelativePath),
            ConfiguredProduct(id: "momomovies", displayName: "MomoMovies", productRootPath: "/synthetic/momomovies", inboxRelativePath: SetupProductDraft.inboxRelativePath, statusRecordRelativePath: SetupProductDraft.statusRecordRelativePath)
        ]).validated()
    }

    private func copiedFixture(_ name: String) throws -> URL {
        let source = Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: destination)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        return destination
    }
}

private final class MemoryConfigurationStorage: ConfigurationStorage {
    var data: Data?
    let shouldFailSave: Bool

    init(data: Data?, shouldFailSave: Bool = false) {
        self.data = data
        self.shouldFailSave = shouldFailSave
    }

    func loadData() throws -> Data? { data }

    func saveData(_ data: Data) throws {
        if shouldFailSave { throw CocoaError(.fileWriteUnknown) }
        self.data = data
    }
}

private struct InaccessibleRootFileSystem: FileSystem {
    func exists(at url: URL) -> Bool { true }
    func isReadable(at url: URL) -> Bool { false }
    func isDirectory(at url: URL) throws -> Bool { throw CocoaError(.fileReadNoPermission) }
    func directoryEntries(at url: URL) throws -> [FileSystemEntry] { throw CocoaError(.fileReadNoPermission) }
    func readData(at url: URL) throws -> Data { throw CocoaError(.fileReadNoPermission) }
    func modificationDate(at url: URL) -> Date? { nil }
}
