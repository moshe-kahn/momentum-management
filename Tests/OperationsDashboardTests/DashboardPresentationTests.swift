import Foundation
import XCTest
@testable import OperationsDashboard

@MainActor
final class DashboardPresentationTests: XCTestCase {
    private let inboxPath = "Dashboard/Inbox"
    private let statusPath = "Reference/Product/Operations Dashboard Status.md"

    func testViewModelExposesLastUpdatedNextActionsAndBlockers() throws {
        let valid = try copiedFixture("ValidProduct")
        let empty = try copiedFixture("EmptyInbox")
        let viewModel = try makeViewModel(first: valid, second: empty)

        let state = try XCTUnwrap(viewModel.products.first)
        XCTAssertEqual(state.status?.currentStatus, "Planning")
        XCTAssertEqual(format(state.status?.lastUpdated), "2026-08-05")
        XCTAssertEqual(state.status?.nextActions, ["Review synthetic fixture", "Run validation"])
        XCTAssertEqual(state.status?.blockers, ["None"])
    }

    func testEmptyOptionalSectionsUseNoneDisplayState() {
        XCTAssertEqual(StatusListDisplay.items([]), ["None"])
        XCTAssertEqual(StatusListDisplay.items(["Keep item"]), ["Keep item"])
    }

    func testExistingConfiguredTargetsPermitOpenActions() throws {
        let valid = try copiedFixture("ValidProduct")
        let empty = try copiedFixture("EmptyInbox")
        let viewModel = try makeViewModel(first: valid, second: empty)
        let product = try XCTUnwrap(viewModel.products.first)

        XCTAssertTrue(viewModel.canOpen(.productFolder, for: product))
        XCTAssertTrue(viewModel.canOpen(.inboxFolder, for: product))
        XCTAssertTrue(viewModel.canOpen(.statusRecord, for: product))
    }

    func testMissingActionTargetDoesNotAffectOtherProduct() throws {
        let missingInbox = try copiedFixture("MissingInbox")
        let valid = try copiedFixture("ValidProduct")
        let viewModel = try makeViewModel(first: missingInbox, second: valid)
        let first = viewModel.products[0]
        let second = viewModel.products[1]

        XCTAssertFalse(viewModel.canOpen(.inboxFolder, for: first))
        XCTAssertTrue(viewModel.canOpen(.productFolder, for: first))
        XCTAssertTrue(viewModel.canOpen(.statusRecord, for: first))
        XCTAssertTrue(viewModel.canOpen(.inboxFolder, for: second))
    }

    func testMissingStatusRecordDoesNotPermitStatusOpenAction() throws {
        let valid = try copiedFixture("ValidProduct")
        let missingStatus = try copiedFixture("MissingStatus")
        let viewModel = try makeViewModel(first: valid, second: missingStatus)
        let product = viewModel.products[1]

        XCTAssertTrue(viewModel.canOpen(.productFolder, for: product))
        XCTAssertTrue(viewModel.canOpen(.inboxFolder, for: product))
        XCTAssertFalse(viewModel.canOpen(.statusRecord, for: product))
    }

    func testOpenFailureMapsToVisibleError() throws {
        let valid = try copiedFixture("ValidProduct")
        let empty = try copiedFixture("EmptyInbox")
        let opener = StubSourceOpener(error: SourceOpenError.failedToOpen("Synthetic"))
        let viewModel = try makeViewModel(first: valid, second: empty, opener: opener)
        let product = try XCTUnwrap(viewModel.products.first)

        viewModel.open(.productFolder, for: product)

        XCTAssertTrue(viewModel.sourceOpenError?.contains("Open Product Folder failed") == true)
    }

    func testOpenExistingTargetUsesOnlyConfiguredPath() throws {
        let valid = try copiedFixture("ValidProduct")
        let empty = try copiedFixture("EmptyInbox")
        let opener = StubSourceOpener()
        let viewModel = try makeViewModel(first: valid, second: empty, opener: opener)
        let product = try XCTUnwrap(viewModel.products.first)

        viewModel.open(.statusRecord, for: product)

        XCTAssertEqual(opener.openedURLs, [product.product.resolved(statusPath)])
        XCTAssertNil(viewModel.sourceOpenError)
    }

    func testRefreshReloadsDisplayedValuesWithoutChangingConfiguration() throws {
        let valid = try copiedFixture("ValidProduct")
        let empty = try copiedFixture("EmptyInbox")
        let configuration = try configuration(first: valid, second: empty)
        let storage = MemoryConfigurationStorage(data: try JSONEncoder().encode(configuration))
        let viewModel = DashboardViewModel(store: ConfigurationStore(storage: storage), fileSystem: LocalFileSystem(), sourceOpener: StubSourceOpener())
        let beforeProducts = viewModel.products
        let beforeConfiguration = storage.data

        viewModel.refresh()

        XCTAssertEqual(viewModel.products, beforeProducts)
        XCTAssertEqual(storage.data, beforeConfiguration)
    }

    private func makeViewModel(first: URL, second: URL, opener: any SourceOpening = StubSourceOpener()) throws -> DashboardViewModel {
        let configuration = try configuration(first: first, second: second)
        return DashboardViewModel(
            store: ConfigurationStore(storage: MemoryConfigurationStorage(data: try JSONEncoder().encode(configuration))),
            fileSystem: LocalFileSystem(),
            sourceOpener: opener
        )
    }

    private func configuration(first: URL, second: URL) throws -> DashboardConfiguration {
        try DashboardConfiguration(schemaVersion: 1, products: [
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

    private func format(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

private final class MemoryConfigurationStorage: ConfigurationStorage {
    var data: Data?

    init(data: Data?) {
        self.data = data
    }

    func loadData() throws -> Data? { data }
    func saveData(_ data: Data) throws { self.data = data }
}

private final class StubSourceOpener: SourceOpening {
    var openedURLs: [URL] = []
    let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func open(_ url: URL) throws {
        if let error { throw error }
        openedURLs.append(url)
    }
}
