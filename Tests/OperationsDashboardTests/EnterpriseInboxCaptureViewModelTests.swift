import XCTest
@testable import OperationsDashboard

@MainActor
final class EnterpriseInboxCaptureViewModelTests: XCTestCase {
    func testSelectionStartsEmptyAndUsesStableSourceQualifiedIdentity() throws {
        let first = item(name: "same.txt", sourceID: "icloud-downloads")
        let second = item(name: "same.txt", sourceID: "kahntra-downloads")
        let model = makeModel(results: [result(items: [first, second])])

        XCTAssertEqual(model.selectedCount, 0)
        model.toggleSelection(of: first)
        XCTAssertEqual(model.selectedItemIDs, [first.id])
        model.toggleSelection(of: second)
        XCTAssertEqual(model.selectedCount, 2)
        model.toggleSelection(of: first)
        XCTAssertEqual(model.selectedItemIDs, [second.id])
    }

    func testSelectAllAndClear() throws {
        let first = item(name: "one.txt", sourceID: "icloud-downloads")
        let second = item(name: "two.txt", sourceID: "kahntra-downloads")
        let model = makeModel(results: [result(items: [first, second])])

        model.selectAll()
        XCTAssertEqual(model.selectedItemIDs, Set([first.id, second.id]))
        model.clearSelection()
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
    }

    func testRefreshRemovesStaleSelectionAndPreservesSurvivingSelection() throws {
        let removed = item(name: "removed.txt", sourceID: "icloud-downloads")
        let retained = item(name: "retained.txt", sourceID: "kahntra-downloads")
        let enumerator = StubEnumerator(results: [result(items: [removed, retained]), result(items: [retained])])
        let model = makeModel(enumerator: enumerator)
        model.selectAll()

        model.refresh()

        XCTAssertEqual(model.selectedItemIDs, [retained.id])
    }

    func testMoveDoesNotRunBeforeConfirmationAndCancelDoesNotMove() throws {
        let item = item(name: "report.txt", sourceID: "icloud-downloads")
        let mover = StubMover(result: IntakeMoveBatchResult(results: []))
        let model = makeModel(results: [result(items: [item])], mover: mover)
        model.toggleSelection(of: item)

        model.requestMoveConfirmation()
        XCTAssertTrue(model.isConfirmationPresented)
        XCTAssertEqual(mover.calls, 0)
        model.cancelMoveConfirmation()
        XCTAssertFalse(model.isConfirmationPresented)
        XCTAssertEqual(mover.calls, 0)
    }

    func testConfirmedMoveSubmitsExactlySelectedItemsAndRefreshes() throws {
        let first = item(name: "first.txt", sourceID: "icloud-downloads")
        let second = item(name: "second.txt", sourceID: "kahntra-downloads")
        let enumerator = StubEnumerator(results: [result(items: [first, second]), result(items: [second])])
        let mover = StubMover(result: IntakeMoveBatchResult(results: [IntakeMoveResult(item: first, outcome: .moved(destination: URL(fileURLWithPath: "/enterprise/Dashboard/Inbox/first.txt")))]))
        var dashboardRefreshes = 0
        let model = makeModel(enumerator: enumerator, mover: mover, dashboardRefresh: { dashboardRefreshes += 1 })
        model.toggleSelection(of: first)
        model.requestMoveConfirmation()
        model.confirmMove()

        XCTAssertEqual(mover.calls, 1)
        XCTAssertEqual(mover.submittedItems, [first])
        XCTAssertEqual(enumerator.calls, 2)
        XCTAssertEqual(dashboardRefreshes, 1)
        XCTAssertTrue(model.selectedItemIDs.isEmpty)
        XCTAssertEqual(model.sessionResults.map(\.title), ["Moved first.txt"])
        XCTAssertEqual(model.sessionResults.first?.isCurrent, true)
    }

