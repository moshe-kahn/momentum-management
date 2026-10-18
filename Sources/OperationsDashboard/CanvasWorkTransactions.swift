import CryptoKit
import Darwin
import Foundation

enum CanvasWorkAction: String, Codable, Equatable, Identifiable {
    case start
    case stop

    var id: String { rawValue }
    var title: String { self == .start ? "Start work" : "Stop work" }
}

enum CanvasWorkTransactionTerminalState: String, Codable, Equatable {
    // Retained for journals written before ordinary desired-state operations.
    case preCommitFailure
    case definiteNoCommit
    case alreadyDesired
    case committed
    case reconciledCommit
    case historicalCommitSuperseded
    case historicallyCommittedWithCurrentStateUncertain
    case committedReloadFailed
    case uncertain
    case journalFinalizationFailedCommittedAndCurrentlySatisfied
    case journalFinalizationFailedHistoricallyCommittedAndSuperseded
    case journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain

    var isIncomplete: Bool { self == .uncertain || self == .preCommitFailure }

    /// Central semantic proof boundary. The exhaustive switch forces every
    /// future terminal state to declare whether it proves a historical commit.
    var provesHistoricalCommit: Bool {
        switch self {
        case .committed, .reconciledCommit, .historicalCommitSuperseded,
             .historicallyCommittedWithCurrentStateUncertain, .committedReloadFailed,
             .journalFinalizationFailedCommittedAndCurrentlySatisfied,
             .journalFinalizationFailedHistoricallyCommittedAndSuperseded,
             .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain:
            true
        case .preCommitFailure, .definiteNoCommit, .alreadyDesired, .uncertain:
            false
        }
    }

    static func merging(
        current: CanvasWorkTransactionTerminalState?,
        proposed: CanvasWorkTransactionTerminalState
    ) -> CanvasWorkTransactionTerminalState {
        guard let current, current.provesHistoricalCommit, !proposed.provesHistoricalCommit else {
            return proposed
        }
        return switch current {
        case .journalFinalizationFailedCommittedAndCurrentlySatisfied,
             .journalFinalizationFailedHistoricallyCommittedAndSuperseded,
             .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain:
            .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain
        case .committedReloadFailed:
            .committedReloadFailed
        case .committed, .reconciledCommit, .historicalCommitSuperseded,
             .historicallyCommittedWithCurrentStateUncertain:
            .historicallyCommittedWithCurrentStateUncertain
        case .preCommitFailure, .definiteNoCommit, .alreadyDesired, .uncertain:
            proposed
        }
    }
}

enum CanvasProvenCommitStatus: String, Codable, Equatable {
    case committedAndCurrentlySatisfied
    case historicallyCommittedAndSuperseded
    case historicallyCommittedWithCurrentStateUncertain

    var diagnostic: String {
        switch self {
        case .committedAndCurrentlySatisfied:
            "The Canvas operation is proven committed and currently satisfied."
        case .historicallyCommittedAndSuperseded:
            "The Canvas operation is proven historically committed and superseded by a later boundary."
        case .historicallyCommittedWithCurrentStateUncertain:
            "The Canvas operation is proven historically committed, but its current state is uncertain."
        }
    }

    var journalFailureTerminalState: CanvasWorkTransactionTerminalState {
        switch self {
        case .committedAndCurrentlySatisfied: .journalFinalizationFailedCommittedAndCurrentlySatisfied
        case .historicallyCommittedAndSuperseded: .journalFinalizationFailedHistoricallyCommittedAndSuperseded
        case .historicallyCommittedWithCurrentStateUncertain: .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain
        }
    }
}

enum CanvasInterruptedMutationCommitEvidence: String, Codable, Equatable {
    case possibleCommit
    case historicallyCommittedWithCurrentStateUncertain

    var diagnostic: String {
        switch self {
        case .possibleCommit:
            "Classification: possible commit. The replacement failed, so current Canvas and journal state are uncertain."
        case .historicallyCommittedWithCurrentStateUncertain:
            "Classification: historically committed with current state uncertain. Reload failure proves the commit, but current Canvas and journal state are uncertain."
        }
    }
}

enum CanvasOperationOutcomeError: LocalizedError, Equatable {
    case journalFinalizationFailed(UUID, CanvasProvenCommitStatus, fallbackRecorded: Bool)
    case interruptedMutationJournalReadFailed(UUID, CanvasInterruptedMutationCommitEvidence, String)
    case definiteNoCommit(UUID, journalFinalized: Bool)

