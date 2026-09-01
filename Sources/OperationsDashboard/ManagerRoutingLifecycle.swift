import CryptoKit
import Darwin
import Foundation

enum ManagerRouteState: String, Codable, CaseIterable, Sendable {
    case queued
    case deliveredAcknowledged = "delivered/acknowledged"
    case running
    case terminalCompleted = "terminal-completed"
    case terminalBlocked = "terminal-blocked"
    case terminalUncertain = "terminal-uncertain"
    case forwarded
    case ownerDecisionRequired = "owner-decision-required"

    var isTerminalReceipt: Bool {
        self == .terminalCompleted || self == .terminalBlocked || self == .terminalUncertain
    }

    var isClosed: Bool { self == .forwarded || self == .ownerDecisionRequired }
}

enum ManagerRouteWaitingFor: String, Codable, Sendable {
    case manager = "Waiting for Manager"
    case target = "Waiting for target"
    case owner = "Waiting for owner"
    case none = "Complete"
}

enum ManagerRouteTerminalClassification: String, Codable, Sendable {
    case completed, blocked, uncertain

    var state: ManagerRouteState {
        switch self {
        case .completed: .terminalCompleted
        case .blocked: .terminalBlocked
        case .uncertain: .terminalUncertain
        }
    }
}

enum ManagerRouteObservation: String, Codable, CaseIterable, Sendable {
    case silentCompletion = "silent-completion"
    case emptyFinalOutput = "empty-final-output"
    case targetInterrupted = "target-interrupted"
    case destinationUnloaded = "destination-unloaded"
    case expiredTaskContext = "expired-task-context"
    case missingReceipt = "missing-receipt"
    case timeout

    var terminalClassification: ManagerRouteTerminalClassification {
        switch self {
        case .targetInterrupted, .destinationUnloaded, .expiredTaskContext: .blocked
        case .silentCompletion, .emptyFinalOutput, .missingReceipt, .timeout: .uncertain
        }
    }
}

enum ManagerContinuationStageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case implementation
    case independentReview = "independent-review"
    case inScopeCorrection = "in-scope-correction"
    case acceptedLocalCommit = "accepted-local-commit"
    case canonicalCheckpoint = "canonical-checkpoint"
    case explicitlyAuthorizedPhase = "explicitly-authorized-phase"
}

enum ManagerContinuationActor: String, Codable, CaseIterable, Hashable, Sendable {
    case productSession = "product-session"
    case reviewer
    case administrator
}

enum ManagerOwnerGateKind: String, Codable, CaseIterable, Hashable, Sendable {
    case materialScopeOrProductChoice = "material-scope-or-product-choice"
    case credentialsOrPrivateData = "credentials-or-private-data"
    case externalOrPublicMutation = "external-or-public-mutation"
    case destructiveAction = "destructive-action"
    case deploymentOrPromotion = "deployment-or-promotion"
    case requestedVisualReview = "requested-visual-review"
    case uncertainOrPossibleCommit = "uncertain-or-possible-commit"
}

enum ManagerContinuationDisposition: String, Codable, Sendable {
    case advance
    case inScopeCorrection = "in-scope-correction"
    case ownerDecision = "owner-decision"
    case safeStop = "safe-stop"
}

struct ManagerCanonicalContextBinding: Codable, Equatable, Sendable {
    let productionsRootPath: String
    let taskRegistrySHA256: String
    let workspaceSHA256: String
    let canvasSHA256: String
    let instructionSHA256: [String: String]
    let taskLifecycle: String
    let taskPriority: String
    let canvasCurrent: Bool
}

struct ManagerContinuationStage: Codable, Equatable, Sendable {
    let id: String
    let kind: ManagerContinuationStageKind
    let actor: ManagerContinuationActor
    let targetThreadID: String
    let action: String
    let authorityReference: String
    let timeoutSeconds: Int
    let nextStageID: String?
    let correctionStageID: String?
}

struct ManagerStandingContinuationEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let envelopeUUID: UUID
    let taskID: String
    let managerThreadID: String
    let architectThreadID: String
    let scope: String
    let createdAt: Date
    let initialStageID: String
    let stages: [ManagerContinuationStage]
    let hardStops: [ManagerOwnerGateKind]
    let initialContext: ManagerCanonicalContextBinding
}

enum ManagerRouteMonitorKind: String, Codable, Sendable {
    case scheduledWake = "scheduled-wake"
    case liveTarget = "live-target"
    case ownerDecision = "owner-decision"
}

struct ManagerRouteMonitor: Codable, Equatable, Sendable {
    let kind: ManagerRouteMonitorKind
    let wakeAt: Date?
}

struct ManagerRouteTransition: Codable, Equatable, Sendable {
    let state: ManagerRouteState
    let occurredAt: Date
    let note: String
}

struct ManagerTerminalHandoff: Codable, Equatable, Sendable {
    let classification: ManagerRouteTerminalClassification
    let summary: String
    let evidence: [String]
    let nextGate: String
    let unperformedBoundaries: [String]
    let continuationDisposition: ManagerContinuationDisposition?
    let ownerGate: ManagerOwnerGateKind?
    let resultingContext: ManagerCanonicalContextBinding?

    init(
        classification: ManagerRouteTerminalClassification, summary: String, evidence: [String],
        nextGate: String, unperformedBoundaries: [String],
        continuationDisposition: ManagerContinuationDisposition? = nil,
        ownerGate: ManagerOwnerGateKind? = nil,
        resultingContext: ManagerCanonicalContextBinding? = nil
    ) {
        self.classification = classification
        self.summary = summary
        self.evidence = evidence
        self.nextGate = nextGate
        self.unperformedBoundaries = unperformedBoundaries
        self.continuationDisposition = continuationDisposition
        self.ownerGate = ownerGate
        self.resultingContext = resultingContext
    }
}

struct ManagerAuthorizedNextRoute: Codable, Equatable, Sendable {
    let operationUUID: UUID
    let targetThreadID: String
    let action: String
    let authorityReference: String
    let timeoutAt: Date
}

struct ManagerRouteRecord: Codable, Equatable, Sendable {
    static let schemaVersion = 1

    let schemaVersion: Int
    let operationUUID: UUID
    let taskID: String
    let managerThreadID: String
    let targetThreadID: String
    let action: String
    let authorityReference: String
    let createdAt: Date
    let timeoutAt: Date
    let nextAuthorizedRoute: ManagerAuthorizedNextRoute?
    let continuationEnvelopeUUID: UUID?
    let continuationStageID: String?
    let predecessorOperationUUID: UUID?
    let predecessorTerminalSHA256: String?
    let canonicalContext: ManagerCanonicalContextBinding?
    private(set) var state: ManagerRouteState
    private(set) var updatedAt: Date
    private(set) var receiptAcknowledgedAt: Date?
    private(set) var runningAt: Date?
    private(set) var terminalHandoff: ManagerTerminalHandoff?
    private(set) var advancedRouteOperationUUID: UUID?
    private(set) var monitor: ManagerRouteMonitor?
    private(set) var transitions: [ManagerRouteTransition]

    init(
        operationUUID: UUID, taskID: String, managerThreadID: String, targetThreadID: String,
        action: String, authorityReference: String, createdAt: Date, timeoutAt: Date,
        nextAuthorizedRoute: ManagerAuthorizedNextRoute?,
        continuationEnvelopeUUID: UUID? = nil, continuationStageID: String? = nil,
        predecessorOperationUUID: UUID? = nil, predecessorTerminalSHA256: String? = nil,
        canonicalContext: ManagerCanonicalContextBinding? = nil
    ) {
        schemaVersion = Self.schemaVersion
        self.operationUUID = operationUUID
        self.taskID = taskID
        self.managerThreadID = managerThreadID
        self.targetThreadID = targetThreadID
        self.action = action
        self.authorityReference = authorityReference
        self.createdAt = createdAt
        self.timeoutAt = timeoutAt
        self.nextAuthorizedRoute = nextAuthorizedRoute
        self.continuationEnvelopeUUID = continuationEnvelopeUUID
        self.continuationStageID = continuationStageID
        self.predecessorOperationUUID = predecessorOperationUUID
        self.predecessorTerminalSHA256 = predecessorTerminalSHA256
        self.canonicalContext = canonicalContext
        state = .queued
        updatedAt = createdAt
        receiptAcknowledgedAt = nil
        runningAt = nil
        terminalHandoff = nil
        advancedRouteOperationUUID = nil
        monitor = ManagerRouteMonitor(kind: .scheduledWake, wakeAt: timeoutAt)
        transitions = [.init(state: .queued, occurredAt: createdAt, note: "Route durably queued for Manager delivery.")]
    }

