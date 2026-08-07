import Foundation
import XCTest
@testable import OperationsDashboard

@MainActor
final class MilestoneTwoTests: XCTestCase {
    private let inboxPath = "Dashboard/Inbox"
    private let statusPath = "Reference/Product/Operations Dashboard Status.md"
    private let firstMetadataDate = Date(timeIntervalSince1970: 1_700_000_000)
    private let secondMetadataDate = Date(timeIntervalSince1970: 1_700_003_600)

    func testInitialSelectionUsesFirstConfiguredProduct() throws {
        let viewModel = try makeViewModel()

        XCTAssertEqual(viewModel.selectedProductID, "momentum-management")
        XCTAssertEqual(viewModel.selectedProduct?.product.id, "momentum-management")
    }

    func testSelectingEitherConfiguredProductChangesOnlyInMemorySelection() throws {
        let storage = MilestoneMemoryConfigurationStorage(data: try JSONEncoder().encode(try configuration()))
        let viewModel = DashboardViewModel(store: ConfigurationStore(storage: storage), fileSystem: MetadataFileSystem(), sourceOpener: StubSourceOpener())
        let savedConfiguration = storage.data

        viewModel.selectProduct(id: "momomovies")

        XCTAssertEqual(viewModel.selectedProductID, "momomovies")
        XCTAssertEqual(viewModel.selectedProduct?.product.displayName, "Synthetic Secondary")
        XCTAssertEqual(storage.data, savedConfiguration)
    }

    func testRefreshPreservesSelectedProductAndReloadsMetadata() throws {
        let configuration = try configuration()
        let storage = MilestoneMemoryConfigurationStorage(data: try JSONEncoder().encode(configuration))
        let fileSystem = MetadataFileSystem()
        let firstStatus = configuration.products[0].resolved(statusPath)
        fileSystem.dates[firstStatus.path] = firstMetadataDate
        let viewModel = DashboardViewModel(store: ConfigurationStore(storage: storage), fileSystem: fileSystem, sourceOpener: StubSourceOpener())
        viewModel.selectProduct(id: "momomovies")
        let secondStatus = configuration.products[1].resolved(statusPath)
        fileSystem.dates[secondStatus.path] = secondMetadataDate
        let savedConfiguration = storage.data

        viewModel.refresh()

        XCTAssertEqual(viewModel.selectedProductID, "momomovies")
        XCTAssertEqual(viewModel.selectedProduct?.statusRecordMetadata?.modificationDate, secondMetadataDate)
        XCTAssertEqual(storage.data, savedConfiguration)
    }

    func testSelectedDetailStateExposesAllApprovedFieldsAndRoles() throws {
        let viewModel = try makeViewModel()
        let product = try XCTUnwrap(viewModel.selectedProduct)

        XCTAssertEqual(product.product.displayName, "Synthetic Primary")
        XCTAssertEqual(product.inboxCount, 2)
        XCTAssertEqual(product.status?.currentStatus, "Planning")
        XCTAssertEqual(product.status?.nextActions, ["Review synthetic fixture", "Run validation"])
        XCTAssertEqual(product.status?.blockers, ["None"])
        XCTAssertEqual(SourceAction.allCases.map(\.roleLabel), ["Product root", "Inbox", "Status record"])
    }

    func testProductSelectionAccessibilityDescribesSelectionState() throws {
        let product = try XCTUnwrap(try makeViewModel().products.first).product

        XCTAssertEqual(ProductSelectionAccessibility.label(for: product), "Synthetic Primary")
        XCTAssertEqual(ProductSelectionAccessibility.hint, "Activates this row to select the product.")
        XCTAssertEqual(ProductSelectionAccessibility.value(isSelected: true), "Selected")
        XCTAssertEqual(ProductSelectionAccessibility.value(isSelected: false), "Not selected")
    }

    func testStatusRecordModificationMetadataIsDistinctFromDeclaredDate() throws {
        let configuration = try configuration()
        let fileSystem = MetadataFileSystem()
        fileSystem.dates[configuration.products[0].resolved(statusPath).path] = firstMetadataDate
        let state = try DashboardLoader(configurationLoader: MilestoneStaticConfigurationLoader(configuration), fileSystem: fileSystem).load()[0]

        XCTAssertEqual(state.status?.lastUpdated, date("2026-08-05"))
        XCTAssertEqual(state.statusRecordMetadata?.modificationDate, firstMetadataDate)
        XCTAssertNotEqual(state.status?.lastUpdated, state.statusRecordMetadata?.modificationDate)
    }

