import Darwin
import Foundation
import XCTest
@testable import OperationsDashboard

final class HeadlessCaptureAutomaticCommandsTests: XCTestCase {
    func testCommandObservePreviewExecuteMovesFilesFoldersAndPackagesInOrderWithoutContractWrites() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("b.txt", "b")
        try fixture.file("a.txt", "a")
        try fixture.directory("Folder", child: "child.txt")
        try fixture.directory("Example.app", child: "Contents/value")
        let before = try fixture.contractSnapshot()
        let adapter = fixture.adapter()

        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.observeArguments, adapter: adapter, write: { output.append($0) }), 0)
        let observed = try fixture.observationOutput(output)
        XCTAssertEqual(observed.observation.items.map(\.basename), ["Example.app", "Folder", "a.txt", "b.txt"])
        fixture.clock.advance(seconds: 2)

        output = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.previewArguments(observed), adapter: adapter, write: { output.append($0) }), 0)
        let previewed = try fixture.previewOutput(output)
        XCTAssertEqual(previewed.preview.items.map(\.disposition), [.planned, .planned, .planned, .planned])

        output = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 0)
        XCTAssertTrue(output[0].contains("\"state\":\"completed\""))
        for name in ["Example.app", "Folder", "a.txt", "b.txt"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appending(path: name).path))
            let destination = fixture.inbox.appending(path: name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            var destinationState = stat(); XCTAssertEqual(lstat(destination.path, &destinationState), 0)
            let observedState = try XCTUnwrap(observed.observation.items.first(where: { $0.basename == name })?.state)
            XCTAssertEqual(UInt64(destinationState.st_dev), observedState.device)
            XCTAssertEqual(UInt64(destinationState.st_ino), observedState.inode)
        }
        XCTAssertEqual(try fixture.contractSnapshot(), before)
    }

    func testCompleteDOC0016TupleResetsStabilityForReplacementInode() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        let source = try fixture.file("same.txt", "same")
        let service = fixture.service()
        let observation = try service.recordAutomaticObservation(productionsRoot: fixture.root)
        let old = try XCTUnwrap(observation.items.first?.state)
        try FileManager.default.removeItem(at: source)
        try Data("same".utf8).write(to: source)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(old.modifiedSeconds) + TimeInterval(old.modifiedNanoseconds) / 1_000_000_000)], ofItemAtPath: source.path)
        fixture.clock.advance(seconds: 2)
        let preview = try service.previewAutomaticMove(productionsRoot: fixture.root, observation: observation)
        XCTAssertNotEqual(preview.items[0].state.inode, old.inode)
        XCTAssertEqual(preview.items[0].disposition, .deferred)
    }

    func testLessThanTwoSecondsForgedReceiptAndBootChangeReject() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("item.txt", "x")
        let service = fixture.service()
        let observation = try service.recordAutomaticObservation(productionsRoot: fixture.root)
        XCTAssertThrowsError(try service.previewAutomaticMove(productionsRoot: fixture.root, observation: observation)) {
            XCTAssertEqual($0.localizedDescription, "A second matching observation must occur at least two seconds after the first.")
        }
        fixture.clock.advance(seconds: 2)
        var forged = observation
        forged = AutomaticCaptureObservation(schema: forged.schema, actionDiscriminator: forged.actionDiscriminator, receiptID: forged.receiptID, bootSessionID: forged.bootSessionID, continuousNanoseconds: forged.continuousNanoseconds, observedAt: forged.observedAt, productionsRoot: forged.productionsRoot, sourcePath: forged.sourcePath + "-forged", officePath: forged.officePath, inboxPath: forged.inboxPath, rootState: forged.rootState, sourceState: forged.sourceState, officeState: forged.officeState, inboxState: forged.inboxState, items: forged.items)
        XCTAssertThrowsError(try service.previewAutomaticMove(productionsRoot: fixture.root, observation: forged))
        fixture.clock.boot = "another-boot"
        XCTAssertThrowsError(try service.previewAutomaticMove(productionsRoot: fixture.root, observation: observation)) {
            XCTAssertTrue($0.localizedDescription.contains("boot session"))
        }
    }

    func testAllProductionsOfficeInboxOverlapDirectionsReject() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        let office = fixture.root.appending(path: "Office", directoryHint: .isDirectory)
        let nestedInbox = fixture.inbox.appending(path: "Nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedInbox, withIntermediateDirectories: true)
        for source in [fixture.root, office, fixture.inbox, nestedInbox, fixture.root.deletingLastPathComponent()] {
            let service = fixture.service(source: source)
            XCTAssertThrowsError(try service.recordAutomaticObservation(productionsRoot: fixture.root)) {
                XCTAssertEqual($0.localizedDescription, "The configured automatic source must not equal, contain, or be contained by Productions, Office, or Office/Inbox.")
            }
        }
    }

    func testMissingConfiguredSourceInvalidRootAndSymbolicConfiguredSourceReject() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        fixture.configuredSource = ""
        XCTAssertThrowsError(try fixture.service().recordAutomaticObservation(productionsRoot: fixture.root)) {
            XCTAssertTrue($0.localizedDescription.contains("No automatic capture source"))
        }
        fixture.configuredSource = fixture.source.path
        XCTAssertThrowsError(try fixture.service().recordAutomaticObservation(productionsRoot: fixture.container.appending(path: "MissingRoot")))
        let linked = fixture.container.appending(path: "LinkedSource")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.source)
        fixture.configuredSource = linked.path
        XCTAssertThrowsError(try fixture.service().recordAutomaticObservation(productionsRoot: fixture.root)) {
            XCTAssertEqual($0.localizedDescription, "Configured automatic source is unavailable or symbolic.")
        }
    }

    func testEligibilityCollisionAndChangedItemsPreserveShallowBehaviorAndOrdering() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        let changed = try fixture.file("a-changed.txt", "a")
        let collision = try fixture.file("b-collision.txt", "b")
        _ = collision
        try fixture.file("c-later.txt", "c")
        let link = fixture.source.appending(path: "0-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: changed)
        let fifo = fixture.source.appending(path: "1-pipe"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let service = fixture.service()
        let observation = try service.recordAutomaticObservation(productionsRoot: fixture.root)
        try Data("changed".utf8).write(to: changed)
        try Data("destination".utf8).write(to: fixture.inbox.appending(path: "b-collision.txt"))
        fixture.clock.advance(seconds: 2)
        let preview = try service.previewAutomaticMove(productionsRoot: fixture.root, observation: observation)
        XCTAssertEqual(preview.items.map(\.basename), ["0-link", "1-pipe", "a-changed.txt", "b-collision.txt", "c-later.txt"])
        XCTAssertEqual(preview.items.map(\.disposition), [.ineligible, .ineligible, .deferred, .collision, .notAttempted])
    }

    func testCrossFilesystemPolicyRejectsBeforeClaimOrMove() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("cross.txt", "x")
        let service = fixture.service(sameFileSystem: false)
        let observation = try service.recordAutomaticObservation(productionsRoot: fixture.root)
        fixture.clock.advance(seconds: 2)
        let preview = try service.previewAutomaticMove(productionsRoot: fixture.root, observation: observation)
        XCTAssertEqual(preview.items[0].disposition, .ineligible)
        XCTAssertTrue(preview.items[0].diagnostic.contains("same-filesystem only"))
        XCTAssertNil(fixture.receipts.loadClaim(observation.receiptID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appending(path: "cross.txt").path))
    }

    func testFirstRenameFailureIsDefiniteExitTwoAndClaimPreventsReplay() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("failure.txt", "x")
        let adapter = fixture.adapter(rename: { _, _, _, _ in EIO })
        let observed = try fixture.observe(adapter)
        fixture.clock.advance(seconds: 2)
        let previewed = try fixture.preview(observed, adapter: adapter)
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 2)
        XCTAssertTrue(output[0].contains("definiteFailure"))
        output = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 3)
        XCTAssertEqual(output[0].components(separatedBy: "do not retry automatically").count - 1, 1)
    }

    func testPartialBatchAndPostPublicationReplacementAreExitThreeNoRetry() throws {
        do {
            let fixture = try AutomaticFixture(); defer { fixture.remove() }
            try fixture.file("a.txt", "a"); try fixture.file("b.txt", "b")
            let live = AutomaticCaptureRuntime.live.renameExclusive
            var calls = 0
            let adapter = fixture.adapter(rename: { sourceFD, source, inboxFD, destination in calls += 1; return calls == 1 ? live(sourceFD, source, inboxFD, destination) : EIO })
            let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
            var output: [String] = []
            XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 3)
            XCTAssertTrue(output[0].contains("partially committed")); XCTAssertEqual(output[0].components(separatedBy: "do not retry automatically").count - 1, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.inbox.appending(path: "a.txt").path)); XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appending(path: "b.txt").path))
        }
        do {
            let fixture = try AutomaticFixture(); defer { fixture.remove() }
            try fixture.file("replace.txt", "original")
            let live = AutomaticCaptureRuntime.live.renameExclusive
            let adapter = fixture.adapter(rename: { sourceFD, source, inboxFD, destination in
                let result = live(sourceFD, source, inboxFD, destination)
                if result == 0 { try? FileManager.default.removeItem(at: fixture.inbox.appending(path: destination)); try? Data("raced".utf8).write(to: fixture.inbox.appending(path: destination)) }
                return result
            })
            let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
            var output: [String] = []
            XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 3)
            XCTAssertTrue(output[0].contains("Post-move namespace verification failed"))
        }
    }

    func testPostPublicationJournalFailureIsExitThreeAndReplayNeverMovesAgain() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("journal.txt", "payload")
        var updates = 0
        let failingStore = AutomaticCaptureReceiptStore(root: fixture.container.appending(path: "FailingReceipts", directoryHint: .isDirectory), now: { fixture.clock.date }, failOperation: { operation in
            guard operation == "update" else { return false }
            updates += 1
            return updates == 2
        })
        let context = fixture.context(receipts: failingStore)
        let adapter = HeadlessCaptureAutomaticAdapter(makeService: { ProductionsInboxCaptureService(automaticCaptureContext: context) })
        let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 3)
        XCTAssertEqual(output[0].components(separatedBy: "do not retry automatically").count - 1, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.inbox.appending(path: "journal.txt").path))
        output = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appending(path: "journal.txt").path))
    }

    func testNextItemInspectionFailureAfterFirstPublicationIsExitThree() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("a.txt", "a"); try fixture.file("b.txt", "b")
        let live = AutomaticCaptureRuntime.live.renameExclusive
        var published = false
        let context = fixture.context(rename: { sourceFD, source, inboxFD, destination in
            let result = live(sourceFD, source, inboxFD, destination)
            if result == 0 { published = true }
            return result
        }, beforeEntryInspection: { name in
            if published && name == "b.txt" { throw AutomaticCaptureError.rejected("Injected next-item inspection failure.") }
        })
        let adapter = HeadlessCaptureAutomaticAdapter(makeService: { ProductionsInboxCaptureService(automaticCaptureContext: context) })
        let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
        try assertCommittedUncertain(fixture: fixture, adapter: adapter, preview: previewed, contains: "Injected next-item inspection failure")
    }

    func testPreRenameJournalFailureAfterFirstPublicationIsExitThree() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("a.txt", "a"); try fixture.file("b.txt", "b")
        var updates = 0
        let store = AutomaticCaptureReceiptStore(root: fixture.container.appending(path: "PreRenameFailure", directoryHint: .isDirectory), now: { fixture.clock.date }, failOperation: { operation in
            guard operation == "update" else { return false }; updates += 1; return updates == 4
        })
        let context = fixture.context(receipts: store)
        let adapter = HeadlessCaptureAutomaticAdapter(makeService: { ProductionsInboxCaptureService(automaticCaptureContext: context) })
        let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
        try assertCommittedUncertain(fixture: fixture, adapter: adapter, preview: previewed, contains: "journal could not be updated")
    }

    func testFailureStateJournalFailureAfterFirstPublicationIsExitThree() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("a.txt", "a"); try fixture.file("b.txt", "b")
        var updates = 0; var renames = 0
        let store = AutomaticCaptureReceiptStore(root: fixture.container.appending(path: "FailureStateFailure", directoryHint: .isDirectory), now: { fixture.clock.date }, failOperation: { operation in
            guard operation == "update" else { return false }; updates += 1; return updates == 5
        })
        let live = AutomaticCaptureRuntime.live.renameExclusive
        let context = fixture.context(receipts: store, rename: { sourceFD, source, inboxFD, destination in
            renames += 1; return renames == 1 ? live(sourceFD, source, inboxFD, destination) : EIO
        })
        let adapter = HeadlessCaptureAutomaticAdapter(makeService: { ProductionsInboxCaptureService(automaticCaptureContext: context) })
        let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
        try assertCommittedUncertain(fixture: fixture, adapter: adapter, preview: previewed, contains: "journal could not be updated")
    }

    func testNamespaceRevalidationThrowAfterPublicationIsExitThree() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("namespace-throw.txt", "payload")
        let live = AutomaticCaptureRuntime.live.renameExclusive
        var published = false
        let context = fixture.context(rename: { sourceFD, source, inboxFD, destination in
            let result = live(sourceFD, source, inboxFD, destination); if result == 0 { published = true }; return result
        }, beforeNamespaceRevalidation: {
            if published { throw AutomaticCaptureError.rejected("Injected namespace revalidation failure.") }
        })
        let adapter = HeadlessCaptureAutomaticAdapter(makeService: { ProductionsInboxCaptureService(automaticCaptureContext: context) })
        let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
        try assertCommittedUncertain(fixture: fixture, adapter: adapter, preview: previewed, contains: "Injected namespace revalidation failure")
    }

    func testInboxNamespaceReplacementDuringRenameIsCommittedUncertain() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("namespace.txt", "payload")
        let displaced = fixture.root.appending(path: "Office/Inbox-displaced", directoryHint: .isDirectory)
        let live = AutomaticCaptureRuntime.live.renameExclusive
        let adapter = fixture.adapter(rename: { sourceFD, source, inboxFD, destination in
            try? FileManager.default.moveItem(at: fixture.inbox, to: displaced)
            try? FileManager.default.createDirectory(at: fixture.inbox, withIntermediateDirectories: false)
            return live(sourceFD, source, inboxFD, destination)
        })
        let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 3)
        XCTAssertEqual(output[0].components(separatedBy: "do not retry automatically").count - 1, 1)
        XCTAssertTrue(output[0].contains("namespace was replaced"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.appending(path: "namespace.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.source.appending(path: "namespace.txt").path))
    }

    func testInTransactionSourceReplacementAndDestinationCollisionRaceAreUncertain() throws {
        do {
            let fixture = try AutomaticFixture(); defer { fixture.remove() }
            try fixture.file("source-race.txt", "same")
            let live = AutomaticCaptureRuntime.live.renameExclusive
            let adapter = fixture.adapter(rename: { sourceFD, source, inboxFD, destination in
                let path = fixture.source.appending(path: source)
                try? FileManager.default.removeItem(at: path)
                try? Data("same".utf8).write(to: path)
                return live(sourceFD, source, inboxFD, destination)
            })
            let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
            var output: [String] = []
            XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 3)
            XCTAssertTrue(output[0].contains("Post-move namespace verification failed"))
        }
        do {
            let fixture = try AutomaticFixture(); defer { fixture.remove() }
            try fixture.file("destination-race.txt", "source")
            let live = AutomaticCaptureRuntime.live.renameExclusive
            let adapter = fixture.adapter(rename: { sourceFD, source, inboxFD, destination in
                try? Data("raced".utf8).write(to: fixture.inbox.appending(path: destination))
                return live(sourceFD, source, inboxFD, destination)
            })
            let observed = try fixture.observe(adapter); fixture.clock.advance(seconds: 2); let previewed = try fixture.preview(observed, adapter: adapter)
            var output: [String] = []
            XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(previewed), adapter: adapter, write: { output.append($0) }), 3)
            XCTAssertTrue(output[0].contains("move outcome is uncertain"))
            XCTAssertEqual(try Data(contentsOf: fixture.source.appending(path: "destination-race.txt")), Data("source".utf8))
            XCTAssertEqual(try Data(contentsOf: fixture.inbox.appending(path: "destination-race.txt")), Data("raced".utf8))
        }
    }

    func testReceiptClaimIsExclusiveUnderConcurrentWritersAndStorageEvictsOldObservations() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("claim.txt", "payload")
        let store = AutomaticCaptureReceiptStore(root: fixture.container.appending(path: "ConcurrentReceipts", directoryHint: .isDirectory), now: { fixture.clock.date }, maximumRecords: 2)
        let service = ProductionsInboxCaptureService(automaticCaptureContext: fixture.context(receipts: store))
        let observation = try service.recordAutomaticObservation(productionsRoot: fixture.root)
        fixture.clock.advance(seconds: 2)
        let preview = try service.previewAutomaticMove(productionsRoot: fixture.root, observation: observation)
        let journal = AutomaticCaptureBatchJournal(receiptID: observation.receiptID, preview: preview, state: .claimed, items: preview.items.map { .init(basename: $0.basename, state: .pending, diagnostic: "pending") }, diagnostic: "claim", updatedAt: "now")
        let results = LockedClaimResults()
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            do { try store.claim(journal); results.record(success: true) }
            catch { results.record(success: false) }
        }
        XCTAssertEqual(results.successes, 1)
        XCTAssertEqual(results.failures, 1)

        let boundedStore = AutomaticCaptureReceiptStore(root: fixture.container.appending(path: "BoundedReceipts", directoryHint: .isDirectory), now: { fixture.clock.date }, maximumRecords: 2)
        let boundedService = ProductionsInboxCaptureService(automaticCaptureContext: fixture.context(receipts: boundedStore))
        _ = try boundedService.recordAutomaticObservation(productionsRoot: fixture.root)
        _ = try boundedService.recordAutomaticObservation(productionsRoot: fixture.root)
        _ = try boundedService.recordAutomaticObservation(productionsRoot: fixture.root)
        let boundedRoot = fixture.container.appending(path: "BoundedReceipts", directoryHint: .isDirectory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: boundedRoot.path).filter { $0.hasSuffix(".observation.json") }.count, 2)
    }

    func testDestinationRaceAndConfiguredSourceChangeRejectWithoutMovingConfirmedSource() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        let source = try fixture.file("race.txt", "source")
        let service = fixture.service()
        let observation = try service.recordAutomaticObservation(productionsRoot: fixture.root)
        fixture.clock.advance(seconds: 2)
        let preview = try service.previewAutomaticMove(productionsRoot: fixture.root, observation: observation)
        try Data("collision".utf8).write(to: fixture.inbox.appending(path: "race.txt"))
        XCTAssertThrowsError(try service.commitAutomaticMove(productionsRoot: fixture.root, confirmedPreview: preview))
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))

        let other = fixture.container.appending(path: "Other", directoryHint: .isDirectory); try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        fixture.configuredSource = other.path
        XCTAssertThrowsError(try service.previewAutomaticMove(productionsRoot: fixture.root, observation: observation))
    }

    func testForgedConfirmedActionAndDestinationCannotClaimOrMove() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        let source = try fixture.file("authority.txt", "payload")
        let service = fixture.service()
        let observation = try service.recordAutomaticObservation(productionsRoot: fixture.root)
        fixture.clock.advance(seconds: 2)
        let preview = try service.previewAutomaticMove(productionsRoot: fixture.root, observation: observation)
        var forgedItems = preview.items
        forgedItems[0] = .init(basename: forgedItems[0].basename, sourcePath: forgedItems[0].sourcePath, destinationPath: fixture.container.appending(path: "forged").path, state: forgedItems[0].state, disposition: .planned, diagnostic: forgedItems[0].diagnostic)
        let forged = AutomaticCaptureMovePreview(schema: preview.schema, actionDiscriminator: "forged-action", observation: preview.observation, productionsRoot: preview.productionsRoot, sourcePath: preview.sourcePath, officePath: preview.officePath, inboxPath: preview.inboxPath, rootState: preview.rootState, sourceState: preview.sourceState, officeState: preview.officeState, inboxState: preview.inboxState, items: forgedItems)
        XCTAssertThrowsError(try service.commitAutomaticMove(productionsRoot: fixture.root, confirmedPreview: forged))
        XCTAssertNil(fixture.receipts.loadClaim(observation.receiptID))
        XCTAssertEqual(try Data(contentsOf: source), Data("payload".utf8))
    }

    func testReceiptStoreRejectsSymlinkAndIsOwnerOnlyAndBounded() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("item.txt", "x")
        let unsafe = fixture.container.appending(path: "UnsafeReceipts", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: unsafe, withDestinationURL: fixture.receiptRoot)
        let store = AutomaticCaptureReceiptStore(root: unsafe)
        let context = fixture.context(receipts: store)
        XCTAssertThrowsError(try ProductionsInboxCaptureService(automaticCaptureContext: context).recordAutomaticObservation(productionsRoot: fixture.root)) {
            XCTAssertTrue($0.localizedDescription.contains("symbolic link"))
        }
        _ = try fixture.service().recordAutomaticObservation(productionsRoot: fixture.root)
        var state = stat(); XCTAssertEqual(lstat(fixture.receiptRoot.path, &state), 0); XCTAssertEqual(state.st_mode & 0o077, 0)
    }

    func testReceiptRootRejectsAncestorSymlink() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("item.txt", "x")
        let realParent = fixture.container.appending(path: "RealReceiptParent", directoryHint: .isDirectory)
        let linkedParent = fixture.container.appending(path: "LinkedReceiptParent", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
        let store = AutomaticCaptureReceiptStore(root: linkedParent.appending(path: "Receipts", directoryHint: .isDirectory))
        XCTAssertThrowsError(try ProductionsInboxCaptureService(automaticCaptureContext: fixture.context(receipts: store)).recordAutomaticObservation(productionsRoot: fixture.root)) {
            XCTAssertTrue($0.localizedDescription.contains("symbolic link"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: realParent.appending(path: "Receipts").path))
    }

    func testReceiptRootFinalReplacementAndEnumerationNamespaceMismatchReject() throws {
        for operation in ["afterRootOpen", "afterEnumeration"] {
            let fixture = try AutomaticFixture(); defer { fixture.remove() }
            try fixture.file("item.txt", "x")
            _ = try fixture.service().recordAutomaticObservation(productionsRoot: fixture.root)
            let displaced = fixture.container.appending(path: "Receipts-\(operation)-displaced", directoryHint: .isDirectory)
            var raced = false
            let store = AutomaticCaptureReceiptStore(root: fixture.receiptRoot, now: { fixture.clock.date }, failOperation: { label in
                guard label == operation, !raced else { return false }
                raced = true
                try? FileManager.default.moveItem(at: fixture.receiptRoot, to: displaced)
                try? FileManager.default.createDirectory(at: fixture.receiptRoot, withIntermediateDirectories: false)
                return false
            })
            XCTAssertThrowsError(try ProductionsInboxCaptureService(automaticCaptureContext: fixture.context(receipts: store)).recordAutomaticObservation(productionsRoot: fixture.root))
            XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: fixture.receiptRoot.path).filter { $0.hasSuffix(".observation.json") }.count) ?? 0, 0)
        }
    }

    func testConcurrentReceiptCapacityAndOrphanTemporaryCleanup() throws {
        let fixture = try AutomaticFixture(); defer { fixture.remove() }
        try fixture.file("item.txt", "x")
        let capacityRoot = fixture.container.appending(path: "ConcurrentCapacity", directoryHint: .isDirectory)
        let store = AutomaticCaptureReceiptStore(root: capacityRoot, now: { fixture.clock.date }, maximumRecords: 2)
        let service = ProductionsInboxCaptureService(automaticCaptureContext: fixture.context(receipts: store))
        let concurrent = ConcurrentObservationBox(service: service, root: fixture.root)
        DispatchQueue.concurrentPerform(iterations: 20) { _ in concurrent.record() }
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: capacityRoot.path).filter { $0.hasSuffix(".observation.json") }.count, 2)

        let orphan = capacityRoot.appending(path: ".abandoned.tmp")
        try Data("orphan".utf8).write(to: orphan, options: .withoutOverwriting)
        _ = try service.recordAutomaticObservation(productionsRoot: fixture.root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertLessThanOrEqual(try FileManager.default.contentsOfDirectory(atPath: capacityRoot.path).filter { $0.hasSuffix(".observation.json") }.count, 2)
    }

    private func assertCommittedUncertain(fixture: AutomaticFixture, adapter: HeadlessCaptureAutomaticAdapter, preview: PreviewCLI, contains diagnostic: String) throws {
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: fixture.executeArguments(preview), adapter: adapter, write: { output.append($0) }), 3)
        let text = try XCTUnwrap(output.first)
        XCTAssertTrue(text.contains(diagnostic), text)
        XCTAssertEqual(text.components(separatedBy: "do not retry automatically").count - 1, 1)
        XCTAssertTrue(text.contains("uncertain"), text)
    }

    @MainActor func testLiteralUsageMalformedOwnershipAndNoArgumentGUIRouting() {
        XCTAssertEqual(AutomaticCaptureContext.preferencesSuiteName, "com.kahntra.operations-dashboard")
        XCTAssertEqual(ProductionsAutomaticCaptureMonitor.sourceKey, AutomaticCaptureContext.preferencesSourceKey)
        XCTAssertNil(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: ["OperationsDashboard"]))
        var output: [String] = []
        XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: ["OperationsDashboard", "capture", "automatic"], write: { output.append($0) }), 2)
        XCTAssertEqual(output, [HeadlessCaptureAutomaticCommandLine.usage])
    }
}