    mutating func acknowledge(targetThreadID: String, at date: Date) throws {
        try requireTarget(targetThreadID)
        if state == .deliveredAcknowledged { return }
        guard state == .queued else { throw ManagerRoutingError.invalidTransition("Receipt can only acknowledge a queued route.") }
        state = .deliveredAcknowledged
        updatedAt = date
        receiptAcknowledgedAt = date
        monitor = ManagerRouteMonitor(kind: .liveTarget, wakeAt: timeoutAt)
        transitions.append(.init(state: state, occurredAt: date, note: "Destination acknowledged the stable routing operation ID."))
    }

    mutating func markRunning(targetThreadID: String, at date: Date) throws {
        try requireTarget(targetThreadID)
        if state == .running { return }
        guard state == .deliveredAcknowledged else { throw ManagerRoutingError.invalidTransition("Running requires a durable destination acknowledgement first.") }
        state = .running
        updatedAt = date
        runningAt = date
        monitor = ManagerRouteMonitor(kind: .liveTarget, wakeAt: timeoutAt)
        transitions.append(.init(state: state, occurredAt: date, note: "Destination reported active execution."))
    }

    mutating func receiveTerminal(
        targetThreadID: String, handoff: ManagerTerminalHandoff, at date: Date,
        requiresAcknowledgement: Bool = true
    ) throws -> Bool {
        try requireTarget(targetThreadID)
        if let existing = terminalHandoff {
            guard ManagerRoutingValidation.equal(existing, handoff) else {
                throw ManagerRoutingError.duplicateTerminal("A different terminal handoff is already durable. Inspect; do not retry automatically.")
            }
            return false
        }
        let mayReceive = requiresAcknowledgement
            ? state == .deliveredAcknowledged || state == .running
            : state == .queued || state == .deliveredAcknowledged || state == .running
        guard mayReceive else {
            throw ManagerRoutingError.invalidTransition("This route cannot accept another terminal handoff.")
        }
        terminalHandoff = handoff
        state = handoff.classification.state
        updatedAt = date
        monitor = ManagerRouteMonitor(kind: .scheduledWake, wakeAt: date)
        transitions.append(.init(state: state, occurredAt: date, note: handoff.summary))
        return true
    }

    mutating func finalizeTerminal(
        at date: Date, advancedRouteID: UUID?, requiresOwnerDecision: Bool = false
    ) throws {
        guard state.isTerminalReceipt, terminalHandoff != nil else {
            throw ManagerRoutingError.invalidTransition("Only a durable terminal receipt can be forwarded or escalated.")
        }
        if terminalHandoff?.classification == .completed, !requiresOwnerDecision {
            state = .forwarded
            advancedRouteOperationUUID = advancedRouteID
            monitor = nil
            transitions.append(.init(
                state: state, occurredAt: date,
                note: advancedRouteID == nil ? "Terminal completion forwarded." : "Terminal completion forwarded and the already-authorized next route queued."
            ))
        } else {
            state = .ownerDecisionRequired
            monitor = ManagerRouteMonitor(kind: .ownerDecision, wakeAt: nil)
            let note = terminalHandoff?.classification == .completed
                ? "Terminal completion is durable, but continuation is not safely eligible; Manager or owner decision required."
                : "Terminal blocker or uncertainty requires one owner-facing decision."
            transitions.append(.init(state: state, occurredAt: date, note: note))
        }
        updatedAt = date
    }

    func waitingFor() -> ManagerRouteWaitingFor {
        switch state {
        case .queued: .manager
        case .deliveredAcknowledged, .running: .target
        case .terminalCompleted, .terminalBlocked, .terminalUncertain: .manager
        case .ownerDecisionRequired: .owner
        case .forwarded: .none
        }
    }

    private func requireTarget(_ supplied: String) throws {
        guard ManagerRoutingUTF8.equal(targetThreadID, supplied) else {
            throw ManagerRoutingError.identityMismatch("The destination thread does not match the immutable route target.")
        }
    }
}

struct ManagerRoutingLedger: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    let schemaVersion: Int
    var routes: [ManagerRouteRecord]
    var continuationEnvelopes: [ManagerStandingContinuationEnvelope]

    init(routes: [ManagerRouteRecord] = [], continuationEnvelopes: [ManagerStandingContinuationEnvelope] = []) {
        schemaVersion = Self.schemaVersion
        self.routes = routes
        self.continuationEnvelopes = continuationEnvelopes
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, routes, continuationEnvelopes }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        routes = try values.decode([ManagerRouteRecord].self, forKey: .routes)
        continuationEnvelopes = try values.decodeIfPresent([ManagerStandingContinuationEnvelope].self, forKey: .continuationEnvelopes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(routes, forKey: .routes)
        if !continuationEnvelopes.isEmpty { try values.encode(continuationEnvelopes, forKey: .continuationEnvelopes) }
    }
}

struct ManagerRoutingLedgerSnapshot: Sendable {
    let ledger: ManagerRoutingLedger
    let sha256: String
}

protocol ManagerRoutingLedgerStoring: Sendable {
    func snapshot() throws -> ManagerRoutingLedgerSnapshot
    func transact(
        expectedSHA256: String?, _ mutation: (inout ManagerRoutingLedger) throws -> Void
    ) throws -> ManagerRoutingLedgerSnapshot
}

protocol ManagerRoutingStatusReading: Sendable {
    func status() throws -> [ManagerRoutingStatusItem]
}

struct ApplicationSupportManagerRoutingLedgerStore: ManagerRoutingLedgerStoring, @unchecked Sendable {
    private static let initializationBytes = Data("manager-routing-v1-initialized\n".utf8)
    private let manager: FileManager
    private let directoryOverride: URL?
    private let afterInitialLedgerPublication: (@Sendable (URL) throws -> Void)?

    init(
        manager: FileManager = .default,
        directory: URL? = nil,
        afterInitialLedgerPublication: (@Sendable (URL) throws -> Void)? = nil
    ) {
        self.manager = manager
        directoryOverride = directory
        self.afterInitialLedgerPublication = afterInitialLedgerPublication
    }

    private var directory: URL {
        directoryOverride ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/Manager Routing Recovery", directoryHint: .isDirectory)
    }

    private var ledgerURL: URL { directory.appending(path: "manager-routing-v1.json") }
    private var initializationMarkerURL: URL {
        directory.deletingLastPathComponent().appending(path: "\(directory.lastPathComponent).initialized")
    }

    func snapshot() throws -> ManagerRoutingLedgerSnapshot {
        do {
            guard try entryExists(directory) else {
                guard !(try entryExists(initializationMarkerURL)) else {
                    throw ManagerRoutingError.storageUncertain("The initialized routing-ledger directory is missing. Inspect storage; do not retry automatically.")
                }
                return try encodedSnapshot(.init())
            }
            return try OfficeJournalAtomicCoordinator.withLock(directory: directory) {
                let initialized = try initializationStateLocked()
                return try readLocked(initialized: initialized)
            }
        } catch let error as ManagerRoutingError {
            throw error
        } catch {
            throw ManagerRoutingError.storageUncertain("The routing ledger is unavailable: \(error.localizedDescription). Inspect storage; do not retry automatically.")
        }
    }

