import CryptoKit
import Foundation
import XCTest
@testable import OperationsDashboard

final class ManagerRoutingLifecycleTests: XCTestCase {
    private let parentID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let childID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private let laterParentID = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
    private let laterChildID = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
    private let thirdParentID = UUID(uuidString: "10000000-0000-4000-8000-000000000005")!
    private let managerThread = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let targetThread = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    private let nextThread = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    private let baseDate = Date(timeIntervalSince1970: 1_788_137_200)

    func testStableRouteAcknowledgementRunningAndExactlyOneTerminalHandoff() throws {
        let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { fixture.remove() }
        let service = fixture.service()
        let created = try service.create(request())
        XCTAssertEqual(created.operationUUID, parentID)
        XCTAssertEqual(created.state, .queued)
        XCTAssertEqual(created.waitingFor, .manager)

        XCTAssertEqual(try service.acknowledge(operationID: parentID, targetThreadID: targetThread).state, .deliveredAcknowledged)
        XCTAssertEqual(try service.markRunning(operationID: parentID, targetThreadID: targetThread).state, .running)
        let handoff = completedHandoff()
        let terminal = try service.receiveTerminal(operationID: parentID, targetThreadID: targetThread, handoff: handoff)
        XCTAssertEqual(terminal.state, .forwarded)
        XCTAssertEqual(terminal.classification, "terminal-forwarded")
        XCTAssertTrue(try service.status().isEmpty)

        let ledgerBeforeDuplicate = try Data(contentsOf: fixture.ledgerURL)
        let duplicate = try service.receiveTerminal(operationID: parentID, targetThreadID: targetThread, handoff: handoff)
        XCTAssertEqual(duplicate.ledgerSHA256, terminal.ledgerSHA256)
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), ledgerBeforeDuplicate, "An exact duplicate is read-only and does not rewrite the ledger.")
        XCTAssertThrowsError(try service.receiveTerminal(
            operationID: parentID, targetThreadID: targetThread,
            handoff: .init(classification: .completed, summary: "Different", evidence: ["Evidence"], nextGate: "Gate", unperformedBoundaries: ["None"])
        )) { XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("different terminal") == true) }
    }

    func testDestinationMustAcknowledgeBeforeTerminalAndByteDifferentDuplicateIsRejected() throws {
        let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { fixture.remove() }
        let service = fixture.service()
        _ = try service.create(request())
        XCTAssertThrowsError(try service.receiveTerminal(
            operationID: parentID, targetThreadID: targetThread, handoff: completedHandoff()
        ))
        _ = try service.acknowledge(operationID: parentID, targetThreadID: targetThread)
        let first = ManagerTerminalHandoff(
            classification: .completed, summary: "Caf\u{00E9} complete.", evidence: ["Evidence"],
            nextGate: "Gate", unperformedBoundaries: ["Boundary"]
        )
        _ = try service.receiveTerminal(operationID: parentID, targetThreadID: targetThread, handoff: first)
        let canonicalAlias = ManagerTerminalHandoff(
            classification: .completed, summary: "Cafe\u{0301} complete.", evidence: ["Evidence"],
            nextGate: "Gate", unperformedBoundaries: ["Boundary"]
        )
        XCTAssertThrowsError(try service.receiveTerminal(
            operationID: parentID, targetThreadID: targetThread, handoff: canonicalAlias
        )) { XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("different terminal") == true) }
    }

    func testStateVocabularyIsExactAndComplete() {
        XCTAssertEqual(Set(ManagerRouteState.allCases.map(\.rawValue)), Set([
            "queued", "delivered/acknowledged", "running", "terminal-completed", "terminal-blocked",
            "terminal-uncertain", "forwarded", "owner-decision-required",
        ]))
    }

    func testAlreadyAuthorizedCompletionAtomicallyQueuesNextGate() throws {
        let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { fixture.remove() }
        let service = fixture.service()
        _ = try service.create(request(next: true))
        _ = try service.acknowledge(operationID: parentID, targetThreadID: targetThread)
        let result = try service.receiveTerminal(operationID: parentID, targetThreadID: targetThread, handoff: completedHandoff())
        XCTAssertEqual(result.state, .forwarded)
        XCTAssertEqual(result.nextRouteOperationUUID, childID)
        let status = try service.status()
        XCTAssertEqual(status.map(\.operationUUID), [childID])
        XCTAssertEqual(status.first?.state, .queued)
        XCTAssertEqual(status.first?.waitingFor, .manager)
        XCTAssertEqual(try service.inspect(operationID: childID).state, .queued)
        XCTAssertNoThrow(try service.assertMayIdle())
    }

    func testParentAndPreauthorizedChildUUIDsMustBeDistinctBeforeStorage() throws {
        let duplicate = try RoutingFixture(ids: [parentID, parentID], now: baseDate)
        defer { duplicate.remove() }
        XCTAssertThrowsError(try duplicate.service().create(request(next: true))) {
            XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("must be distinct") == true)
        }
        XCTAssertEqual(duplicate.ids.callCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.ledgerURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: duplicate.initializationMarkerURL.path))

        let distinct = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { distinct.remove() }
        _ = try distinct.service().create(request(next: true))
        _ = try distinct.service().acknowledge(operationID: parentID, targetThreadID: targetThread)
        let terminal = try distinct.service().receiveTerminal(
            operationID: parentID, targetThreadID: targetThread, handoff: completedHandoff()
        )
        XCTAssertEqual(terminal.nextRouteOperationUUID, childID)
        XCTAssertEqual(try distinct.service().inspection(operationID: parentID).route.terminalHandoff, completedHandoff())
        XCTAssertEqual(try distinct.service().inspect(operationID: childID).state, .queued)

        let corrupt = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { corrupt.remove() }
        _ = try corrupt.service().create(request(next: true))
        try rewriteRoutingLedger(corrupt.ledgerURL) { route in
            var next = route["nextAuthorizedRoute"] as! [String: Any]
            next["operationUUID"] = self.parentID.uuidString
            route["nextAuthorizedRoute"] = next
        }
        XCTAssertThrowsError(try corrupt.store.snapshot()) {
            guard case .storageCorrupt = $0 as? ManagerRoutingError else {
                return XCTFail("Expected equal parent/child UUID envelope corruption, got \($0)")
            }
        }
    }

    func testGlobalChildReservationRejectsLaterClaimsAndOriginalTerminalPersists() throws {
        let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { fixture.remove() }
        _ = try fixture.service().create(request(next: true))
        let originalBytes = try Data(contentsOf: fixture.ledgerURL)
        let currentDate = baseDate

        let laterParentClaimsReservation = RoutingIDSource([childID])
        let parentClaimService = ManagerRoutingService(
            store: fixture.store, now: { currentDate }, makeOperationID: { laterParentClaimsReservation.next() }
        )
        XCTAssertThrowsError(try parentClaimService.create(request())) { assertReservationCollision($0) }
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), originalBytes)

        let laterReservationClaimsRoute = RoutingIDSource([laterParentID, parentID])
        let routeClaimService = ManagerRoutingService(
            store: fixture.store, now: { currentDate }, makeOperationID: { laterReservationClaimsRoute.next() }
        )
        XCTAssertThrowsError(try routeClaimService.create(request(next: true))) { assertReservationCollision($0) }
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), originalBytes)

        let duplicateReservation = RoutingIDSource([thirdParentID, childID])
        let duplicateService = ManagerRoutingService(
            store: fixture.store, now: { currentDate }, makeOperationID: { duplicateReservation.next() }
        )
        XCTAssertThrowsError(try duplicateService.create(request(next: true))) { assertReservationCollision($0) }
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), originalBytes)

        _ = try fixture.service().acknowledge(operationID: parentID, targetThreadID: targetThread)
        let terminal = try fixture.service().receiveTerminal(
            operationID: parentID, targetThreadID: targetThread, handoff: completedHandoff()
        )
        XCTAssertEqual(terminal.nextRouteOperationUUID, childID)
        XCTAssertEqual(try fixture.service().inspection(operationID: parentID).route.terminalHandoff, completedHandoff())
        XCTAssertEqual(try fixture.service().inspect(operationID: childID).state, .queued)
    }

    func testDurableReloadRejectsRouteReservationAndDuplicateReservationCollisions() throws {
        do {
            let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
            defer { fixture.remove() }
            _ = try fixture.service().create(request(next: true))
            try rewriteRoutingRoutes(fixture.ledgerURL) { routes in
                var claimant = routes[0]
                claimant["operationUUID"] = self.childID.uuidString
                claimant["nextAuthorizedRoute"] = NSNull()
                routes.append(claimant)
            }
            XCTAssertThrowsError(try fixture.store.snapshot()) { assertDurableReservationCorruption($0) }
        }

        do {
            let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
            defer { fixture.remove() }
            _ = try fixture.service().create(request())
            let ids = RoutingIDSource([laterParentID, laterChildID])
            let currentDate = baseDate
            _ = try ManagerRoutingService(
                store: fixture.store, now: { currentDate }, makeOperationID: { ids.next() }
            ).create(request(next: true))
            try rewriteRoutingRoutes(fixture.ledgerURL) { routes in
                var next = routes[1]["nextAuthorizedRoute"] as! [String: Any]
                next["operationUUID"] = self.parentID.uuidString
                routes[1]["nextAuthorizedRoute"] = next
            }
            XCTAssertThrowsError(try fixture.store.snapshot()) { assertDurableReservationCorruption($0) }
        }

        do {
            let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
            defer { fixture.remove() }
            _ = try fixture.service().create(request(next: true))
            let ids = RoutingIDSource([laterParentID, laterChildID])
            let currentDate = baseDate
            _ = try ManagerRoutingService(
                store: fixture.store, now: { currentDate }, makeOperationID: { ids.next() }
            ).create(request(next: true))
            try rewriteRoutingRoutes(fixture.ledgerURL) { routes in
                var next = routes[1]["nextAuthorizedRoute"] as! [String: Any]
                next["operationUUID"] = self.childID.uuidString
                routes[1]["nextAuthorizedRoute"] = next
            }
            XCTAssertThrowsError(try fixture.store.snapshot()) { assertDurableReservationCorruption($0) }
        }
    }

    func testUnparsableNextTimeoutCLIRejectsBeforeUUIDOrStorage() throws {
        for invalid in ["not-a-time", "2026-08-31T01:20:00.500Z"] {
            let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
            defer { fixture.remove() }
            var output: [String] = []
            let exit = HeadlessManagerRoutingCommandLine.runIfRequested(
                arguments: [
                    "OperationsDashboard", "manager", "route", "create", "--task", "TASK-0076",
                    "--manager-thread", managerThread, "--target-thread", targetThread,
                    "--action", "Perform bounded work.", "--authority", "Owner authorization.",
                    "--timeout-at", "2026-08-31T01:00:00Z", "--next-timeout-at", invalid,
                ], service: fixture.service(), write: { output.append($0) }
            )
            XCTAssertEqual(exit, 2)
            XCTAssertEqual(fixture.ids.callCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.initializationMarkerURL.path))
            XCTAssertTrue(output.last?.contains("not-committed") == true)
        }
    }

    func testServiceRejectsFractionalDeadlinesBeforeUUIDAndWholeSecondsRoundTrip() throws {
        let fractionalDeadline = baseDate.addingTimeInterval(60.5)
        for current in [
            fractionalDeadline.addingTimeInterval(-0.1),
            fractionalDeadline,
            fractionalDeadline.addingTimeInterval(0.1),
        ] {
            let fixture = try RoutingFixture(ids: [parentID], now: current)
            defer { fixture.remove() }
            XCTAssertThrowsError(try fixture.service().create(request(timeout: fractionalDeadline))) {
                XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("whole-second precision") == true)
            }
            XCTAssertEqual(fixture.ids.callCount, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.ledgerURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.initializationMarkerURL.path))
        }

        let fractionalChild = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { fractionalChild.remove() }
        let nextFractionRequest = ManagerRouteCreateRequest(
            taskID: "TASK-0076", managerThreadID: managerThread, targetThreadID: targetThread,
            action: "Perform the bounded routing lifecycle phase.", authorityReference: "Owner authorization TASK-0076.",
            timeoutAt: baseDate.addingTimeInterval(600),
            nextTargetThreadID: nextThread, nextAction: "Perform the already-authorized next gate.",
            nextAuthorityReference: "Existing owner authorization.",
            nextTimeoutAt: baseDate.addingTimeInterval(1_200.5)
        )
        XCTAssertThrowsError(try fractionalChild.service().create(nextFractionRequest)) {
            XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("whole-second precision") == true)
        }
        XCTAssertEqual(fractionalChild.ids.callCount, 0)

        let exact = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { exact.remove() }
        let exactDeadline = baseDate.addingTimeInterval(60)
        _ = try exact.service().create(request(timeout: exactDeadline))
        let restarted = ManagerRoutingService(
            store: ApplicationSupportManagerRoutingLedgerStore(directory: exact.directory),
            now: { exactDeadline }, makeOperationID: { UUID() }
        )
        XCTAssertEqual(try restarted.inspection(operationID: parentID).route.timeoutAt, exactDeadline)
    }

    func testSilentCompletionAndEmptyFinalOutputUseReadOnlyFirstNoRetryReconciliation() throws {
        for observation in [ManagerRouteObservation.silentCompletion, .emptyFinalOutput] {
            let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
            defer { fixture.remove() }
            let service = fixture.service()
            _ = try service.create(request())
            let before = try Data(contentsOf: fixture.ledgerURL)
            let plan = try service.reconciliationPreview(operationID: parentID, observation: observation)
            XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), before, "Preview must be read-only.")
            XCTAssertEqual(plan.proposedTerminalState, .terminalUncertain)
            let result = try service.applyReconciliation(plan, confirmationToken: plan.confirmationToken)
            XCTAssertEqual(result.state, .ownerDecisionRequired)
            XCTAssertTrue(result.noRetry)
            XCTAssertEqual(try service.status().first?.waitingFor, .owner)
        }
    }

    func testTargetInterruptionBecomesOneDurableOwnerFacingBlocker() throws {
        let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { fixture.remove() }
        let service = fixture.service()
        _ = try service.create(request())
        _ = try service.acknowledge(operationID: parentID, targetThreadID: targetThread)
        let plan = try service.reconciliationPreview(operationID: parentID, observation: .targetInterrupted)
        XCTAssertEqual(plan.proposedTerminalState, .terminalBlocked)
        let result = try service.applyReconciliation(plan, confirmationToken: plan.confirmationToken)
        XCTAssertEqual(result.outcome, "owner-decision-required")
        XCTAssertEqual(result.waitingFor, .owner)
        XCTAssertTrue(result.noRetry)
    }

    func testManagerRestartReloadsAwaitingQueueAndPreIdleInvariant() throws {
        let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { fixture.remove() }
        _ = try fixture.service().create(request())
        let restartedDate = baseDate.addingTimeInterval(30)
        let restarted = ManagerRoutingService(
            store: ApplicationSupportManagerRoutingLedgerStore(directory: fixture.directory),
            now: { restartedDate }, makeOperationID: { UUID() }
        )
        let status = try restarted.status()
        XCTAssertEqual(status.count, 1)
        XCTAssertEqual(status[0].ageSeconds, 30)
        XCTAssertEqual(status[0].unresolvedAgeSeconds, 30)
        XCTAssertEqual(status[0].waitingFor, .manager)
        XCTAssertNoThrow(try restarted.assertMayIdle())

        let decoded = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.ledgerURL)) as! [String: Any]
        var corrupted = decoded
        var routes = corrupted["routes"] as! [[String: Any]]
        routes[0]["monitor"] = NSNull()
        corrupted["routes"] = routes
        let data = try JSONSerialization.data(withJSONObject: corrupted)
        let ledger = try routingDecoder().decode(ManagerRoutingLedger.self, from: data)
        let fake = SnapshotRoutingStore(snapshotValue: .init(ledger: ledger, sha256: digest(data)))
        XCTAssertThrowsError(try ManagerRoutingService(store: fake).assertMayIdle()) {
            XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("no live monitor") == true)
        }
    }

    func testInitializedProductionStoreNeverTreatsDeletedOrUnavailableStorageAsEmpty() throws {
        do {
            let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
            defer { fixture.remove() }
            XCTAssertEqual(try fixture.service().status(), [], "A genuinely never-initialized store may be empty.")
            _ = try fixture.service().create(request())
            try FileManager.default.removeItem(at: fixture.ledgerURL)
            let restarted = fixture.service()
            XCTAssertThrowsError(try restarted.status()) { assertStorageUncertain($0) }
            XCTAssertThrowsError(try restarted.assertMayIdle()) { assertStorageUncertain($0) }
        }

        do {
            let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
            defer { fixture.remove() }
            _ = try fixture.service().create(request())
            try FileManager.default.removeItem(at: fixture.directory)
            let currentDate = baseDate
            let restarted = ManagerRoutingService(
                store: ApplicationSupportManagerRoutingLedgerStore(directory: fixture.directory),
                now: { currentDate }, makeOperationID: { UUID() }
            )
            XCTAssertThrowsError(try restarted.status()) { assertStorageUncertain($0) }
        }

        do {
            let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
            defer { fixture.remove() }
            _ = try fixture.service().create(request())
            try FileManager.default.removeItem(at: fixture.directory)
            try Data("not-a-directory".utf8).write(to: fixture.directory)
            let currentDate = baseDate
            let restarted = ManagerRoutingService(
                store: ApplicationSupportManagerRoutingLedgerStore(directory: fixture.directory),
                now: { currentDate }, makeOperationID: { UUID() }
            )
            XCTAssertThrowsError(try restarted.assertMayIdle()) { assertStorageUncertain($0) }
        }
    }

    func testLateTerminalReceiptPersistsAndExpiredNextDeadlineRequiresDecision() throws {
        for offset in [1_199.0, 1_200.0, 1_201.0] {
            let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
            defer { fixture.remove() }
            _ = try fixture.service().create(request(next: true))
            _ = try fixture.service().acknowledge(operationID: parentID, targetThreadID: targetThread)
            fixture.clock.value = baseDate.addingTimeInterval(offset)

            let result = try fixture.service().receiveTerminal(
                operationID: parentID, targetThreadID: targetThread, handoff: completedHandoff()
            )
            let parent = try fixture.service().inspection(operationID: parentID).route
            XCTAssertEqual(parent.terminalHandoff, completedHandoff(), "The valid late receipt must always become durable.")
            if offset < 1_200 {
                XCTAssertEqual(result.state, .forwarded)
                XCTAssertEqual(result.nextRouteOperationUUID, childID)
                XCTAssertEqual(try fixture.service().inspect(operationID: childID).state, .queued)
            } else {
                XCTAssertEqual(result.state, .ownerDecisionRequired)
                XCTAssertEqual(result.waitingFor, .owner)
                XCTAssertNil(result.nextRouteOperationUUID)
                XCTAssertTrue(result.noRetry)
                XCTAssertThrowsError(try fixture.service().inspect(operationID: childID))
                XCTAssertEqual(try fixture.service().status().map(\.operationUUID), [parentID])
            }
        }
    }

    func testTimeoutReconciliationDeadlineBeforeEqualAfterForEveryActiveState() throws {
        for activeState in [ManagerRouteState.queued, .deliveredAcknowledged, .running] {
            for offset in [59.0, 60.0, 61.0] {
                let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
                defer { fixture.remove() }
                _ = try fixture.service().create(request(timeout: baseDate.addingTimeInterval(60)))
                if activeState != .queued {
                    _ = try fixture.service().acknowledge(operationID: parentID, targetThreadID: targetThread)
                }
                if activeState == .running {
                    _ = try fixture.service().markRunning(operationID: parentID, targetThreadID: targetThread)
                }
                fixture.clock.value = baseDate.addingTimeInterval(offset)
                if offset < 60 {
                    XCTAssertThrowsError(try fixture.service().reconciliationPreview(operationID: parentID, observation: .timeout)) {
                        XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("before the exact route deadline") == true)
                    }
                    XCTAssertEqual(try fixture.service().inspect(operationID: parentID).state, activeState)
                } else {
                    let plan = try fixture.service().reconciliationPreview(operationID: parentID, observation: .timeout)
                    let result = try fixture.service().applyReconciliation(plan, confirmationToken: plan.confirmationToken)
                    XCTAssertEqual(result.state, .ownerDecisionRequired)
                    XCTAssertTrue(result.noRetry)
                }
            }
        }
    }

    func testTimeoutApplyRechecksDeadlineInsideHashBoundTransaction() throws {
        let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { fixture.remove() }
        _ = try fixture.service().create(request(timeout: baseDate.addingTimeInterval(60)))
        fixture.clock.value = baseDate.addingTimeInterval(60)
        let plan = try fixture.service().reconciliationPreview(operationID: parentID, observation: .timeout)
        let sequenced = SequencedRoutingClock([
            baseDate.addingTimeInterval(60),
            baseDate.addingTimeInterval(59),
        ])
        let applying = ManagerRoutingService(
            store: fixture.store, now: { sequenced.next() }, makeOperationID: { UUID() }
        )
        let before = try Data(contentsOf: fixture.ledgerURL)
        XCTAssertThrowsError(try applying.applyReconciliation(plan, confirmationToken: plan.confirmationToken)) {
            XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("before the exact route deadline") == true)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), before)
    }

    func testMonitorWakeAndReceiptRunningTimestampsAreExactlyStateBound() throws {
        let mutations: [(ManagerRouteState, (inout [String: Any]) -> Void)] = [
            (.queued, { route in
                var monitor = route["monitor"] as! [String: Any]
                monitor["wakeAt"] = "2030-01-01T00:00:00Z"
                route["monitor"] = monitor
            }),
            (.deliveredAcknowledged, { route in route["receiptAcknowledgedAt"] = "2030-01-01T00:00:00Z" }),
            (.running, { route in route["runningAt"] = "2030-01-01T00:00:00Z" }),
        ]
        for (state, mutation) in mutations {
            let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
            defer { fixture.remove() }
            _ = try fixture.service().create(request())
            if state != .queued { _ = try fixture.service().acknowledge(operationID: parentID, targetThreadID: targetThread) }
            if state == .running { _ = try fixture.service().markRunning(operationID: parentID, targetThreadID: targetThread) }
            try rewriteRoutingLedger(fixture.ledgerURL, mutation: mutation)
            XCTAssertThrowsError(try fixture.store.snapshot()) {
                guard case .storageCorrupt = $0 as? ManagerRoutingError else {
                    return XCTFail("Expected durable storage corruption, got \($0)")
                }
            }
        }
    }

    func testStorageUncertainCreatePreservesGeneratedUUIDAndInspectionGuidance() throws {
        for failure in InitialPublicationFailure.allCases {
            let directory = URL(
                fileURLWithPath: "/private/tmp/ManagerRoutingCreateFailure-\(UUID().uuidString)",
                isDirectory: true
            )
            let marker = directory.deletingLastPathComponent().appending(path: "\(directory.lastPathComponent).initialized")
            defer {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.removeItem(at: marker)
            }
            let store = ApplicationSupportManagerRoutingLedgerStore(
                directory: directory,
                afterInitialLedgerPublication: { ledgerURL in
                    switch failure {
                    case .writeThenThrow: throw SyntheticRoutingFailure.afterWrite
                    case .reloadMismatch: try Data("reload-mismatch".utf8).write(to: ledgerURL)
                    }
                }
            )
            let ids = RoutingIDSource([parentID])
            let currentDate = baseDate
            let service = ManagerRoutingService(store: store, now: { currentDate }, makeOperationID: { ids.next() })
            var output: [String] = []
            let exit = HeadlessManagerRoutingCommandLine.runIfRequested(
                arguments: [
                    "OperationsDashboard", "manager", "route", "create", "--task", "TASK-0076",
                    "--manager-thread", managerThread, "--target-thread", targetThread,
                    "--action", "Perform bounded work.", "--authority", "Owner authorization.",
                    "--timeout-at", "2026-08-31T01:00:00Z",
                ], service: service, write: { output.append($0) }
            )
            XCTAssertEqual(exit, 3)
            XCTAssertTrue(output.last?.contains(parentID.uuidString) == true)
            XCTAssertTrue(output.last?.contains("manager routing inspect --operation \(parentID.uuidString)") == true)
            XCTAssertTrue(output.last?.contains("\"noRetry\":true") == true)
            let inspectionStore = ApplicationSupportManagerRoutingLedgerStore(directory: directory)
            switch failure {
            case .writeThenThrow:
                XCTAssertEqual(
                    try ManagerRoutingService(store: inspectionStore).inspection(operationID: parentID).route.operationUUID,
                    parentID,
                    "The reported uncertain UUID must identify the bytes published before the throw."
                )
            case .reloadMismatch:
                XCTAssertThrowsError(try inspectionStore.snapshot()) {
                    guard case .storageCorrupt = $0 as? ManagerRoutingError else {
                        return XCTFail("Expected the failed reload bytes to remain inspectably corrupt, got \($0)")
                    }
                }
            }
        }
    }

    func testTimeoutAgeAndEscalationRemainMonitoredAndDoNotRetryAction() throws {
        let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { fixture.remove() }
        _ = try fixture.service().create(request(timeout: baseDate.addingTimeInterval(60)))
        fixture.clock.value = baseDate.addingTimeInterval(120)
        let item = try XCTUnwrap(fixture.service().status().first)
        XCTAssertTrue(item.overdue)
        XCTAssertEqual(item.ageSeconds, 120)
        XCTAssertThrowsError(try fixture.service().assertMayIdle()) {
            XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("scheduled wake") == true)
        }
        let plan = try fixture.service().reconciliationPreview(operationID: parentID, observation: .timeout)
        let result = try fixture.service().applyReconciliation(plan, confirmationToken: plan.confirmationToken)
        XCTAssertEqual(result.state, .ownerDecisionRequired)
        XCTAssertTrue(result.noRetry)
        XCTAssertNoThrow(try fixture.service().assertMayIdle())
    }

    func testStaleWriterCASAndImmutableHistoryNeverOverwriteNewerLedger() throws {
        let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { fixture.remove() }
        let stale = try fixture.store.snapshot()
        _ = try fixture.service().create(request())
        let current = try Data(contentsOf: fixture.ledgerURL)
        XCTAssertThrowsError(try fixture.store.transact(expectedSHA256: stale.sha256) { _ in }) {
            XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("changed") == true)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), current)
    }

    func testNoncooperatingWriterDuringLockedTransactionIsDetectedWithoutOverwrite() throws {
        let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { fixture.remove() }
        _ = try fixture.service().create(request())
        let foreign = Data("foreign-stale-writer-bytes".utf8)
        XCTAssertThrowsError(try fixture.store.transact(expectedSHA256: nil) { ledger in
            try foreign.write(to: fixture.ledgerURL)
            ledger.routes.append(.init(
                operationUUID: self.childID, taskID: "TASK-0076",
                managerThreadID: self.managerThread, targetThreadID: self.nextThread,
                action: "Should not publish.", authorityReference: "Synthetic concurrency probe.",
                createdAt: self.baseDate, timeoutAt: self.baseDate.addingTimeInterval(1_200), nextAuthorizedRoute: nil
            ))
        }) { XCTAssertTrue(($0 as? ManagerRoutingError)?.localizedDescription.contains("changed during") == true) }
        XCTAssertEqual(try Data(contentsOf: fixture.ledgerURL), foreign)
    }

    func testHeadlessProductionAdapterRequiresStructuredTerminalAndReturnsCompactStatus() throws {
        let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { fixture.remove() }
        let service = fixture.service()
        var output: [String] = []
        let create = [
            "OperationsDashboard", "manager", "route", "create", "--task", "TASK-0076",
            "--manager-thread", managerThread, "--target-thread", targetThread,
            "--action", "Perform bounded work.", "--authority", "Owner authorization.",
            "--timeout-at", "2026-08-31T01:00:00Z",
        ]
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(arguments: create, service: service, write: { output.append($0) }), 0)
        XCTAssertTrue(output.last?.contains(parentID.uuidString) == true)
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: ["OperationsDashboard", "manager", "route", "terminal", "--operation", parentID.uuidString, "--target-thread", targetThread, "--classification", "completed", "--summary", "Done"],
            service: service, write: { output.append($0) }
        ), 2, "Empty/incomplete final output cannot become a terminal handoff.")
        XCTAssertEqual(try service.inspect(operationID: parentID).state, .queued)
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: ["OperationsDashboard", "manager", "routing", "status"], service: service, write: { output.append($0) }
        ), 0)
        XCTAssertTrue(output.last?.contains("Waiting for Manager") == true)
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: ["OperationsDashboard", "manager", "route", "acknowledge", "--operation", parentID.uuidString, "--target-thread", targetThread],
            service: service, write: { output.append($0) }
        ), 0)
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: ["OperationsDashboard", "manager", "route", "running", "--operation", parentID.uuidString, "--target-thread", targetThread],
            service: service, write: { output.append($0) }
        ), 0)
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: [
                "OperationsDashboard", "manager", "route", "terminal", "--operation", parentID.uuidString,
                "--target-thread", targetThread, "--classification", "completed", "--summary", "Done",
                "--evidence", "Tests passed.", "--next-gate", "Forward result.", "--unperformed", "No Productions mutation.",
            ], service: service, write: { output.append($0) }
        ), 0)
        XCTAssertTrue(output.last?.contains("terminal-forwarded") == true)
        XCTAssertEqual(try service.inspect(operationID: parentID).state, .forwarded)
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: ["OperationsDashboard", "manager", "routing", "inspect", "--operation", parentID.uuidString],
            service: service, write: { output.append($0) }
        ), 0)
        XCTAssertTrue(output.last?.contains("terminalHandoff") == true)
        XCTAssertTrue(output.last?.contains("transitions") == true)
    }

    private func request(next: Bool = false, timeout: Date? = nil) -> ManagerRouteCreateRequest {
        .init(
            taskID: "TASK-0076", managerThreadID: managerThread, targetThreadID: targetThread,
            action: "Perform the bounded routing lifecycle phase.", authorityReference: "Owner authorization TASK-0076.",
            timeoutAt: timeout ?? baseDate.addingTimeInterval(600),
            nextTargetThreadID: next ? nextThread : nil, nextAction: next ? "Perform the already-authorized next gate." : nil,
            nextAuthorityReference: next ? "Existing owner authorization." : nil,
            nextTimeoutAt: next ? baseDate.addingTimeInterval(1_200) : nil
        )
    }

    private func completedHandoff() -> ManagerTerminalHandoff {
        .init(
            classification: .completed, summary: "Bounded route completed.", evidence: ["Validation passed."],
            nextGate: "Advance the already-authorized gate.", unperformedBoundaries: ["No unrelated mutation."]
        )
    }
}

