import CryptoKit
import Darwin
import Foundation

enum LifecyclePriorityRule: String, Codable, Equatable {
    case registryAuthoritative = "registry"
    case deterministicMaximum = "maximum"
}

enum ReconciliationDisposition: String, Codable, Equatable {
    case pending, confirmed, corrected
}

struct LifecyclePriorityRepair: Codable, Equatable, Identifiable {
    let field: String
    let registryValueBefore: String
    let workspaceValuesBefore: [String]
    let chosenValue: String
    let rule: String
    let provenance: String
    var id: String { field }
}

struct LifecyclePriorityRequest: Equatable {
    let workID: String
    let expectedRegistrySHA256: String
    let expectedWorkspaceSHA256: String
    let priorityRule: LifecyclePriorityRule
    let desiredLifecycle: String?
    let desiredPriority: String?
    let correctsOperation: UUID?
}

struct LifecyclePriorityPreview: Codable, Equatable {
    let workID: String
    let registryPath: String
    let workspacePath: String
    let registrySHA256Before: String
    let registrySHA256After: String
    let workspaceSHA256Before: String
    let workspaceSHA256After: String
    let lifecycle: String
    let priority: String
    let repairs: [LifecyclePriorityRepair]
    let confirmationToken: String
}

struct LifecyclePriorityCommandResult: Codable, Equatable {
    let outcome: String
    let operationUUID: UUID?
    let workID: String?
    let registrySHA256Before: String?
    let registrySHA256After: String?
    let workspaceSHA256Before: String?
    let workspaceSHA256After: String?
    let lifecycle: String?
    let priority: String?
    let repairs: [LifecyclePriorityRepair]?
    let queueDisposition: ReconciliationDisposition?
    let classification: String?
    let journalFinalized: Bool
    let fallbackRecorded: Bool
    let historicalCommitProven: Bool
    let inspectCommand: String?
    let diagnostic: String?
}

struct LifecyclePriorityQueueEntry: Codable, Equatable {
    let operationUUID: UUID
    let workID: String
    let workTitle: String
    let occurredAt: Date
    let ageSeconds: Int
    let repairs: [LifecyclePriorityRepair]
    let disposition: ReconciliationDisposition
    let journalFinalized: Bool
    let fallbackRecorded: Bool
    let historicalCommitProven: Bool
}

enum ReconciliationQueueJournalKind: String, Equatable {
    case lifecyclePriority = "lifecycle-priority-reconciliation"
    case taskCheckpoint = "task-checkpoint"
    case acceptedHandoff = "accepted-handoff"
}

struct ReconciliationQueueRecord: Equatable {
    let kind: ReconciliationQueueJournalKind
    let operationUUID: UUID
    let productionsRootPath: String
    let workID: String
    let workTitle: String
    let registryPath: String
    let occurredAt: Date
    let lifecycle: String
    let priority: String
    let priorityRule: LifecyclePriorityRule
    let repairs: [LifecyclePriorityRepair]
    let disposition: ReconciliationDisposition
    let journalFinalized: Bool
    let fallbackRecorded: Bool
    let historicalCommitProven: Bool
}

protocol ReconciliationQueueResolving {
    func resolve(operationID: UUID, productionsRootPath: String) throws -> ReconciliationQueueRecord
    func pendingEntries(productionsRootPath: String, now: Date) throws -> [LifecyclePriorityQueueEntry]
    func acknowledge(operationID: UUID, productionsRootPath: String) throws -> ReconciliationQueueRecord
    func markCorrected(operationID: UUID, correctedBy: UUID, productionsRootPath: String, workID: String) throws
    func recoverCommittedCorrections(productionsRootPath: String) throws
    func reserveCorrection(operationID: UUID, productionsRootPath: String, workID: String) throws -> AnyObject
}

extension ReconciliationQueueResolving {
    func reserveCorrection(operationID: UUID, productionsRootPath: String, workID: String) throws -> AnyObject {
        throw LifecyclePriorityValidationError.targetContractInvalid("This queue resolver cannot reserve a correction target.")
    }
}

struct LifecyclePriorityCommandFailure: Error, Equatable {
    let result: LifecyclePriorityCommandResult
    let exitCode: Int32
}

enum LifecyclePriorityValidationError: LocalizedError, Equatable {
    case invalidInput(String)
    case hashMismatch(String)
    case targetContractInvalid(String)
    case confirmationMismatch
    case lockUnavailable
    case journalCreateFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(value), let .hashMismatch(value), let .targetContractInvalid(value): value
        case .confirmationMismatch: "The confirmation token does not bind the current complete preview."
        case .lockUnavailable: "The Registry-and-Workspace writer lock is unavailable."
        case let .journalCreateFailed(value): "The initial recovery journal could not be created: \(value)"
        }
    }
}

struct LifecyclePriorityJournal: Codable, Equatable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let operationUUID: UUID
    let operationKind: String
    let productionsRootPath: String
    let workID: String
    let workTitle: String
    let registryPath: String
    let workspacePath: String
    let timestamp: Date
    let registrySHA256Before: String
    let registryPreimage: Data
    let registrySHA256ExpectedAfter: String
    let registryExpectedAfter: Data
    let workspaceSHA256Before: String
    let workspacePreimage: Data
    let workspaceSHA256ExpectedAfter: String
    let workspaceExpectedAfter: Data
    let lifecycle: String
    let priority: String
    let priorityRule: LifecyclePriorityRule
    let repairs: [LifecyclePriorityRepair]
    let correctsOperation: UUID?
    private(set) var queueDisposition: ReconciliationDisposition
    private(set) var terminalState: OfficeWorkspaceTerminalState?
    private(set) var journalFinalized: Bool
    private(set) var fallbackRecorded: Bool
    private(set) var diagnostic: String?

    mutating func transition(to proposed: OfficeWorkspaceTerminalState, diagnostic: String?, finalized: Bool) {
        terminalState = .merging(current: terminalState, proposed: proposed)
        journalFinalized = finalized
        self.diagnostic = diagnostic
    }

    mutating func markFallback(_ state: OfficeWorkspaceTerminalState, diagnostic: String) {
        terminalState = .merging(current: terminalState, proposed: state)
        journalFinalized = false
        fallbackRecorded = true
        self.diagnostic = diagnostic
    }

    mutating func acknowledge() { queueDisposition = .confirmed }
    mutating func markCorrected() { queueDisposition = .corrected }
    mutating func preserveQueueDisposition(_ value: ReconciliationDisposition) { queueDisposition = value }
}

protocol LifecyclePriorityJournalStore {
    func persist(_ journal: LifecyclePriorityJournal) throws
    func update(_ journal: LifecyclePriorityJournal) throws
    func recordFallback(_ journal: LifecyclePriorityJournal) throws
    func journal(operationID: UUID) throws -> LifecyclePriorityJournal?
    func all(productionsRootPath: String) throws -> [LifecyclePriorityJournal]
    func incomplete() throws -> [LifecyclePriorityJournal]
    func pending(productionsRootPath: String) throws -> [LifecyclePriorityJournal]
}

extension LifecyclePriorityJournalStore {
    func all(productionsRootPath: String) throws -> [LifecyclePriorityJournal] {
        try pending(productionsRootPath: productionsRootPath)
    }
    func incomplete() throws -> [LifecyclePriorityJournal] { [] }
}

struct ApplicationSupportLifecyclePriorityJournalStore: LifecyclePriorityJournalStore, @unchecked Sendable {
    private let manager: FileManager
    private let directoryOverride: URL?

    init(manager: FileManager = .default, directory: URL? = nil) {
        self.manager = manager
        directoryOverride = directory
    }

    var directory: URL {
        directoryOverride ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/Office Workspace Transaction Recovery", directoryHint: .isDirectory)
    }