    func transact(
        expectedSHA256: String?, _ mutation: (inout ManagerRoutingLedger) throws -> Void
    ) throws -> ManagerRoutingLedgerSnapshot {
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw ManagerRoutingError.storageUncertain("The routing-ledger directory is unavailable: \(error.localizedDescription). Inspect storage; do not retry automatically.")
        }
        do {
            return try OfficeJournalAtomicCoordinator.withLock(directory: directory) {
                let initialized = try initializationStateLocked()
                let before = try readLocked(initialized: initialized)
            if let expectedSHA256, !ManagerRoutingUTF8.equal(expectedSHA256, before.sha256) {
                throw ManagerRoutingError.staleLedger("The durable routing ledger changed. Inspect; do not retry automatically.")
            }
            var proposed = before.ledger
            try mutation(&proposed)
            try validate(proposed, previous: before.ledger)
            if proposed == before.ledger { return before }
            let encoded = try encode(proposed)
            do {
                if initialized {
                    guard try entryExists(ledgerURL) else {
                        throw ManagerRoutingError.storageUncertain("The initialized routing ledger disappeared during the locked transaction. Inspect; do not retry automatically.")
                    }
                    let durableBytes = try OfficeJournalAtomicCoordinator.readRegular(ledgerURL)
                    guard ManagerRoutingUTF8.equal(sha256(durableBytes), before.sha256) else {
                        throw ManagerRoutingError.staleLedger("The durable routing ledger changed during the locked transaction. Inspect; do not retry automatically.")
                    }
                    try OfficeJournalAtomicCoordinator.replaceIfUnchanged(
                        expectedDurableBytes: durableBytes, proposedBytes: encoded, at: ledgerURL, manager: manager
                    )
                } else {
                    guard before.ledger.routes.isEmpty, !(try entryExists(ledgerURL)) else {
                        throw ManagerRoutingError.storageCorrupt("An uninitialized routing store contains unexpected ledger bytes.")
                    }
                    try DurableReplacement(manager: manager).replace(
                        data: Self.initializationBytes, at: initializationMarkerURL
                    )
                    guard try OfficeJournalAtomicCoordinator.readRegular(initializationMarkerURL) == Self.initializationBytes else {
                        throw ManagerRoutingError.storageUncertain("Routing-ledger initialization did not reload exactly. Inspect; do not retry automatically.")
                    }
                    try DurableReplacement(manager: manager).replace(data: encoded, at: ledgerURL)
                    try afterInitialLedgerPublication?(ledgerURL)
                    guard try OfficeJournalAtomicCoordinator.readRegular(ledgerURL) == encoded else {
                        throw ManagerRoutingError.storageUncertain("Initial routing ledger publication did not reload exactly. Inspect; do not retry automatically.")
                    }
                }
            } catch let error as ManagerRoutingError {
                throw error
            } catch {
                throw ManagerRoutingError.storageUncertain("Routing ledger replacement or reload failed: \(error.localizedDescription). Inspect; do not retry automatically.")
            }
                return .init(ledger: proposed, sha256: sha256(encoded))
            }
        } catch let error as ManagerRoutingError {
            throw error
        } catch {
            throw ManagerRoutingError.storageUncertain("The routing-ledger transaction is unavailable: \(error.localizedDescription). Inspect storage; do not retry automatically.")
        }
    }

    private func initializationStateLocked() throws -> Bool {
        guard try entryExists(initializationMarkerURL) else { return false }
        guard try OfficeJournalAtomicCoordinator.readRegular(initializationMarkerURL) == Self.initializationBytes else {
            throw ManagerRoutingError.storageCorrupt("The routing-ledger initialization marker is malformed.")
        }
        return true
    }

    private func readLocked(initialized: Bool) throws -> ManagerRoutingLedgerSnapshot {
        guard try entryExists(ledgerURL) else {
            guard !initialized else {
                throw ManagerRoutingError.storageUncertain("The initialized routing-ledger file is missing. Inspect storage; do not retry automatically.")
            }
            return try encodedSnapshot(.init())
        }
        guard initialized else {
            throw ManagerRoutingError.storageCorrupt("Routing-ledger bytes exist without the durable initialization marker.")
        }
        let data = try OfficeJournalAtomicCoordinator.readRegular(ledgerURL)
        let ledger: ManagerRoutingLedger
        do { ledger = try JSONDecoder.managerRouting.decode(ManagerRoutingLedger.self, from: data) }
        catch { throw ManagerRoutingError.storageCorrupt("The durable routing ledger cannot be decoded: \(error.localizedDescription)") }
        try validate(ledger, previous: nil)
        return .init(ledger: ledger, sha256: sha256(data))
    }

    private func entryExists(_ url: URL) throws -> Bool {
        var information = stat()
        if lstat(url.path, &information) == 0 { return true }
        if errno == ENOENT { return false }
        throw ManagerRoutingError.storageUncertain("Cannot inspect routing storage at \(url.path): errno \(errno).")
    }

    private func encodedSnapshot(_ ledger: ManagerRoutingLedger) throws -> ManagerRoutingLedgerSnapshot {
        let data = try encode(ledger)
        return .init(ledger: ledger, sha256: sha256(data))
    }

    private func encode(_ ledger: ManagerRoutingLedger) throws -> Data {
        try JSONEncoder.managerRouting.encode(ledger)
    }

    private func validate(_ ledger: ManagerRoutingLedger, previous: ManagerRoutingLedger?) throws {
        guard ledger.schemaVersion == ManagerRoutingLedger.schemaVersion else {
            throw ManagerRoutingError.storageCorrupt("Unsupported routing ledger schema.")
        }
        var ids = Set<UUID>()
        var envelopeIDs = Set<UUID>()
        for envelope in ledger.continuationEnvelopes {
            guard envelopeIDs.insert(envelope.envelopeUUID).inserted else {
                throw ManagerRoutingError.storageCorrupt("Duplicate standing continuation envelope UUID.")
            }
            try ManagerRoutingValidation.validate(envelope)
        }
        for route in ledger.routes {
            guard ids.insert(route.operationUUID).inserted else { throw ManagerRoutingError.storageCorrupt("Duplicate routing operation UUID.") }
            try ManagerRoutingValidation.validate(route)
            if let envelopeID = route.continuationEnvelopeUUID {
                guard let envelope = ledger.continuationEnvelopes.first(where: { $0.envelopeUUID == envelopeID }),
                      let stageID = route.continuationStageID,
                      let stage = envelope.stages.first(where: { ManagerRoutingUTF8.equal($0.id, stageID) }),
                      ManagerRoutingUTF8.equal(envelope.taskID, route.taskID),
                      ManagerRoutingUTF8.equal(envelope.managerThreadID, route.managerThreadID),
                      ManagerRoutingUTF8.equal(stage.targetThreadID, route.targetThreadID),
                      ManagerRoutingUTF8.equal(stage.action, route.action),
                      ManagerRoutingUTF8.equal(stage.authorityReference, route.authorityReference),
                      let context = route.canonicalContext,
                      ManagerRoutingUTF8.equal(context.productionsRootPath, envelope.initialContext.productionsRootPath) else {
                    throw ManagerRoutingError.storageCorrupt("A route does not resolve to its immutable standing continuation envelope and stage.")
                }
                try ManagerRoutingValidation.validate(context)
            } else if route.continuationStageID != nil || route.canonicalContext != nil ||
                        route.predecessorOperationUUID != nil || route.predecessorTerminalSHA256 != nil {
                throw ManagerRoutingError.storageCorrupt("A route contains orphaned standing-continuation data.")
            }
        }
        let byID = Dictionary(uniqueKeysWithValues: ledger.routes.map { ($0.operationUUID, $0) })
        for route in ledger.routes where route.continuationEnvelopeUUID != nil {
            let envelope = ledger.continuationEnvelopes.first { $0.envelopeUUID == route.continuationEnvelopeUUID }!
            if let predecessorID = route.predecessorOperationUUID {
                guard let predecessor = byID[predecessorID],
                      predecessor.continuationEnvelopeUUID == route.continuationEnvelopeUUID,
                      predecessor.advancedRouteOperationUUID == route.operationUUID,
                      let handoff = predecessor.terminalHandoff,
                      handoff.classification == .completed,
                      ManagerRoutingUTF8.equal(
                        route.predecessorTerminalSHA256 ?? "",
                        try ManagerRoutingValidation.terminalSHA256(handoff)
                      ),
                      let predecessorStageID = predecessor.continuationStageID,
                      let predecessorStage = envelope.stages.first(where: { ManagerRoutingUTF8.equal($0.id, predecessorStageID) }),
                      let expectedStageID = ManagerRoutingValidation.selectedStageID(handoff, from: predecessorStage),
                      ManagerRoutingUTF8.equal(expectedStageID, route.continuationStageID ?? "") else {
                    throw ManagerRoutingError.storageCorrupt("A continuation child does not bind its exact predecessor terminal receipt and stage edge.")
                }
            } else {
                guard route.predecessorTerminalSHA256 == nil,
                      ManagerRoutingUTF8.equal(route.continuationStageID ?? "", envelope.initialStageID) else {
                    throw ManagerRoutingError.storageCorrupt("A continuation route lacks its exact predecessor linkage.")
                }
            }
        }
        var reservationOwners: [UUID: UUID] = [:]
        for parent in ledger.routes {
            guard let reservation = parent.nextAuthorizedRoute?.operationUUID else { continue }
            guard reservationOwners.updateValue(parent.operationUUID, forKey: reservation) == nil else {
                throw ManagerRoutingError.storageCorrupt("Two durable parents reserve the same child routing UUID.")
            }
            if byID[reservation] != nil {
                guard parent.state == .forwarded,
                      parent.advancedRouteOperationUUID == reservation else {
                    throw ManagerRoutingError.storageCorrupt("A child reservation collides with a route ID before its exact parent forwarded it.")
                }
            }
        }
        for parent in ledger.routes where parent.advancedRouteOperationUUID != nil {
            guard let advanced = parent.advancedRouteOperationUUID, let child = byID[advanced],
                  ManagerRoutingUTF8.equal(child.taskID, parent.taskID),
                  ManagerRoutingUTF8.equal(child.managerThreadID, parent.managerThreadID),
                  child.createdAt == parent.updatedAt else {
                throw ManagerRoutingError.storageCorrupt("An advanced route does not exactly match its immutable authorized template.")
            }
            if parent.continuationEnvelopeUUID != nil {
                guard child.predecessorOperationUUID == parent.operationUUID,
                      child.continuationEnvelopeUUID == parent.continuationEnvelopeUUID else {
                    throw ManagerRoutingError.storageCorrupt("An advanced continuation route does not bind its exact parent.")
                }
            } else {
                guard let template = parent.nextAuthorizedRoute, template.operationUUID == advanced,
                      ManagerRoutingUTF8.equal(child.targetThreadID, template.targetThreadID),
                      ManagerRoutingUTF8.equal(child.action, template.action),
                      ManagerRoutingUTF8.equal(child.authorityReference, template.authorityReference),
                      child.timeoutAt == template.timeoutAt else {
                    throw ManagerRoutingError.storageCorrupt("An advanced route does not exactly match its immutable authorized template.")
                }
            }
        }
        guard let previous else { return }
        guard previous.continuationEnvelopes == ledger.continuationEnvelopes.prefix(previous.continuationEnvelopes.count).map({ $0 }) else {
            throw ManagerRoutingError.storageCorrupt("A standing continuation envelope was changed or deleted.")
        }
        let proposed = Dictionary(uniqueKeysWithValues: ledger.routes.map { ($0.operationUUID, $0) })
        for old in previous.routes {
            guard let new = proposed[old.operationUUID] else { throw ManagerRoutingError.storageCorrupt("A durable route was deleted.") }
            try ManagerRoutingValidation.validateMonotonic(old: old, new: new)
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct ManagerRouteCreateRequest: Equatable, Sendable {
    let taskID: String
    let managerThreadID: String
    let targetThreadID: String
    let action: String
    let authorityReference: String
    let timeoutAt: Date
    let nextTargetThreadID: String?
    let nextAction: String?
    let nextAuthorityReference: String?
    let nextTimeoutAt: Date?
    let standingContinuation: ManagerStandingContinuationEnvelope?

    init(
        taskID: String, managerThreadID: String, targetThreadID: String, action: String,
        authorityReference: String, timeoutAt: Date, nextTargetThreadID: String?,
        nextAction: String?, nextAuthorityReference: String?, nextTimeoutAt: Date?,
        standingContinuation: ManagerStandingContinuationEnvelope? = nil
    ) {
        self.taskID = taskID
        self.managerThreadID = managerThreadID
        self.targetThreadID = targetThreadID
        self.action = action
        self.authorityReference = authorityReference
        self.timeoutAt = timeoutAt
        self.nextTargetThreadID = nextTargetThreadID
        self.nextAction = nextAction
        self.nextAuthorityReference = nextAuthorityReference
        self.nextTimeoutAt = nextTimeoutAt
        self.standingContinuation = standingContinuation
    }
}

struct ManagerRoutingStatusItem: Codable, Equatable, Sendable {
    let operationUUID: UUID
    let taskID: String
    let targetThreadID: String
    let state: ManagerRouteState
    let waitingFor: ManagerRouteWaitingFor
    let ageSeconds: Int
    let unresolvedAgeSeconds: Int
    let timeoutAt: Date
    let overdue: Bool
    let action: String
    let authorityReference: String
    let continuationStageID: String?
    let decisionRecipientThreadID: String?

    init(
        operationUUID: UUID, taskID: String, targetThreadID: String, state: ManagerRouteState,
        waitingFor: ManagerRouteWaitingFor, ageSeconds: Int, unresolvedAgeSeconds: Int,
        timeoutAt: Date, overdue: Bool, action: String = "Route action unavailable.",
        authorityReference: String = "Authority unavailable.", continuationStageID: String? = nil,
        decisionRecipientThreadID: String? = nil
    ) {
        self.operationUUID = operationUUID
        self.taskID = taskID
        self.targetThreadID = targetThreadID
        self.state = state
        self.waitingFor = waitingFor
        self.ageSeconds = ageSeconds
        self.unresolvedAgeSeconds = unresolvedAgeSeconds
        self.timeoutAt = timeoutAt
        self.overdue = overdue
        self.action = action
        self.authorityReference = authorityReference
        self.continuationStageID = continuationStageID
        self.decisionRecipientThreadID = decisionRecipientThreadID
    }
}

struct ManagerRoutingCommandResult: Codable, Equatable, Sendable {
    let outcome: String
    let operationUUID: UUID?
    let state: ManagerRouteState?
    let waitingFor: ManagerRouteWaitingFor?
    let ledgerSHA256: String?
    let nextRouteOperationUUID: UUID?
    let classification: String
    let diagnostic: String?
    let inspectionCommand: String?
    let noRetry: Bool
}

struct ManagerRoutingInspection: Codable, Equatable, Sendable {
    let ledgerSHA256: String
    let route: ManagerRouteRecord
}

struct ManagerRoutingReconciliationPlan: Codable, Equatable, Sendable {
    let operationUUID: UUID
    let observation: ManagerRouteObservation
    let currentState: ManagerRouteState
    let proposedTerminalState: ManagerRouteState
    let expectedLedgerSHA256: String
    let confirmationToken: String
    let diagnostic: String
}

struct ManagerRoutingService: ManagerRoutingStatusReading, @unchecked Sendable {
    let store: any ManagerRoutingLedgerStoring
    let contextResolver: any ManagerCanonicalContextResolving
    let contextLocking: any ManagerCanonicalContextLocking
    let now: @Sendable () -> Date
    let makeOperationID: @Sendable () -> UUID

    init(
        store: any ManagerRoutingLedgerStoring = ApplicationSupportManagerRoutingLedgerStore(),
        contextResolver: any ManagerCanonicalContextResolving = LiveManagerCanonicalContextResolver(),
        contextLocking: any ManagerCanonicalContextLocking = LiveManagerCanonicalContextLock(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeOperationID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.store = store
        self.contextResolver = contextResolver
        self.contextLocking = contextLocking
        self.now = now
        self.makeOperationID = makeOperationID
    }

    func create(_ request: ManagerRouteCreateRequest) throws -> ManagerRoutingCommandResult {
        try ManagerRoutingValidation.validate(request, now: now())
        var contextLock: AnyObject?
        defer { withExtendedLifetime(contextLock) {} }
        if let envelope = request.standingContinuation {
            try ManagerRoutingValidation.validate(envelope, request: request)
            guard let acquired = contextLocking.acquire(
                productionsRootPath: envelope.initialContext.productionsRootPath
            ) else {
                throw ManagerRoutingError.invalidTransition("Canonical Registry/Canvas context is busy or unavailable; no route UUID or ledger mutation occurred.")
            }
            contextLock = acquired
            let live = try contextResolver.resolve(
                productionsRootPath: envelope.initialContext.productionsRootPath, taskID: request.taskID
            )
            guard live.bytewiseEquals(envelope.initialContext), live.canvasCurrent else {
                throw ManagerRoutingError.staleLedger("The standing-continuation authorization is stale or its Task is not Canvas-current. Reread canonical state; do not route it.")
            }
        }
        let operationID = makeOperationID()
        let next = try makeNext(request)
        guard next?.operationUUID != operationID else {
            throw ManagerRoutingError.duplicateOperation("Generated parent and preauthorized-child routing UUIDs must be distinct.")
        }
        let date = secondPrecision(now())
        let snapshot: ManagerRoutingLedgerSnapshot
        do {
            snapshot = try store.transact(expectedSHA256: nil) { ledger in
                let routeIDs = Set(ledger.routes.map(\.operationUUID))
                let reservations = Set(ledger.routes.compactMap { $0.nextAuthorizedRoute?.operationUUID })
                let proposedIDs = Set([operationID] + [next?.operationUUID].compactMap { $0 })
                guard proposedIDs.isDisjoint(with: routeIDs),
                      proposedIDs.isDisjoint(with: reservations) else {
                    throw ManagerRoutingError.duplicateOperation("A generated parent or child UUID collides with a durable route or reservation.")
                }
                ledger.routes.append(.init(
                    operationUUID: operationID, taskID: request.taskID,
                    managerThreadID: request.managerThreadID, targetThreadID: request.targetThreadID,
                    action: request.action, authorityReference: request.authorityReference,
                    createdAt: date, timeoutAt: request.timeoutAt, nextAuthorizedRoute: next,
                    continuationEnvelopeUUID: request.standingContinuation?.envelopeUUID,
                    continuationStageID: request.standingContinuation?.initialStageID,
                    canonicalContext: request.standingContinuation?.initialContext
                ))
                if let envelope = request.standingContinuation {
                    guard !ledger.continuationEnvelopes.contains(where: { $0.envelopeUUID == envelope.envelopeUUID }) else {
                        throw ManagerRoutingError.duplicateOperation("The standing continuation envelope UUID already exists.")
                    }
                    ledger.continuationEnvelopes.append(envelope)
                }
            }
        } catch let error as ManagerRoutingError {
            switch error {
            case .storageCorrupt, .storageUncertain, .staleLedger:
                throw ManagerRoutingError.createStorageUncertain(
                    operationID,
                    "Create storage outcome is uncertain: \(error.localizedDescription) Inspect with `manager routing inspect --operation \(operationID.uuidString)`; do not retry automatically."
                )
            default: throw error
            }
        }
        return result(route: try route(operationID, in: snapshot), snapshot: snapshot, classification: "queued")
    }

    func acknowledge(operationID: UUID, targetThreadID: String) throws -> ManagerRoutingCommandResult {
        try transition(operationID: operationID) { try $0.acknowledge(targetThreadID: targetThreadID, at: secondPrecision(now())) }
    }

    func markRunning(operationID: UUID, targetThreadID: String) throws -> ManagerRoutingCommandResult {
        try transition(operationID: operationID) { try $0.markRunning(targetThreadID: targetThreadID, at: secondPrecision(now())) }
    }

    func receiveTerminal(
        operationID: UUID, targetThreadID: String, handoff: ManagerTerminalHandoff
    ) throws -> ManagerRoutingCommandResult {
        let date = secondPrecision(now())
        let before = try store.snapshot()
        let beforeRoute = try route(operationID, in: before)
        let liveContextResult: Result<ManagerCanonicalContextBinding, Error>?
        var contextLock: AnyObject?
        defer { withExtendedLifetime(contextLock) {} }
        if let context = beforeRoute.canonicalContext {
            if let acquired = contextLocking.acquire(productionsRootPath: context.productionsRootPath) {
                contextLock = acquired
                liveContextResult = Result {
                    try contextResolver.resolve(productionsRootPath: context.productionsRootPath, taskID: beforeRoute.taskID)
                }
            } else {
                liveContextResult = .failure(ManagerRoutingError.storageUncertain(
                    "Canonical Registry/Canvas context is busy or unavailable."
                ))
            }
        } else {
            liveContextResult = nil
        }
        if beforeRoute.continuationEnvelopeUUID != nil, handoff.continuationDisposition == nil {
            throw ManagerRoutingError.invalidInput("A standing-continuation terminal handoff requires an exact continuation disposition.")
        }
        let snapshot = try store.transact(expectedSHA256: before.sha256) { ledger in
            guard let index = ledger.routes.firstIndex(where: { $0.operationUUID == operationID }) else {
                throw ManagerRoutingError.notFound("Routing operation not found.")
            }
            let inserted = try ledger.routes[index].receiveTerminal(targetThreadID: targetThreadID, handoff: handoff, at: date)
            guard inserted else { return }
            var childID: UUID?
            var expiredNextRoute = false
            var forceDecision = handoff.classification != .completed || handoff.continuationDisposition == .ownerDecision
            if handoff.ownerGate != nil { forceDecision = true }
            if let envelopeID = ledger.routes[index].continuationEnvelopeUUID {
                guard let envelope = ledger.continuationEnvelopes.first(where: { $0.envelopeUUID == envelopeID }),
                      let currentStageID = ledger.routes[index].continuationStageID,
                      let currentStage = envelope.stages.first(where: { ManagerRoutingUTF8.equal($0.id, currentStageID) }) else {
                    throw ManagerRoutingError.storageCorrupt("The terminal route lost its continuation envelope or stage.")
                }
                let liveContext: ManagerCanonicalContextBinding?
                switch liveContextResult {
                case let .success(value): liveContext = value
                case .failure, .none: liveContext = nil; forceDecision = true
                }
                if let liveContext {
                    if !liveContext.canvasCurrent { forceDecision = true }
                    if let expected = ledger.routes[index].canonicalContext,
                       !liveContext.bytewiseEquals(expected) {
                        let checkpointChangeIsBound = currentStage.kind == .canonicalCheckpoint &&
                            handoff.resultingContext?.bytewiseEquals(liveContext) == true &&
                            expected.onlyWorkspaceHashDiffers(from: liveContext)
                        if !checkpointChangeIsBound { forceDecision = true }
                    } else if let resulting = handoff.resultingContext,
                              !resulting.bytewiseEquals(liveContext) {
                        forceDecision = true
                    }
                }
                let nextStageID: String? = switch handoff.continuationDisposition ?? .safeStop {
                case .advance: currentStage.nextStageID
                case .inScopeCorrection: currentStage.correctionStageID
                case .ownerDecision, .safeStop: nil
                }
                if handoff.continuationDisposition == .inScopeCorrection, currentStage.correctionStageID == nil {
                    forceDecision = true
                }
                if !forceDecision, let nextStageID {
                    guard let nextStage = envelope.stages.first(where: { ManagerRoutingUTF8.equal($0.id, nextStageID) }) else {
                        throw ManagerRoutingError.storageCorrupt("The continuation terminal points to an unresolved stage.")
                    }
                    let generated = makeOperationID()
                    let reservations = Set(ledger.routes.compactMap { $0.nextAuthorizedRoute?.operationUUID })
                    guard !ledger.routes.contains(where: { $0.operationUUID == generated }),
                          !reservations.contains(generated) else {
                        throw ManagerRoutingError.duplicateOperation("The generated continuation route UUID collides with a durable route or reservation.")
                    }
                    childID = generated
                    ledger.routes.append(.init(
                        operationUUID: generated, taskID: envelope.taskID,
                        managerThreadID: envelope.managerThreadID, targetThreadID: nextStage.targetThreadID,
                        action: nextStage.action, authorityReference: nextStage.authorityReference,
                        createdAt: date, timeoutAt: date.addingTimeInterval(TimeInterval(nextStage.timeoutSeconds)),
                        nextAuthorizedRoute: nil, continuationEnvelopeUUID: envelope.envelopeUUID,
                        continuationStageID: nextStage.id, predecessorOperationUUID: operationID,
                        predecessorTerminalSHA256: try ManagerRoutingValidation.terminalSHA256(handoff),
                        canonicalContext: liveContext
                    ))
                }
            } else if handoff.classification == .completed, let next = ledger.routes[index].nextAuthorizedRoute {
                if date >= next.timeoutAt {
                    expiredNextRoute = true
                } else {
                    guard !ledger.routes.contains(where: { $0.operationUUID == next.operationUUID }) else {
                        throw ManagerRoutingError.duplicateOperation("The already-authorized next route UUID already exists.")
                    }
                    childID = next.operationUUID
                    ledger.routes.append(.init(
                        operationUUID: next.operationUUID, taskID: ledger.routes[index].taskID,
                        managerThreadID: ledger.routes[index].managerThreadID, targetThreadID: next.targetThreadID,
                        action: next.action, authorityReference: next.authorityReference,
                        createdAt: date, timeoutAt: next.timeoutAt, nextAuthorizedRoute: nil
                    ))
                }
            }
            try ledger.routes[index].finalizeTerminal(
                at: date, advancedRouteID: childID, requiresOwnerDecision: expiredNextRoute || forceDecision
            )
        }
        let current = try route(operationID, in: snapshot)
        return result(
            route: current, snapshot: snapshot,
            classification: current.state == ManagerRouteState.ownerDecisionRequired ? "owner-decision-required" : "terminal-forwarded",
            diagnostic: current.state == ManagerRouteState.ownerDecisionRequired ? "One concise owner decision is required; do not retry the routed action automatically." : nil,
            noRetry: current.state == ManagerRouteState.ownerDecisionRequired
        )
    }

    func inspect(operationID: UUID) throws -> ManagerRoutingCommandResult {
        let snapshot = try store.snapshot()
        return result(route: try route(operationID, in: snapshot), snapshot: snapshot, classification: "inspected")
    }

    func canonicalContext(productionsRootPath: String, taskID: String) throws -> ManagerCanonicalContextBinding {
        try contextResolver.resolve(productionsRootPath: productionsRootPath, taskID: taskID)
    }

    func inspection(operationID: UUID) throws -> ManagerRoutingInspection {
        let snapshot = try store.snapshot()
        return .init(ledgerSHA256: snapshot.sha256, route: try route(operationID, in: snapshot))
    }

    func status() throws -> [ManagerRoutingStatusItem] {
        let snapshot = try store.snapshot()
        return snapshot.ledger.routes.filter { $0.state != .forwarded }.map { route in
            let age = max(0, Int(now().timeIntervalSince(route.createdAt)))
            let unresolved = max(0, Int(now().timeIntervalSince(route.updatedAt)))
            return .init(
                operationUUID: route.operationUUID, taskID: route.taskID, targetThreadID: route.targetThreadID,
                state: route.state, waitingFor: route.waitingFor(), ageSeconds: age,
                unresolvedAgeSeconds: unresolved, timeoutAt: route.timeoutAt, overdue: now() >= route.timeoutAt,
                action: route.action, authorityReference: route.authorityReference,
                continuationStageID: route.continuationStageID,
                decisionRecipientThreadID: route.state == .ownerDecisionRequired
                    ? route.continuationEnvelopeUUID.flatMap { id in
                        snapshot.ledger.continuationEnvelopes.first(where: { $0.envelopeUUID == id })?.architectThreadID
                    } : nil
            )
        }.sorted { lhs, rhs in
            lhs.waitingFor.rawValue == rhs.waitingFor.rawValue
                ? lhs.operationUUID.uuidString < rhs.operationUUID.uuidString
                : lhs.waitingFor.rawValue < rhs.waitingFor.rawValue
        }
    }

    func assertMayIdle() throws -> ManagerRoutingCommandResult {
        let snapshot = try store.snapshot()
        for route in snapshot.ledger.routes where route.state != .forwarded {
            guard ManagerRoutingValidation.hasRequiredMonitor(route) else {
                throw ManagerRoutingError.idleInvariant("Open route \(route.operationUUID.uuidString) has no live monitor, scheduled wake, forwarded terminal, or explicit owner decision.")
            }
            if route.waitingFor() != .owner, let wake = route.monitor?.wakeAt, wake <= now() {
                throw ManagerRoutingError.idleInvariant("Open route \(route.operationUUID.uuidString) has reached its scheduled wake and must be reconciled before Manager idleness.")
            }
        }
        return .init(
            outcome: "safe-to-idle", operationUUID: nil, state: nil, waitingFor: nil,
            ledgerSHA256: snapshot.sha256, nextRouteOperationUUID: nil,
            classification: "pre-idle-invariant-satisfied", diagnostic: nil,
            inspectionCommand: nil, noRetry: false
        )
    }

    func reconciliationPreview(
        operationID: UUID, observation: ManagerRouteObservation
    ) throws -> ManagerRoutingReconciliationPlan {
        let snapshot = try store.snapshot()
        let current = try route(operationID, in: snapshot)
        guard !current.state.isClosed, current.terminalHandoff == nil else {
            throw ManagerRoutingError.invalidTransition("A terminal or closed route must be inspected, not reconciled again.")
        }
        if observation == .timeout, now() < current.timeoutAt {
            throw ManagerRoutingError.invalidTransition("Timeout reconciliation is not eligible before the exact route deadline.")
        }
        let proposed = observation.terminalClassification.state
        let diagnostic = switch observation {
        case .silentCompletion: "Target appears complete but returned no structured terminal handoff. Record uncertainty; do not repeat the routed action."
        case .emptyFinalOutput: "Target returned empty final output. Record uncertainty; do not repeat the routed action."
        case .targetInterrupted: "Target was interrupted before a structured terminal handoff. Record a blocker; do not repeat the routed action."
        case .destinationUnloaded: "The destination task is unavailable or unloaded before a structured terminal handoff. Record a blocker; do not repeat the routed action."
        case .expiredTaskContext: "The destination task context expired before a structured terminal handoff. Record a blocker; reread canonical context before any new route."
        case .missingReceipt: "The destination produced no durable receipt. Record uncertainty; inspect before any further action."
        case .timeout: "The monitored route exceeded its wake deadline without a terminal handoff. Escalate uncertainty; do not repeat the routed action."
        }
        let unsigned = "\(operationID.uuidString)|\(observation.rawValue)|\(current.state.rawValue)|\(proposed.rawValue)|\(snapshot.sha256)"
        return .init(
            operationUUID: operationID, observation: observation, currentState: current.state,
            proposedTerminalState: proposed, expectedLedgerSHA256: snapshot.sha256,
            confirmationToken: sha256(Data(unsigned.utf8)), diagnostic: diagnostic
        )
    }

    func applyReconciliation(
        _ plan: ManagerRoutingReconciliationPlan, confirmationToken: String
    ) throws -> ManagerRoutingCommandResult {
        let fresh = try reconciliationPreview(operationID: plan.operationUUID, observation: plan.observation)
        guard fresh == plan, ManagerRoutingUTF8.equal(confirmationToken, plan.confirmationToken) else {
            throw ManagerRoutingError.staleLedger("The read-only reconciliation plan is stale or its confirmation token is invalid. Inspect; do not retry automatically.")
        }
        let snapshot = try store.transact(expectedSHA256: plan.expectedLedgerSHA256) { ledger in
            guard let index = ledger.routes.firstIndex(where: { $0.operationUUID == plan.operationUUID }) else {
                throw ManagerRoutingError.notFound("Routing operation not found.")
            }
            let route = ledger.routes[index]
            let applicationDate = secondPrecision(now())
            if plan.observation == .timeout, applicationDate < route.timeoutAt {
                throw ManagerRoutingError.invalidTransition("Timeout reconciliation is not eligible before the exact route deadline.")
            }
            let handoff = ManagerTerminalHandoff(
                classification: plan.observation.terminalClassification,
                summary: plan.diagnostic, evidence: ["Read-only routing reconciliation: \(plan.observation.rawValue)."],
                nextGate: "Manager must surface one concise owner decision or blocker.",
                unperformedBoundaries: ["The routed action was not retried."]
            )
            _ = try ledger.routes[index].receiveTerminal(
                targetThreadID: route.targetThreadID, handoff: handoff,
                at: applicationDate, requiresAcknowledgement: false
            )
            try ledger.routes[index].finalizeTerminal(at: applicationDate, advancedRouteID: nil)
        }
        return result(
            route: try route(plan.operationUUID, in: snapshot), snapshot: snapshot,
            classification: "owner-decision-required", diagnostic: plan.diagnostic, noRetry: true
        )
    }

    private func transition(
        operationID: UUID, _ body: (inout ManagerRouteRecord) throws -> Void
    ) throws -> ManagerRoutingCommandResult {
        let snapshot = try store.transact(expectedSHA256: nil) { ledger in
            guard let index = ledger.routes.firstIndex(where: { $0.operationUUID == operationID }) else {
                throw ManagerRoutingError.notFound("Routing operation not found.")
            }
            try body(&ledger.routes[index])
        }
        return result(route: try route(operationID, in: snapshot), snapshot: snapshot, classification: "state-updated")
    }

    private func makeNext(_ request: ManagerRouteCreateRequest) throws -> ManagerAuthorizedNextRoute? {
        let values = [request.nextTargetThreadID, request.nextAction, request.nextAuthorityReference]
        guard values.contains(where: { $0 != nil }) || request.nextTimeoutAt != nil else { return nil }
        guard let target = request.nextTargetThreadID, let action = request.nextAction,
              let authority = request.nextAuthorityReference, let timeout = request.nextTimeoutAt else {
            throw ManagerRoutingError.invalidInput("An already-authorized next route requires target, action, authority, and timeout together.")
        }
        return .init(operationUUID: makeOperationID(), targetThreadID: target, action: action, authorityReference: authority, timeoutAt: timeout)
    }

    private func route(_ id: UUID, in snapshot: ManagerRoutingLedgerSnapshot) throws -> ManagerRouteRecord {
        guard let route = snapshot.ledger.routes.first(where: { $0.operationUUID == id }) else {
            throw ManagerRoutingError.notFound("Routing operation not found.")
        }
        return route
    }

    private func result(
        route: ManagerRouteRecord, snapshot: ManagerRoutingLedgerSnapshot, classification: String,
        diagnostic: String? = nil, noRetry: Bool = false
    ) -> ManagerRoutingCommandResult {
        .init(
            outcome: route.state == .ownerDecisionRequired ? "owner-decision-required" : "committed",
            operationUUID: route.operationUUID, state: route.state, waitingFor: route.waitingFor(),
            ledgerSHA256: snapshot.sha256, nextRouteOperationUUID: route.advancedRouteOperationUUID,
            classification: classification, diagnostic: diagnostic,
            inspectionCommand: nil, noRetry: noRetry
        )
    }

    private func secondPrecision(_ date: Date) -> Date { Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)) }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum ManagerRoutingValidation {
    static func terminalSHA256(_ handoff: ManagerTerminalHandoff) throws -> String {
        let data = try JSONEncoder.managerRouting.encode(handoff)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func validate(_ request: ManagerRouteCreateRequest, now: Date) throws {
        guard secondPrecision(request.timeoutAt),
              request.nextTimeoutAt.map(secondPrecision) ?? true else {
            throw ManagerRoutingError.invalidInput("Route deadlines must use exact whole-second precision.")
        }
        guard request.taskID.range(of: #"^TASK-[0-9]{4,}$"#, options: .regularExpression) != nil,
              thread(request.managerThreadID), thread(request.targetThreadID),
              line(request.action), line(request.authorityReference), request.timeoutAt > now else {
            throw ManagerRoutingError.invalidInput("A route requires an exact Task ID, two exact thread IDs, one-line action/authority, and a future timeout.")
        }
        if let value = request.nextTargetThreadID, !thread(value) { throw ManagerRoutingError.invalidInput("The next target thread ID is invalid.") }
        if let value = request.nextAction, !line(value) { throw ManagerRoutingError.invalidInput("The next action is invalid.") }
        if let value = request.nextAuthorityReference, !line(value) { throw ManagerRoutingError.invalidInput("The next authority reference is invalid.") }
        if let value = request.nextTimeoutAt, value <= request.timeoutAt { throw ManagerRoutingError.invalidInput("The next route timeout must be later than the current route timeout.") }
        if request.standingContinuation != nil,
           [request.nextTargetThreadID, request.nextAction, request.nextAuthorityReference].contains(where: { $0 != nil }) ||
            (request.standingContinuation != nil && request.nextTimeoutAt != nil) {
            throw ManagerRoutingError.invalidInput("A standing continuation envelope cannot be combined with the legacy one-step next route.")
        }
    }

    static func validate(_ envelope: ManagerStandingContinuationEnvelope, request: ManagerRouteCreateRequest? = nil) throws {
        guard envelope.schemaVersion == ManagerStandingContinuationEnvelope.schemaVersion,
              envelope.taskID.range(of: #"^TASK-[0-9]{4,}$"#, options: .regularExpression) != nil,
              thread(envelope.managerThreadID), thread(envelope.architectThreadID), line(envelope.scope),
              !envelope.stages.isEmpty,
              envelope.hardStops.count == ManagerOwnerGateKind.allCases.count,
              Set(envelope.hardStops) == Set(ManagerOwnerGateKind.allCases),
              secondPrecision(envelope.createdAt),
              envelope.initialContext.canvasCurrent,
              line(envelope.initialContext.productionsRootPath),
              envelope.initialContext.taskRegistrySHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              envelope.initialContext.workspaceSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              envelope.initialContext.canvasSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw ManagerRoutingError.storageCorrupt("The standing continuation envelope or canonical binding is incomplete.")
        }
        var stageIDs = Set<String>()
        for stage in envelope.stages {
            guard line(stage.id), stageIDs.insert(stage.id).inserted, thread(stage.targetThreadID),
                  line(stage.action), line(stage.authorityReference), stage.timeoutSeconds > 0,
                  stage.timeoutSeconds <= 604_800 else {
                throw ManagerRoutingError.storageCorrupt("A standing continuation stage is invalid or duplicated.")
            }
            let expectedActor: ManagerContinuationActor = switch stage.kind {
            case .independentReview: .reviewer
            case .canonicalCheckpoint: .administrator
            case .implementation, .inScopeCorrection, .acceptedLocalCommit, .explicitlyAuthorizedPhase: .productSession
            }
            guard stage.actor == expectedActor else {
                throw ManagerRoutingError.storageCorrupt("A continuation stage has the wrong authority role.")
            }
        }
        guard stageIDs.contains(envelope.initialStageID) else {
            throw ManagerRoutingError.storageCorrupt("The initial continuation stage does not resolve.")
        }
        for stage in envelope.stages {
            if let next = stage.nextStageID, !stageIDs.contains(next) {
                throw ManagerRoutingError.storageCorrupt("A continuation next-stage edge does not resolve.")
            }
            if let correction = stage.correctionStageID, !stageIDs.contains(correction) {
                throw ManagerRoutingError.storageCorrupt("A continuation correction-stage edge does not resolve.")
            }
        }
        if let request {
            guard ManagerRoutingUTF8.equal(envelope.taskID, request.taskID),
                  ManagerRoutingUTF8.equal(envelope.managerThreadID, request.managerThreadID),
                  let initial = envelope.stages.first(where: { ManagerRoutingUTF8.equal($0.id, envelope.initialStageID) }),
                  ManagerRoutingUTF8.equal(initial.targetThreadID, request.targetThreadID),
                  ManagerRoutingUTF8.equal(initial.action, request.action),
                  ManagerRoutingUTF8.equal(initial.authorityReference, request.authorityReference) else {
                throw ManagerRoutingError.invalidInput("The initial route does not exactly match its standing continuation envelope.")
            }
        }
    }

    static func validate(_ route: ManagerRouteRecord) throws {
        guard route.schemaVersion == ManagerRouteRecord.schemaVersion,
              route.taskID.range(of: #"^TASK-[0-9]{4,}$"#, options: .regularExpression) != nil,
              thread(route.managerThreadID), thread(route.targetThreadID), line(route.action), line(route.authorityReference),
              route.createdAt < route.timeoutAt, route.updatedAt >= route.createdAt,
              route.transitions.first?.state == .queued, route.transitions.last?.state == route.state,
              route.transitions.map(\.occurredAt) == route.transitions.map(\.occurredAt).sorted(),
              route.updatedAt == route.transitions.last?.occurredAt else {
            throw ManagerRoutingError.storageCorrupt("A route envelope, identity, or transition history is invalid.")
        }
        for transition in route.transitions {
            guard line(transition.note) else { throw ManagerRoutingError.storageCorrupt("A route transition note is invalid.") }
        }
        for pair in zip(route.transitions, route.transitions.dropFirst()) {
            guard allowed(pair.0.state, pair.1.state) else {
                throw ManagerRoutingError.storageCorrupt("A route contains a non-monotonic or skipped transition.")
            }
        }
        let terminals = route.transitions.filter(\.state.isTerminalReceipt)
        guard terminals.count <= 1, (route.terminalHandoff == nil) == terminals.isEmpty else {
            throw ManagerRoutingError.storageCorrupt("A route must contain exactly one terminal handoff or none.")
        }
        if let handoff = route.terminalHandoff {
            guard line(handoff.summary), line(handoff.nextGate), !handoff.evidence.isEmpty,
                  !handoff.unperformedBoundaries.isEmpty,
                  handoff.evidence.allSatisfy(line), handoff.unperformedBoundaries.allSatisfy(line),
                  terminals.first?.state == handoff.classification.state else {
                throw ManagerRoutingError.storageCorrupt("The structured terminal handoff is incomplete or disagrees with its typed terminal transition.")
            }
            if handoff.ownerGate != nil, handoff.continuationDisposition != .ownerDecision {
                throw ManagerRoutingError.storageCorrupt("A genuine owner gate must route through the Architect decision disposition.")
            }
            if handoff.classification != .completed,
               handoff.continuationDisposition == .advance || handoff.continuationDisposition == .inScopeCorrection {
                throw ManagerRoutingError.storageCorrupt("A blocked or uncertain result cannot advance a continuation envelope.")
            }
            if let context = handoff.resultingContext { try validate(context) }
        }
        if route.state == .forwarded {
            let advancedIsBound = route.continuationEnvelopeUUID != nil
                ? route.nextAuthorizedRoute == nil
                : (route.nextAuthorizedRoute == nil && route.advancedRouteOperationUUID == nil) ||
                    route.nextAuthorizedRoute?.operationUUID == route.advancedRouteOperationUUID
            guard route.terminalHandoff?.classification == .completed, advancedIsBound else {
                throw ManagerRoutingError.storageCorrupt("A forwarded route does not exactly bind its completion or advanced route.")
            }
        }
        if route.state == .ownerDecisionRequired, route.advancedRouteOperationUUID != nil {
            throw ManagerRoutingError.storageCorrupt("An owner-decision route cannot advance a later gate.")
        }
        let acknowledgements = route.transitions.filter { $0.state == .deliveredAcknowledged }
        let runningTransitions = route.transitions.filter { $0.state == .running }
        let timestampsAreOrdered: Bool
        if let runningAt = route.runningAt, let acknowledgedAt = route.receiptAcknowledgedAt {
            timestampsAreOrdered = acknowledgedAt <= runningAt
        } else {
            timestampsAreOrdered = route.runningAt == nil
        }
        guard acknowledgements.count <= 1, runningTransitions.count <= 1,
              route.receiptAcknowledgedAt == acknowledgements.first?.occurredAt,
              route.runningAt == runningTransitions.first?.occurredAt,
              timestampsAreOrdered else {
            throw ManagerRoutingError.storageCorrupt("Acknowledgement or running timestamps disagree with durable transitions.")
        }
        guard hasRequiredMonitor(route) else {
            throw ManagerRoutingError.storageCorrupt("A route lacks its required live monitor, scheduled wake, or owner decision marker.")
        }
        if let next = route.nextAuthorizedRoute {
            guard next.operationUUID != route.operationUUID,
                  thread(next.targetThreadID), line(next.action), line(next.authorityReference),
                  secondPrecision(route.timeoutAt), secondPrecision(next.timeoutAt),
                  next.timeoutAt > route.timeoutAt else {
                throw ManagerRoutingError.storageCorrupt("The already-authorized next route envelope is invalid.")
            }
        } else if !secondPrecision(route.timeoutAt) {
            throw ManagerRoutingError.storageCorrupt("The route deadline is not exact whole-second data.")
        }
    }

    static func validateMonotonic(old: ManagerRouteRecord, new: ManagerRouteRecord) throws {
        guard old.schemaVersion == new.schemaVersion, old.operationUUID == new.operationUUID,
              ManagerRoutingUTF8.equal(old.taskID, new.taskID),
              ManagerRoutingUTF8.equal(old.managerThreadID, new.managerThreadID),
              ManagerRoutingUTF8.equal(old.targetThreadID, new.targetThreadID),
              ManagerRoutingUTF8.equal(old.action, new.action),
              ManagerRoutingUTF8.equal(old.authorityReference, new.authorityReference),
              old.createdAt == new.createdAt, old.timeoutAt == new.timeoutAt,
              equal(old.nextAuthorizedRoute, new.nextAuthorizedRoute),
              old.continuationEnvelopeUUID == new.continuationEnvelopeUUID,
              utf8Optional(old.continuationStageID, new.continuationStageID),
              old.predecessorOperationUUID == new.predecessorOperationUUID,
              utf8Optional(old.predecessorTerminalSHA256, new.predecessorTerminalSHA256),
              old.canonicalContext == new.canonicalContext,
              transitionPrefix(old.transitions, new.transitions),
              terminalIsSticky(old.terminalHandoff, new.terminalHandoff),
              old.advancedRouteOperationUUID == nil || old.advancedRouteOperationUUID == new.advancedRouteOperationUUID else {
            throw ManagerRoutingError.storageCorrupt("A routing transaction changed immutable bytes or rewrote durable history.")
        }
    }

    static func hasRequiredMonitor(_ route: ManagerRouteRecord) -> Bool {
        switch route.state {
        case .queued:
            route.monitor?.kind == .scheduledWake && route.monitor?.wakeAt == route.timeoutAt
        case .deliveredAcknowledged, .running:
            route.monitor?.kind == .liveTarget && route.monitor?.wakeAt == route.timeoutAt
        case .terminalCompleted, .terminalBlocked, .terminalUncertain:
            route.monitor?.kind == .scheduledWake && route.monitor?.wakeAt == route.updatedAt
        case .ownerDecisionRequired:
            route.monitor?.kind == .ownerDecision && route.monitor?.wakeAt == nil
        case .forwarded:
            route.monitor == nil
        }
    }

    private static func allowed(_ old: ManagerRouteState, _ new: ManagerRouteState) -> Bool {
        switch (old, new) {
        case (.queued, .deliveredAcknowledged), (.deliveredAcknowledged, .running),
             (.queued, .terminalCompleted), (.queued, .terminalBlocked), (.queued, .terminalUncertain),
             (.deliveredAcknowledged, .terminalCompleted), (.deliveredAcknowledged, .terminalBlocked), (.deliveredAcknowledged, .terminalUncertain),
             (.running, .terminalCompleted), (.running, .terminalBlocked), (.running, .terminalUncertain),
             (.terminalCompleted, .forwarded), (.terminalCompleted, .ownerDecisionRequired),
             (.terminalBlocked, .ownerDecisionRequired), (.terminalUncertain, .ownerDecisionRequired): true
        default: false
        }
    }

    private static func transitionPrefix(_ old: [ManagerRouteTransition], _ new: [ManagerRouteTransition]) -> Bool {
        guard new.count >= old.count else { return false }
        return zip(old, new.prefix(old.count)).allSatisfy {
            $0.state == $1.state && $0.occurredAt == $1.occurredAt && ManagerRoutingUTF8.equal($0.note, $1.note)
        }
    }

    private static func terminalIsSticky(_ old: ManagerTerminalHandoff?, _ new: ManagerTerminalHandoff?) -> Bool {
        guard let old else { return true }
        guard let new else { return false }
        return equal(old, new)
    }

    static func equal(_ lhs: ManagerTerminalHandoff, _ rhs: ManagerTerminalHandoff) -> Bool {
        lhs.classification == rhs.classification && ManagerRoutingUTF8.equal(lhs.summary, rhs.summary) &&
            equal(lhs.evidence, rhs.evidence) && ManagerRoutingUTF8.equal(lhs.nextGate, rhs.nextGate) &&
            equal(lhs.unperformedBoundaries, rhs.unperformedBoundaries) &&
            lhs.continuationDisposition == rhs.continuationDisposition && lhs.ownerGate == rhs.ownerGate &&
            lhs.resultingContext == rhs.resultingContext
    }

    static func selectedStageID(
        _ handoff: ManagerTerminalHandoff, from stage: ManagerContinuationStage
    ) -> String? {
        switch handoff.continuationDisposition {
        case .advance: stage.nextStageID
        case .inScopeCorrection: stage.correctionStageID
        case .none, .ownerDecision, .safeStop: nil
        }
    }

    static func validate(_ context: ManagerCanonicalContextBinding) throws {
        guard line(context.productionsRootPath),
              context.taskRegistrySHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              context.workspaceSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              context.canvasSHA256.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              line(context.taskLifecycle), line(context.taskPriority),
              !context.instructionSHA256.isEmpty,
              context.instructionSHA256.allSatisfy({ line($0.key) && $0.value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil }) else {
            throw ManagerRoutingError.storageCorrupt("A canonical continuation context binding is malformed.")
        }
    }

    private static func equal(_ lhs: ManagerAuthorizedNextRoute?, _ rhs: ManagerAuthorizedNextRoute?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (.some(lhs), .some(rhs)):
            lhs.operationUUID == rhs.operationUUID && ManagerRoutingUTF8.equal(lhs.targetThreadID, rhs.targetThreadID) &&
                ManagerRoutingUTF8.equal(lhs.action, rhs.action) && ManagerRoutingUTF8.equal(lhs.authorityReference, rhs.authorityReference) &&
                lhs.timeoutAt == rhs.timeoutAt
        default: false
        }
    }

    private static func equal(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy(ManagerRoutingUTF8.equal)
    }

    private static func utf8Optional(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (.some(lhs), .some(rhs)): ManagerRoutingUTF8.equal(lhs, rhs)
        default: false
        }
    }

    private static func thread(_ value: String) -> Bool {
        value.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) != nil
    }

    private static func line(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.contains("\n") && !value.contains("\r")
    }

    private static func secondPrecision(_ value: Date) -> Bool {
        value.timeIntervalSince1970 == floor(value.timeIntervalSince1970)
    }
}

enum ManagerRoutingUTF8 {
    static func equal(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
}

enum ManagerRoutingError: LocalizedError, Equatable {
    case invalidInput(String)
    case identityMismatch(String)
    case invalidTransition(String)
    case duplicateTerminal(String)
    case duplicateOperation(String)
    case notFound(String)
    case staleLedger(String)
    case storageCorrupt(String)
    case storageUncertain(String)
    case createStorageUncertain(UUID, String)
    case idleInvariant(String)

    var operationUUID: UUID? {
        if case let .createStorageUncertain(operationUUID, _) = self { return operationUUID }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case let .invalidInput(value), let .identityMismatch(value), let .invalidTransition(value),
             let .duplicateTerminal(value), let .duplicateOperation(value), let .notFound(value),
             let .staleLedger(value), let .storageCorrupt(value), let .storageUncertain(value),
             let .idleInvariant(value): value
        case let .createStorageUncertain(_, value): value
        }
    }
}

private extension JSONEncoder {
    static var managerRouting: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var managerRouting: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