    func testCollisionMoveResultNamesTheRenamedDestination() throws {
        let item = item(name: "test.txt", sourceID: "kahntra-downloads")
        let renamedDestination = URL(fileURLWithPath: "/enterprise/Dashboard/Inbox/test (2).txt")
        let mover = StubMover(result: IntakeMoveBatchResult(results: [
            IntakeMoveResult(item: item, outcome: .moved(destination: renamedDestination))
        ]))
        let model = makeModel(results: [result(items: [item]), result(items: [])], mover: mover)
        model.toggleSelection(of: item)
        model.requestMoveConfirmation()
        model.confirmMove()

        XCTAssertEqual(model.sessionResults.map(\.title), ["Moved test.txt, renamed to test (2).txt"])
        XCTAssertEqual(model.sessionResults.first?.isCurrent, true)
    }

    func testPartialFailureKeepsFailedVisibleItemSelected() throws {
        let moved = item(name: "moved.txt", sourceID: "icloud-downloads")
        let failed = item(name: "failed.txt", sourceID: "kahntra-downloads")
        let enumeration = StubEnumerator(results: [result(items: [moved, failed]), result(items: [failed])])
        let outcome = IntakeMoveBatchResult(results: [
            IntakeMoveResult(item: moved, outcome: .moved(destination: URL(fileURLWithPath: "/enterprise/Dashboard/Inbox/moved.txt"))),
            IntakeMoveResult(item: failed, outcome: .failed(category: .permissionDenied, diagnostic: "Permission denied.", attemptedDestination: nil))
        ])
        let model = makeModel(enumerator: enumeration, mover: StubMover(result: outcome))
        model.selectAll()
        model.requestMoveConfirmation()
        model.confirmMove()

        XCTAssertEqual(model.selectedItemIDs, [failed.id])
        XCTAssertEqual(model.moveResult, outcome)
    }

    func testMissingConfigurationAndIndependentUnavailableSourceAreRepresented() throws {
        let missingStore = CaptureConfigurationStore(storage: MemoryStorage(data: nil))
        let missingModel = EnterpriseInboxCaptureViewModel(
            configurationStore: missingStore,
            fileSystem: PermissiveCaptureFileSystem(),
            mover: StubMover(result: IntakeMoveBatchResult(results: []))
        )
        XCTAssertNotNil(missingModel.configurationProblem)
        XCTAssertTrue(missingModel.items.isEmpty)

        let valid = item(name: "available.txt", sourceID: "icloud-downloads")
        let mixed = result(items: [valid], firstAvailability: .available, secondAvailability: .missing)
        let populatedModel = makeModel(results: [mixed])
        XCTAssertEqual(populatedModel.items, [valid])
        XCTAssertEqual(populatedModel.enumeration?.sources[1].availability, .missing)
    }

    func testDestinationUnavailableBlocksConfirmationAndMove() throws {
        let item = item(name: "report.txt", sourceID: "icloud-downloads")
        let mover = StubMover(result: IntakeMoveBatchResult(results: []))
        let model = makeModel(results: [result(items: [item])], fileSystem: DestinationUnavailableFileSystem(), mover: mover)
        model.toggleSelection(of: item)

        XCTAssertNotNil(model.destinationProblem)
        XCTAssertFalse(model.canMove)
        model.requestMoveConfirmation()
        XCTAssertFalse(model.isConfirmationPresented)
        XCTAssertEqual(mover.calls, 0)
    }

    func testQuickCaptureRequiresExplicitValidTextAndSuccessClearsTextWithoutChangingSelection() throws {
        let item = item(name: "selected.txt", sourceID: "icloud-downloads")
        let writer = StubQuickCaptureWriter(result: .success(path: URL(fileURLWithPath: "/enterprise/Dashboard/Inbox/Quick Capture 2026-08-07 163245.md")))
        var dashboardRefreshes = 0
        let model = makeModel(
            enumerator: StubEnumerator(results: [result(items: [item]), result(items: [item])]),
            quickCaptureWriter: writer,
            dashboardRefresh: { dashboardRefreshes += 1 }
        )
        model.toggleSelection(of: item)
        model.quickCaptureText = " \n\t"
        XCTAssertFalse(model.canQuickCapture)
        model.submitQuickCapture()
        XCTAssertEqual(writer.calls, 0)

        model.quickCaptureText = "Capture this\nverbatim"
        XCTAssertTrue(model.canQuickCapture)
        model.submitQuickCapture()

        XCTAssertEqual(writer.calls, 1)
        XCTAssertEqual(writer.submittedText, "Capture this\nverbatim")
        XCTAssertEqual(model.quickCaptureText, "")
        XCTAssertEqual(model.selectedItemIDs, [item.id])
        XCTAssertEqual(dashboardRefreshes, 1)
        XCTAssertEqual(model.sessionResults.first?.title, "Added Quick Capture 2026-08-07 163245.md")
        XCTAssertEqual(model.sessionResults.first?.isCurrent, true)
    }