    func persist(_ journal: LifecyclePriorityJournal) throws {
        try validateEnvelope(journal)
        guard journal.terminalState == nil, !journal.journalFinalized, !journal.fallbackRecorded,
              journal.queueDisposition == (journal.repairs.isEmpty ? .confirmed : .pending), journal.diagnostic == nil else {
            throw LifecyclePriorityValidationError.journalCreateFailed("Initial journal flags are invalid.")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try OfficeJournalAtomicCoordinator.withLock(directory: directory) {
            guard try matching(operationID: journal.operationUUID).isEmpty else {
                throw LifecyclePriorityValidationError.journalCreateFailed("The operation UUID already has a journal.")
            }
            try writeNew(journal)
        }
    }

    func update(_ journal: LifecyclePriorityJournal) throws {
        try validateEnvelope(journal)
        try OfficeJournalAtomicCoordinator.withLock(directory: directory) {
            let (url, bytes, durable) = try durableSnapshot(operationID: journal.operationUUID)
            var merged = journal
            if merged.terminalState != durable.terminalState, merged.queueDisposition != durable.queueDisposition {
                merged.preserveQueueDisposition(durable.queueDisposition)
            }
            try validateUpdate(merged, from: durable, fallback: false)
            try compareAndReplace(merged, expectedBytes: bytes, at: url)
        }
    }

    func recordFallback(_ journal: LifecyclePriorityJournal) throws {
        try validateEnvelope(journal)
        try OfficeJournalAtomicCoordinator.withLock(directory: directory) {
            let (url, bytes, durable) = try durableSnapshot(operationID: journal.operationUUID)
            var merged = journal
            if merged.terminalState != durable.terminalState, merged.queueDisposition != durable.queueDisposition {
                merged.preserveQueueDisposition(durable.queueDisposition)
            }
            try validateUpdate(merged, from: durable, fallback: true)
            try compareAndReplace(merged, expectedBytes: bytes, at: url)
        }
    }

    func journal(operationID: UUID) throws -> LifecyclePriorityJournal? {
        let matches = try matching(operationID: operationID)
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1,
              TaskCheckpointUTF8.equal(matches[0].lastPathComponent, "\(operationID.uuidString).json") else {
            throw LifecyclePriorityValidationError.targetContractInvalid("The journal filename does not exactly bind its UUID.")
        }
        var status = stat()
        guard lstat(matches[0].path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw LifecyclePriorityValidationError.targetContractInvalid("The journal is not a non-followed regular file.")
        }
        let journal = try JSONDecoder.officeJournal.decode(LifecyclePriorityJournal.self, from: Data(contentsOf: matches[0]))
        guard journal.operationUUID == operationID else {
            throw LifecyclePriorityValidationError.targetContractInvalid("The journal payload UUID does not match its filename.")
        }
        try validateEnvelope(journal)
        return journal
    }

    func all(productionsRootPath: String) throws -> [LifecyclePriorityJournal] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                var status = stat()
                guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A recovery journal is not a non-followed regular file.")
                }
                let data = try Data(contentsOf: url)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawKind = object["operationKind"] as? String,
                      let kind = ReconciliationQueueJournalKind(rawValue: rawKind) else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A recovery journal has a malformed or unsupported operation kind.")
                }
                guard kind == .lifecyclePriority else { return nil }
                guard let operationID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      TaskCheckpointUTF8.equal(url.lastPathComponent, "\(operationID.uuidString).json"),
                      let journal = try self.journal(operationID: operationID) else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A lifecycle recovery journal filename or payload is invalid.")
                }
                guard TaskCheckpointUTF8.equal(journal.productionsRootPath, productionsRootPath) else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A lifecycle recovery journal root does not match the supplied root.")
                }
                return journal
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func incomplete() throws -> [LifecyclePriorityJournal] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                var status = stat()
                guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A startup recovery journal is not a non-followed regular file.")
                }
                let data = try Data(contentsOf: url)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawKind = object["operationKind"] as? String,
                      let kind = ReconciliationQueueJournalKind(rawValue: rawKind) else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A startup recovery journal has a malformed or unsupported operation kind.")
                }
                guard kind == .lifecyclePriority else { return nil }
                guard let operationID = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      TaskCheckpointUTF8.equal(url.lastPathComponent, "\(operationID.uuidString).json"),
                      let journal = try self.journal(operationID: operationID) else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A startup lifecycle journal filename or payload is invalid.")
                }
                return journal.terminalState == nil || journal.terminalState?.isStartupIncomplete == true ? journal : nil
            }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func pending(productionsRootPath: String) throws -> [LifecyclePriorityJournal] {
        try all(productionsRootPath: productionsRootPath).filter {
            $0.terminalState?.provesHistoricalCommit == true && !$0.repairs.isEmpty && $0.queueDisposition == .pending
        }
    }

    private func matching(operationID: UUID) throws -> [URL] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let expected = "\(operationID.uuidString).json"
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.caseInsensitiveCompare(expected) == .orderedSame }
    }

    private func writeNew(_ journal: LifecyclePriorityJournal) throws {
        let data = try JSONEncoder.officeJournal.encode(journal)
        let url = directory.appending(path: "\(journal.operationUUID.uuidString).json")
        try DurableReplacement(manager: manager).replace(data: data, at: url)
        guard try OfficeJournalAtomicCoordinator.readRegular(url) == data else {
            throw LifecyclePriorityValidationError.journalCreateFailed("The initial durable journal failed exact reload validation.")
        }
    }

    private func durableSnapshot(operationID: UUID) throws -> (URL, Data, LifecyclePriorityJournal) {
        let matches = try matching(operationID: operationID)
        guard matches.count == 1, TaskCheckpointUTF8.equal(matches[0].lastPathComponent, "\(operationID.uuidString).json") else {
            throw LifecyclePriorityValidationError.targetContractInvalid("The bound recovery journal is unavailable or ambiguous.")
        }
        let bytes = try OfficeJournalAtomicCoordinator.readRegular(matches[0])
        let durable = try JSONDecoder.officeJournal.decode(LifecyclePriorityJournal.self, from: bytes)
        try validateEnvelope(durable)
        return (matches[0], bytes, durable)
    }

    private func compareAndReplace(_ journal: LifecyclePriorityJournal, expectedBytes: Data, at url: URL) throws {
        try OfficeJournalAtomicCoordinator.replaceIfUnchanged(
            expectedDurableBytes: expectedBytes, proposedBytes: try JSONEncoder.officeJournal.encode(journal), at: url, manager: manager
        )
    }

    private func validateEnvelope(_ value: LifecyclePriorityJournal) throws {
        let hash = { (data: Data) in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard value.schemaVersion == LifecyclePriorityJournal.schemaVersion, value.operationKind == "lifecycle-priority-reconciliation",
              TaskCheckpointCanonicalRoot.isExact(value.productionsRootPath),
              value.workID.range(of: #"^(TASK|IDEA|PROJ|INIT)-[0-9]{4,}$"#, options: .regularExpression) != nil,
              !value.workTitle.isEmpty,
              value.registryPath.hasPrefix("Office/Registry/"),
              value.workspacePath == "Workspace/\(value.workID)/\(value.workID).md",
              hash(value.registryPreimage) == value.registrySHA256Before,
              hash(value.registryExpectedAfter) == value.registrySHA256ExpectedAfter,
              hash(value.workspacePreimage) == value.workspaceSHA256Before,
              hash(value.workspaceExpectedAfter) == value.workspaceSHA256ExpectedAfter else {
            throw LifecyclePriorityValidationError.targetContractInvalid("The journal immutable envelope is invalid.")
        }
        switch value.terminalState {
        case nil:
            guard !value.journalFinalized, !value.fallbackRecorded else { throw LifecyclePriorityValidationError.targetContractInvalid("A nonterminal journal has terminal flags.") }
        case let state?:
            if state.hasFallback {
                guard !value.journalFinalized, value.fallbackRecorded else { throw LifecyclePriorityValidationError.targetContractInvalid("Fallback terminal flags are invalid.") }
            } else {
                guard value.journalFinalized, !value.fallbackRecorded else { throw LifecyclePriorityValidationError.targetContractInvalid("Normal terminal flags are invalid.") }
            }
        }
        guard value.repairs.isEmpty ? value.queueDisposition == .confirmed : true else {
            throw LifecyclePriorityValidationError.targetContractInvalid("A non-repair operation cannot enter the review queue.")
        }
    }

    private func validateUpdate(_ proposed: LifecyclePriorityJournal, from durable: LifecyclePriorityJournal, fallback: Bool) throws {
        // Compare the immutable fields explicitly; terminal/diagnostic/disposition are the only mutable envelope members.
        guard proposed.schemaVersion == durable.schemaVersion, proposed.operationUUID == durable.operationUUID,
              TaskCheckpointUTF8.equal(proposed.operationKind, durable.operationKind),
              TaskCheckpointUTF8.equal(proposed.productionsRootPath, durable.productionsRootPath),
              TaskCheckpointUTF8.equal(proposed.workID, durable.workID),
              TaskCheckpointUTF8.equal(proposed.workTitle, durable.workTitle),
              TaskCheckpointUTF8.equal(proposed.registryPath, durable.registryPath),
              TaskCheckpointUTF8.equal(proposed.workspacePath, durable.workspacePath),
              proposed.timestamp == durable.timestamp,
              proposed.registryPreimage == durable.registryPreimage,
              TaskCheckpointUTF8.equal(proposed.registrySHA256Before, durable.registrySHA256Before),
              TaskCheckpointUTF8.equal(proposed.registrySHA256ExpectedAfter, durable.registrySHA256ExpectedAfter),
              proposed.registryExpectedAfter == durable.registryExpectedAfter,
              proposed.workspacePreimage == durable.workspacePreimage,
              TaskCheckpointUTF8.equal(proposed.workspaceSHA256Before, durable.workspaceSHA256Before),
              TaskCheckpointUTF8.equal(proposed.workspaceSHA256ExpectedAfter, durable.workspaceSHA256ExpectedAfter),
              proposed.workspaceExpectedAfter == durable.workspaceExpectedAfter,
              proposed.lifecycle == durable.lifecycle, proposed.priority == durable.priority,
              proposed.priorityRule == durable.priorityRule, proposed.repairs == durable.repairs,
              proposed.correctsOperation == durable.correctsOperation else {
            throw LifecyclePriorityValidationError.targetContractInvalid("A journal update substituted an immutable operation-envelope field.")
        }
        let dispositionChanged = proposed.queueDisposition != durable.queueDisposition
        if dispositionChanged {
            guard durable.terminalState?.provesHistoricalCommit == true,
                  durable.queueDisposition == .pending,
                  proposed.queueDisposition == .confirmed || proposed.queueDisposition == .corrected else {
                throw LifecyclePriorityValidationError.targetContractInvalid("The reconciliation disposition transition is invalid.")
            }
        }
        let terminalChanged = proposed.terminalState != durable.terminalState
        if dispositionChanged, terminalChanged {
            throw LifecyclePriorityValidationError.targetContractInvalid("Queue disposition and terminal proof cannot change in one journal update.")
        }
        if fallback {
            guard proposed.fallbackRecorded, !proposed.journalFinalized, proposed.terminalState?.hasFallback == true else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Fallback state and update method disagree.")
            }
        } else if terminalChanged {
            guard let terminal = proposed.terminalState,
                  terminal == OfficeWorkspaceTerminalState.merging(current: durable.terminalState, proposed: terminal),
                  proposed.journalFinalized, !proposed.fallbackRecorded else {
                throw LifecyclePriorityValidationError.targetContractInvalid("The journal terminal transition is not monotonic.")
            }
        } else {
            guard proposed.journalFinalized == durable.journalFinalized,
                  proposed.fallbackRecorded == durable.fallbackRecorded,
                  proposed.diagnostic == durable.diagnostic else {
                throw LifecyclePriorityValidationError.targetContractInvalid("A queue-only update changed terminal proof flags or diagnostics.")
            }
        }
        guard !durable.fallbackRecorded || proposed.fallbackRecorded,
              !(durable.terminalState?.provesHistoricalCommit == true && proposed.terminalState?.provesHistoricalCommit != true) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Historical proof and fallback markers are sticky.")
        }
    }
}

/// One typed resolver owns every reconciliation-queue transition regardless of
/// which canonical writer originated the durable journal. The recovery
/// directory itself is the cross-process serialization object; journal stores
/// still perform their own immutable-envelope/CAS validation before rewriting.
enum ReconciliationForeignRootPolicy: Equatable, Sendable {
    case reject
    case ignoreValidExactRootForReadOnlyStatus
}

struct ApplicationSupportReconciliationQueueResolver: ReconciliationQueueResolving, @unchecked Sendable {
    private let manager: FileManager
    private let directory: URL
    private let foreignRootPolicy: ReconciliationForeignRootPolicy

    init(
        manager: FileManager = .default, directory: URL? = nil,
        foreignRootPolicy: ReconciliationForeignRootPolicy = .reject
    ) {
        self.manager = manager
        self.directory = directory ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/Office Workspace Transaction Recovery", directoryHint: .isDirectory)
        self.foreignRootPolicy = foreignRootPolicy
    }

    func resolve(operationID: UUID, productionsRootPath: String) throws -> ReconciliationQueueRecord {
        try withQueueLock { try resolveLocked(operationID: operationID, productionsRootPath: productionsRootPath) }
    }

    func pendingEntries(productionsRootPath: String, now: Date) throws -> [LifecyclePriorityQueueEntry] {
        guard TaskCheckpointCanonicalRoot.isExact(productionsRootPath) else {
            throw LifecyclePriorityValidationError.invalidInput("The supplied Productions root is not exact.")
        }
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try withQueueLock {
            try recoverCommittedCorrectionsLocked(productionsRootPath: productionsRootPath)
            return try journalDescriptors().compactMap { descriptor in
                guard let record = try resolveOptionalLocked(
                    descriptor: descriptor, productionsRootPath: productionsRootPath
                ) else { return nil }
                guard record.historicalCommitProven, !record.repairs.isEmpty, record.disposition == .pending else { return nil }
                return LifecyclePriorityQueueEntry(
                    operationUUID: record.operationUUID, workID: record.workID, workTitle: record.workTitle,
                    occurredAt: record.occurredAt, ageSeconds: max(0, Int(now.timeIntervalSince(record.occurredAt))),
                    repairs: record.repairs, disposition: record.disposition,
                    journalFinalized: record.journalFinalized, fallbackRecorded: record.fallbackRecorded,
                    historicalCommitProven: record.historicalCommitProven
                )
            }.sorted { $0.occurredAt < $1.occurredAt }
        }
    }

