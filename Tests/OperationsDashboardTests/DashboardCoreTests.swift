import Foundation
import XCTest
@testable import OperationsDashboard

final class DashboardCoreTests: XCTestCase {
    private let statusPath = "Reference/Product/Operations Dashboard Status.md"
    private let inboxPath = "Dashboard/Inbox"

    func testValidConfigurationDecoding() throws {
        let data = try fixtureData("ValidConfiguration")
        let configuration = try ConfigurationStore().decode(data: data)
        XCTAssertEqual(configuration.schemaVersion, 1)
        XCTAssertEqual(configuration.products.map(\.id).sorted(), ["momentum-management", "momomovies"])
    }

    func testMalformedConfigurationHandling() {
        XCTAssertThrowsError(try ConfigurationStore().decode(data: Data("{}".utf8))) { error in
            XCTAssertNotNil(error as? ConfigurationError)
        }
    }

    func testDirectInboxCountingCountsVisibleFilesAndDirectoriesOnly() throws {
        let root = try copiedFixture("HiddenAndDirectory")
        let count = try InboxScanner().countEntries(at: root.appending(path: inboxPath), fileSystem: LocalFileSystem())
        XCTAssertEqual(count, 2)
    }

    func testEmptyInboxIsZero() throws {
        let root = try copiedFixture("EmptyInbox")
        let count = try InboxScanner().countEntries(at: root.appending(path: inboxPath), fileSystem: LocalFileSystem())
        XCTAssertEqual(count, 0)
    }

    func testMissingInboxIsIndependentFromValidStatus() throws {
        let root = try copiedFixture("MissingInbox")
        let state = try loadSingleFixture(root: root, id: "momentum-management")
        XCTAssertNil(state.inboxCount)
        XCTAssertEqual(state.status?.currentStatus, "Blocked")
        XCTAssertTrue(state.issues.contains(.missingInbox))
    }

    func testCompleteStatusParsing() throws {
        let root = try copiedFixture("ValidProduct")
        let data = try Data(contentsOf: root.appending(path: statusPath))
        let status = try StatusParser().parse(data: data)
        XCTAssertEqual(status.currentStatus, "Planning")
        XCTAssertEqual(status.nextActions, ["Review synthetic fixture", "Run validation"])
        XCTAssertEqual(status.blockers, ["None"])
    }

    func testAbsentOptionalSectionsProduceEmptyCollections() throws {
        let root = try copiedFixture("EmptyInbox")
        let data = try Data(contentsOf: root.appending(path: statusPath))
        let status = try StatusParser().parse(data: data)
        XCTAssertEqual(status.nextActions, [])
        XCTAssertEqual(status.blockers, [])
    }

    func testMalformedStatusProducesAParseIssue() throws {
        let root = try copiedFixture("MalformedStatus")
        let state = try loadSingleFixture(root: root, id: "momentum-management")
        XCTAssertTrue(state.issues.contains { issue in
            if case .malformedStatusRecord = issue { return true }
            return false
        })
    }

    func testIndependentProductFailureDoesNotBlockOtherProduct() throws {
        let valid = try copiedFixture("ValidProduct")
        let missing = try copiedFixture("MissingStatus")
        let configuration = DashboardConfiguration(schemaVersion: 1, products: [
            product(id: "momentum-management", root: valid),
            product(id: "momomovies", root: missing)
        ])
        let states = try DashboardLoader(configurationLoader: StaticConfigurationLoader(configuration), fileSystem: LocalFileSystem()).load()
        XCTAssertEqual(states.count, 2)
        XCTAssertEqual(states[0].inboxCount, 2)
        XCTAssertEqual(states[0].status?.currentStatus, "Planning")
        XCTAssertTrue(states[1].issues.contains(.missingStatusRecord))
    }

    func testFixtureBasedAggregateLoading() throws {
        let valid = try copiedFixture("ValidProduct")
        let empty = try copiedFixture("EmptyInbox")
        let configuration = DashboardConfiguration(schemaVersion: 1, products: [
            product(id: "momentum-management", root: valid),
            product(id: "momomovies", root: empty)
        ])
        let states = try DashboardLoader(configurationLoader: StaticConfigurationLoader(configuration), fileSystem: LocalFileSystem()).load()
        XCTAssertEqual(states.map(\.inboxCount), [2, 0])
        XCTAssertEqual(states[1].status?.currentStatus, "Ready")
    }

    func testUnreadableSourceMapsThroughInjectedFileSystem() throws {
        let product = ConfiguredProduct(id: "momentum-management", displayName: "Synthetic", productRootPath: "/synthetic/unreadable", inboxRelativePath: inboxPath, statusRecordRelativePath: statusPath)
        let fileSystem = ThrowingFileSystem(existingPaths: [product.resolved(inboxPath), product.resolved(statusPath)])
        let state = try DashboardLoader(configurationLoader: StaticConfigurationLoader(DashboardConfiguration(schemaVersion: 1, products: [product, productForMomoMovies()])), fileSystem: fileSystem).load().first!
        XCTAssertTrue(state.issues.contains { issue in
            if case .unreadableInbox = issue { return true }
            return false
        })
        XCTAssertTrue(state.issues.contains { issue in
            if case .unreadableStatusRecord = issue { return true }
            return false
        })
    }

    private func product(id: String, root: URL) -> ConfiguredProduct {
        ConfiguredProduct(id: id, displayName: id, productRootPath: root.path, inboxRelativePath: inboxPath, statusRecordRelativePath: statusPath)
    }

    private func productForMomoMovies() -> ConfiguredProduct {
        ConfiguredProduct(id: "momomovies", displayName: "Synthetic Secondary", productRootPath: "/synthetic/secondary", inboxRelativePath: inboxPath, statusRecordRelativePath: statusPath)
    }

    private func loadSingleFixture(root: URL, id: String) throws -> ProductDashboardState {
        let primary = product(id: id, root: root)
        let secondary = productForMomoMovies()
        let configuration = DashboardConfiguration(schemaVersion: 1, products: id == "momentum-management" ? [primary, secondary] : [secondary, primary])
        return try DashboardLoader(configurationLoader: StaticConfigurationLoader(configuration), fileSystem: LocalFileSystem()).load().first { $0.product.id == id }!
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)", directoryHint: .notDirectory))
    }

    private func copiedFixture(_ name: String) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: fixtureURL(name), to: destination)
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        return destination
    }

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!.appending(path: "Fixtures/\(name)", directoryHint: .isDirectory)
    }
}

private struct StaticConfigurationLoader: ConfigurationLoading {
    let configuration: DashboardConfiguration
    init(_ configuration: DashboardConfiguration) { self.configuration = configuration }
    func loadConfiguration() throws -> DashboardConfiguration { try configuration.validated() }
}

private struct ThrowingFileSystem: FileSystem {
    let existingPaths: Set<URL>
    func exists(at url: URL) -> Bool { existingPaths.contains(url) }
    func isDirectory(at url: URL) throws -> Bool { true }
    func directoryEntries(at url: URL) throws -> [FileSystemEntry] { throw CocoaError(.fileReadNoPermission) }
    func readData(at url: URL) throws -> Data { throw CocoaError(.fileReadNoPermission) }
    func modificationDate(at url: URL) -> Date? { nil }
}