    func testQuickCaptureFailurePreservesTextAndExposesResult() throws {
        let failure = QuickCaptureResult.failure(.writeFailed, diagnostic: "Disk write failed.")
        let writer = StubQuickCaptureWriter(result: failure)
        let model = makeModel(results: [result(items: [])], quickCaptureWriter: writer)
        model.quickCaptureText = "Keep this text"

        model.submitQuickCapture()

        XCTAssertEqual(writer.calls, 1)
        XCTAssertEqual(model.quickCaptureText, "Keep this text")
        XCTAssertEqual(model.quickCaptureResult, failure)
    }

    func testNewUserInteractionDeemphasizesSessionResultsWithoutRemovingThem() throws {
        let item = item(name: "selected.txt", sourceID: "icloud-downloads")
        let writer = StubQuickCaptureWriter(result: .success(path: URL(fileURLWithPath: "/enterprise/Dashboard/Inbox/Quick Capture 2026-08-07 163245.md")))
        let model = makeModel(results: [result(items: [item])], quickCaptureWriter: writer)
        model.quickCaptureText = "Capture this"
        model.submitQuickCapture()

        model.toggleSelection(of: item)

        XCTAssertEqual(model.sessionResults.count, 1)
        XCTAssertEqual(model.sessionResults.first?.isCurrent, false)
        XCTAssertEqual(model.successfulSessionResultCount, 1)
        XCTAssertEqual(model.failedSessionResultCount, 0)
    }

    func testPreparedItemsRequireConfirmationThenUseDedicatedMoveBoundaryAndResults() throws {
        let prepared = preparedItem(name: "ready.txt", sourceID: "icloud-downloads")
        let preparedEnumerator = StubPreparedEnumerator(results: [preparedResult(items: [prepared]), preparedResult(items: [])])
        let preparedMover = StubPreparedMover(result: PreparedItemMoveBatchResult(results: [
            PreparedItemMoveResult(item: prepared, outcome: .moved(destination: URL(fileURLWithPath: "/enterprise/Dashboard/Inbox/ready.txt")))
        ]))
        let model = makeModel(
            enumerator: StubEnumerator(results: [result(items: []), result(items: [])]),
            preparedEnumerator: preparedEnumerator,
            preparedMover: preparedMover
        )

        XCTAssertEqual(model.preparedItems, [prepared])
        XCTAssertTrue(model.canMovePrepared)
        model.requestPreparedMoveConfirmation()
        XCTAssertTrue(model.isPreparedConfirmationPresented)
        XCTAssertEqual(preparedMover.calls, 0)

        model.confirmPreparedMove()

        XCTAssertEqual(preparedMover.calls, 1)
        XCTAssertEqual(preparedMover.submittedItems, [prepared])
        XCTAssertEqual(model.preparedItems, [])
        XCTAssertEqual(model.sessionResults.first?.title, "Moved ready.txt from iCloud Drive Downloads")
        XCTAssertEqual(model.sessionResults.first?.isCurrent, true)
    }

    private func makeModel(
        results: [IntakeEnumerationResult],
        fileSystem: any CaptureFileSystem = PermissiveCaptureFileSystem(),
        mover: StubMover = StubMover(result: IntakeMoveBatchResult(results: [])),
        quickCaptureWriter: StubQuickCaptureWriter = StubQuickCaptureWriter(result: .failure(.writeFailed, diagnostic: "Unused"))
    ) -> EnterpriseInboxCaptureViewModel {
        makeModel(enumerator: StubEnumerator(results: results), fileSystem: fileSystem, mover: mover, quickCaptureWriter: quickCaptureWriter)
    }