    func acknowledge(operationID: UUID, productionsRootPath: String) throws -> ReconciliationQueueRecord {
        try withQueueLock {
            let descriptor = try descriptor(operationID: operationID)
            var record = try resolveLocked(descriptor: descriptor, productionsRootPath: productionsRootPath)
            guard record.historicalCommitProven, !record.repairs.isEmpty else {
                throw LifecyclePriorityValidationError.targetContractInvalid("The operation is not a proven reconciliation queue entry.")
            }
            if record.disposition == .pending {
                switch descriptor.kind {
                case .lifecyclePriority:
                    let store = ApplicationSupportLifecyclePriorityJournalStore(manager: manager, directory: directory)
                    guard var journal = try store.journal(operationID: operationID) else { throw unavailable(operationID) }
                    journal.acknowledge(); try store.update(journal)
                case .taskCheckpoint:
                    let store = ApplicationSupportTaskCheckpointJournalStore(manager: manager, directory: directory)
                    guard var journal = try store.journal(operationID: operationID) else { throw unavailable(operationID) }
                    journal.acknowledgeReconciliation(); try store.update(journal)
                case .acceptedHandoff:
                    let store = ApplicationSupportAcceptedHandoffJournalStore(manager: manager, directory: directory)
                    guard var journal = try store.journal(operationID: operationID) else { throw unavailable(operationID) }
                    journal.acknowledgeReconciliation(); try store.update(journal)
                }
                record = try resolveLocked(descriptor: descriptor, productionsRootPath: productionsRootPath)
            }
            guard record.disposition == .confirmed else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Only a pending queue entry can be acknowledged.")
            }
            return record
        }
    }

    func markCorrected(operationID: UUID, correctedBy: UUID, productionsRootPath: String, workID: String) throws {
        try withQueueLock {
            let descriptor = try descriptor(operationID: operationID)
            let record = try resolveLocked(descriptor: descriptor, productionsRootPath: productionsRootPath)
            guard record.historicalCommitProven, record.disposition == .pending,
                  TaskCheckpointUTF8.equal(record.workID, workID), operationID != correctedBy else {
                throw LifecyclePriorityValidationError.targetContractInvalid("The committed correction does not bind a different proven pending entry for the same work.")
            }
            switch descriptor.kind {
            case .lifecyclePriority:
                let store = ApplicationSupportLifecyclePriorityJournalStore(manager: manager, directory: directory)
                guard var journal = try store.journal(operationID: operationID) else { throw unavailable(operationID) }
                journal.markCorrected(); try store.update(journal)
            case .taskCheckpoint:
                let store = ApplicationSupportTaskCheckpointJournalStore(manager: manager, directory: directory)
                guard var journal = try store.journal(operationID: operationID) else { throw unavailable(operationID) }
                journal.markReconciliationCorrected(); try store.update(journal)
            case .acceptedHandoff:
                let store = ApplicationSupportAcceptedHandoffJournalStore(manager: manager, directory: directory)
                guard var journal = try store.journal(operationID: operationID) else { throw unavailable(operationID) }
                journal.markReconciliationCorrected(); try store.update(journal)
            }
            let durable = try resolveLocked(descriptor: descriptor, productionsRootPath: productionsRootPath)
            guard durable.disposition == .corrected else {
                throw LifecyclePriorityValidationError.targetContractInvalid("The corrected queue disposition did not persist.")
            }
        }
    }

    func recoverCommittedCorrections(productionsRootPath: String) throws {
        guard manager.fileExists(atPath: directory.path) else { return }
        try withQueueLock { try recoverCommittedCorrectionsLocked(productionsRootPath: productionsRootPath) }
    }

    func reserveCorrection(operationID: UUID, productionsRootPath: String, workID: String) throws -> AnyObject {
        let token = try OfficeJournalAtomicCoordinator.acquire(directory: directory)
        do {
            let record = try resolveLocked(operationID: operationID, productionsRootPath: productionsRootPath)
            guard record.historicalCommitProven, record.disposition == .pending,
                  TaskCheckpointUTF8.equal(record.workID, workID) else {
                throw LifecyclePriorityValidationError.targetContractInvalid("The correction target is not one proven pending queue entry for this work.")
            }
            return token
        } catch {
            _ = token
            throw error
        }
    }

    private struct Descriptor {
        let operationID: UUID
        let kind: ReconciliationQueueJournalKind
    }

    private struct CorrectionRecoveryPlan {
        let prior: Descriptor
        let correctionID: UUID
        let productionsRootPath: String
        let workID: String
    }

    private func recoverCommittedCorrectionsLocked(productionsRootPath: String) throws {
        var plans: [CorrectionRecoveryPlan] = []
        var claimedPriors = Set<UUID>()
        for correctionDescriptor in try journalDescriptors() where correctionDescriptor.kind == .lifecyclePriority {
            let store = ApplicationSupportLifecyclePriorityJournalStore(manager: manager, directory: directory)
            guard let correction = try store.journal(operationID: correctionDescriptor.operationID) else { throw unavailable(correctionDescriptor.operationID) }
            guard correction.terminalState?.provesHistoricalCommit == true, let corrected = correction.correctsOperation else { continue }
            let correctionRecord = try lifecycleRecord(correction)
            if !TaskCheckpointUTF8.equal(correctionRecord.productionsRootPath, productionsRootPath) {
                guard TaskCheckpointCanonicalRoot.isExact(correctionRecord.productionsRootPath) else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A committed correction contains a malformed queue root.")
                }
                continue
            }
            guard correctionRecord.historicalCommitProven else {
                throw LifecyclePriorityValidationError.targetContractInvalid("A committed correction does not semantically bind this queue root.")
            }
            let prior = try resolveLocked(operationID: corrected, productionsRootPath: productionsRootPath)
            guard TaskCheckpointUTF8.equal(prior.workID, correction.workID), prior.disposition != .confirmed else {
                throw LifecyclePriorityValidationError.targetContractInvalid("A committed correction does not bind an eligible prior queue entry.")
            }
            if prior.disposition == .pending {
                guard claimedPriors.insert(corrected).inserted else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("Multiple committed corrections claim the same pending queue entry.")
                }
                plans.append(.init(prior: try descriptor(operationID: corrected), correctionID: correction.operationUUID,
                                   productionsRootPath: productionsRootPath, workID: correction.workID))
            }
        }
        // No queue disposition changes until every correction and target has
        // produced one complete semantic, bytewise-root-bound recovery plan.
        for plan in plans {
            try markCorrectedLocked(descriptor: plan.prior, correctedBy: plan.correctionID,
                                    productionsRootPath: plan.productionsRootPath, workID: plan.workID)
        }
    }

    private func markCorrectedLocked(descriptor: Descriptor, correctedBy: UUID, productionsRootPath: String, workID: String) throws {
        let record = try resolveLocked(descriptor: descriptor, productionsRootPath: productionsRootPath)
        guard record.historicalCommitProven, record.disposition == .pending,
              TaskCheckpointUTF8.equal(record.workID, workID), record.operationUUID != correctedBy else {
            throw LifecyclePriorityValidationError.targetContractInvalid("The correction recovery target is not one different proven pending entry.")
        }
        switch descriptor.kind {
        case .lifecyclePriority:
            let store = ApplicationSupportLifecyclePriorityJournalStore(manager: manager, directory: directory)
            guard var value = try store.journal(operationID: descriptor.operationID) else { throw unavailable(descriptor.operationID) }
            value.markCorrected(); try store.update(value)
        case .taskCheckpoint:
            let store = ApplicationSupportTaskCheckpointJournalStore(manager: manager, directory: directory)
            guard var value = try store.journal(operationID: descriptor.operationID) else { throw unavailable(descriptor.operationID) }
            value.markReconciliationCorrected(); try store.update(value)
        case .acceptedHandoff:
            let store = ApplicationSupportAcceptedHandoffJournalStore(manager: manager, directory: directory)
            guard var value = try store.journal(operationID: descriptor.operationID) else { throw unavailable(descriptor.operationID) }
            value.markReconciliationCorrected(); try store.update(value)
        }
    }

    private func resolveLocked(operationID: UUID, productionsRootPath: String) throws -> ReconciliationQueueRecord {
        try resolveLocked(descriptor: descriptor(operationID: operationID), productionsRootPath: productionsRootPath)
    }

    private func resolveLocked(descriptor: Descriptor, productionsRootPath: String) throws -> ReconciliationQueueRecord {
        guard let record = try resolveOptionalLocked(descriptor: descriptor, productionsRootPath: productionsRootPath) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("The typed writer journal has no reconciliation queue entry.")
        }
        return record
    }

    private func resolveOptionalLocked(
        descriptor: Descriptor, productionsRootPath: String
    ) throws -> ReconciliationQueueRecord? {
        let record: ReconciliationQueueRecord?
        switch descriptor.kind {
        case .lifecyclePriority:
            guard let journal = try ApplicationSupportLifecyclePriorityJournalStore(manager: manager, directory: directory).journal(operationID: descriptor.operationID) else { throw unavailable(descriptor.operationID) }
            record = try lifecycleRecord(journal)
        case .taskCheckpoint:
            guard let journal = try ApplicationSupportTaskCheckpointJournalStore(manager: manager, directory: directory).journal(operationID: descriptor.operationID) else { throw unavailable(descriptor.operationID) }
            record = journal.lifecyclePriorityRepairs?.isEmpty == false ? try checkpointRecord(journal) : nil
        case .acceptedHandoff:
            guard let journal = try ApplicationSupportAcceptedHandoffJournalStore(manager: manager, directory: directory).journal(operationID: descriptor.operationID) else { throw unavailable(descriptor.operationID) }
            record = journal.lifecyclePriorityRepairs?.isEmpty == false ? try handoffRecord(journal) : nil
        }
        guard let record else { return nil }
        guard TaskCheckpointUTF8.equal(record.productionsRootPath, productionsRootPath) else {
            if foreignRootPolicy == .ignoreValidExactRootForReadOnlyStatus,
               TaskCheckpointCanonicalRoot.isExact(record.productionsRootPath) {
                return nil
            }
            throw LifecyclePriorityValidationError.targetContractInvalid("The queue journal Productions root does not bytewise match the supplied root.")
        }
        return record
    }

    private func lifecycleRecord(_ journal: LifecyclePriorityJournal) throws -> ReconciliationQueueRecord {
        let kind = try LifecyclePriorityKind(id: journal.workID)
        guard TaskCheckpointUTF8.equal(journal.registryPath, kind.registryPath),
              TaskCheckpointUTF8.equal(journal.workspacePath, "Workspace/\(journal.workID)/\(journal.workID).md") else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Lifecycle queue paths do not match the durable record kind.")
        }
        let preRegistry = try LifecyclePriorityRegistryDocument(data: journal.registryPreimage, kind: kind, workID: journal.workID)
        let preWorkspace = try LifecyclePriorityWorkspace(data: journal.workspacePreimage, kind: kind, workID: journal.workID, registryRow: preRegistry.row)
        let postRegistry = try LifecyclePriorityRegistryDocument(data: journal.registryExpectedAfter, kind: kind, workID: journal.workID)
        let postWorkspace = try LifecyclePriorityWorkspace(data: journal.workspaceExpectedAfter, kind: kind, workID: journal.workID, registryRow: postRegistry.row)
        let preLifecycle = preRegistry.row[kind.stateHeader]!, prePriority = preRegistry.row["Priority"]!
        let postLifecycle = postRegistry.row[kind.stateHeader]!, postPriority = postRegistry.row["Priority"]!
        guard TaskCheckpointUTF8.equal(journal.workTitle, preRegistry.row["Title"]!),
              TaskCheckpointUTF8.equal(journal.lifecycle, postLifecycle), TaskCheckpointUTF8.equal(journal.priority, postPriority),
              lifecycleRepairsAreDerived(journal.repairs, preLifecycle: preLifecycle, postLifecycle: postLifecycle,
                                         workspaceLifecycles: preWorkspace.lifecycleValues, prePriority: prePriority,
                                         postPriority: postPriority, workspacePriorities: preWorkspace.priorityValuesFound,
                                         priorityRule: journal.priorityRule),
              postWorkspace.lifecycleValues.allSatisfy({ TaskCheckpointUTF8.equal($0, postLifecycle) }),
              postWorkspace.priorityValuesFound.allSatisfy({ TaskCheckpointUTF8.equal($0, postPriority) }) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Lifecycle queue metadata is not derivable from its bound pre/postimages.")
        }
        return record(kind: .lifecyclePriority, operationID: journal.operationUUID, root: journal.productionsRootPath,
                      workID: journal.workID, title: journal.workTitle, registryPath: journal.registryPath, occurredAt: journal.timestamp,
                      lifecycle: journal.lifecycle, priority: journal.priority, rule: journal.priorityRule, repairs: journal.repairs,
                      disposition: journal.queueDisposition, terminal: journal.terminalState,
                      journalFinalized: journal.journalFinalized, fallbackRecorded: journal.fallbackRecorded)
    }

    private func checkpointRecord(_ journal: TaskCheckpointJournal) throws -> ReconciliationQueueRecord {
        guard let repairs = journal.lifecyclePriorityRepairs, !repairs.isEmpty,
              let title = journal.reconciliationWorkTitle, let lifecycle = journal.reconciliationLifecycle,
              let priority = journal.reconciliationPriority, let rule = journal.reconciliationPriorityRule,
              let disposition = journal.reconciliationQueueDisposition else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Checkpoint journal is not a complete reconciliation queue entry.")
        }
        let plan = try LifecyclePriorityMirrorReconciler.task(registryData: journal.registryPreimage, workspaceData: journal.workspacePreimage, taskID: journal.taskID)
        let registry = try LifecyclePriorityRegistryDocument(data: journal.registryPreimage, kind: .task, workID: journal.taskID)
        let post = try LifecyclePriorityWorkspace(data: journal.workspaceExpectedAfter, kind: .task, workID: journal.taskID, registryRow: registry.row)
        guard TaskCheckpointUTF8.equal(journal.registryPath, LifecyclePriorityKind.task.registryPath),
              TaskCheckpointUTF8.equal(title, plan.workTitle), TaskCheckpointUTF8.equal(lifecycle, plan.lifecycle),
              TaskCheckpointUTF8.equal(priority, plan.priority), rule == plan.priorityRule, repairsEqual(repairs, plan.repairs),
              post.lifecycleValues.allSatisfy({ TaskCheckpointUTF8.equal($0, lifecycle) }),
              post.priorityValuesFound.allSatisfy({ TaskCheckpointUTF8.equal($0, priority) }) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Checkpoint queue metadata is not derivable from its bound pre/postimages.")
        }
        return record(kind: .taskCheckpoint, operationID: journal.operationUUID, root: journal.productionsRootPath,
                      workID: journal.taskID, title: title, registryPath: journal.registryPath, occurredAt: journal.timestamp,
                      lifecycle: lifecycle, priority: priority, rule: rule, repairs: repairs, disposition: disposition,
                      terminal: journal.terminalState, journalFinalized: journal.journalFinalized, fallbackRecorded: journal.fallbackRecorded)
    }

    private func handoffRecord(_ journal: AcceptedHandoffJournal) throws -> ReconciliationQueueRecord {
        guard let repairs = journal.lifecyclePriorityRepairs, !repairs.isEmpty,
              let title = journal.reconciliationWorkTitle, let lifecycle = journal.reconciliationLifecycle,
              let priority = journal.reconciliationPriority, let rule = journal.reconciliationPriorityRule,
              let disposition = journal.reconciliationQueueDisposition,
              let occurredAt = AcceptedHandoffService.exactTimestamp(journal.acceptedAt) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Accepted-handoff journal is not a complete reconciliation queue entry.")
        }
        let plan = try LifecyclePriorityMirrorReconciler.task(registryData: journal.registryPreimage, workspaceData: journal.workspacePreimage, taskID: journal.sourceID)
        let registry = try LifecyclePriorityRegistryDocument(data: journal.registryPreimage, kind: .task, workID: journal.sourceID)
        let post = try LifecyclePriorityWorkspace(data: journal.workspaceExpectedAfter, kind: .task, workID: journal.sourceID, registryRow: registry.row)
        guard TaskCheckpointUTF8.equal(journal.registryPath, LifecyclePriorityKind.task.registryPath),
              TaskCheckpointUTF8.equal(title, plan.workTitle), TaskCheckpointUTF8.equal(lifecycle, plan.lifecycle),
              TaskCheckpointUTF8.equal(priority, plan.priority), rule == plan.priorityRule, repairsEqual(repairs, plan.repairs),
              post.lifecycleValues.allSatisfy({ TaskCheckpointUTF8.equal($0, lifecycle) }),
              post.priorityValuesFound.allSatisfy({ TaskCheckpointUTF8.equal($0, priority) }) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Accepted-handoff queue metadata is not derivable from its bound pre/postimages.")
        }
        return record(kind: .acceptedHandoff, operationID: journal.operationUUID, root: journal.productionsRootPath,
                      workID: journal.sourceID, title: title, registryPath: journal.registryPath, occurredAt: occurredAt,
                      lifecycle: lifecycle, priority: priority, rule: rule, repairs: repairs, disposition: disposition,
                      terminal: journal.terminalState, journalFinalized: journal.journalFinalized, fallbackRecorded: journal.fallbackRecorded)
    }

    private func record(kind: ReconciliationQueueJournalKind, operationID: UUID, root: String, workID: String, title: String,
                        registryPath: String, occurredAt: Date, lifecycle: String, priority: String, rule: LifecyclePriorityRule,
                        repairs: [LifecyclePriorityRepair], disposition: ReconciliationDisposition,
                        terminal: OfficeWorkspaceTerminalState?, journalFinalized: Bool, fallbackRecorded: Bool) -> ReconciliationQueueRecord {
        ReconciliationQueueRecord(kind: kind, operationUUID: operationID, productionsRootPath: root, workID: workID,
                                  workTitle: title, registryPath: registryPath, occurredAt: occurredAt, lifecycle: lifecycle,
                                  priority: priority, priorityRule: rule, repairs: repairs, disposition: disposition,
                                  journalFinalized: journalFinalized, fallbackRecorded: fallbackRecorded,
                                  historicalCommitProven: terminal?.provesHistoricalCommit == true)
    }

    private func journalDescriptors() throws -> [Descriptor] {
        try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { url in
                let stem = url.deletingPathExtension().lastPathComponent
                guard let operationID = UUID(uuidString: stem), TaskCheckpointUTF8.equal(url.lastPathComponent, "\(operationID.uuidString).json") else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A queue journal filename is not one exact canonical UUID.")
                }
                let data = try readRegular(url)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawKind = object["operationKind"] as? String,
                      let kind = ReconciliationQueueJournalKind(rawValue: rawKind) else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("A recovery journal has a malformed or unsupported operation kind.")
                }
                return Descriptor(operationID: operationID, kind: kind)
            }
    }

    private func repairsEqual(_ lhs: [LifecyclePriorityRepair], _ rhs: [LifecyclePriorityRepair]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            TaskCheckpointUTF8.equal(left.field, right.field) &&
            TaskCheckpointUTF8.equal(left.registryValueBefore, right.registryValueBefore) &&
            left.workspaceValuesBefore.count == right.workspaceValuesBefore.count &&
            zip(left.workspaceValuesBefore, right.workspaceValuesBefore).allSatisfy { TaskCheckpointUTF8.equal($0.0, $0.1) } &&
            TaskCheckpointUTF8.equal(left.chosenValue, right.chosenValue) &&
            TaskCheckpointUTF8.equal(left.rule, right.rule) &&
            TaskCheckpointUTF8.equal(left.provenance, right.provenance)
        }
    }

    private func lifecycleRepairsAreDerived(
        _ repairs: [LifecyclePriorityRepair], preLifecycle: String, postLifecycle: String,
        workspaceLifecycles: [String], prePriority: String, postPriority: String,
        workspacePriorities: [String], priorityRule: LifecyclePriorityRule
    ) -> Bool {
        var expectedFields: [String] = []
        if workspaceLifecycles.contains(where: { !TaskCheckpointUTF8.equal($0, preLifecycle) }) { expectedFields.append("lifecycle") }
        if workspacePriorities.contains(where: { !TaskCheckpointUTF8.equal($0, prePriority) }) { expectedFields.append("priority") }
        guard repairs.map(\.field).elementsEqual(expectedFields, by: TaskCheckpointUTF8.equal) else { return false }
        for repair in repairs {
            if TaskCheckpointUTF8.equal(repair.field, "lifecycle") {
                guard TaskCheckpointUTF8.equal(repair.registryValueBefore, preLifecycle),
                      repairsArrayEqual(repair.workspaceValuesBefore, workspaceLifecycles),
                      TaskCheckpointUTF8.equal(repair.chosenValue, postLifecycle) else { return false }
                let registry = TaskCheckpointUTF8.equal(repair.rule, "registry-wins") &&
                    TaskCheckpointUTF8.equal(repair.provenance, "Registry") && TaskCheckpointUTF8.equal(preLifecycle, postLifecycle)
                let explicit = TaskCheckpointUTF8.equal(repair.rule, "explicit-owner-decision") &&
                    TaskCheckpointUTF8.equal(repair.provenance, "owner-authorized request")
                guard registry || explicit else { return false }
            } else if TaskCheckpointUTF8.equal(repair.field, "priority") {
                guard TaskCheckpointUTF8.equal(repair.registryValueBefore, prePriority),
                      repairsArrayEqual(repair.workspaceValuesBefore, workspacePriorities),
                      TaskCheckpointUTF8.equal(repair.chosenValue, postPriority) else { return false }
                let registry = TaskCheckpointUTF8.equal(repair.rule, LifecyclePriorityRule.registryAuthoritative.rawValue) &&
                    TaskCheckpointUTF8.equal(repair.provenance, "owner-authorized Registry decision") &&
                    TaskCheckpointUTF8.equal(prePriority, postPriority)
                let maximumValue = ([prePriority] + workspacePriorities).max { priorityRankForQueue($0) < priorityRankForQueue($1) }
                let maximum = priorityRule == .deterministicMaximum && TaskCheckpointUTF8.equal(repair.rule, LifecyclePriorityRule.deterministicMaximum.rawValue) &&
                    TaskCheckpointUTF8.equal(repair.provenance, "recognized conflict without provenance") &&
                    maximumValue.map { TaskCheckpointUTF8.equal($0, postPriority) } == true
                let explicit = TaskCheckpointUTF8.equal(repair.rule, "explicit-owner-decision") &&
                    TaskCheckpointUTF8.equal(repair.provenance, "owner-authorized Registry decision")
                guard registry || maximum || explicit else { return false }
            } else { return false }
        }
        return true
    }

    private func repairsArrayEqual(_ lhs: [String], _ rhs: [String]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { TaskCheckpointUTF8.equal($0.0, $0.1) }
    }

    private func priorityRankForQueue(_ value: String) -> Int {
        ["Unranked", "Low", "Medium", "High", "Highest"].firstIndex(where: { TaskCheckpointUTF8.equal($0, value) }) ?? -1
    }

    private func descriptor(operationID: UUID) throws -> Descriptor {
        let matches = try journalDescriptors().filter { $0.operationID == operationID }
        guard matches.count == 1 else { throw unavailable(operationID) }
        return matches[0]
    }

    private func readRegular(_ url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw LifecyclePriorityValidationError.targetContractInvalid("A recovery journal cannot be opened without following links.") }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw LifecyclePriorityValidationError.targetContractInvalid("A recovery journal is not a non-followed regular file.")
        }
        return try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
    }

    private func withQueueLock<T>(_ body: () throws -> T) throws -> T {
        try OfficeJournalAtomicCoordinator.withLock(directory: directory, body)
    }

    private func unavailable(_ operationID: UUID) -> LifecyclePriorityValidationError {
        .targetContractInvalid("No unique typed reconciliation journal exists for operation \(operationID.uuidString).")
    }
}