    func testMissingStatusRecordHasUnavailableMetadata() throws {
        let valid = try copiedFixture("ValidProduct")
        let missing = try copiedFixture("MissingStatus")
        let configuration = try configuration(first: valid, second: missing)
        let states = try DashboardLoader(configurationLoader: MilestoneStaticConfigurationLoader(configuration), fileSystem: MetadataFileSystem()).load()

        XCTAssertNil(states[1].statusRecordMetadata)
        XCTAssertTrue(states[1].issues.contains(.missingStatusRecord))
    }

    func testMalformedStatusStillExposesMetadata() throws {
        let malformed = try copiedFixture("MalformedStatus")
        let valid = try copiedFixture("ValidProduct")
        let configuration = try configuration(first: malformed, second: valid)
        let fileSystem = MetadataFileSystem()
        fileSystem.dates[configuration.products[0].resolved(statusPath).path] = firstMetadataDate
        let state = try DashboardLoader(configurationLoader: MilestoneStaticConfigurationLoader(configuration), fileSystem: fileSystem).load()[0]

        XCTAssertNil(state.status)
        XCTAssertEqual(state.statusRecordMetadata?.modificationDate, firstMetadataDate)
        XCTAssertTrue(state.issues.contains { if case .malformedStatusRecord = $0 { return true }; return false })
    }

    func testMetadataFailureIsVisibleAndDoesNotAffectOtherProduct() throws {
        let configuration = try configuration()
        let fileSystem = MetadataFileSystem()
        fileSystem.failingPaths.insert(configuration.products[0].resolved(statusPath).path)
        fileSystem.dates[configuration.products[1].resolved(statusPath).path] = secondMetadataDate
        let states = try DashboardLoader(configurationLoader: MilestoneStaticConfigurationLoader(configuration), fileSystem: fileSystem).load()

        XCTAssertNil(states[0].statusRecordMetadata?.modificationDate)
        XCTAssertNotNil(states[0].statusRecordMetadata?.issue)
        XCTAssertTrue(states[0].issues.contains { if case .statusRecordMetadataUnavailable = $0 { return true }; return false })
        XCTAssertEqual(states[1].statusRecordMetadata?.modificationDate, secondMetadataDate)
        XCTAssertTrue(states[1].issues.isEmpty)
    }

    private func makeViewModel() throws -> DashboardViewModel {
        let configuration = try configuration()
        return DashboardViewModel(
            store: ConfigurationStore(storage: MilestoneMemoryConfigurationStorage(data: try JSONEncoder().encode(configuration))),
            fileSystem: MetadataFileSystem(),
            sourceOpener: StubSourceOpener()
        )
    }

    private func configuration(first: URL? = nil, second: URL? = nil) throws -> DashboardConfiguration {
        let first = try first ?? copiedFixture("ValidProduct")
        let second = try second ?? copiedFixture("EmptyInbox")
        return try DashboardConfiguration(schemaVersion: 1, products: [
            ConfiguredProduct(id: "momentum-management", displayName: "Synthetic Primary", productRootPath: first.path, inboxRelativePath: inboxPath, statusRecordRelativePath: statusPath),
            ConfiguredProduct(id: "momomovies", displayName: "Synthetic Secondary", productRootPath: second.path, inboxRelativePath: inboxPath, statusRecordRelativePath: statusPath)
        ]).validated()
    }

    private func copiedFixture(_ name: String) throws -> URL {
        let source = Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)", directoryHint: .isDirectory)
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: source, to: destination)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        return destination
    }

    private func date(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

private final class MilestoneMemoryConfigurationStorage: ConfigurationStorage {
    var data: Data?

    init(data: Data?) {
        self.data = data
    }

    func loadData() throws -> Data? { data }
    func saveData(_ data: Data) throws { self.data = data }
}

private struct MilestoneStaticConfigurationLoader: ConfigurationLoading {
    let configuration: DashboardConfiguration

    init(_ configuration: DashboardConfiguration) {
        self.configuration = configuration
    }

    func loadConfiguration() throws -> DashboardConfiguration {
        try configuration.validated()
    }
}

private final class StubSourceOpener: SourceOpening {
    func open(_ url: URL) throws {}
}

private final class MetadataFileSystem: FileSystem {
    private let base = LocalFileSystem()
    var dates: [String: Date] = [:]
    var failingPaths: Set<String> = []

    func exists(at url: URL) -> Bool { base.exists(at: url) }
    func isReadable(at url: URL) -> Bool { base.isReadable(at: url) }
    func isDirectory(at url: URL) throws -> Bool { try base.isDirectory(at: url) }
    func directoryEntries(at url: URL) throws -> [FileSystemEntry] { try base.directoryEntries(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }
    func modificationDate(at url: URL) throws -> Date? {
        if failingPaths.contains(url.path) { throw CocoaError(.fileReadNoPermission) }
        return dates[url.path]
    }
}