    var requiresExitThree: Bool {
        switch self {
        case .journalFinalizationFailed, .interruptedMutationJournalReadFailed: true
        case .definiteNoCommit: false
        }
    }

    var errorDescription: String? {
        switch self {
        case let .journalFinalizationFailed(operationID, commitStatus, fallbackRecorded):
            let fallback = fallbackRecorded
                ? "A terminal journal-finalization-failure marker was recorded."
                : "The journal may still appear incomplete in startup recovery."
            return "Canvas operation \(operationID.uuidString): \(commitStatus.diagnostic) The journal failed to reach its correct terminal state. \(fallback) The operation must not be retried. Inspect with `canvas inspect --productions-root <path> --operation \(operationID.uuidString)`."
        case let .interruptedMutationJournalReadFailed(operationID, evidence, journalDiagnostic):
            return "Canvas operation \(operationID.uuidString): \(evidence.diagnostic) The recovery journal could not be read: \(journalDiagnostic). The operation must not be retried. When journal access is available, inspect with `canvas inspect --productions-root <path> --operation \(operationID.uuidString)`."
        case let .definiteNoCommit(operationID, journalFinalized):
            let journal = journalFinalized
                ? "The journal records definite no-commit."
                : "The journal could not be finalized and may remain visible in startup recovery. Do not retry until `canvas inspect` confirms the no-commit evidence."
            return "Canvas operation \(operationID.uuidString) definitely did not commit. \(journal) Inspect with `canvas inspect --productions-root <path> --operation \(operationID.uuidString)`."
        }
    }
}

struct CanvasWorkTransactionJournal: Codable, Equatable {
    let transactionID: UUID
    let timestamp: Date
    let action: CanvasWorkAction
    let workID: String
    let canvasHash: String
    let canvasPreimage: Data
    let appendedEvents: [String]
    let reason: String?
    let context: String?
    let clearBasis: CanvasClearBasis?
    let targetHash: String?
    let expectedCanvasHash: String?
    private(set) var terminalState: CanvasWorkTransactionTerminalState?
    var diagnostic: String?

    mutating func transition(
        to proposed: CanvasWorkTransactionTerminalState,
        diagnostic proposedDiagnostic: String?
    ) {
        let priorProvesCommit = terminalState?.provesHistoricalCommit == true
        terminalState = .merging(current: terminalState, proposed: proposed)
        if priorProvesCommit, !proposed.provesHistoricalCommit {
            let detail = proposedDiagnostic.map { " \($0)" } ?? ""
            diagnostic = "The operation is proven historically committed, but its current state is uncertain.\(detail) The operation must not be retried."
        } else {
            diagnostic = proposedDiagnostic
        }
    }
}

protocol CanvasWorkTransactionJournalStore {
    func persist(_ journal: CanvasWorkTransactionJournal) throws
    func update(_ journal: CanvasWorkTransactionJournal) throws
    func incomplete() throws -> [CanvasWorkTransactionJournal]
    func journal(transactionID: UUID) throws -> CanvasWorkTransactionJournal?
}

extension CanvasWorkTransactionJournalStore {
    func journal(transactionID: UUID) throws -> CanvasWorkTransactionJournal? {
        try incomplete().first { $0.transactionID == transactionID }
    }
}

struct ApplicationSupportCanvasWorkTransactionJournalStore: CanvasWorkTransactionJournalStore {
    private let manager = FileManager.default
    private var directory: URL {
        RecoveryJournalRoot.directory(named: "Canvas Work Transaction Recovery", manager: manager)
    }

    func persist(_ journal: CanvasWorkTransactionJournal) throws { try write(journal) }
    func update(_ journal: CanvasWorkTransactionJournal) throws { try write(journal) }
    func incomplete() throws -> [CanvasWorkTransactionJournal] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            let journal = try JSONDecoder().decode(CanvasWorkTransactionJournal.self, from: Data(contentsOf: url))
            guard let terminalState = journal.terminalState else { return journal }
            return terminalState.isIncomplete ? journal : nil
        }
    }
    func journal(transactionID: UUID) throws -> CanvasWorkTransactionJournal? {
        let target = directory.appending(path: "\(transactionID.uuidString).json")
        guard manager.fileExists(atPath: target.path) else { return nil }
        return try JSONDecoder().decode(CanvasWorkTransactionJournal.self, from: Data(contentsOf: target))
    }

    private func write(_ journal: CanvasWorkTransactionJournal) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "\(journal.transactionID.uuidString).json")
        try DurableReplacement(manager: manager).replace(data: try JSONEncoder().encode(journal), at: target)
    }
}