enum LifecyclePriorityKind: String {
    case task = "Task", idea = "Idea", project = "Project", initiative = "Initiative"

    init(id: String) throws {
        if id.range(of: #"^TASK-[0-9]{4,}$"#, options: .regularExpression) != nil { self = .task }
        else if id.range(of: #"^IDEA-[0-9]{4,}$"#, options: .regularExpression) != nil { self = .idea }
        else if id.range(of: #"^PROJ-[0-9]{4,}$"#, options: .regularExpression) != nil { self = .project }
        else if id.range(of: #"^INIT-[0-9]{4,}$"#, options: .regularExpression) != nil { self = .initiative }
        else { throw LifecyclePriorityValidationError.invalidInput("Work ID must use exact TASK/IDEA/PROJ/INIT durable-ID grammar.") }
    }

    var idHeader: String { self == .project ? "Project ID" : self == .initiative ? "Initiative ID" : "\(rawValue) ID" }
    var identifierPrefix: String { self == .project ? "PROJ" : self == .initiative ? "INIT" : rawValue.uppercased() }
    var stateHeader: String { self == .idea ? "Disposition" : "State" }
    var registryPath: String {
        switch self {
        case .task: ProductionsPath.tasks.rawValue
        case .idea: ProductionsPath.ideas.rawValue
        case .project: ProductionsPath.projects.rawValue
        case .initiative: ProductionsPath.initiatives.rawValue
        }
    }
    var headers: [String] {
        switch self {
        case .task: ["Task ID", "Title", "State", "Priority", "Current lead", "Initiative", "Project", "Depends on", "Review after", "Short description", "Workspace"]
        case .idea: ["Idea ID", "Title", "Disposition", "Priority", "Current lead", "Related records", "Review after", "Source artifacts", "Short description", "Workspace"]
        case .project: ["Project ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"]
        case .initiative: ["Initiative ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"]
        }
    }
    var lifecycleValues: [String] {
        self == .idea ? ["Open", "Promoted", "Archived", "Discarded"] : [
            "Active / Current", "Active / Paused", "Active / Blocked", "Pending / Review",
            "Pending / Deferred", "Done / Complete", "Done / Obsolete",
        ]
    }
}

struct LifecyclePriorityRegistryDocument {
    let data: Data
    let lines: [String]
    let finalNewline: Bool
    let kind: LifecyclePriorityKind
    let rowIndex: Int
    let row: [String: String]

    init(data: Data, kind: LifecyclePriorityKind, workID: String) throws {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\r") else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Registry must be valid LF-only UTF-8.")
        }
        self.data = data; self.kind = kind; finalNewline = text.hasSuffix("\n")
        let parsedLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let header = "| " + kind.headers.joined(separator: " | ") + " |"
        let delimiter = "| " + Array(repeating: "---", count: kind.headers.count).joined(separator: " | ") + " |"
        let headers = parsedLines.indices.filter { parsedLines[$0] == header }
        guard headers.count == 1, let headerIndex = headers.first, headerIndex + 1 < parsedLines.count,
              parsedLines[headerIndex + 1] == delimiter else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Registry must contain one exact adopted header and delimiter.")
        }
        var found: [(Int, [String: String])] = [], seen = Set<String>()
        var index = headerIndex + 2
        while index < parsedLines.count, parsedLines[index].hasPrefix("|") {
            let values = MarkdownTable.cells(parsedLines[index])
            guard values.count == kind.headers.count else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Registry contains a row with the wrong field count.")
            }
            let parsed = Dictionary(uniqueKeysWithValues: zip(kind.headers, values))
            let id = parsed[kind.idHeader] ?? ""
            guard (try? LifecyclePriorityKind(id: id)) == kind else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Registry contains an invalid or wrong-kind durable ID.")
            }
            guard seen.insert(id).inserted else { throw LifecyclePriorityValidationError.targetContractInvalid("Registry contains a duplicate durable ID.") }
            let lifecycle = parsed[kind.stateHeader] ?? "", priority = parsed["Priority"] ?? ""
            let terminal = kind == .idea ? ["Promoted", "Archived", "Discarded"].contains(lifecycle) : lifecycle.hasPrefix("Done / ")
            guard kind.lifecycleValues.contains(lifecycle), LifecyclePriorityWorkspace.priorityValues.contains(priority),
                  !((parsed["Title"] ?? "").isEmpty), !((parsed["Current lead"] ?? "").isEmpty),
                  !terminal || priority == "Unranked",
                  MarkdownTable.resolvedPath(parsed["Workspace"] ?? "", relativeTo: "Office/Registry") == "Workspace/\(id)/\(id).md",
                  parsedLines[index] == "| " + kind.headers.map({ parsed[$0] ?? "" }).joined(separator: " | ") + " |" else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Registry contains an inconsistent or noncanonical durable row.")
            }
            if TaskCheckpointUTF8.equal(id, workID) { found.append((index, parsed)) }
            index += 1
        }
        if parsedLines.dropFirst(index).contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("|") }) {
            throw LifecyclePriorityValidationError.targetContractInvalid("Registry contains a hidden, wrong-kind, or malformed later table fragment.")
        }
        guard found.count == 1, let match = found.first else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Registry must contain exactly one row for \(workID).")
        }
        lines = parsedLines; rowIndex = match.0; row = match.1
        guard kind.lifecycleValues.contains(row[kind.stateHeader] ?? ""),
              LifecyclePriorityWorkspace.priorityValues.contains(row["Priority"] ?? ""),
              !(row["Title"] ?? "").isEmpty, !(row["Current lead"] ?? "").isEmpty else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Registry lifecycle, priority, title, or lead is invalid.")
        }
        guard MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry") == "Workspace/\(workID)/\(workID).md" else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Registry Workspace link is not the exact same-ID canonical record.")
        }
    }

    func replacing(lifecycle: String, priority: String) -> Data {
        var updated = lines
        var values = kind.headers.map { row[$0] ?? "" }
        values[kind.headers.firstIndex(of: kind.stateHeader)!] = lifecycle
        values[kind.headers.firstIndex(of: "Priority")!] = priority
        updated[rowIndex] = "| " + values.joined(separator: " | ") + " |"
        return Data(updated.joined(separator: "\n").utf8)
    }
}

struct LifecyclePriorityWorkspace {
    static let priorityValues = ["Highest", "High", "Medium", "Low", "Unranked"]
    private let data: Data
    private let lines: [String]
    private let finalNewline: Bool
    private let kind: LifecyclePriorityKind
    private let lifecycleEdits: [(Int, String, String)]
    private let priorityEdits: [(Int, String, String)]
    let lifecycleValues: [String]
    let priorityValuesFound: [String]