private final class RoutingClock: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

private final class SequencedRoutingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]
    init(_ values: [Date]) { self.values = values }
    func next() -> Date {
        lock.lock(); defer { lock.unlock() }
        return values.removeFirst()
    }
}

private final class RoutingIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]
    private var calls = 0
    init(_ values: [UUID]) { self.values = values }
    var callCount: Int {
        lock.lock(); defer { lock.unlock() }
        return calls
    }
    func next() -> UUID {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return values.removeFirst()
    }
}

private final class RoutingFixture {
    let directory: URL
    let store: ApplicationSupportManagerRoutingLedgerStore
    let clock: RoutingClock
    let ids: RoutingIDSource
    var ledgerURL: URL { directory.appending(path: "manager-routing-v1.json") }
    var initializationMarkerURL: URL {
        directory.deletingLastPathComponent().appending(path: "\(directory.lastPathComponent).initialized")
    }

    init(ids: [UUID], now: Date) throws {
        directory = URL(fileURLWithPath: "/private/tmp/ManagerRoutingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = .init(directory: directory)
        clock = .init(now)
        self.ids = .init(ids)
    }

    func service() -> ManagerRoutingService {
        let clock = clock
        let ids = ids
        return ManagerRoutingService(store: store, now: { clock.value }, makeOperationID: { ids.next() })
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: initializationMarkerURL)
    }
}