protocol CanvasWorkTransactionLocking {
    func acquire(canvasURL: URL) -> AnyObject?
}

private final class CanvasWriteLock: NSObject {
    private let descriptor: Int32

    init?(canvasURL: URL) {
        descriptor = open(canvasURL.path, O_RDWR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            return nil
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

struct LocalCanvasWorkTransactionLocking: CanvasWorkTransactionLocking {
    func acquire(canvasURL: URL) -> AnyObject? { CanvasWriteLock(canvasURL: canvasURL) }
}

enum CanvasWorkTransactionError: LocalizedError, Equatable {
    case invalidInput(String)
    case invalidTarget(String)
    case notCurrent
    case conflict(String)
    case lockUnavailable
    case journalFailed(String)
    case replacementFailed(String)
    case reloadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(message), let .invalidTarget(message), let .conflict(message),
             let .journalFailed(message), let .replacementFailed(message), let .reloadFailed(message): message
        case .notCurrent: "Stop work is available only while the selected work is on Canvas."
        case .lockUnavailable: "Another Canvas write transaction is in progress."
        }
    }
}

struct CanvasWorkTransactionResult: Equatable {
    let workID: String
    let action: CanvasWorkAction
    let appendedEvents: [String]
    let timestamp: Date
}

enum CanvasDesiredState: String, Codable, Equatable {
    case focused
    case clear

    var action: CanvasWorkAction { self == .focused ? .start : .stop }
    func matches(isCurrent: Bool) -> Bool { self == .focused ? isCurrent : !isCurrent }
}

enum CanvasDesiredStateTransactionOutcome: Equatable {
    case changed(CanvasWorkTransactionResult)
    case alreadyDesired
}

struct CanvasWorkTransactionService {
    let journalStore: any CanvasWorkTransactionJournalStore
    let replacer: any AtomicFileReplacing
    let locking: any CanvasWorkTransactionLocking
    let now: () -> Date
    let makeOperationID: () -> UUID

    init(
        journalStore: any CanvasWorkTransactionJournalStore = ApplicationSupportCanvasWorkTransactionJournalStore(),
        replacer: (any AtomicFileReplacing)? = nil,
        locking: any CanvasWorkTransactionLocking = LocalCanvasWorkTransactionLocking(),
        now: @escaping () -> Date = Date.init,
        makeOperationID: @escaping () -> UUID = UUID.init
    ) {
        self.journalStore = journalStore
        self.replacer = replacer ?? DurableReplacement()
        self.locking = locking
        self.now = now
        self.makeOperationID = makeOperationID
    }

    func startupRecovery() -> [CanvasWorkTransactionJournal] { (try? journalStore.incomplete()) ?? [] }

    func perform(
        action: CanvasWorkAction,
        configuration: ProductionsConfiguration,
        work: WorkItem,
        reason: String,
        context: String,
        clearBasis: CanvasClearBasis? = nil,
        reload: (ProductionsConfiguration) throws -> ProductionsState
    ) throws -> CanvasWorkTransactionResult {
        try CanvasContinuityPolicy.validate(
            desiredState: action == .start ? .focused : .clear,
            clearBasis: clearBasis,
            kind: work.kind,
            lifecycle: work.lifecycle
        )
        let outcome = try performLocked(
            action: action,
            configuration: configuration,
            work: work,
            reason: reason,
            context: context,
            operationID: makeOperationID(),
            noOpWhenDesired: false,
            requiresCleanProductions: true,
            clearBasis: clearBasis,
            reload: reload
        )
        guard case let .changed(result) = outcome else { preconditionFailure("Low-level Canvas actions never return a desired-state no-op.") }
        return result
    }