    private func makeModel(
        enumerator: StubEnumerator,
        fileSystem: any CaptureFileSystem = PermissiveCaptureFileSystem(),
        mover: StubMover = StubMover(result: IntakeMoveBatchResult(results: [])),
        preparedEnumerator: StubPreparedEnumerator = StubPreparedEnumerator(results: [PreparedItemsEnumerationResult(folders: [], items: [])]),
        preparedMover: StubPreparedMover = StubPreparedMover(result: PreparedItemMoveBatchResult(results: [])),
        quickCaptureWriter: StubQuickCaptureWriter = StubQuickCaptureWriter(result: .failure(.writeFailed, diagnostic: "Unused")),
        dashboardRefresh: @escaping () -> Void = {}
    ) -> EnterpriseInboxCaptureViewModel {
        let data = try! JSONEncoder().encode(configuration())
        return EnterpriseInboxCaptureViewModel(
            configurationStore: CaptureConfigurationStore(storage: MemoryStorage(data: data)),
            fileSystem: fileSystem,
            enumerator: enumerator,
            mover: mover,
            preparedEnumerator: preparedEnumerator,
            preparedMover: preparedMover,
            quickCaptureWriter: quickCaptureWriter,
            now: { Date(timeIntervalSince1970: 0) },
            dashboardRefresh: dashboardRefresh
        )
    }

    private func configuration() -> CaptureConfiguration {
        CaptureConfiguration(schemaVersion: 1, intakeSources: [
            IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: "/capture/icloud"),
            IntakeSource(id: "kahntra-downloads", displayName: "Kahntra Downloads", rootPath: "/capture/kahntra")
        ], enterpriseInboxPath: "/enterprise/Dashboard/Inbox")
    }

    private func result(
        items: [IntakeItem],
        firstAvailability: IntakeSourceAvailability = .available,
        secondAvailability: IntakeSourceAvailability = .available
    ) -> IntakeEnumerationResult {
        let configuration = configuration()
        return IntakeEnumerationResult(sources: [
            IntakeSourceEnumeration(source: configuration.intakeSources[0], availability: firstAvailability, items: items.filter { $0.sourceID == "icloud-downloads" }),
            IntakeSourceEnumeration(source: configuration.intakeSources[1], availability: secondAvailability, items: items.filter { $0.sourceID == "kahntra-downloads" })
        ], items: items)
    }

    private func item(name: String, sourceID: String) -> IntakeItem {
        let source = sourceID == "icloud-downloads"
            ? IntakeSource(id: sourceID, displayName: "iCloud Drive Downloads", rootPath: "/capture/icloud")
            : IntakeSource(id: sourceID, displayName: "Kahntra Downloads", rootPath: "/capture/kahntra")
        return IntakeItem(sourceID: source.id, sourceDisplayName: source.displayName, sourceRootURL: source.rootURL, itemURL: source.rootURL.appending(path: name), displayName: name, kind: .file, resourceIdentifier: "\(sourceID)-\(name)")
    }

    private func preparedItem(name: String, sourceID: String) -> PreparedIntakeItem {
        let source = sourceID == "icloud-downloads"
            ? IntakeSource(id: sourceID, displayName: "iCloud Drive Downloads", rootPath: "/capture/icloud")
            : IntakeSource(id: sourceID, displayName: "Kahntra Downloads", rootPath: "/capture/kahntra")
        let folder = source.rootURL.appending(path: PreparedItemsEnumerator.folderName, directoryHint: .isDirectory)
        return PreparedIntakeItem(sourceID: source.id, sourceDisplayName: source.displayName, preparedFolderURL: folder, itemURL: folder.appending(path: name), displayName: name, kind: .file, resourceIdentifier: "\(sourceID)-\(name)")
    }

    private func preparedResult(
        items: [PreparedIntakeItem],
        firstAvailability: IntakeSourceAvailability = .available,
        secondAvailability: IntakeSourceAvailability = .available
    ) -> PreparedItemsEnumerationResult {
        let configuration = configuration()
        let folders = configuration.intakeSources.map { source in
            PreparedIntakeFolder(source: source, folderURL: source.rootURL.appending(path: PreparedItemsEnumerator.folderName, directoryHint: .isDirectory))
        }
        return PreparedItemsEnumerationResult(folders: [
            PreparedFolderEnumeration(folder: folders[0], availability: firstAvailability, items: items.filter { $0.sourceID == "icloud-downloads" }),
            PreparedFolderEnumeration(folder: folders[1], availability: secondAvailability, items: items.filter { $0.sourceID == "kahntra-downloads" })
        ], items: items)
    }
}