private final class AutomaticClock {
    var date = Date(timeIntervalSince1970: 1_700_000_000)
    var nanoseconds: UInt64 = 10_000_000_000
    var boot = "stable-boot"
    func advance(seconds: UInt64) { nanoseconds += seconds * 1_000_000_000; date.addTimeInterval(TimeInterval(seconds)) }
}

private final class LockedClaimResults: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Bool] = []
    func record(success: Bool) { lock.lock(); values.append(success); lock.unlock() }
    var successes: Int { lock.lock(); defer { lock.unlock() }; return values.filter { $0 }.count }
    var failures: Int { lock.lock(); defer { lock.unlock() }; return values.filter { !$0 }.count }
}

private final class ConcurrentObservationBox: @unchecked Sendable {
    let service: ProductionsInboxCaptureService
    let root: URL
    init(service: ProductionsInboxCaptureService, root: URL) { self.service = service; self.root = root }
    func record() { _ = try? service.recordAutomaticObservation(productionsRoot: root) }
}

private final class AutomaticFixture {
    let container: URL
    let root: URL
    let source: URL
    let inbox: URL
    let receiptRoot: URL
    let clock = AutomaticClock()
    let receipts: AutomaticCaptureReceiptStore
    var configuredSource: String

    init() throws {
        let requestedContainer = FileManager.default.temporaryDirectory.appending(path: "Phase3E-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: requestedContainer, withIntermediateDirectories: true)
        guard let canonicalPointer = realpath(requestedContainer.path, nil) else { throw CocoaError(.fileNoSuchFile) }
        container = URL(fileURLWithPath: String(cString: canonicalPointer), isDirectory: true)
        free(canonicalPointer)
        root = container.appending(path: "Productions", directoryHint: .isDirectory)
        source = container.appending(path: "ConfiguredSource", directoryHint: .isDirectory)
        inbox = root.appending(path: "Office/Inbox", directoryHint: .isDirectory)
        receiptRoot = container.appending(path: "Receipts", directoryHint: .isDirectory)
        configuredSource = source.path
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "Warehouse/Reference", directoryHint: .isDirectory), withIntermediateDirectories: true)
        try Data("flow".utf8).write(to: root.appending(path: "Office/Flow.md"))
        try Data("ledger".utf8).write(to: root.appending(path: "Warehouse/Reference/Identifier Ledger.md"))
        receipts = AutomaticCaptureReceiptStore(root: receiptRoot, now: { [clock] in clock.date })
    }

    var observeArguments: [String] { ["OperationsDashboard", "capture", "automatic", "observe", "--productions-root", root.path] }
    func previewArguments(_ value: ObservationCLI) -> [String] { ["OperationsDashboard", "capture", "automatic", "preview", "--productions-root", root.path, "--observation", value.envelope, "--observe-token", value.token] }
    func executeArguments(_ value: PreviewCLI) -> [String] { ["OperationsDashboard", "capture", "automatic", "execute", "--productions-root", root.path, "--confirmed-preview", value.envelope, "--confirm", value.token] }

    func context(source: URL? = nil, receipts: AutomaticCaptureReceiptStore? = nil, sameFileSystem: Bool = true, rename: ((Int32, String, Int32, String) -> Int32)? = nil, beforeEntryInspection: @escaping (String) throws -> Void = { _ in }, beforeNamespaceRevalidation: @escaping () throws -> Void = {}) -> AutomaticCaptureContext {
        let runtime = AutomaticCaptureRuntime(now: { [clock] in clock.date }, continuousNanoseconds: { [clock] in clock.nanoseconds }, bootSessionID: { [clock] in clock.boot }, sameFileSystem: { _, _ in sameFileSystem }, renameExclusive: rename ?? AutomaticCaptureRuntime.live.renameExclusive, beforeEntryInspection: beforeEntryInspection, beforeNamespaceRevalidation: beforeNamespaceRevalidation)
        return .init(configuredSource: { [weak self] in source?.path ?? self?.configuredSource }, receipts: receipts ?? self.receipts, runtime: runtime, manager: .default)
    }
    func service(source: URL? = nil, sameFileSystem: Bool = true, rename: ((Int32, String, Int32, String) -> Int32)? = nil, beforeEntryInspection: @escaping (String) throws -> Void = { _ in }, beforeNamespaceRevalidation: @escaping () throws -> Void = {}) -> ProductionsInboxCaptureService { .init(automaticCaptureContext: context(source: source, sameFileSystem: sameFileSystem, rename: rename, beforeEntryInspection: beforeEntryInspection, beforeNamespaceRevalidation: beforeNamespaceRevalidation)) }
    func adapter(rename: ((Int32, String, Int32, String) -> Int32)? = nil) -> HeadlessCaptureAutomaticAdapter { HeadlessCaptureAutomaticAdapter(makeService: { [self] in service(rename: rename) }) }
    @discardableResult func file(_ name: String, _ contents: String) throws -> URL { let url = source.appending(path: name); try Data(contents.utf8).write(to: url); return url }
    func directory(_ name: String, child: String) throws { let url = source.appending(path: name, directoryHint: .isDirectory); let childURL = url.appending(path: child); try FileManager.default.createDirectory(at: childURL.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("child".utf8).write(to: childURL) }
    func contractSnapshot() throws -> [Data] { [try Data(contentsOf: root.appending(path: "Office/Flow.md")), try Data(contentsOf: root.appending(path: "Warehouse/Reference/Identifier Ledger.md"))] }
    func remove() { try? FileManager.default.removeItem(at: container) }

    func observe(_ adapter: HeadlessCaptureAutomaticAdapter) throws -> ObservationCLI { var output: [String] = []; XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: observeArguments, adapter: adapter, write: { output.append($0) }), 0); return try observationOutput(output) }
    func preview(_ observation: ObservationCLI, adapter: HeadlessCaptureAutomaticAdapter) throws -> PreviewCLI { var output: [String] = []; XCTAssertEqual(HeadlessCaptureAutomaticCommandLine.runIfRequested(arguments: previewArguments(observation), adapter: adapter, write: { output.append($0) }), 0); return try previewOutput(output) }
    func observationOutput(_ output: [String]) throws -> ObservationCLI {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output.first).utf8)) as? [String: Any])
        let observationData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["observation"]))
        return .init(observation: try JSONDecoder().decode(AutomaticCaptureObservation.self, from: observationData), envelope: try XCTUnwrap(object["observationEnvelope"] as? String), token: try XCTUnwrap(object["observationToken"] as? String))
    }
    func previewOutput(_ output: [String]) throws -> PreviewCLI {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output.first).utf8)) as? [String: Any])
        let previewData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["preview"]))
        return .init(preview: try JSONDecoder().decode(AutomaticCaptureMovePreview.self, from: previewData), envelope: try XCTUnwrap(object["confirmedPreview"] as? String), token: try XCTUnwrap(object["confirmationToken"] as? String))
    }
}

private struct ObservationCLI { let observation: AutomaticCaptureObservation; let envelope: String; let token: String }
private struct PreviewCLI { let preview: AutomaticCaptureMovePreview; let envelope: String; let token: String }