    func performDesiredState(
        _ desiredState: CanvasDesiredState,
        operationID: UUID,
        configuration: ProductionsConfiguration,
        work: WorkItem,
        reason: String,
        context: String,
        clearBasis: CanvasClearBasis? = nil,
        reload: (ProductionsConfiguration) throws -> ProductionsState
    ) throws -> CanvasDesiredStateTransactionOutcome {
        try performLocked(
            action: desiredState.action,
            configuration: configuration,
            work: work,
            reason: reason,
            context: context,
            operationID: operationID,
            noOpWhenDesired: true,
            requiresCleanProductions: false,
            clearBasis: clearBasis,
            reload: reload
        )
    }

    private func performLocked(
        action: CanvasWorkAction,
        configuration: ProductionsConfiguration,
        work: WorkItem,
        reason: String,
        context: String,
        operationID: UUID,
        noOpWhenDesired: Bool,
        requiresCleanProductions: Bool,
        clearBasis: CanvasClearBasis?,
        reload: (ProductionsConfiguration) throws -> ProductionsState
    ) throws -> CanvasDesiredStateTransactionOutcome {
        try validateField(reason, name: "Reason")
        try validateField(context, name: "Context")
        let canvasURL = configuration.url(ProductionsPath.canvas.rawValue)
        guard let lock = locking.acquire(canvasURL: canvasURL) else { throw CanvasWorkTransactionError.lockUnavailable }
        defer { _ = lock }

        let baselineState = try reload(configuration)
        guard !requiresCleanProductions || baselineState.issues.isEmpty else {
            throw CanvasWorkTransactionError.conflict("Productions has contract issues; resolve them before changing Canvas.")
        }
        guard let canonicalWork = baselineState.work.first(where: { $0.id == work.id && $0.kind == work.kind }) else {
            throw CanvasWorkTransactionError.invalidTarget("The selected work is no longer present in the canonical loaded state.")
        }
        guard canonicalWork.lifecycle == work.lifecycle else {
            throw CanvasWorkTransactionError.conflict("The selected work lifecycle changed before the Canvas transaction.")
        }
        try CanvasContinuityPolicy.validate(
            desiredState: action == .start ? .focused : .clear,
            clearBasis: clearBasis,
            kind: canonicalWork.kind,
            lifecycle: canonicalWork.lifecycle
        )
        let targetHash = try validateTarget(work, configuration: configuration)
        let preimage = try Data(contentsOf: canvasURL)
        let canvasHash = hash(preimage)
        let document = String(decoding: preimage, as: UTF8.self)
        let rows = try parseCanvasRows(document)
        try validateResolvedCanvasRows(rows, state: baselineState, targetOnly: requiresCleanProductions ? nil : work)
        try validateTransitionHistory(rows, workID: work.id)
        let isCurrent = currentIDs(rows).contains(work.id)
        if noOpWhenDesired, (action == .start) == isCurrent {
            let journal = CanvasWorkTransactionJournal(
                transactionID: operationID,
                timestamp: now(),
                action: action,
                workID: work.id,
                canvasHash: canvasHash,
                canvasPreimage: preimage,
                appendedEvents: [],
                reason: reason,
                context: context,
                clearBasis: clearBasis,
                targetHash: targetHash,
                expectedCanvasHash: canvasHash,
                terminalState: .alreadyDesired,
                diagnostic: "The requested Canvas state was already current; no event was appended."
            )
            do { try journalStore.persist(journal) }
            catch { throw CanvasWorkTransactionError.journalFailed("Could not persist Canvas operation journal: \(error.localizedDescription)") }
            return .alreadyDesired
        }
        if action == .stop, !isCurrent { throw CanvasWorkTransactionError.notCurrent }

        let timestamp = now()
        let formatter = ISO8601DateFormatter()
        let occurred = formatter.string(from: timestamp)
        let events: [String]
        switch action {
        case .start:
            events = isCurrent ? ["Engaged"] : ["Placed", "Engaged"]
        case .stop:
            events = ["Cleared"]
        }
        let eventRows = try events.map { event in
            try makeRow(occurred: occurred, workID: work.id, event: event, reason: reason, context: context)
        }
        let replacement = try append(rows: eventRows, to: document)
        try validateReplacement(replacement, previousRows: rows, appendedRows: eventRows, workID: work.id, action: action)

        var journal = CanvasWorkTransactionJournal(
            transactionID: operationID,
            timestamp: timestamp,
            action: action,
            workID: work.id,
            canvasHash: canvasHash,
            canvasPreimage: preimage,
            appendedEvents: events,
            reason: reason,
            context: context,
            clearBasis: clearBasis,
            targetHash: targetHash,
            expectedCanvasHash: hash(Data(replacement.utf8)),
            terminalState: nil,
            diagnostic: nil
        )
        do { try journalStore.persist(journal) }
        catch { throw CanvasWorkTransactionError.journalFailed("Could not persist Canvas recovery journal: \(error.localizedDescription)") }

        let expectedCurrent = try Data(contentsOf: canvasURL)
        guard hash(expectedCurrent) == canvasHash else {
            journal.transition(to: .definiteNoCommit, diagnostic: "Canvas changed after the transaction was prepared.")
            try? journalStore.update(journal)
            throw CanvasWorkTransactionError.conflict(journal.diagnostic!)
        }
        guard try validateTarget(work, configuration: configuration) == targetHash else {
            journal.transition(to: .definiteNoCommit, diagnostic: "The canonical Canvas target changed after the transaction was prepared.")
            try? journalStore.update(journal)
            throw CanvasWorkTransactionError.conflict(journal.diagnostic!)
        }

        do { try replacer.replace(data: Data(replacement.utf8), at: canvasURL) }
        catch {
            let currentHash = (try? Data(contentsOf: canvasURL)).map(hash)
            journal.transition(
                to: currentHash == canvasHash ? .definiteNoCommit : .uncertain,
                diagnostic: "Canvas replacement failed: \(error.localizedDescription)"
            )
            try? journalStore.update(journal)
            throw CanvasWorkTransactionError.replacementFailed(journal.diagnostic!)
        }

        try finalizeJournalAfterProvenCommit(
            journal: &journal, terminalState: .committed, diagnostic: nil,
            previousRows: rows, occurred: occurred, events: events, workID: work.id,
            reason: reason, context: context, canvasURL: canvasURL
        )
        let state: ProductionsState
        do {
            state = try reload(configuration)
        } catch {
            try finalizeJournalAfterProvenCommit(
                journal: &journal, terminalState: .committedReloadFailed,
                diagnostic: error.localizedDescription,
                previousRows: rows, occurred: occurred, events: events, workID: work.id,
                reason: reason, context: context, canvasURL: canvasURL
            )
            throw CanvasWorkTransactionError.reloadFailed("Canvas committed but canonical reload needs investigation: \(journal.diagnostic!)")
        }
        guard !requiresCleanProductions || state.issues.isEmpty else {
            let diagnostic = state.issues.map(\.message).joined(separator: " · ")
            try finalizeJournalAfterProvenCommit(
                journal: &journal, terminalState: .committedReloadFailed, diagnostic: diagnostic,
                previousRows: rows, occurred: occurred, events: events, workID: work.id,
                reason: reason, context: context, canvasURL: canvasURL
            )
            throw CanvasWorkTransactionError.reloadFailed("Canvas committed but contract reload needs investigation: \(journal.diagnostic!)")
        }
        guard try validateTarget(work, configuration: configuration) == targetHash else {
            try finalizeJournalAfterProvenCommit(
                journal: &journal, terminalState: .committedReloadFailed,
                diagnostic: "Canvas committed, but the canonical target changed during verification.",
                previousRows: rows, occurred: occurred, events: events, workID: work.id,
                reason: reason, context: context, canvasURL: canvasURL
            )
            throw CanvasWorkTransactionError.reloadFailed(journal.diagnostic!)
        }
        let committedRows = try parseCanvasRows(String(decoding: Data(contentsOf: canvasURL), as: UTF8.self))
        do { try validateResolvedCanvasRows(committedRows, state: state, targetOnly: requiresCleanProductions ? nil : work) }
        catch {
            try finalizeJournalAfterProvenCommit(
                journal: &journal, terminalState: .committedReloadFailed, diagnostic: error.localizedDescription,
                previousRows: rows, occurred: occurred, events: events, workID: work.id,
                reason: reason, context: context, canvasURL: canvasURL
            )
            throw CanvasWorkTransactionError.reloadFailed("Canvas committed but its live schema needs investigation: \(error.localizedDescription)")
        }
        if noOpWhenDesired, !exactOperationBoundaryIsCurrent(
            previousRows: rows,
            committedRows: committedRows,
            occurred: occurred,
            events: events,
            workID: work.id,
            reason: reason,
            context: context
        ) {
            try finalizeJournalAfterProvenCommit(
                journal: &journal, terminalState: .committedReloadFailed,
                diagnostic: "Canvas committed, but the exact operation boundary is no longer current.",
                previousRows: rows, occurred: occurred, events: events, workID: work.id,
                reason: reason, context: context, canvasURL: canvasURL
            )
            throw CanvasWorkTransactionError.reloadFailed(journal.diagnostic!)
        }
        let shouldBeCurrent = action == .start
        guard state.canvasCurrentIDs.contains(work.id) == shouldBeCurrent else {
            try finalizeJournalAfterProvenCommit(
                journal: &journal, terminalState: .committedReloadFailed,
                diagnostic: "Reloaded Canvas membership does not match the committed \(action.title) action.",
                previousRows: rows, occurred: occurred, events: events, workID: work.id,
                reason: reason, context: context, canvasURL: canvasURL
            )
            throw CanvasWorkTransactionError.reloadFailed(journal.diagnostic!)
        }

        return .changed(CanvasWorkTransactionResult(workID: work.id, action: action, appendedEvents: events, timestamp: timestamp))
    }