    init(data: Data, kind: LifecyclePriorityKind, workID: String, registryRow: [String: String]) throws {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\r") else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Workspace must be valid LF-only UTF-8.")
        }
        self.data = data; self.kind = kind; finalNewline = text.hasSuffix("\n")
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fenced = false, h1: [String] = [], section: String?, coreFields: [String: [(Int, String)]] = [:]
        var lifeEdits: [(Int, String, String)] = [], priorityEditsLocal: [(Int, String, String)] = []
        var lifeValues: [String] = [], priorities: [String] = []
        var summaryCandidates = 0, lifecycleAttentionSections = 0
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            guard !fenced else {
                if section == "Core Record", let colon = line.firstIndex(of: ":") {
                    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    coreFields[key, default: []].append((index, value))
                }
                continue
            }
            if line.hasPrefix("# "), !line.hasPrefix("## ") { h1.append(String(line.dropFirst(2))) }
            if line.hasPrefix("## "), !line.hasPrefix("### ") {
                section = String(line.dropFirst(3))
                if TaskCheckpointUTF8.equal(section!, "Lifecycle and Attention") { lifecycleAttentionSections += 1 }
            }
            guard section == "Lifecycle and Attention" else { continue }
            let trimmedSummary = line.trimmingCharacters(in: .whitespaces)
            guard trimmedSummary.hasPrefix("This \(kind.rawValue) is ") else { continue }
            summaryCandidates += 1
            guard TaskCheckpointUTF8.equal(trimmedSummary, line) else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Lifecycle and Attention summary has noncanonical leading or trailing whitespace.")
            }
            let prefix = "This \(kind.rawValue) is "
            let allowedPairs = kind.lifecycleValues.flatMap { lifecycle in Self.priorityValues.map { (lifecycle, $0) } }
            let matches = allowedPairs.compactMap { lifecycle, priority -> (String, String)? in
                let quoted = "\(prefix)`\(lifecycle)` at `\(priority)` priority"
                let plain = "\(prefix)\(lifecycle) at \(priority) priority"
                if line.hasPrefix(quoted) { return (lifecycle, priority) }
                if line.hasPrefix(plain) { return (lifecycle, priority) }
                return nil
            }
            guard matches.count == 1, let match = matches.first else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Lifecycle and Attention contains a malformed lifecycle/priority summary.")
            }
            lifeValues.append(match.0); priorities.append(match.1)
            lifeEdits.append((index, match.0, match.0)); priorityEditsLocal.append((index, match.1, match.1))
        }
        guard h1.count == 1, TaskCheckpointUTF8.equal(h1[0], registryRow["Title"] ?? "") else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Workspace must have one exact Registry-title H1.")
        }
        let idKeys = ["ID", kind.idHeader]
        let presentIDKeys = idKeys.filter { coreFields[$0] != nil }
        let idMatches = presentIDKeys.flatMap { coreFields[$0] ?? [] }
        guard presentIDKeys.count == 1, idMatches.count == 1, TaskCheckpointUTF8.equal(idMatches[0].1, workID) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Workspace Core identity does not match the Registry record.")
        }
        let workspaceLines = lines
        let exactField = { (key: String, entry: (Int, String)) in TaskCheckpointUTF8.equal(workspaceLines[entry.0], "\(key): \(entry.1)") }
        guard exactField(presentIDKeys[0], idMatches[0]) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Workspace Core identity field spelling is not exact.")
        }
        if let titles = coreFields["Title"] {
            guard titles.count == 1, exactField("Title", titles[0]), TaskCheckpointUTF8.equal(titles[0].1, registryRow["Title"] ?? "") else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Workspace Core Title does not match Registry Title.")
            }
        }
        if let types = coreFields["Type"] {
            guard types.count == 1, exactField("Type", types[0]), TaskCheckpointUTF8.equal(types[0].1, kind.rawValue) else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Workspace Core Type is invalid.")
            }
        }
        if let leads = coreFields["Current lead"] {
            guard leads.count == 1, exactField("Current lead", leads[0]), TaskCheckpointUTF8.equal(leads[0].1, registryRow["Current lead"] ?? "") else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Workspace Current lead does not match Registry.")
            }
        }
        if let sources = coreFields["Status source"] {
            let expected = "Office/Registry/\(kind.registryPath.split(separator: "/").last!)"
            guard sources.count == 1, exactField("Status source", sources[0]),
                  TaskCheckpointUTF8.equal(sources[0].1, expected) || TaskCheckpointUTF8.equal(sources[0].1, "Productions/\(expected)") else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Workspace Status source is invalid for its Registry.")
            }
        }
        let lifecycleKeys = kind == .idea ? ["Disposition"] : ["State", "Lifecycle"]
        for key in lifecycleKeys {
            if let entries = coreFields[key] {
                guard entries.count == 1, exactField(key, entries[0]), kind.lifecycleValues.contains(entries[0].1) else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("Workspace contains malformed or duplicate \(key) mirrors.")
                }
                lifeValues.append(entries[0].1); lifeEdits.append((entries[0].0, entries[0].1, entries[0].1))
            }
        }
        if let entries = coreFields["Priority"] {
            guard entries.count == 1, exactField("Priority", entries[0]), Self.priorityValues.contains(entries[0].1) else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Workspace contains malformed or duplicate Priority mirrors.")
            }
            priorities.append(entries[0].1); priorityEditsLocal.append((entries[0].0, entries[0].1, entries[0].1))
        }
        guard lifecycleAttentionSections <= 1, summaryCandidates <= 1 else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Workspace contains duplicate Lifecycle and Attention sections or summaries.")
        }
        lifecycleEdits = lifeEdits; priorityEdits = priorityEditsLocal
        lifecycleValues = lifeValues; priorityValuesFound = priorities
    }

    func replacing(lifecycle: String, priority: String) throws -> Data {
        var output = lines
        for (index, old, _) in lifecycleEdits {
            output[index] = try replaceToken(old, with: lifecycle, in: output[index], label: "lifecycle")
        }
        for (index, old, _) in priorityEdits {
            output[index] = try replaceToken(old, with: priority, in: output[index], label: "priority")
        }
        return Data(output.joined(separator: "\n").utf8)
    }

    private func replaceToken(_ old: String, with new: String, in line: String, label: String) throws -> String {
        guard let range = line.range(of: old) else { throw LifecyclePriorityValidationError.targetContractInvalid("Workspace \(label) mirror is not replaceable.") }
        return line.replacingCharacters(in: range, with: new)
    }
}

struct LifecyclePriorityMirrorRepairPlan: Equatable {
    let workspaceAfter: Data
    let workTitle: String
    let lifecycle: String
    let priority: String
    let priorityRule: LifecyclePriorityRule
    let repairs: [LifecyclePriorityRepair]
}

enum LifecyclePriorityMirrorReconciler {
    static func task(registryData: Data, workspaceData: Data, taskID: String) throws -> LifecyclePriorityMirrorRepairPlan {
        let kind = try LifecyclePriorityKind(id: taskID)
        guard kind == .task else {
            throw LifecyclePriorityValidationError.targetContractInvalid("A Task writer can reconcile only an exact Task mirror.")
        }
        let registry = try LifecyclePriorityRegistryDocument(data: registryData, kind: kind, workID: taskID)
        let relationships = try TaskRelationshipMirrorReconciler.task(
            registryRow: registry.row, workspaceData: workspaceData
        )
        let workspace = try LifecyclePriorityWorkspace(
            data: relationships.workspaceAfter, kind: kind, workID: taskID, registryRow: registry.row
        )
        let lifecycle = registry.row[kind.stateHeader]!
        let registryPriority = registry.row["Priority"]!
        // A later writer's owner-authorized request binds the exact Registry hash, so that
        // bound Registry value is the explicit decision for its incidental mirror repair.
        let rule: LifecyclePriorityRule = .registryAuthoritative
        let priority = registryPriority
        var repairs: [LifecyclePriorityRepair] = relationships.repairs
        if workspace.lifecycleValues.contains(where: { !TaskCheckpointUTF8.equal($0, lifecycle) }) {
            repairs.append(.init(field: "lifecycle", registryValueBefore: lifecycle, workspaceValuesBefore: workspace.lifecycleValues,
                                 chosenValue: lifecycle, rule: "registry-wins", provenance: "Registry"))
        }
        if workspace.priorityValuesFound.contains(where: { !TaskCheckpointUTF8.equal($0, registryPriority) }) {
            repairs.append(.init(field: "priority", registryValueBefore: registryPriority, workspaceValuesBefore: workspace.priorityValuesFound,
                                 chosenValue: priority, rule: rule.rawValue,
                                 provenance: "owner-authorized hash-bound Registry decision"))
        }
        let after = try workspace.replacing(lifecycle: lifecycle, priority: priority)
        let validated = try LifecyclePriorityWorkspace(data: after, kind: kind, workID: taskID, registryRow: registry.row)
        guard validated.lifecycleValues.allSatisfy({ TaskCheckpointUTF8.equal($0, lifecycle) }),
              validated.priorityValuesFound.allSatisfy({ TaskCheckpointUTF8.equal($0, priority) }) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Prepared Task mirror repair did not produce complete agreement.")
        }
        return LifecyclePriorityMirrorRepairPlan(workspaceAfter: after, workTitle: registry.row["Title"]!, lifecycle: lifecycle,
                                                 priority: priority, priorityRule: rule, repairs: repairs)
    }
}

private struct LifecyclePriorityPrepared {
    let kind: LifecyclePriorityKind
    let registryURL: URL
    let workspaceURL: URL
    let registryBefore: Data
    let registryAfter: Data
    let workspaceBefore: Data
    let workspaceAfter: Data
    let lifecycle: String
    let priority: String
    let workTitle: String
    let repairs: [LifecyclePriorityRepair]
    let registryPath: String
    let workspacePath: String
}

struct LifecyclePriorityService: @unchecked Sendable {
    let journalStore: any LifecyclePriorityJournalStore
    let queueResolver: (any ReconciliationQueueResolving)?
    let replacer: any AtomicFileReplacing
    let locking: any TaskCheckpointLocking
    let contractValidator: any OfficeV112ContractValidating
    let manager: FileManager
    let now: () -> Date
    let makeOperationID: () -> UUID

    init(
        journalStore: any LifecyclePriorityJournalStore = ApplicationSupportLifecyclePriorityJournalStore(),
        queueResolver: (any ReconciliationQueueResolving)? = nil,
        replacer: (any AtomicFileReplacing)? = nil,
        locking: any TaskCheckpointLocking = LocalTaskCheckpointLocking(),
        contractValidator: any OfficeV112ContractValidating = AdoptedOfficeV112ContractValidator(),
        manager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeOperationID: @escaping () -> UUID = UUID.init
    ) {
        self.journalStore = journalStore
        if let queueResolver { self.queueResolver = queueResolver }
        else if let applicationStore = journalStore as? ApplicationSupportLifecyclePriorityJournalStore {
            self.queueResolver = ApplicationSupportReconciliationQueueResolver(manager: manager, directory: applicationStore.directory)
        } else { self.queueResolver = nil }
        self.replacer = replacer ?? DurableReplacement(manager: manager)
        self.locking = locking; self.contractValidator = contractValidator; self.manager = manager
        self.now = now; self.makeOperationID = makeOperationID
    }

    func startupRecovery() -> [LifecyclePriorityJournal] { (try? journalStore.incomplete()) ?? [] }

    func preview(request: LifecyclePriorityRequest, configuration: ProductionsConfiguration) throws -> LifecyclePriorityPreview {
        do {
            try preflight(request: request, configuration: configuration)
            let prepared = try prepare(request: request, configuration: configuration)
            return makePreview(request: request, prepared: prepared, root: configuration.productionsRootPath)
        } catch {
            throw failure(nil, request: request, classification: error is OfficeContractValidationError ? "contractNotAdopted" : classify(error), diagnostic: error.localizedDescription + " Preview is read-only; no operation UUID or journal was created.", exit: 2)
        }
    }