private struct SnapshotRoutingStore: ManagerRoutingLedgerStoring {
    let snapshotValue: ManagerRoutingLedgerSnapshot
    func snapshot() throws -> ManagerRoutingLedgerSnapshot { snapshotValue }
    func transact(expectedSHA256: String?, _ mutation: (inout ManagerRoutingLedger) throws -> Void) throws -> ManagerRoutingLedgerSnapshot {
        throw ManagerRoutingError.storageUncertain("Mutation is unavailable in the read-only fake.")
    }
}

private enum InitialPublicationFailure: CaseIterable, Sendable {
    case writeThenThrow
    case reloadMismatch
}

private enum SyntheticRoutingFailure: Error {
    case afterWrite
}

private func routingDecoder() -> JSONDecoder {
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func assertStorageUncertain(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
    guard let routing = error as? ManagerRoutingError else {
        return XCTFail("Expected ManagerRoutingError, got \(error)", file: file, line: line)
    }
    XCTAssertTrue(
        routing.localizedDescription.contains("missing") || routing.localizedDescription.contains("unavailable"),
        routing.localizedDescription, file: file, line: line
    )
}

private func rewriteRoutingLedger(
    _ url: URL, mutation: (inout [String: Any]) -> Void
) throws {
    try rewriteRoutingRoutes(url) { routes in
        var route = routes[0]
        mutation(&route)
        routes[0] = route
    }
}

private func rewriteRoutingRoutes(
    _ url: URL, mutation: (inout [[String: Any]]) -> Void
) throws {
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var routes = try XCTUnwrap(root["routes"] as? [[String: Any]])
    mutation(&routes)
    root["routes"] = routes
    try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url)
}

private func assertReservationCollision(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(
        (error as? ManagerRoutingError)?.localizedDescription.contains("collides with a durable route or reservation") == true,
        error.localizedDescription, file: file, line: line
    )
}

private func assertDurableReservationCorruption(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
    guard case .storageCorrupt = error as? ManagerRoutingError else {
        return XCTFail("Expected durable reservation corruption, got \(error)", file: file, line: line)
    }
}
