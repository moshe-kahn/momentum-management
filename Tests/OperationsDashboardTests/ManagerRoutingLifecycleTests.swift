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

    func testStandingContinuationAdvancesReviewCorrectionCommitAndCheckpointWithoutOwnerGate() throws {
        let ids = [parentID, childID, laterParentID, laterChildID, thirdParentID]
        let fixture = try RoutingFixture(ids: ids, now: baseDate)
        defer { fixture.remove() }
        let context = canonicalContext()
        let service = fixture.service(context: context)
        let envelope = continuationEnvelope(context: context)
        _ = try service.create(continuationRequest(envelope))
        _ = try service.acknowledge(operationID: parentID, targetThreadID: targetThread)
        let implementation = try service.receiveTerminal(
            operationID: parentID, targetThreadID: targetThread,
            handoff: continuationHandoff(.advance, summary: "Implementation ready for review.")
        )
        XCTAssertEqual(implementation.nextRouteOperationUUID, childID)

        _ = try service.acknowledge(operationID: childID, targetThreadID: nextThread)
        let rejected = try service.receiveTerminal(
            operationID: childID, targetThreadID: nextThread,
            handoff: continuationHandoff(.inScopeCorrection, summary: "Review found one in-scope correction.")
        )
        XCTAssertEqual(rejected.nextRouteOperationUUID, laterParentID)

        _ = try service.acknowledge(operationID: laterParentID, targetThreadID: targetThread)
        let corrected = try service.receiveTerminal(
            operationID: laterParentID, targetThreadID: targetThread,
            handoff: continuationHandoff(.advance, summary: "Correction is review-ready.")
        )
        XCTAssertEqual(corrected.nextRouteOperationUUID, laterChildID)

        _ = try service.acknowledge(operationID: laterChildID, targetThreadID: nextThread)
        let accepted = try service.receiveTerminal(
            operationID: laterChildID, targetThreadID: nextThread,
            handoff: continuationHandoff(.advance, summary: "Independent review accepted.")
        )
        XCTAssertEqual(accepted.nextRouteOperationUUID, thirdParentID)
        let commit = try service.inspection(operationID: thirdParentID).route
        XCTAssertEqual(commit.continuationStageID, "commit")
        XCTAssertEqual(commit.predecessorOperationUUID, laterChildID)
        XCTAssertNotNil(commit.predecessorTerminalSHA256)
        XCTAssertEqual(try service.status().map(\.operationUUID), [thirdParentID])

        let restartDate = baseDate
        let restarted = ManagerRoutingService(
            store: fixture.store, contextResolver: StaticRoutingContextResolver(context),
            contextLocking: TestRoutingContextLock(),
            now: { restartDate }, makeOperationID: { UUID() }
        )
        XCTAssertEqual(try restarted.inspection(operationID: thirdParentID).route.continuationStageID, "commit")
    }

    func testStandingContinuationRejectsStaleCanonicalContextAndRoutesGenuineGateToArchitect() throws {
        let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { fixture.remove() }
        let original = canonicalContext()
        let changed = ManagerCanonicalContextBinding(
            productionsRootPath: original.productionsRootPath,
            taskRegistrySHA256: String(repeating: "9", count: 64), workspaceSHA256: original.workspaceSHA256,
            canvasSHA256: original.canvasSHA256, instructionSHA256: original.instructionSHA256,
            taskLifecycle: original.taskLifecycle, taskPriority: original.taskPriority, canvasCurrent: true
        )
        let box = RoutingContextBox(original)
        let service = fixture.service(contextBox: box)
        _ = try service.create(continuationRequest(continuationEnvelope(context: original)))
        _ = try service.acknowledge(operationID: parentID, targetThreadID: targetThread)
        box.value = changed
        let result = try service.receiveTerminal(
            operationID: parentID, targetThreadID: targetThread,
            handoff: continuationHandoff(.advance, summary: "Completed against stale context.")
        )
        XCTAssertEqual(result.state, .ownerDecisionRequired)
        XCTAssertTrue(result.noRetry)
        XCTAssertNil(result.nextRouteOperationUUID)
        XCTAssertEqual(try service.inspection(operationID: parentID).route.terminalHandoff?.summary, "Completed against stale context.")
        XCTAssertEqual(try service.status().first?.decisionRecipientThreadID, "dddddddd-dddd-4ddd-8ddd-dddddddddddd")
    }

    func testStandingContinuationCLIBindsEnvelopeAndRequiresDisposition() throws {
        let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { fixture.remove() }
        let context = canonicalContext()
        let service = fixture.service(context: context)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(continuationEnvelope(context: context)).base64EncodedString()
        var output: [String] = []
        let create = [
            "OperationsDashboard", "manager", "route", "create", "--task", "TASK-0076",
            "--manager-thread", managerThread, "--target-thread", targetThread,
            "--action", "Implement bounded slice.", "--authority", "Owner completion authorization.",
            "--timeout-at", "2026-09-01T01:00:00Z", "--standing-continuation-base64", encoded,
        ]
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(arguments: create, service: service, write: { output.append($0) }), 0)
        _ = try service.acknowledge(operationID: parentID, targetThreadID: targetThread)
        let incomplete = [
            "OperationsDashboard", "manager", "route", "terminal", "--operation", parentID.uuidString,
            "--target-thread", targetThread, "--classification", "completed", "--summary", "Done.",
            "--evidence", "Tests pass.", "--next-gate", "Review.", "--unperformed", "No deployment.",
        ]
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(arguments: incomplete, service: service, write: { output.append($0) }), 2)
        XCTAssertEqual(try service.inspect(operationID: parentID).state, .deliveredAcknowledged)
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: incomplete + ["--continuation-disposition", "advance"], service: service, write: { output.append($0) }
        ), 0)
        XCTAssertTrue(output.last?.contains(childID.uuidString) == true)
    }

    func testCanonicalCheckpointMayAdvanceOnlyWithExactBoundWorkspacePostimage() throws {
        let before = canonicalContext()
        let after = ManagerCanonicalContextBinding(
            productionsRootPath: before.productionsRootPath, taskRegistrySHA256: before.taskRegistrySHA256,
            workspaceSHA256: String(repeating: "8", count: 64), canvasSHA256: before.canvasSHA256,
            instructionSHA256: before.instructionSHA256, taskLifecycle: before.taskLifecycle,
            taskPriority: before.taskPriority, canvasCurrent: true
        )
        let stage = ManagerContinuationStage(
            id: "checkpoint", kind: .canonicalCheckpoint, actor: .administrator,
            targetThreadID: targetThread, action: "Commit exact checkpoint.", authorityReference: "Owner completion authorization.",
            timeoutSeconds: 600, nextStageID: "phase", correctionStageID: nil
        )
        let next = ManagerContinuationStage(
            id: "phase", kind: .explicitlyAuthorizedPhase, actor: .productSession,
            targetThreadID: nextThread, action: "Begin next exact phase.", authorityReference: "Owner completion authorization.",
            timeoutSeconds: 600, nextStageID: nil, correctionStageID: nil
        )
        let envelope = ManagerStandingContinuationEnvelope(
            schemaVersion: 1, envelopeUUID: UUID(uuidString: "abababab-abab-4bab-8bab-abababababab")!,
            taskID: "TASK-0076", managerThreadID: managerThread,
            architectThreadID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd", scope: "Synthetic checkpoint chain.",
            createdAt: baseDate, initialStageID: "checkpoint", stages: [stage, next],
            hardStops: ManagerOwnerGateKind.allCases, initialContext: before
        )
        let request = ManagerRouteCreateRequest(
            taskID: "TASK-0076", managerThreadID: managerThread, targetThreadID: targetThread,
            action: stage.action, authorityReference: stage.authorityReference,
            timeoutAt: baseDate.addingTimeInterval(600), nextTargetThreadID: nil, nextAction: nil,
            nextAuthorityReference: nil, nextTimeoutAt: nil, standingContinuation: envelope
        )

        let acceptedFixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { acceptedFixture.remove() }
        let acceptedBox = RoutingContextBox(before)
        let accepted = acceptedFixture.service(contextBox: acceptedBox)
        _ = try accepted.create(request)
        _ = try accepted.acknowledge(operationID: parentID, targetThreadID: targetThread)
        acceptedBox.value = after
        let advanced = try accepted.receiveTerminal(
            operationID: parentID, targetThreadID: targetThread,
            handoff: .init(
                classification: .completed, summary: "Checkpoint committed.", evidence: ["Post-write hash verified."],
                nextGate: "Begin phase.", unperformedBoundaries: ["No unrelated mutation."],
                continuationDisposition: .advance, resultingContext: after
            )
        )
        XCTAssertEqual(advanced.nextRouteOperationUUID, childID)
        XCTAssertEqual(try accepted.inspection(operationID: childID).route.canonicalContext, after)

        let rejectedFixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { rejectedFixture.remove() }
        let rejectedBox = RoutingContextBox(before)
        let rejected = rejectedFixture.service(contextBox: rejectedBox)
        _ = try rejected.create(request)
        _ = try rejected.acknowledge(operationID: parentID, targetThreadID: targetThread)
        rejectedBox.value = after
        let frozen = try rejected.receiveTerminal(
            operationID: parentID, targetThreadID: targetThread,
            handoff: .init(
                classification: .completed, summary: "Unbound checkpoint result.", evidence: ["Missing postimage binding."],
                nextGate: "Inspect.", unperformedBoundaries: ["No retry."], continuationDisposition: .advance
            )
        )
        XCTAssertEqual(frozen.state, .ownerDecisionRequired)
        XCTAssertNil(frozen.nextRouteOperationUUID)
        XCTAssertTrue(frozen.noRetry)
    }

    func testStandingEnvelopeReloadRejectsStageAndPredecessorReceiptSubstitution() throws {
        for mutation in ["stage", "digest"] {
            let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
            defer { fixture.remove() }
            let context = canonicalContext()
            let service = fixture.service(context: context)
            _ = try service.create(continuationRequest(continuationEnvelope(context: context)))
            _ = try service.acknowledge(operationID: parentID, targetThreadID: targetThread)
            _ = try service.receiveTerminal(
                operationID: parentID, targetThreadID: targetThread,
                handoff: continuationHandoff(.advance, summary: "Ready.")
            )
            try rewriteRoutingRoutes(fixture.ledgerURL) { routes in
                if mutation == "stage" { routes[1]["continuationStageID"] = "commit" }
                else { routes[1]["predecessorTerminalSHA256"] = String(repeating: "0", count: 64) }
            }
            XCTAssertThrowsError(try fixture.store.snapshot()) {
                guard case .storageCorrupt = $0 as? ManagerRoutingError else {
                    return XCTFail("Expected continuation envelope corruption, got \($0)")
                }
            }
        }
    }

    func testNewMissingReceiptUnloadedAndExpiredContextObservationsAreMonitoredNoRetryTerminals() throws {
        for observation in [ManagerRouteObservation.missingReceipt, .destinationUnloaded, .expiredTaskContext] {
            let fixture = try RoutingFixture(ids: [parentID], now: baseDate)
            defer { fixture.remove() }
            let service = fixture.service()
            _ = try service.create(request())
            let plan = try service.reconciliationPreview(operationID: parentID, observation: observation)
            let result = try service.applyReconciliation(plan, confirmationToken: plan.confirmationToken)
            XCTAssertEqual(result.state, .ownerDecisionRequired)
            XCTAssertTrue(result.noRetry)
            XCTAssertEqual(plan.proposedTerminalState, observation == .missingReceipt ? .terminalUncertain : .terminalBlocked)
        }
    }

    func testCanonicalContextLockDenialPreventsCreateAndFreezesTerminalReceipt() throws {
        let fixture = try RoutingFixture(ids: [parentID, childID], now: baseDate)
        defer { fixture.remove() }
        let context = canonicalContext()
        let clock = fixture.clock
        let ids = fixture.ids
        let deniedCreate = ManagerRoutingService(
            store: fixture.store, contextResolver: StaticRoutingContextResolver(context),
            contextLocking: DeniedRoutingContextLock(), now: { clock.value },
            makeOperationID: { ids.next() }
        )
        XCTAssertThrowsError(try deniedCreate.create(continuationRequest(continuationEnvelope(context: context))))
        XCTAssertEqual(fixture.ids.callCount, 0)
        XCTAssertTrue(try fixture.store.snapshot().ledger.routes.isEmpty)

        let allowed = fixture.service(context: context)
        _ = try allowed.create(continuationRequest(continuationEnvelope(context: context)))
        _ = try allowed.acknowledge(operationID: parentID, targetThreadID: targetThread)
        let deniedTerminal = ManagerRoutingService(
            store: fixture.store, contextResolver: StaticRoutingContextResolver(context),
            contextLocking: DeniedRoutingContextLock(), now: { clock.value },
            makeOperationID: { ids.next() }
        )
        let result = try deniedTerminal.receiveTerminal(
            operationID: parentID, targetThreadID: targetThread,
            handoff: continuationHandoff(.advance, summary: "Completed while canonical context was locked elsewhere.")
        )
        XCTAssertEqual(result.state, .ownerDecisionRequired)
        XCTAssertTrue(result.noRetry)
        XCTAssertNil(result.nextRouteOperationUUID)
        XCTAssertEqual(
            try deniedTerminal.inspection(operationID: parentID).route.terminalHandoff?.summary,
            "Completed while canonical context was locked elsewhere."
        )
        XCTAssertEqual(fixture.ids.callCount, 1)
    }

    func testDurableContinuationRejectsWrongActorsAndOrphanPredecessorFields() throws {
        let continuationFixture = try RoutingFixture(ids: [parentID], now: baseDate)
        defer { continuationFixture.remove() }
        let context = canonicalContext()
        _ = try continuationFixture.service(context: context).create(
            continuationRequest(continuationEnvelope(context: context))
        )
        try rewriteRoutingRoot(continuationFixture.ledgerURL) { root in
            var envelopes = try XCTUnwrap(root["continuationEnvelopes"] as? [[String: Any]])
            var stages = try XCTUnwrap(envelopes[0]["stages"] as? [[String: Any]])
            stages[0]["actor"] = "reviewer"
            envelopes[0]["stages"] = stages
            root["continuationEnvelopes"] = envelopes
        }
        XCTAssertThrowsError(try continuationFixture.store.snapshot()) {
            guard case .storageCorrupt = $0 as? ManagerRoutingError else {
                return XCTFail("Expected wrong-actor corruption, got \($0)")
            }
        }

        let legacyFixture = try RoutingFixture(ids: [laterParentID], now: baseDate)
        defer { legacyFixture.remove() }
        _ = try legacyFixture.service().create(request())
        try rewriteRoutingLedger(legacyFixture.ledgerURL) {
            $0["predecessorOperationUUID"] = self.parentID.uuidString
            $0["predecessorTerminalSHA256"] = String(repeating: "0", count: 64)
        }
        XCTAssertThrowsError(try legacyFixture.store.snapshot()) {
            guard case .storageCorrupt = $0 as? ManagerRoutingError else {
                return XCTFail("Expected orphan predecessor corruption, got \($0)")
            }
        }
    }

    func testLiveProductionAdaptersResolveCreateAndRereadTerminalAgainstCompleteV112Copy() throws {
        let productions = try ManagerLiveContextFixture(); defer { productions.remove() }
        try productions.assertBaselineHashes()
        let routing = try RoutingFixture(ids: [parentID, childID], now: baseDate); defer { routing.remove() }
        let clock = routing.clock, ids = routing.ids
        let service = ManagerRoutingService(
            store: routing.store, contextResolver: LiveManagerCanonicalContextResolver(),
            contextLocking: LiveManagerCanonicalContextLock(), now: { clock.value },
            makeOperationID: { ids.next() }
        )
        var output: [String] = []
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: [
                "OperationsDashboard", "manager", "routing", "context",
                "--productions-root", productions.root.path, "--task", "TASK-0076",
            ], service: service, write: { output.append($0) }
        ), 0)
        let context = try routingDecoder().decode(
            ManagerCanonicalContextBinding.self, from: try XCTUnwrap(output.last?.data(using: .utf8))
        )
        XCTAssertTrue(context.canvasCurrent)
        XCTAssertEqual(context.taskLifecycle, "Active / Current")
        XCTAssertEqual(context.taskPriority, "Medium")

        let envelope = continuationEnvelope(context: context)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(envelope).base64EncodedString()
        output.removeAll()
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: [
                "OperationsDashboard", "manager", "route", "create", "--task", "TASK-0076",
                "--manager-thread", managerThread, "--target-thread", targetThread,
                "--action", "Implement bounded slice.", "--authority", "Owner completion authorization.",
                "--timeout-at", iso8601(baseDate.addingTimeInterval(600)),
                "--standing-continuation-base64", encoded,
            ], service: service, write: { output.append($0) }
        ), 0)
        XCTAssertEqual(try service.inspection(operationID: parentID).route.canonicalContext, context)
        XCTAssertEqual(try service.acknowledge(operationID: parentID, targetThreadID: targetThread).state, .deliveredAcknowledged)
        output.removeAll()
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: [
                "OperationsDashboard", "manager", "route", "terminal", "--operation", parentID.uuidString,
                "--target-thread", targetThread, "--classification", "completed", "--summary", "Production adapter complete.",
                "--evidence", "Complete v1.12 copy validated.", "--next-gate", "Independent review.",
                "--unperformed", "No canonical mutation.", "--continuation-disposition", "advance",
            ], service: service, write: { output.append($0) }
        ), 0)
        let terminal = try routingDecoder().decode(
            ManagerRoutingCommandResult.self, from: try XCTUnwrap(output.last?.data(using: .utf8))
        )
        XCTAssertEqual(terminal.state, .forwarded)
        XCTAssertEqual(terminal.nextRouteOperationUUID, childID)
        XCTAssertEqual(try service.inspection(operationID: childID).route.canonicalContext, context)
    }

    func testLiveProductionCreateRejectsEveryCanonicalContextDefectBeforeUUIDOrLedger() throws {
        for mutation in ManagerLiveContextMutation.allCases {
            try assertLiveCreateRejectsBeforeLedger(mutation: mutation)
        }
        try assertLiveCreateRejectsBeforeLedger(
            mutation: nil,
            contextLocking: LiveManagerCanonicalContextLock(
                registryLocking: ManagerDeniedCheckpointLock(),
                canvasLocking: LocalCanvasWorkTransactionLocking()
            )
        )
        try assertLiveCreateRejectsBeforeLedger(
            mutation: nil,
            contextLocking: LiveManagerCanonicalContextLock(
                registryLocking: LocalTaskCheckpointLocking(),
                canvasLocking: ManagerDeniedCanvasLock()
            )
        )
    }

    func testLiveTerminalRereadPreservesReceiptAndFreezesOnPostCreateWorkspaceDrift() throws {
        let productions = try ManagerLiveContextFixture(); defer { productions.remove() }
        try productions.assertBaselineHashes()
        let routing = try RoutingFixture(ids: [parentID, childID], now: baseDate); defer { routing.remove() }
        let clock = routing.clock, ids = routing.ids
        let service = ManagerRoutingService(
            store: routing.store, contextResolver: LiveManagerCanonicalContextResolver(),
            contextLocking: LiveManagerCanonicalContextLock(), now: { clock.value },
            makeOperationID: { ids.next() }
        )
        let context = try service.canonicalContext(productionsRootPath: productions.root.path, taskID: "TASK-0076")
        _ = try service.create(continuationRequest(continuationEnvelope(context: context)))
        _ = try service.acknowledge(operationID: parentID, targetThreadID: targetThread)
        try productions.apply(.workspaceIdentityDrift)
        var output: [String] = []
        XCTAssertEqual(HeadlessManagerRoutingCommandLine.runIfRequested(
            arguments: [
                "OperationsDashboard", "manager", "route", "terminal", "--operation", parentID.uuidString,
                "--target-thread", targetThread, "--classification", "completed", "--summary", "Completed before drift detection.",
                "--evidence", "Target returned one exact receipt.", "--next-gate", "Inspect stale context.",
                "--unperformed", "No routed action was retried.", "--continuation-disposition", "advance",
            ], service: service, write: { output.append($0) }
        ), 0)
        let result = try routingDecoder().decode(
            ManagerRoutingCommandResult.self, from: try XCTUnwrap(output.last?.data(using: .utf8))
        )
        XCTAssertEqual(result.state, .ownerDecisionRequired)
        XCTAssertTrue(result.noRetry)
        XCTAssertNil(result.nextRouteOperationUUID)
        XCTAssertEqual(ids.callCount, 1)
        XCTAssertEqual(
            try service.inspection(operationID: parentID).route.terminalHandoff?.summary,
            "Completed before drift detection."
        )
    }

    private func assertLiveCreateRejectsBeforeLedger(
        mutation: ManagerLiveContextMutation?,
        contextLocking: any ManagerCanonicalContextLocking = LiveManagerCanonicalContextLock()
    ) throws {
        let productions = try ManagerLiveContextFixture(); defer { productions.remove() }
        try productions.assertBaselineHashes()
        let resolver = LiveManagerCanonicalContextResolver()
        let context = try resolver.resolve(productionsRootPath: productions.root.path, taskID: "TASK-0076")
        if let mutation { try productions.apply(mutation) }
        let routing = try RoutingFixture(ids: [parentID], now: baseDate); defer { routing.remove() }
        let clock = routing.clock, ids = routing.ids
        let service = ManagerRoutingService(
            store: routing.store, contextResolver: resolver, contextLocking: contextLocking,
            now: { clock.value }, makeOperationID: { ids.next() }
        )
        XCTAssertThrowsError(try service.create(continuationRequest(continuationEnvelope(context: context))), mutation?.rawValue ?? "lock-denial")
        XCTAssertEqual(ids.callCount, 0, mutation?.rawValue ?? "lock-denial")
        XCTAssertTrue(try routing.store.snapshot().ledger.routes.isEmpty, mutation?.rawValue ?? "lock-denial")
        XCTAssertFalse(FileManager.default.fileExists(atPath: routing.initializationMarkerURL.path), mutation?.rawValue ?? "lock-denial")
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
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

    private func canonicalContext() -> ManagerCanonicalContextBinding {
        .init(
            productionsRootPath: "/private/tmp/synthetic-productions", taskRegistrySHA256: String(repeating: "1", count: 64),
            workspaceSHA256: String(repeating: "2", count: 64), canvasSHA256: String(repeating: "3", count: 64),
            instructionSHA256: ["AGENTS.md": String(repeating: "4", count: 64)],
            taskLifecycle: "Active / Current", taskPriority: "Medium", canvasCurrent: true
        )
    }

    private func continuationEnvelope(context: ManagerCanonicalContextBinding) -> ManagerStandingContinuationEnvelope {
        .init(
            schemaVersion: 1, envelopeUUID: UUID(uuidString: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")!,
            taskID: "TASK-0076", managerThreadID: managerThread,
            architectThreadID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            scope: "Complete bounded TASK-0076 workflow reliability.", createdAt: baseDate,
            initialStageID: "implementation",
            stages: [
                .init(id: "implementation", kind: .implementation, actor: .productSession, targetThreadID: targetThread, action: "Implement bounded slice.", authorityReference: "Owner completion authorization.", timeoutSeconds: 600, nextStageID: "review", correctionStageID: nil),
                .init(id: "review", kind: .independentReview, actor: .reviewer, targetThreadID: nextThread, action: "Independently review bounded slice.", authorityReference: "Owner completion authorization.", timeoutSeconds: 600, nextStageID: "commit", correctionStageID: "correction"),
                .init(id: "correction", kind: .inScopeCorrection, actor: .productSession, targetThreadID: targetThread, action: "Correct accepted in-scope findings.", authorityReference: "Owner completion authorization.", timeoutSeconds: 600, nextStageID: "review", correctionStageID: nil),
                .init(id: "commit", kind: .acceptedLocalCommit, actor: .productSession, targetThreadID: targetThread, action: "Create exact accepted local commit.", authorityReference: "Owner completion authorization.", timeoutSeconds: 600, nextStageID: "checkpoint", correctionStageID: nil),
                .init(id: "checkpoint", kind: .canonicalCheckpoint, actor: .administrator, targetThreadID: "ffffffff-ffff-4fff-8fff-ffffffffffff", action: "Commit exact canonical checkpoint.", authorityReference: "Owner completion authorization.", timeoutSeconds: 600, nextStageID: nil, correctionStageID: nil),
            ],
            hardStops: ManagerOwnerGateKind.allCases, initialContext: context
        )
    }

    private func continuationRequest(_ envelope: ManagerStandingContinuationEnvelope) -> ManagerRouteCreateRequest {
        .init(
            taskID: "TASK-0076", managerThreadID: managerThread, targetThreadID: targetThread,
            action: "Implement bounded slice.", authorityReference: "Owner completion authorization.",
            timeoutAt: baseDate.addingTimeInterval(600), nextTargetThreadID: nil, nextAction: nil,
            nextAuthorityReference: nil, nextTimeoutAt: nil, standingContinuation: envelope
        )
    }

    private func continuationHandoff(
        _ disposition: ManagerContinuationDisposition, summary: String
    ) -> ManagerTerminalHandoff {
        .init(
            classification: .completed, summary: summary, evidence: ["Exact binding validated."],
            nextGate: "Advance the standing envelope.", unperformedBoundaries: ["No unrelated mutation."],
            continuationDisposition: disposition
        )
    }
}

private enum ManagerLiveContextMutation: String, CaseIterable {
    case adoptedV112Failure
    case registryIdentityDrift
    case workspaceIdentityDrift
    case canvasFragmented
    case canvasCleared
    case requiredInstructionDrift
    case requiredInstructionMissing
    case symlinkInput
    case nonregularInput
}

private final class ManagerLiveContextFixture {
    let root: URL
    private let manager = FileManager.default
    private static let fixtureSHA256: [String: String] = [
        "AGENTS.md": "530631592b66b0642f600a8e7ae436c2d0b44b2fb469362a0ca5820359e9a8af",
        "PRODUCTIONS_COORDINATOR.md": "aefd79d6b33b9a91f9f0f3a34811126c9a2467b92df1839baa3e37dd851576ce",
        "PRODUCTIONS_OFFICE_ADMINISTRATOR.md": "187c06aa6821f86556192c48185e639ab77280e8d5097cfbff481113f46d681e",
        "Warehouse/Reference/Canonical Work Record Template.md": "3c7f3784904a9d4ac2b85e45d53089dcbf8c1e73ad37c8c1cbddc40e5a386353",
        "Warehouse/Reference/Document Registry.md": "ef390dd5139393d3491e35713c6e838b3fcf0acd2a961e0e05b394048465dc84",
        "Warehouse/Reference/Momentum Management Filesystem Contract.md": "998e56b888c87a226fa5fe253fadfef975f5171e5663a1441e61930f3bb8fafa",
        "Warehouse/Reference/Task Intake and Promotion Policy.md": "7df7bf0e5de24cefa4807e48a5313671b2b9342460e788527a3988f0efc9b978",
        "Warehouse/Reference/Task Status and Continuity Protocol.md": "8d8583cd859fbff3f861dbf38635aabf7aa5fd9eeeccaeca18103e8f00a4e4a7",
        "Office/Registry/Ideas.md": "91adbce4b3f2c7d446450c868b25255b8f01d6e973dd62aa498c5fe07eab78a7",
        "Office/Registry/Initiatives.md": "988f68c13d618ca64d1b61092ed073c135633417c05a0d3e9bd849138955764e",
        "Office/Registry/Projects.md": "45ca279f36698f50f79ceee1f83fe4bc8d9a5d0b8fa1d064e2f85adb681546f4",
        "Office/Registry/Tasks.md": "ccc997f3a4d5d0ebc80ab36fda23fc9153e92c61a673515c0790b2d7dbf662f6",
        "Office/Threads/Canvas.md": "6d0103df21b35c78c528bda68c20d456491ec88ecc96ce2daa95187c5e4314b5",
        "Workspace/IDEA-0006/IDEA-0006.md": "e7e3549757e6c54c0894f28e2027516a979c80eca9581613c9cde98ec4096e9d",
        "Workspace/TASK-0017/TASK-0017.md": "84aedaed662c66a1ae0e196304a20831a0005bcdfc590ac32671447809d33f13",
        "Workspace/TASK-0076/TASK-0076.md": "488329f55e05f870496ca5855d01245505bd72eacd70db6c16b8c03c6bb7fb3d",
    ]

    init() throws {
        root = URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true)
            .appending(path: "ManagerLiveContextTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let corpus = try XCTUnwrap(Bundle.module.resourceURL)
            .appending(path: "Fixtures/OfficeV112", directoryHint: .isDirectory)
        for (path, expected) in Self.fixtureSHA256 {
            let data = try OfficeJournalAtomicCoordinator.readRegular(corpus.appending(path: path))
            guard hash(data) == expected else { throw ManagerLiveFixtureError.corpusHashMismatch(path) }
            try write(data, path: path)
        }
    }

    func remove() { try? manager.removeItem(at: root) }

    func assertBaselineHashes() throws {
        let files = try manager.subpathsOfDirectory(atPath: root.path).filter { path in
            var directory: ObjCBool = false
            return manager.fileExists(atPath: root.appending(path: path).path, isDirectory: &directory) && !directory.boolValue
        }
        XCTAssertEqual(Set(files), Set(Self.fixtureSHA256.keys))
        for (path, expected) in Self.fixtureSHA256 {
            XCTAssertEqual(hash(try OfficeJournalAtomicCoordinator.readRegular(root.appending(path: path))), expected, path)
        }
    }

    func apply(_ mutation: ManagerLiveContextMutation) throws {
        switch mutation {
        case .adoptedV112Failure:
            try append("\nNon-adopted byte.", path: "Warehouse/Reference/Canonical Work Record Template.md")
        case .registryIdentityDrift:
            try replaceFirst(
                "| TASK-0076 | Establish Productions Office Administration and Session Handoffs |",
                with: "| TASK-0076 | Drifted TASK-0076 title |", path: "Office/Registry/Tasks.md"
            )
        case .workspaceIdentityDrift:
            try replaceFirst(
                "# Establish Productions Office Administration and Session Handoffs",
                with: "# Drifted TASK-0076 title", path: "Workspace/TASK-0076/TASK-0076.md"
            )
        case .canvasFragmented:
            try append(
                "\nNarrative interruption.\n| 2026-08-31T23:59:58Z | TASK-0076 | Engaged | Fragment. | Invalid later row. |\n",
                path: "Office/Threads/Canvas.md"
            )
        case .canvasCleared:
            try insertCanvasRow(
                "| 2026-08-31T23:59:59Z | TASK-0076 | Cleared | Synthetic stop. | Fixture only. |"
            )
        case .requiredInstructionDrift:
            try append("\nInstruction drift.", path: "AGENTS.md")
        case .requiredInstructionMissing:
            try manager.removeItem(at: root.appending(path: "PRODUCTIONS_COORDINATOR.md"))
        case .symlinkInput:
            let path = "Workspace/TASK-0076/TASK-0076.md"
            let url = root.appending(path: path)
            let real = url.deletingLastPathComponent().appending(path: ".real-TASK-0076.md")
            try manager.moveItem(at: url, to: real)
            try manager.createSymbolicLink(at: url, withDestinationURL: real)
        case .nonregularInput:
            let url = root.appending(path: "Workspace/TASK-0076/TASK-0076.md")
            try manager.removeItem(at: url)
            try manager.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }

    private func insertCanvasRow(_ row: String) throws {
        let path = "Office/Threads/Canvas.md"
        let url = root.appending(path: path)
        var lines = try strictText(url).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = try XCTUnwrap(lines.firstIndex(where: { MarkdownTable.cells($0) == CanvasMarkdown.headers }))
        var insertion = header + 2
        while insertion < lines.count, lines[insertion].hasPrefix("|") { insertion += 1 }
        lines.insert(row, at: insertion)
        try write(Data(lines.joined(separator: "\n").utf8), path: path)
    }

    private func replaceFirst(_ old: String, with new: String, path: String) throws {
        let url = root.appending(path: path)
        var text = try strictText(url)
        let range = try XCTUnwrap(text.range(of: old))
        text.replaceSubrange(range, with: new)
        try write(Data(text.utf8), path: path)
    }

    private func append(_ suffix: String, path: String) throws {
        let url = root.appending(path: path)
        var data = try OfficeJournalAtomicCoordinator.readRegular(url)
        data.append(Data(suffix.utf8))
        try write(data, path: path)
    }

    private func strictText(_ url: URL) throws -> String {
        let data = try OfficeJournalAtomicCoordinator.readRegular(url)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func write(_ data: Data, path: String) throws {
        let url = root.appending(path: path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum ManagerLiveFixtureError: Error {
    case corpusHashMismatch(String)
}

private struct ManagerDeniedCheckpointLock: TaskCheckpointLocking {
    func acquire(registryURL: URL) -> AnyObject? { nil }
}

private struct ManagerDeniedCanvasLock: CanvasWorkTransactionLocking {
    func acquire(canvasURL: URL) -> AnyObject? { nil }
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

    func service(context: ManagerCanonicalContextBinding) -> ManagerRoutingService {
        let clock = clock; let ids = ids
        return ManagerRoutingService(
            store: store, contextResolver: StaticRoutingContextResolver(context),
            contextLocking: TestRoutingContextLock(),
            now: { clock.value }, makeOperationID: { ids.next() }
        )
    }

    func service(contextBox: RoutingContextBox) -> ManagerRoutingService {
        let clock = clock; let ids = ids
        return ManagerRoutingService(
            store: store, contextResolver: contextBox,
            contextLocking: TestRoutingContextLock(),
            now: { clock.value }, makeOperationID: { ids.next() }
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: initializationMarkerURL)
    }
}

private struct StaticRoutingContextResolver: ManagerCanonicalContextResolving {
    let context: ManagerCanonicalContextBinding
    init(_ context: ManagerCanonicalContextBinding) { self.context = context }
    func resolve(productionsRootPath: String, taskID: String) throws -> ManagerCanonicalContextBinding { context }
}

private final class RoutingContextBox: ManagerCanonicalContextResolving, @unchecked Sendable {
    var value: ManagerCanonicalContextBinding
    init(_ value: ManagerCanonicalContextBinding) { self.value = value }
    func resolve(productionsRootPath: String, taskID: String) throws -> ManagerCanonicalContextBinding { value }
}

private final class TestRoutingContextLockToken: NSObject {}
private struct TestRoutingContextLock: ManagerCanonicalContextLocking {
    func acquire(productionsRootPath: String) -> AnyObject? { TestRoutingContextLockToken() }
}

private struct DeniedRoutingContextLock: ManagerCanonicalContextLocking {
    func acquire(productionsRootPath: String) -> AnyObject? { nil }
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

private func rewriteRoutingRoot(
    _ url: URL, mutation: (inout [String: Any]) throws -> Void
) throws {
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    try mutation(&root)
    try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]).write(to: url)
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