    func validateTarget(_ work: WorkItem, configuration: ProductionsConfiguration) throws -> String {
        let path: ProductionsPath
        let idHeader: String
        switch work.kind {
        case .task: path = .tasks; idHeader = "Task ID"
        case .idea: path = .ideas; idHeader = "Idea ID"
        case .project: path = .projects; idHeader = "Project ID"
        case .initiative: path = .initiatives; idHeader = "Initiative ID"
        }
        let data = try Data(contentsOf: configuration.url(path.rawValue))
        let registryRows: [[String: String]]
        do { registryRows = try MarkdownTable.parse(String(decoding: data, as: UTF8.self), required: [idHeader, "Workspace"]) }
        catch { throw CanvasWorkTransactionError.invalidTarget("The selected work Registry is malformed.") }
        let matches = registryRows.filter { $0[idHeader] == work.id }
        guard matches.count == 1, let row = matches.first else {
            throw CanvasWorkTransactionError.invalidTarget("The selected work is no longer registered.")
        }
        let canonicalLifecycle = row["State"] ?? row["Disposition"] ?? ""
        guard row["Title"] == work.title,
              canonicalLifecycle == work.lifecycle,
              row["Priority"] == work.priority,
              row["Current lead"] == work.lead else {
            throw CanvasWorkTransactionError.invalidTarget("The selected work changed after it was loaded; reload before changing Canvas.")
        }
        let workspace = MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry")
        let workspaceURL = configuration.url(workspace)
        guard workspace == "Workspace/\(work.id)/\(work.id).md",
              FileManager.default.fileExists(atPath: workspaceURL.path) else {
            throw CanvasWorkTransactionError.invalidTarget("The selected work does not resolve to its canonical Workspace record.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let identity = try encoder.encode(row) + Data(contentsOf: workspaceURL)
        return hash(identity)
    }

    func inspect(
        configuration: ProductionsConfiguration,
        work: WorkItem,
        state: ProductionsState,
        targetOnly: Bool = false
    ) throws -> CanvasOperationInspection {
        let targetHash = try validateTarget(work, configuration: configuration)
        let data = try Data(contentsOf: configuration.url(ProductionsPath.canvas.rawValue))
        let rows = try parseCanvasRows(String(decoding: data, as: UTF8.self))
        try validateResolvedCanvasRows(rows, state: state, targetOnly: targetOnly ? work : nil)
        try validateTransitionHistory(rows, workID: work.id)
        return CanvasOperationInspection(canvasHash: hash(data), targetHash: targetHash, isCurrent: currentIDs(rows).contains(work.id), rows: rows)
    }

    private func validateField(_ value: String, name: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CanvasWorkTransactionError.invalidInput("\(name) is required.") }
        guard !value.contains("|"), !value.contains("\n"), !value.contains("\r"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw CanvasWorkTransactionError.invalidInput("\(name) cannot contain table-breaking characters.")
        }
    }

    private func parseCanvasRows(_ canvas: String) throws -> [[String: String]] {
        do {
            let result = try CanvasMarkdown.parse(canvas)
            guard !result.isFragmented else {
                throw CanvasWorkTransactionError.conflict("Canvas is fragmented or contains orphaned rows.")
            }
            let rows = result.rows
            guard rows.allSatisfy({ ["Placed", "Engaged", "Cleared"].contains($0["Event"] ?? "") }) else {
                throw CanvasWorkTransactionError.conflict("Canvas contains an invalid event.")
            }
            let formatter = ISO8601DateFormatter()
            guard rows.allSatisfy({ row in
                formatter.date(from: row["Occurred"] ?? "") != nil
                    && !(row["Work ID"] ?? "").isEmpty
                    && !(row["Reason"] ?? "").isEmpty
                    && !(row["Context"] ?? "").isEmpty
            }) else {
                throw CanvasWorkTransactionError.conflict("Canvas contains a malformed required field.")
            }
            return rows
        } catch let error as CanvasWorkTransactionError { throw error }
        catch { throw CanvasWorkTransactionError.conflict("Canvas table is malformed: \(error.localizedDescription)") }
    }

    private func validateResolvedCanvasRows(
        _ rows: [[String: String]],
        state: ProductionsState,
        targetOnly: WorkItem? = nil
    ) throws {
        if let targetOnly {
            let workIDs = Set(state.work.map(\.id))
            guard state.work.contains(where: { $0.id == targetOnly.id && $0.kind == targetOnly.kind }),
                  rows.count == state.canvas.count,
                  rows.allSatisfy({ workIDs.contains($0["Work ID"] ?? "") }) else {
                throw CanvasWorkTransactionError.conflict("Canvas membership for \(targetOnly.id) cannot be resolved from its canonical target fingerprint.")
            }
            return
        }
        let workIDs = Set(state.work.map(\.id))
        guard rows.count == state.canvas.count, rows.allSatisfy({ workIDs.contains($0["Work ID"] ?? "") }) else {
            throw CanvasWorkTransactionError.conflict("Canvas contains an unresolved or malformed canonical row.")
        }
    }

    private func validateTransitionHistory(_ rows: [[String: String]], workID: String) throws {
        var isCurrent = false
        for row in rows where row["Work ID"] == workID {
            switch row["Event"] {
            case "Placed" where !isCurrent:
                isCurrent = true
            case "Engaged" where isCurrent:
                break
            case "Cleared" where isCurrent:
                isCurrent = false
            case "Placed":
                throw CanvasWorkTransactionError.conflict("Canvas transition history for \(workID) contains Placed while already current.")
            case "Engaged":
                throw CanvasWorkTransactionError.conflict("Canvas transition history for \(workID) contains Engaged while off Canvas.")
            case "Cleared":
                throw CanvasWorkTransactionError.conflict("Canvas transition history for \(workID) contains Cleared while already off Canvas.")
            default:
                throw CanvasWorkTransactionError.conflict("Canvas transition history for \(workID) contains an invalid event.")
            }
        }
    }

    private func currentIDs(_ rows: [[String: String]]) -> Set<String> {
        let boundaries = rows.reduce(into: [String: String]()) { result, row in
            if row["Event"] == "Placed" || row["Event"] == "Cleared" { result[row["Work ID"] ?? ""] = row["Event"] }
        }
        return Set(boundaries.filter { $0.value == "Placed" }.map(\.key))
    }

    private func makeRow(occurred: String, workID: String, event: String, reason: String, context: String) throws -> String {
        for value in [occurred, workID, event] { try validateField(value, name: "Canvas field") }
        return "| \([occurred, workID, event, reason, context].joined(separator: " | ")) |"
    }

    private func append(rows: [String], to canvas: String) throws -> String {
        var lines = canvas.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.firstIndex(where: { MarkdownTable.cells($0) == ["Occurred", "Work ID", "Event", "Reason", "Context"] }),
              headerIndex + 1 < lines.count,
              lines[headerIndex + 1].contains("---") else {
            throw CanvasWorkTransactionError.conflict("Canvas table header is unavailable.")
        }
        var insertionIndex = headerIndex + 2
        while insertionIndex < lines.count, lines[insertionIndex].hasPrefix("|") { insertionIndex += 1 }
        lines.insert(contentsOf: rows, at: insertionIndex)
        let joined = lines.joined(separator: "\n")
        return canvas.hasSuffix("\n") && !joined.hasSuffix("\n") ? joined + "\n" : joined
    }

    private func validateReplacement(_ canvas: String, previousRows: [[String: String]], appendedRows: [String], workID: String, action: CanvasWorkAction) throws {
        let rows = try parseCanvasRows(canvas)
        try validateTransitionHistory(rows, workID: workID)
        guard rows.count == previousRows.count + appendedRows.count else {
            throw CanvasWorkTransactionError.conflict("Canvas replacement changed an unexpected number of rows.")
        }
        let tail = Array(rows.suffix(appendedRows.count))
        guard tail.map({ $0["Work ID"] ?? "" }) == Array(repeating: workID, count: appendedRows.count),
              tail.map({ $0["Event"] ?? "" }) == (action == .start && appendedRows.count == 2 ? ["Placed", "Engaged"] : [action == .start ? "Engaged" : "Cleared"]) else {
            throw CanvasWorkTransactionError.conflict("Canvas replacement does not contain the exact authorized events.")
        }
    }

    private func exactOperationBoundaryIsCurrent(
        previousRows: [[String: String]],
        committedRows: [[String: String]],
        occurred: String,
        events: [String],
        workID: String,
        reason: String,
        context: String
    ) -> Bool {
        guard committedRows.count >= previousRows.count + events.count,
              Array(committedRows.prefix(previousRows.count)) == previousRows else { return false }
        let operationRows = committedRows.dropFirst(previousRows.count).prefix(events.count)
        guard zip(operationRows, events).allSatisfy({ row, event in
            row["Occurred"] == occurred && row["Work ID"] == workID && row["Event"] == event && row["Reason"] == reason && row["Context"] == context
        }), let relativeBoundary = events.firstIndex(where: { $0 == "Placed" || $0 == "Cleared" }) else { return false }
        let operationBoundary = previousRows.count + relativeBoundary
        let latestBoundary = committedRows.indices.last { index in
            committedRows[index]["Work ID"] == workID && ["Placed", "Cleared"].contains(committedRows[index]["Event"] ?? "")
        }
        return latestBoundary == operationBoundary
    }

    private func provenCommitStatus(
        journal: CanvasWorkTransactionJournal,
        previousRows: [[String: String]],
        occurred: String,
        events: [String],
        workID: String,
        reason: String,
        context: String,
        canvasURL: URL
    ) -> CanvasProvenCommitStatus {
        guard let data = try? Data(contentsOf: canvasURL) else { return .historicallyCommittedWithCurrentStateUncertain }
        if journal.expectedCanvasHash == hash(data) { return .committedAndCurrentlySatisfied }
        guard let committedRows = try? parseCanvasRows(String(decoding: data, as: UTF8.self)),
              committedRows.count >= previousRows.count + events.count,
              Array(committedRows.prefix(previousRows.count)) == previousRows else { return .historicallyCommittedWithCurrentStateUncertain }
        let operationRows = committedRows.dropFirst(previousRows.count).prefix(events.count)
        guard zip(operationRows, events).allSatisfy({ row, event in
            row["Occurred"] == occurred && row["Work ID"] == workID && row["Event"] == event && row["Reason"] == reason && row["Context"] == context
        }) else { return .historicallyCommittedWithCurrentStateUncertain }
        return exactOperationBoundaryIsCurrent(
            previousRows: previousRows,
            committedRows: committedRows,
            occurred: occurred,
            events: events,
            workID: workID,
            reason: reason,
            context: context
        ) ? .committedAndCurrentlySatisfied : .historicallyCommittedAndSuperseded
    }

    private func finalizeJournalAfterProvenCommit(
        journal: inout CanvasWorkTransactionJournal,
        terminalState: CanvasWorkTransactionTerminalState,
        diagnostic: String?,
        previousRows: [[String: String]],
        occurred: String,
        events: [String],
        workID: String,
        reason: String,
        context: String,
        canvasURL: URL
    ) throws {
        journal.transition(to: terminalState, diagnostic: diagnostic)
        do { try journalStore.update(journal) }
        catch {
            let commitStatus = provenCommitStatus(
                journal: journal,
                previousRows: previousRows,
                occurred: occurred,
                events: events,
                workID: workID,
                reason: reason,
                context: context,
                canvasURL: canvasURL
            )
            journal.transition(
                to: commitStatus.journalFailureTerminalState,
                diagnostic: "\(commitStatus.diagnostic) The journal failed to reach its correct terminal state: \(error.localizedDescription). The operation must not be retried."
            )
            let fallbackRecorded = (try? journalStore.update(journal)) != nil
            throw CanvasOperationOutcomeError.journalFinalizationFailed(journal.transactionID, commitStatus, fallbackRecorded: fallbackRecorded)
        }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