private final class MemoryStorage: CaptureConfigurationStorage {
    let data: Data?
    init(data: Data?) { self.data = data }
    func loadData() throws -> Data? { data }
    func saveData(_ data: Data) throws {}
}

private final class StubEnumerator: IntakeEnumerating {
    private var results: [IntakeEnumerationResult]
    private(set) var calls = 0

    init(results: [IntakeEnumerationResult]) { self.results = results }

    func enumerate(configuration: CaptureConfiguration, fileSystem: any CaptureFileSystem) throws -> IntakeEnumerationResult {
        calls += 1
        return results[min(calls - 1, results.count - 1)]
    }
}

private final class StubMover: CaptureMoving {
    let result: IntakeMoveBatchResult
    private(set) var calls = 0
    private(set) var submittedItems: [IntakeItem] = []

    init(result: IntakeMoveBatchResult) { self.result = result }

    func move(selected items: [IntakeItem], configuration: CaptureConfiguration) -> IntakeMoveBatchResult {
        calls += 1
        submittedItems = items
        return result
    }
}

private final class StubPreparedEnumerator: PreparedItemsEnumerating {
    private var results: [PreparedItemsEnumerationResult]
    private(set) var calls = 0

    init(results: [PreparedItemsEnumerationResult]) { self.results = results }

    func enumerate(configuration: CaptureConfiguration, fileSystem: any CaptureFileSystem) throws -> PreparedItemsEnumerationResult {
        calls += 1
        return results[min(calls - 1, results.count - 1)]
    }
}

private final class StubPreparedMover: PreparedItemsMoving {
    let result: PreparedItemMoveBatchResult
    private(set) var calls = 0
    private(set) var submittedItems: [PreparedIntakeItem] = []

    init(result: PreparedItemMoveBatchResult) { self.result = result }

    func move(selected items: [PreparedIntakeItem], configuration: CaptureConfiguration) -> PreparedItemMoveBatchResult {
        calls += 1
        submittedItems = items
        return result
    }
}

private final class StubQuickCaptureWriter: QuickCaptureWriting {
    let result: QuickCaptureResult
    private(set) var calls = 0
    private(set) var submittedText: String?

    init(result: QuickCaptureResult) { self.result = result }

    func create(text: String, configuration: CaptureConfiguration, now: Date) -> QuickCaptureResult {
        calls += 1
        submittedText = text
        return result
    }
}

private struct PermissiveCaptureFileSystem: CaptureFileSystem {
    func exists(at url: URL) -> Bool { true }
    func isReadable(at url: URL) -> Bool { true }
    func isWritable(at url: URL) -> Bool { true }
    func isDirectory(at url: URL) throws -> Bool { true }
    func isSymbolicLink(at url: URL) throws -> Bool { false }
    func directoryEntries(at url: URL) throws -> [CaptureDirectoryEntry] { [] }
    func entry(at url: URL) throws -> CaptureDirectoryEntry { throw NSError(domain: "unused", code: 0) }
}

private struct DestinationUnavailableFileSystem: CaptureFileSystem {
    func exists(at url: URL) -> Bool { true }
    func isReadable(at url: URL) -> Bool { true }
    func isWritable(at url: URL) -> Bool { false }
    func isDirectory(at url: URL) throws -> Bool { true }
    func isSymbolicLink(at url: URL) throws -> Bool { false }
    func directoryEntries(at url: URL) throws -> [CaptureDirectoryEntry] { [] }
    func entry(at url: URL) throws -> CaptureDirectoryEntry { throw NSError(domain: "unused", code: 0) }
}