    func perform(
        request: LifecyclePriorityRequest,
        confirmationToken: String,
        configuration: ProductionsConfiguration
    ) throws -> LifecyclePriorityCommandResult {
        do { try preflight(request: request, configuration: configuration) }
        catch {
            throw failure(nil, request: request, classification: error is OfficeContractValidationError ? "contractNotAdopted" : classify(error), diagnostic: error.localizedDescription + " No operation journal was created.", exit: 2)
        }
        let operationID = makeOperationID()
        let kind: LifecyclePriorityKind
        do { kind = try LifecyclePriorityKind(id: request.workID) }
        catch { throw failure(operationID, request: request, classification: classify(error), diagnostic: error.localizedDescription + " No operation journal was created.", exit: 2) }
        let registryURL = configuration.taskCheckpointURL(kind.registryPath)
        do { try requireSafeFile(registryURL, configuration: configuration, label: "Registry") }
        catch { throw failure(operationID, request: request, classification: classify(error), diagnostic: error.localizedDescription + " No operation journal was created.", exit: 2) }
        guard let lock = locking.acquire(registryURL: registryURL) else {
            throw failure(operationID, request: request, classification: "lockUnavailable", diagnostic: LifecyclePriorityValidationError.lockUnavailable.localizedDescription + " No operation journal was created.", exit: 2)
        }
        defer { _ = lock }
        var correctionReservation: AnyObject?
        if let corrected = request.correctsOperation, let resolver = queueResolver {
            do {
                guard corrected != operationID, request.desiredLifecycle != nil || request.desiredPriority != nil else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("The correction must bind a different operation and an explicit owner-authorized Registry decision.")
                }
                correctionReservation = try resolver.reserveCorrection(
                    operationID: corrected, productionsRootPath: configuration.productionsRootPath, workID: request.workID
                )
            } catch {
                throw failure(operationID, request: request, classification: classify(error),
                              diagnostic: error.localizedDescription + " No operation journal was created.", exit: 2)
            }
        }
        defer { _ = correctionReservation }
        let prepared: LifecyclePriorityPrepared
        do {
            prepared = try prepare(request: request, configuration: configuration)
            let current = makePreview(request: request, prepared: prepared, root: configuration.productionsRootPath)
            guard TaskCheckpointUTF8.equal(current.confirmationToken, confirmationToken) else { throw LifecyclePriorityValidationError.confirmationMismatch }
            if let corrected = request.correctsOperation {
                guard corrected != operationID, request.desiredLifecycle != nil || request.desiredPriority != nil else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("The corrected reconciliation must be a different proven pending entry for the same root and work.")
                }
                if let resolver = queueResolver {
                    let prior = try resolver.resolve(operationID: corrected, productionsRootPath: configuration.productionsRootPath)
                    guard TaskCheckpointUTF8.equal(prior.workID, request.workID), prior.historicalCommitProven,
                          prior.disposition == .pending else {
                        throw LifecyclePriorityValidationError.targetContractInvalid("The corrected reconciliation must be a different proven pending entry for the same root and work.")
                    }
                } else {
                    guard let prior = try journalStore.journal(operationID: corrected),
                          TaskCheckpointUTF8.equal(prior.productionsRootPath, configuration.productionsRootPath),
                          TaskCheckpointUTF8.equal(prior.workID, request.workID),
                          prior.terminalState?.provesHistoricalCommit == true, prior.queueDisposition == .pending else {
                        throw LifecyclePriorityValidationError.targetContractInvalid("The corrected reconciliation must be a different proven pending entry for the same root and work.")
                    }
                }
            }
        } catch {
            throw failure(operationID, request: request, classification: classify(error), diagnostic: error.localizedDescription + " No operation journal was created.", exit: 2)
        }
        var journal = LifecyclePriorityJournal(
            schemaVersion: LifecyclePriorityJournal.schemaVersion, operationUUID: operationID,
            operationKind: "lifecycle-priority-reconciliation", productionsRootPath: configuration.productionsRootPath,
            workID: request.workID, workTitle: prepared.workTitle, registryPath: prepared.registryPath, workspacePath: prepared.workspacePath,
            timestamp: Date(timeIntervalSince1970: floor(now().timeIntervalSince1970)), registrySHA256Before: hash(prepared.registryBefore), registryPreimage: prepared.registryBefore,
            registrySHA256ExpectedAfter: hash(prepared.registryAfter), registryExpectedAfter: prepared.registryAfter,
            workspaceSHA256Before: hash(prepared.workspaceBefore), workspacePreimage: prepared.workspaceBefore,
            workspaceSHA256ExpectedAfter: hash(prepared.workspaceAfter), workspaceExpectedAfter: prepared.workspaceAfter,
            lifecycle: prepared.lifecycle, priority: prepared.priority, priorityRule: request.priorityRule,
            repairs: prepared.repairs, correctsOperation: request.correctsOperation,
            queueDisposition: prepared.repairs.isEmpty ? .confirmed : .pending,
            terminalState: nil, journalFinalized: false, fallbackRecorded: false, diagnostic: nil
        )
        do { try journalStore.persist(journal) }
        catch {
            throw failure(operationID, request: request, prepared: prepared, classification: "journalCreateFailed", diagnostic: "Initial recovery journal could not be persisted; no canonical replacement was attempted and no durable operation journal was created: \(error.localizedDescription)", exit: 2)
        }
        do {
            try requireSafeFile(prepared.registryURL, configuration: configuration, label: "Registry")
            try requireSafeFile(prepared.workspaceURL, configuration: configuration, label: "Workspace")
            guard try Data(contentsOf: prepared.registryURL) == prepared.registryBefore,
                  try Data(contentsOf: prepared.workspaceURL) == prepared.workspaceBefore else {
                return try finishNoCommit(&journal, prepared: prepared, diagnostic: "Registry or Workspace changed after preparation; no replacement was attempted.")
            }
        } catch {
            return try finishNoCommit(&journal, prepared: prepared, diagnostic: "Registry or Workspace pre-replacement validation failed: \(error.localizedDescription)")
        }
        do {
            if prepared.workspaceBefore != prepared.workspaceAfter { try replacer.replace(data: prepared.workspaceAfter, at: prepared.workspaceURL) }
            if prepared.registryBefore != prepared.registryAfter { try replacer.replace(data: prepared.registryAfter, at: prepared.registryURL) }
        } catch {
            return try reconcileReplacement(&journal, prepared: prepared, configuration: configuration, diagnostic: error.localizedDescription)
        }
        do { try validatePostimage(journal, configuration: configuration) }
        catch {
            return try finishProven(&journal, prepared: prepared, state: .committedReloadFailed,
                                    classification: "historically-committed-current-state-uncertain",
                                    diagnostic: "Replacement returned success, but complete reload validation failed: \(error.localizedDescription)")
        }
        do {
            var proposed = journal
            proposed.transition(to: .committedAndCurrent, diagnostic: nil, finalized: true)
            try journalStore.update(proposed)
            journal = proposed
        } catch {
            return try finishFallback(&journal, prepared: prepared, fallback: .journalFinalizationFailedCommittedAndCurrent,
                                      classification: "committed-and-current",
                                      diagnostic: "The canonical commit is proven current, but normal journal finalization failed: \(error.localizedDescription)")
        }
        if let corrected = request.correctsOperation {
            do {
                guard corrected == journal.correctsOperation else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("The correction journal lost its bound prior operation.")
                }
                try consumeCommittedCorrection(journal)
            } catch {
                return queueRecoveryFailure(journal, error: error)
            }
        }
        return result("committed", journal: journal, classification: "committed-and-current", diagnostic: nil)
    }

    func inspect(operationID: UUID, configuration: ProductionsConfiguration) throws -> LifecyclePriorityCommandResult {
        let journal: LifecyclePriorityJournal
        do {
            guard let value = try journalStore.journal(operationID: operationID) else {
                throw LifecyclePriorityValidationError.targetContractInvalid("No lifecycle/priority journal exists for this UUID.")
            }
            journal = value
        } catch {
            throw failure(operationID, request: nil, classification: "journal-read-failed", diagnostic: "The operation journal could not be read: \(error.localizedDescription). Do not retry automatically.", exit: 3)
        }
        if journal.terminalState == .definiteNoCommit || journal.terminalState == .journalFinalizationFailedDefiniteNoCommit {
            return result("not-committed", journal: journal, classification: "definite-no-commit", diagnostic: journal.diagnostic)
        }
        let proven = journal.terminalState?.provesHistoricalCommit == true
        guard TaskCheckpointCanonicalRoot.isExact(configuration.productionsRootPath),
              TaskCheckpointUTF8.equal(configuration.productionsRootPath, journal.productionsRootPath) else {
            return uncertain(journal, proven: proven, "The supplied canonical Productions root does not match the immutable journal root; no live read or reconciliation occurred.")
        }
        let registryURL = configuration.taskCheckpointURL(journal.registryPath)
        let workspaceURL = configuration.taskCheckpointURL(journal.workspacePath)
        let registry: Data, workspace: Data
        do {
            try requireSafeFile(registryURL, configuration: configuration, label: "Registry")
            try requireSafeFile(workspaceURL, configuration: configuration, label: "Workspace")
            registry = try Data(contentsOf: registryURL); workspace = try Data(contentsOf: workspaceURL)
        } catch { return uncertain(journal, proven: proven, "The bound targets are unavailable: \(error.localizedDescription)") }
        if registry == journal.registryExpectedAfter, workspace == journal.workspaceExpectedAfter {
            do { try validatePostimage(journal, configuration: configuration) }
            catch { return uncertain(journal, proven: proven, "Exact postimage bytes failed complete validation: \(error.localizedDescription)") }
            if proven {
                do { try consumeCommittedCorrection(journal) }
                catch { return queueRecoveryFailure(journal, error: error) }
                return result("committed", journal: journal, classification: "committed-and-current", diagnostic: journal.diagnostic)
            }
            var updated = journal
            updated.transition(to: .reconciledCommittedAndCurrent, diagnostic: "Inspection reconciled the exact complete postimage as committed.", finalized: true)
            do { try journalStore.update(updated) }
            catch {
                var durable = journal
                return try finishFallback(&durable, prepared: nil, fallback: .journalFinalizationFailedCommittedAndCurrent,
                                          classification: "committed-and-current",
                                          diagnostic: "Inspection proved the commit, but terminal finalization failed: \(error.localizedDescription)")
            }
            return result("committed", journal: updated, classification: "committed-and-current", diagnostic: updated.diagnostic)
        }
        if registry == journal.registryPreimage, workspace == journal.workspacePreimage {
            if proven { return uncertain(journal, proven: true, "Canonical bytes returned to the complete preimage after a proven commit.") }
            do {
                let prepared = try prepared(from: journal, configuration: configuration)
                var recovered = journal
                return try finishNoCommit(&recovered, prepared: prepared, diagnostic: "Inspection found both exact complete preimages and durably classified definite no commit. Do not retry automatically.")
            } catch {
                return uncertain(journal, proven: false, "Exact complete preimages were found, but definite-no-commit journal finalization failed: \(error.localizedDescription)")
            }
        }
        if !proven,
           (registry == journal.registryExpectedAfter && workspace == journal.workspacePreimage) ||
           (registry == journal.registryPreimage && workspace == journal.workspaceExpectedAfter) {
            let registryURL = configuration.taskCheckpointURL(journal.registryPath)
            guard let lock = locking.acquire(registryURL: registryURL) else {
                return uncertain(journal, proven: false, "Incomplete two-file publication was found, but the recovery lock is unavailable.")
            }
            defer { _ = lock }
            do {
                let prepared = try prepared(from: journal, configuration: configuration)
                // The pre-lock descriptors are not trusted for recovery. Resolve and
                // verify both exact non-followed regular targets again while holding
                // the writer lock, before any reread or restore rename.
                try requireSafeFile(prepared.registryURL, configuration: configuration, label: "Registry recovery target")
                try requireSafeFile(prepared.workspaceURL, configuration: configuration, label: "Workspace recovery target")
                let lockedRegistry = try readBoundRegular(prepared.registryURL, label: "Registry recovery target")
                let lockedWorkspace = try readBoundRegular(prepared.workspaceURL, label: "Workspace recovery target")
                guard (lockedRegistry.data == journal.registryExpectedAfter && lockedWorkspace.data == journal.workspacePreimage) ||
                      (lockedRegistry.data == journal.registryPreimage && lockedWorkspace.data == journal.workspaceExpectedAfter) else {
                    return uncertain(journal, proven: false, "Incomplete two-file publication changed before bounded recovery acquired the lock.")
                }
                if lockedRegistry.data == journal.registryExpectedAfter {
                    try requireBoundIdentity(prepared.registryURL, bound: lockedRegistry, label: "Registry recovery target")
                    try replacer.replace(data: journal.registryPreimage, at: prepared.registryURL)
                }
                if lockedWorkspace.data == journal.workspaceExpectedAfter {
                    try requireBoundIdentity(prepared.workspaceURL, bound: lockedWorkspace, label: "Workspace recovery target")
                    try replacer.replace(data: journal.workspacePreimage, at: prepared.workspaceURL)
                }
                try requireSafeFile(prepared.registryURL, configuration: configuration, label: "Registry recovery reload")
                try requireSafeFile(prepared.workspaceURL, configuration: configuration, label: "Workspace recovery reload")
                let restoredRegistry = try readBoundRegular(prepared.registryURL, label: "Registry recovery reload")
                let restoredWorkspace = try readBoundRegular(prepared.workspaceURL, label: "Workspace recovery reload")
                guard restoredRegistry.data == journal.registryPreimage,
                      restoredWorkspace.data == journal.workspacePreimage else {
                    throw LifecyclePriorityValidationError.targetContractInvalid("Bounded recovery did not reproduce both complete preimages.")
                }
                var recovered = journal
                return try finishNoCommit(&recovered, prepared: prepared, diagnostic: "Startup inspection restored an incomplete two-file publication to both exact preimages. Do not retry automatically.")
            } catch {
                return uncertain(journal, proven: false, "Incomplete two-file publication could not be safely restored: \(error.localizedDescription)")
            }
        }
        if proven {
            do {
                let kind = try LifecyclePriorityKind(id: journal.workID)
                let doc = try LifecyclePriorityRegistryDocument(data: registry, kind: kind, workID: journal.workID)
                _ = try LifecyclePriorityWorkspace(data: workspace, kind: kind, workID: journal.workID, registryRow: doc.row)
                do { try consumeCommittedCorrection(journal) }
                catch { return queueRecoveryFailure(journal, error: error) }
                return result("committed", journal: journal, classification: "historically-committed-and-superseded", diagnostic: "The proven commit was superseded by a later valid canonical state.")
            } catch { return uncertain(journal, proven: true, "Historical commit remains proven, but current canonical agreement is invalid: \(error.localizedDescription)") }
        }
        return uncertain(journal, proven: false, "Neither the exact complete preimages nor exact complete postimages are current.")
    }

    func acknowledge(operationID: UUID, configuration: ProductionsConfiguration) throws -> LifecyclePriorityCommandResult {
        guard TaskCheckpointCanonicalRoot.isExact(configuration.productionsRootPath) else {
            throw failure(nil, request: nil, classification: "invalidInput", diagnostic: "The supplied Productions root is not exact.", exit: 2)
        }
        if let resolver = queueResolver {
            do {
                let record = try resolver.acknowledge(operationID: operationID, productionsRootPath: configuration.productionsRootPath)
                return LifecyclePriorityCommandResult(
                    outcome: "committed", operationUUID: record.operationUUID, workID: record.workID,
                    registrySHA256Before: nil, registrySHA256After: nil, workspaceSHA256Before: nil, workspaceSHA256After: nil,
                    lifecycle: record.lifecycle, priority: record.priority, repairs: record.repairs, queueDisposition: record.disposition,
                    classification: "acknowledged", journalFinalized: record.journalFinalized,
                    fallbackRecorded: record.fallbackRecorded, historicalCommitProven: record.historicalCommitProven,
                    inspectCommand: "OperationsDashboard office inspect --productions-root \(configuration.productionsRootPath) --operation \(operationID.uuidString)",
                    diagnostic: "Owner confirmation acknowledged the mirror repair only; lifecycle, priority, and Canvas were unchanged."
                )
            } catch {
                let durable = try? resolver.resolve(operationID: operationID, productionsRootPath: configuration.productionsRootPath)
                throw LifecyclePriorityCommandFailure(
                    result: LifecyclePriorityCommandResult(
                        outcome: "uncertain", operationUUID: operationID, workID: durable?.workID,
                        registrySHA256Before: nil, registrySHA256After: nil, workspaceSHA256Before: nil, workspaceSHA256After: nil,
                        lifecycle: durable?.lifecycle, priority: durable?.priority, repairs: durable?.repairs,
                        queueDisposition: durable?.disposition,
                        classification: "acknowledgement-state-uncertain",
                        journalFinalized: durable?.journalFinalized ?? false,
                        fallbackRecorded: durable?.fallbackRecorded ?? false,
                        historicalCommitProven: durable?.historicalCommitProven ?? false,
                        inspectCommand: "OperationsDashboard office inspect --productions-root \(configuration.productionsRootPath) --operation \(operationID.uuidString)",
                        diagnostic: "The typed queue acknowledgement update failed; inspect its durable writer journal before any separately authorized action. Do not retry automatically. \(error.localizedDescription)"
                    ), exitCode: 3
                )
            }
        }
        var journal: LifecyclePriorityJournal
        do {
            guard let value = try journalStore.journal(operationID: operationID) else { throw LifecyclePriorityValidationError.targetContractInvalid("No reconciliation queue entry exists.") }
            journal = value
            guard TaskCheckpointUTF8.equal(journal.productionsRootPath, configuration.productionsRootPath),
                  journal.terminalState?.provesHistoricalCommit == true, !journal.repairs.isEmpty else {
                throw LifecyclePriorityValidationError.targetContractInvalid("The operation is not a proven pending reconciliation for this root.")
            }
            if journal.queueDisposition == .pending {
                let durable = journal
                journal.acknowledge()
                do { try journalStore.update(journal) }
                catch {
                    throw LifecyclePriorityCommandFailure(
                        result: LifecyclePriorityCommandResult(
                            outcome: "uncertain", operationUUID: durable.operationUUID, workID: durable.workID,
                            registrySHA256Before: durable.registrySHA256Before,
                            registrySHA256After: durable.terminalState?.provesHistoricalCommit == true ? durable.registrySHA256ExpectedAfter : nil,
                            workspaceSHA256Before: durable.workspaceSHA256Before,
                            workspaceSHA256After: durable.terminalState?.provesHistoricalCommit == true ? durable.workspaceSHA256ExpectedAfter : nil,
                            lifecycle: durable.lifecycle, priority: durable.priority, repairs: durable.repairs,
                            queueDisposition: durable.queueDisposition, classification: "acknowledgement-state-uncertain",
                            journalFinalized: durable.journalFinalized, fallbackRecorded: durable.fallbackRecorded,
                            historicalCommitProven: durable.terminalState?.provesHistoricalCommit == true,
                            inspectCommand: "OperationsDashboard office inspect --productions-root \(durable.productionsRootPath) --operation \(durable.operationUUID.uuidString)",
                            diagnostic: "The acknowledgement journal update failed; durable disposition is not safely classified. Inspect before any separately authorized action. Do not retry automatically. \(error.localizedDescription)"
                        ), exitCode: 3
                    )
                }
            }
            return result("committed", journal: journal, classification: "acknowledged", diagnostic: "Owner confirmation acknowledged the repair only; lifecycle, priority, and Canvas were unchanged.")
        } catch let failure as LifecyclePriorityCommandFailure { throw failure }
        catch { throw failure(operationID, request: nil, classification: "not-committed", diagnostic: error.localizedDescription, exit: 2) }
    }

    func pending(configuration: ProductionsConfiguration) throws -> [LifecyclePriorityJournal] {
        guard TaskCheckpointCanonicalRoot.isExact(configuration.productionsRootPath) else { throw LifecyclePriorityValidationError.invalidInput("The supplied Productions root is not exact.") }
        for correction in try journalStore.all(productionsRootPath: configuration.productionsRootPath)
            where correction.terminalState?.provesHistoricalCommit == true && correction.correctsOperation != nil {
            try consumeCommittedCorrection(correction)
        }
        return try journalStore.pending(productionsRootPath: configuration.productionsRootPath)
    }

    func pendingEntries(configuration: ProductionsConfiguration) throws -> [LifecyclePriorityQueueEntry] {
        if let resolver = queueResolver {
            return try resolver.pendingEntries(productionsRootPath: configuration.productionsRootPath, now: now())
        }
        let entries = try pending(configuration: configuration).map {
            LifecyclePriorityQueueEntry(operationUUID: $0.operationUUID, workID: $0.workID, workTitle: $0.workTitle,
                                        occurredAt: $0.timestamp, ageSeconds: max(0, Int(now().timeIntervalSince($0.timestamp))),
                                        repairs: $0.repairs, disposition: $0.queueDisposition,
                                        journalFinalized: $0.journalFinalized, fallbackRecorded: $0.fallbackRecorded,
                                        historicalCommitProven: $0.terminalState?.provesHistoricalCommit == true)
        }
        return entries.sorted { $0.occurredAt < $1.occurredAt }
    }

    private func preflight(request: LifecyclePriorityRequest, configuration: ProductionsConfiguration) throws {
        guard TaskCheckpointCanonicalRoot.isExact(configuration.productionsRootPath) else { throw OfficeContractValidationError.contractNotAdopted("The supplied Productions root is not exact.") }
        try contractValidator.validate(configuration: configuration)
        _ = try LifecyclePriorityKind(id: request.workID)
        for value in [request.expectedRegistrySHA256, request.expectedWorkspaceSHA256] where value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) == nil {
            throw LifecyclePriorityValidationError.invalidInput("Expected hashes must be 64 lowercase hexadecimal characters.")
        }
    }

    private func prepare(request: LifecyclePriorityRequest, configuration: ProductionsConfiguration) throws -> LifecyclePriorityPrepared {
        let kind = try LifecyclePriorityKind(id: request.workID)
        let registryPath = kind.registryPath, workspacePath = "Workspace/\(request.workID)/\(request.workID).md"
        let registryURL = configuration.taskCheckpointURL(registryPath), workspaceURL = configuration.taskCheckpointURL(workspacePath)
        try requireSafeFile(registryURL, configuration: configuration, label: "Registry")
        try requireSafeFile(workspaceURL, configuration: configuration, label: "Workspace")
        let registryBefore = try Data(contentsOf: registryURL), workspaceBefore = try Data(contentsOf: workspaceURL)
        guard hash(registryBefore) == request.expectedRegistrySHA256 else { throw LifecyclePriorityValidationError.hashMismatch("Registry SHA-256 does not match the authorized preimage.") }
        guard hash(workspaceBefore) == request.expectedWorkspaceSHA256 else { throw LifecyclePriorityValidationError.hashMismatch("Workspace SHA-256 does not match the authorized preimage.") }
        let registry = try LifecyclePriorityRegistryDocument(data: registryBefore, kind: kind, workID: request.workID)
        let workspace = try LifecyclePriorityWorkspace(data: workspaceBefore, kind: kind, workID: request.workID, registryRow: registry.row)
        let registryLifecycle = registry.row[kind.stateHeader]!, registryPriority = registry.row["Priority"]!
        let lifecycle = request.desiredLifecycle ?? registryLifecycle
        guard kind.lifecycleValues.contains(lifecycle) else { throw LifecyclePriorityValidationError.invalidInput("Requested lifecycle is not valid for \(kind.rawValue).") }
        let priority: String
        if let desired = request.desiredPriority { priority = desired }
        else if request.priorityRule == .registryAuthoritative { priority = registryPriority }
        else { priority = ([registryPriority] + workspace.priorityValuesFound).max(by: { priorityRank($0) < priorityRank($1) })! }
        guard LifecyclePriorityWorkspace.priorityValues.contains(priority) else { throw LifecyclePriorityValidationError.invalidInput("Requested priority is invalid.") }
        let terminal = kind == .idea ? ["Promoted", "Archived", "Discarded"].contains(lifecycle) : lifecycle.hasPrefix("Done / ")
        if terminal, priority != "Unranked" {
            throw LifecyclePriorityValidationError.targetContractInvalid("Terminal durable work must use Unranked priority.")
        }
        var repairs: [LifecyclePriorityRepair] = []
        if workspace.lifecycleValues.contains(where: { !TaskCheckpointUTF8.equal($0, registryLifecycle) }) {
            repairs.append(.init(field: "lifecycle", registryValueBefore: registryLifecycle, workspaceValuesBefore: workspace.lifecycleValues, chosenValue: lifecycle, rule: request.desiredLifecycle == nil ? "registry-wins" : "explicit-owner-decision", provenance: request.desiredLifecycle == nil ? "Registry" : "owner-authorized request"))
        }
        if workspace.priorityValuesFound.contains(where: { !TaskCheckpointUTF8.equal($0, registryPriority) }) {
            repairs.append(.init(field: "priority", registryValueBefore: registryPriority, workspaceValuesBefore: workspace.priorityValuesFound, chosenValue: priority, rule: request.desiredPriority != nil ? "explicit-owner-decision" : request.priorityRule.rawValue, provenance: request.desiredPriority != nil || request.priorityRule == .registryAuthoritative ? "owner-authorized Registry decision" : "recognized conflict without provenance"))
        }
        let registryAfter = registry.replacing(lifecycle: lifecycle, priority: priority)
        let workspaceAfter = try workspace.replacing(lifecycle: lifecycle, priority: priority)
        let postRegistry = try LifecyclePriorityRegistryDocument(data: registryAfter, kind: kind, workID: request.workID)
        let postWorkspace = try LifecyclePriorityWorkspace(data: workspaceAfter, kind: kind, workID: request.workID, registryRow: postRegistry.row)
        guard postWorkspace.lifecycleValues.allSatisfy({ TaskCheckpointUTF8.equal($0, lifecycle) }),
              postWorkspace.priorityValuesFound.allSatisfy({ TaskCheckpointUTF8.equal($0, priority) }) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Prepared postimage did not reconcile every recognized mirror.")
        }
        return LifecyclePriorityPrepared(kind: kind, registryURL: registryURL, workspaceURL: workspaceURL,
                                         registryBefore: registryBefore, registryAfter: registryAfter,
                                         workspaceBefore: workspaceBefore, workspaceAfter: workspaceAfter,
                                         lifecycle: lifecycle, priority: priority, workTitle: registry.row["Title"]!, repairs: repairs,
                                         registryPath: registryPath, workspacePath: workspacePath)
    }

    private func makePreview(request: LifecyclePriorityRequest, prepared: LifecyclePriorityPrepared, root: String) -> LifecyclePriorityPreview {
        let material = [root, request.workID, prepared.registryPath, prepared.workspacePath,
                        hash(prepared.registryBefore), hash(prepared.registryAfter), hash(prepared.workspaceBefore), hash(prepared.workspaceAfter),
                        prepared.lifecycle, prepared.priority, request.priorityRule.rawValue,
                        request.desiredLifecycle ?? "—", request.desiredPriority ?? "—", request.correctsOperation?.uuidString ?? "—"].joined(separator: "\u{1f}")
        return LifecyclePriorityPreview(workID: request.workID, registryPath: prepared.registryPath, workspacePath: prepared.workspacePath,
                                        registrySHA256Before: hash(prepared.registryBefore), registrySHA256After: hash(prepared.registryAfter),
                                        workspaceSHA256Before: hash(prepared.workspaceBefore), workspaceSHA256After: hash(prepared.workspaceAfter),
                                        lifecycle: prepared.lifecycle, priority: prepared.priority, repairs: prepared.repairs,
                                        confirmationToken: hash(Data(material.utf8)))
    }

    private func prepared(from journal: LifecyclePriorityJournal, configuration: ProductionsConfiguration) throws -> LifecyclePriorityPrepared {
        let kind = try LifecyclePriorityKind(id: journal.workID)
        guard TaskCheckpointUTF8.equal(journal.registryPath, kind.registryPath),
              TaskCheckpointUTF8.equal(journal.workspacePath, "Workspace/\(journal.workID)/\(journal.workID).md") else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Journal recovery paths do not match the bound durable record.")
        }
        return LifecyclePriorityPrepared(
            kind: kind,
            registryURL: configuration.taskCheckpointURL(journal.registryPath),
            workspaceURL: configuration.taskCheckpointURL(journal.workspacePath),
            registryBefore: journal.registryPreimage,
            registryAfter: journal.registryExpectedAfter,
            workspaceBefore: journal.workspacePreimage,
            workspaceAfter: journal.workspaceExpectedAfter,
            lifecycle: journal.lifecycle,
            priority: journal.priority,
            workTitle: journal.workTitle,
            repairs: journal.repairs,
            registryPath: journal.registryPath,
            workspacePath: journal.workspacePath
        )
    }

    private func consumeCommittedCorrection(_ correction: LifecyclePriorityJournal) throws {
        guard let correctedID = correction.correctsOperation,
              correction.terminalState?.provesHistoricalCommit == true else { return }
        if let resolver = queueResolver {
            try resolver.markCorrected(operationID: correctedID, correctedBy: correction.operationUUID,
                                       productionsRootPath: correction.productionsRootPath, workID: correction.workID)
            return
        }
        guard var prior = try journalStore.journal(operationID: correctedID),
              TaskCheckpointUTF8.equal(prior.productionsRootPath, correction.productionsRootPath),
              TaskCheckpointUTF8.equal(prior.workID, correction.workID),
              prior.terminalState?.provesHistoricalCommit == true else {
            throw LifecyclePriorityValidationError.targetContractInvalid("The committed correction cannot resolve its bound prior queue entry.")
        }
        guard prior.queueDisposition != .confirmed else {
            throw LifecyclePriorityValidationError.targetContractInvalid("The committed correction targets an acknowledged entry.")
        }
        if prior.queueDisposition == .pending {
            prior.markCorrected()
            try journalStore.update(prior)
        }
    }

    private func queueRecoveryFailure(_ journal: LifecyclePriorityJournal, error: Error) -> LifecyclePriorityCommandResult {
        LifecyclePriorityCommandResult(
            outcome: "committed-with-queue-failure", operationUUID: journal.operationUUID, workID: journal.workID,
            registrySHA256Before: journal.registrySHA256Before, registrySHA256After: journal.registrySHA256ExpectedAfter,
            workspaceSHA256Before: journal.workspaceSHA256Before, workspaceSHA256After: journal.workspaceSHA256ExpectedAfter,
            lifecycle: journal.lifecycle, priority: journal.priority, repairs: journal.repairs,
            queueDisposition: journal.queueDisposition, classification: "committed-and-current-queue-uncertain",
            journalFinalized: journal.journalFinalized, fallbackRecorded: journal.fallbackRecorded,
            historicalCommitProven: true,
            inspectCommand: "OperationsDashboard office inspect --productions-root \(journal.productionsRootPath) --operation \(journal.operationUUID.uuidString)",
            diagnostic: "The canonical correction remains proven, but its prior queue disposition could not be durably reconciled: \(error.localizedDescription). Do not retry automatically."
        )
    }

    private func validatePostimage(_ journal: LifecyclePriorityJournal, configuration: ProductionsConfiguration) throws {
        let registryURL = configuration.taskCheckpointURL(journal.registryPath), workspaceURL = configuration.taskCheckpointURL(journal.workspacePath)
        try requireSafeFile(registryURL, configuration: configuration, label: "Registry reload")
        try requireSafeFile(workspaceURL, configuration: configuration, label: "Workspace reload")
        let registryData = try Data(contentsOf: registryURL), workspaceData = try Data(contentsOf: workspaceURL)
        guard registryData == journal.registryExpectedAfter, workspaceData == journal.workspaceExpectedAfter else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Reload bytes do not match the complete expected postimages.")
        }
        let kind = try LifecyclePriorityKind(id: journal.workID)
        let registry = try LifecyclePriorityRegistryDocument(data: registryData, kind: kind, workID: journal.workID)
        let workspace = try LifecyclePriorityWorkspace(data: workspaceData, kind: kind, workID: journal.workID, registryRow: registry.row)
        guard registry.row[kind.stateHeader] == journal.lifecycle, registry.row["Priority"] == journal.priority,
              workspace.lifecycleValues.allSatisfy({ $0 == journal.lifecycle }), workspace.priorityValuesFound.allSatisfy({ $0 == journal.priority }) else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Reloaded Registry and Workspace mirrors do not agree.")
        }
    }

    private func reconcileReplacement(_ journal: inout LifecyclePriorityJournal, prepared: LifecyclePriorityPrepared, configuration: ProductionsConfiguration, diagnostic: String) throws -> LifecyclePriorityCommandResult {
        let currentRegistry = try? Data(contentsOf: prepared.registryURL), currentWorkspace = try? Data(contentsOf: prepared.workspaceURL)
        if currentRegistry == prepared.registryAfter, currentWorkspace == prepared.workspaceAfter {
            do { try validatePostimage(journal, configuration: configuration) }
            catch { return try finishProven(&journal, prepared: prepared, state: .historicallyCommittedWithCurrentStateUncertain, classification: "historically-committed-current-state-uncertain", diagnostic: "Replacement threw after publication and postimage validation failed: \(error.localizedDescription)") }
            var proposed = journal
            proposed.transition(to: .reconciledCommittedAndCurrent, diagnostic: "Replacement threw after publication; exact complete postimages prove commit. Do not retry automatically.", finalized: true)
            do { try journalStore.update(proposed); journal = proposed }
            catch { return try finishFallback(&journal, prepared: prepared, fallback: .journalFinalizationFailedCommittedAndCurrent, classification: "committed-and-current", diagnostic: "Reconciled commit journal finalization failed: \(error.localizedDescription)") }
            return result("committed", journal: journal, classification: "committed-and-current", diagnostic: journal.diagnostic)
        }
        if currentRegistry == prepared.registryBefore, currentWorkspace == prepared.workspaceBefore {
            return try finishNoCommit(&journal, prepared: prepared, diagnostic: "Replacement failed before a complete commit: \(diagnostic). Do not retry automatically.")
        }
        do {
            if currentRegistry == prepared.registryAfter { try replacer.replace(data: prepared.registryBefore, at: prepared.registryURL) }
            if currentWorkspace == prepared.workspaceAfter { try replacer.replace(data: prepared.workspaceBefore, at: prepared.workspaceURL) }
            guard try Data(contentsOf: prepared.registryURL) == prepared.registryBefore,
                  try Data(contentsOf: prepared.workspaceURL) == prepared.workspaceBefore else { throw LifecyclePriorityValidationError.targetContractInvalid("Restore did not reproduce complete preimages.") }
            return try finishNoCommit(&journal, prepared: prepared, diagnostic: "Partial replacement was restored to exact complete preimages. Do not retry automatically.")
        } catch {
            return finishUncertain(&journal, diagnostic: "Partial replacement could not be safely classified or restored: \(error.localizedDescription). Do not retry automatically.")
        }
    }

    private func finishNoCommit(_ journal: inout LifecyclePriorityJournal, prepared: LifecyclePriorityPrepared, diagnostic: String) throws -> LifecyclePriorityCommandResult {
        do {
            var proposed = journal
            proposed.transition(to: .definiteNoCommit, diagnostic: diagnostic, finalized: true)
            try journalStore.update(proposed)
            journal = proposed
            return result("not-committed", journal: journal, classification: "definite-no-commit", diagnostic: diagnostic)
        }
        catch { return try finishFallback(&journal, prepared: prepared, fallback: .journalFinalizationFailedDefiniteNoCommit, classification: "definite-no-commit", diagnostic: "Definite-no-commit journal finalization failed: \(error.localizedDescription)") }
    }

    private func finishProven(_ journal: inout LifecyclePriorityJournal, prepared: LifecyclePriorityPrepared?, state: OfficeWorkspaceTerminalState, classification: String, diagnostic: String) throws -> LifecyclePriorityCommandResult {
        do {
            var proposed = journal
            proposed.transition(to: state, diagnostic: diagnostic + " Do not retry automatically.", finalized: true)
            try journalStore.update(proposed)
            journal = proposed
            return result("uncertain", journal: journal, classification: classification, diagnostic: journal.diagnostic)
        }
        catch { return try finishFallback(&journal, prepared: prepared, fallback: .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain, classification: classification, diagnostic: "Terminal journal finalization failed: \(error.localizedDescription)") }
    }

    private func finishUncertain(_ journal: inout LifecyclePriorityJournal, diagnostic: String) -> LifecyclePriorityCommandResult {
        var proposed = journal
        proposed.transition(to: .uncertain, diagnostic: diagnostic, finalized: true)
        do { try journalStore.update(proposed); journal = proposed }
        catch { return uncertain(journal, proven: false, "Uncertain outcome could not be finalized in the journal: \(error.localizedDescription)") }
        return uncertain(journal, proven: false, diagnostic)
    }

    private func finishFallback(_ journal: inout LifecyclePriorityJournal, prepared: LifecyclePriorityPrepared?, fallback: OfficeWorkspaceTerminalState, classification: String, diagnostic: String) throws -> LifecyclePriorityCommandResult {
        var proposed = journal
        proposed.markFallback(fallback, diagnostic: diagnostic + " Do not retry automatically.")
        do { try journalStore.recordFallback(proposed); journal = proposed }
        catch { return uncertain(journal, proven: fallback.provesHistoricalCommit, "Terminal fallback could not be recorded: \(error.localizedDescription)") }
        return result(fallback.provesHistoricalCommit ? "uncertain" : "not-committed", journal: journal, classification: classification, diagnostic: journal.diagnostic)
    }

    private func result(_ outcome: String, journal: LifecyclePriorityJournal, classification: String, diagnostic: String?) -> LifecyclePriorityCommandResult {
        LifecyclePriorityCommandResult(outcome: outcome, operationUUID: journal.operationUUID, workID: journal.workID,
            registrySHA256Before: journal.registrySHA256Before, registrySHA256After: journal.terminalState?.provesHistoricalCommit == true ? journal.registrySHA256ExpectedAfter : nil,
            workspaceSHA256Before: journal.workspaceSHA256Before, workspaceSHA256After: journal.terminalState?.provesHistoricalCommit == true ? journal.workspaceSHA256ExpectedAfter : nil,
            lifecycle: journal.lifecycle, priority: journal.priority, repairs: journal.repairs, queueDisposition: journal.queueDisposition,
            classification: classification, journalFinalized: journal.journalFinalized, fallbackRecorded: journal.fallbackRecorded,
            historicalCommitProven: journal.terminalState?.provesHistoricalCommit == true,
            inspectCommand: "OperationsDashboard office inspect --productions-root \(journal.productionsRootPath) --operation \(journal.operationUUID.uuidString)", diagnostic: diagnostic)
    }

    private func uncertain(_ journal: LifecyclePriorityJournal, proven: Bool, _ diagnostic: String) -> LifecyclePriorityCommandResult {
        LifecyclePriorityCommandResult(outcome: "uncertain", operationUUID: journal.operationUUID, workID: journal.workID,
            registrySHA256Before: journal.registrySHA256Before, registrySHA256After: proven ? journal.registrySHA256ExpectedAfter : nil,
            workspaceSHA256Before: journal.workspaceSHA256Before, workspaceSHA256After: proven ? journal.workspaceSHA256ExpectedAfter : nil,
            lifecycle: journal.lifecycle, priority: journal.priority, repairs: journal.repairs, queueDisposition: journal.queueDisposition,
            classification: proven ? "historically-committed-current-state-uncertain" : "uncertain", journalFinalized: journal.journalFinalized,
            fallbackRecorded: journal.fallbackRecorded, historicalCommitProven: proven,
            inspectCommand: "OperationsDashboard office inspect --productions-root \(journal.productionsRootPath) --operation \(journal.operationUUID.uuidString)", diagnostic: diagnostic + " Do not retry automatically.")
    }

    private func failure(_ operationID: UUID?, request: LifecyclePriorityRequest?, prepared: LifecyclePriorityPrepared? = nil, classification: String, diagnostic: String, exit: Int32) -> LifecyclePriorityCommandFailure {
        LifecyclePriorityCommandFailure(result: LifecyclePriorityCommandResult(outcome: exit == 3 ? "uncertain" : "not-committed", operationUUID: operationID,
            workID: request?.workID, registrySHA256Before: prepared.map { hash($0.registryBefore) }, registrySHA256After: nil,
            workspaceSHA256Before: prepared.map { hash($0.workspaceBefore) }, workspaceSHA256After: nil, lifecycle: prepared?.lifecycle,
            priority: prepared?.priority, repairs: prepared?.repairs, queueDisposition: nil, classification: classification,
            journalFinalized: false, fallbackRecorded: false, historicalCommitProven: false, inspectCommand: nil, diagnostic: diagnostic), exitCode: exit)
    }

    private func classify(_ error: Error) -> String {
        switch error {
        case LifecyclePriorityValidationError.invalidInput: "invalidInput"
        case LifecyclePriorityValidationError.hashMismatch: "hashMismatch"
        case LifecyclePriorityValidationError.confirmationMismatch: "confirmationMismatch"
        case LifecyclePriorityValidationError.targetContractInvalid: "targetContractInvalid"
        default: "not-committed"
        }
    }

    private func requireSafeFile(_ url: URL, configuration: ProductionsConfiguration, label: String) throws {
        let root = configuration.taskCheckpointRootURL, target = url
        guard TaskCheckpointUTF8.hasPrefix(target.path, root.path + "/") else { throw LifecyclePriorityValidationError.targetContractInvalid("\(label) is outside Productions.") }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in target.pathComponents.dropFirst() {
            guard let entries = try? manager.contentsOfDirectory(atPath: current.path), entries.contains(where: { TaskCheckpointUTF8.equal($0, component) }) else { throw LifecyclePriorityValidationError.targetContractInvalid("\(label) path spelling is not exact.") }
            current.append(path: component)
            if (try? manager.destinationOfSymbolicLink(atPath: current.path)) != nil { throw LifecyclePriorityValidationError.targetContractInvalid("\(label) path contains a symbolic link.") }
        }
        var status = stat()
        guard lstat(target.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG, manager.isReadableFile(atPath: target.path) else { throw LifecyclePriorityValidationError.targetContractInvalid("\(label) is not a readable non-followed regular file.") }
    }

    private struct BoundRegularRead {
        let data: Data
        let device: dev_t
        let inode: ino_t
    }

    private func readBoundRegular(_ url: URL, label: String) throws -> BoundRegularRead {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LifecyclePriorityValidationError.targetContractInvalid("\(label) could not be opened without following links.")
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw LifecyclePriorityValidationError.targetContractInvalid("\(label) is not a descriptor-bound regular file.")
        }
        let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).readToEnd() ?? Data()
        return BoundRegularRead(data: data, device: status.st_dev, inode: status.st_ino)
    }

    private func requireBoundIdentity(_ url: URL, bound: BoundRegularRead, label: String) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_dev == bound.device, status.st_ino == bound.inode else {
            throw LifecyclePriorityValidationError.targetContractInvalid("\(label) changed identity before restore.")
        }
    }

    private func priorityRank(_ value: String) -> Int { ["Unranked", "Low", "Medium", "High", "Highest"].firstIndex(of: value) ?? -1 }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}



private extension JSONEncoder {
    static var officeJournal: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var officeJournal: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
