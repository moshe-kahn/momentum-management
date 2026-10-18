import Foundation

struct CanvasOperationInspection: Equatable {
    let canvasHash: String
    let targetHash: String
    let isCurrent: Bool
    let rows: [[String: String]]
}

struct CanvasLockRetryPolicy: Equatable {
    let maximumAttempts: Int
    let delay: TimeInterval

    static let ordinary = CanvasLockRetryPolicy(maximumAttempts: 4, delay: 0.15)
}

/// The complete set of owner-level conditions that can end task-level Canvas
/// attention. A working session ending, a review handoff, a checkpoint, or a
/// routine next phase is deliberately not represented here.
enum CanvasClearBasis: String, Codable, CaseIterable, Equatable {
    case ownerPause = "owner-pause"
    case ownerStop = "owner-stop"
    case completed
    case obsolete
    case indefiniteExternalWait = "indefinite-external-wait"

    var auditContextPrefix: String { "Canvas clear basis: \(rawValue)." }
}

enum CanvasContinuityPolicyError: LocalizedError, Equatable {
    case clearBasisRequired
    case clearBasisForbiddenForFocus
    case clearBasisForbiddenForNonTask
    case lifecycleMismatch(CanvasClearBasis, String)

    var errorDescription: String? {
        switch self {
        case .clearBasisRequired:
            "Clear requires one explicit task-level basis: owner-pause, owner-stop, completed, obsolete, or indefinite-external-wait. A session stop, review handoff, checkpoint, or routine phase transition must leave the Task focused."
        case .clearBasisForbiddenForFocus:
            "Focus and Start do not accept a clear basis."
        case .clearBasisForbiddenForNonTask:
            "Task-level clear bases do not apply to Idea, Project, or Initiative attention."
        case let .lifecycleMismatch(basis, lifecycle):
            "Canvas clear basis \(basis.rawValue) does not match canonical lifecycle \(lifecycle). Completed requires Done / Complete and obsolete requires Done / Obsolete."
        }
    }
}

enum CanvasContinuityPolicy {
    static func validateShape(
        desiredState: CanvasDesiredState,
        clearBasis: CanvasClearBasis?,
        workID: String
    ) throws {
        switch desiredState {
        case .focused:
            guard clearBasis == nil else { throw CanvasContinuityPolicyError.clearBasisForbiddenForFocus }
        case .clear where workID.hasPrefix("\(WorkKind.task.identifierPrefix)-"):
            guard clearBasis != nil else { throw CanvasContinuityPolicyError.clearBasisRequired }
        case .clear:
            guard clearBasis == nil else { throw CanvasContinuityPolicyError.clearBasisForbiddenForNonTask }
        }
    }

    static func validate(
        desiredState: CanvasDesiredState,
        clearBasis: CanvasClearBasis?,
        kind: WorkKind,
        lifecycle: String
    ) throws {
        switch desiredState {
        case .focused:
            guard clearBasis == nil else { throw CanvasContinuityPolicyError.clearBasisForbiddenForFocus }
        case .clear where kind == .task:
            guard let clearBasis else { throw CanvasContinuityPolicyError.clearBasisRequired }
            if clearBasis == .completed, lifecycle != "Done / Complete" {
                throw CanvasContinuityPolicyError.lifecycleMismatch(clearBasis, lifecycle)
            }
            if clearBasis == .obsolete, lifecycle != "Done / Obsolete" {
                throw CanvasContinuityPolicyError.lifecycleMismatch(clearBasis, lifecycle)
            }
        case .clear:
            guard clearBasis == nil else { throw CanvasContinuityPolicyError.clearBasisForbiddenForNonTask }
        }
    }
}

enum CanvasContinuityPresentation {
    static let taskClearExplanation = "Task attention persists across session, review, checkpoint, and routine phase handoffs. Clear requires an explicit owner-level or terminal basis."

    static func requiresTaskClearBasis(action: CanvasWorkAction, kind: WorkKind) -> Bool {
        action == .stop && kind == .task
    }

    static func clearBasisOptions(action: CanvasWorkAction, kind: WorkKind) -> [CanvasClearBasis] {
        requiresTaskClearBasis(action: action, kind: kind) ? CanvasClearBasis.allCases : []
    }
}

enum CanvasAttentionDisposition: String, Codable, Equatable {
    case changed
    case alreadyDesired
    case reconciled
}

struct CanvasAttentionOperationResult: Equatable {
    let operationID: UUID
    let workID: String
    let desiredState: CanvasDesiredState
    let clearBasis: CanvasClearBasis?
    let disposition: CanvasAttentionDisposition
    let appendedEvents: [String]

    var compactDescription: String {
        let operation = "Operation \(operationID.uuidString)."
        let basis = clearBasis.map { " for \($0.rawValue)" } ?? ""
        return switch (desiredState, disposition) {
        case (.focused, .changed): "Focused \(workID). \(operation)"
        case (.focused, .alreadyDesired): "\(workID) is already focused; no Canvas event was appended. \(operation)"
        case (.focused, .reconciled): "Focused \(workID); the exact committed result was reconciled. \(operation)"
        case (.clear, .changed): "Cleared \(workID)\(basis). \(operation)"
        case (.clear, .alreadyDesired): "\(workID) is already clear\(basis); no Canvas event was appended. \(operation)"
        case (.clear, .reconciled): "Cleared \(workID)\(basis); the exact committed result was reconciled. \(operation)"
        }
    }
}

enum CanvasAttentionReconciliationStatus: Equatable {
    case committedAndCurrentlySatisfied
    case historicallyCommittedAndSuperseded
    case historicallyCommittedWithCurrentStateUncertain(String)
    case notCommitted
    case alreadyDesired
    case targetChanged
    case uncertain(String)

    var label: String {
        switch self {
        case .committedAndCurrentlySatisfied: "committed-and-currently-satisfied"
        case .historicallyCommittedAndSuperseded: "historically-committed-and-superseded"
        case .historicallyCommittedWithCurrentStateUncertain: "historically-committed-with-current-state-uncertain"
        case .notCommitted: "not-committed"
        case .alreadyDesired: "already-desired"
        case .targetChanged: "target-changed"
        case .uncertain: "uncertain"
        }
    }

    var diagnostic: String? {
        switch self {
        case .committedAndCurrentlySatisfied:
            "The exact journal-bound operation is committed and currently satisfied. A proven commit must not be retried."
        case .historicallyCommittedAndSuperseded:
            "The exact journal-bound operation is historically committed and superseded. A proven commit must not be retried."
        case let .historicallyCommittedWithCurrentStateUncertain(message), let .uncertain(message): message
        default: nil
        }
    }

    var historicalCommitProven: Bool {
        switch self {
        case .committedAndCurrentlySatisfied, .historicallyCommittedAndSuperseded, .historicallyCommittedWithCurrentStateUncertain: true
        case .notCommitted, .alreadyDesired, .targetChanged, .uncertain: false
        }
    }
    var currentRequestedBoundaryProven: Bool { self == .committedAndCurrentlySatisfied || self == .alreadyDesired }
}

enum CanvasAttentionOperationError: LocalizedError, Equatable {
    case targetChanged(UUID)
    case historicalCommitSuperseded(UUID)
    case uncertain(UUID, String)

    var errorDescription: String? {
        switch self {
        case let .targetChanged(operationID):
            "Canvas operation \(operationID.uuidString) stopped because the canonical target changed. Inspect the operation journal and current target; do not retry automatically."
        case let .historicalCommitSuperseded(operationID):
            "Canvas operation \(operationID.uuidString) is proven in Canvas history, but a later boundary superseded it. The original operation is not currently satisfied; inspect it and do not retry automatically."
        case let .uncertain(operationID, diagnostic):
            "Canvas operation \(operationID.uuidString) has an uncertain outcome. \(diagnostic) Inspect canonical Canvas and the recovery journal; do not retry automatically."
        }
    }
}

/// High-level desired-state orchestration for ordinary attention changes.
/// The low-level preview-confirmed Start/Stop surface remains available for
/// sensitive workflows and continues to call CanvasWorkTransactionService
/// directly with its original semantics.
struct CanvasAttentionOperationService {
    let canvas: CanvasWorkTransactionService
    let retryPolicy: CanvasLockRetryPolicy
    let sleep: (TimeInterval) -> Void
    let makeOperationID: () -> UUID

    init(
        canvas: CanvasWorkTransactionService = CanvasWorkTransactionService(),
        retryPolicy: CanvasLockRetryPolicy = .ordinary,
        sleep: @escaping (TimeInterval) -> Void = Thread.sleep(forTimeInterval:),
        makeOperationID: @escaping () -> UUID = UUID.init
    ) {
        self.canvas = canvas
        self.retryPolicy = retryPolicy
        self.sleep = sleep
        self.makeOperationID = makeOperationID
    }

    func perform(
        desiredState: CanvasDesiredState,
        configuration: ProductionsConfiguration,
        work: WorkItem,
        reason: String,
        context: String,
        clearBasis: CanvasClearBasis? = nil,
        reload: (ProductionsConfiguration) throws -> ProductionsState
    ) throws -> CanvasAttentionOperationResult {
        try CanvasContinuityPolicy.validate(desiredState: desiredState, clearBasis: clearBasis, kind: work.kind, lifecycle: work.lifecycle)
        let transactionContext = clearBasis.map { "\($0.auditContextPrefix) \(context)" } ?? context
        let operationID = makeOperationID()
        let before = try canvas.inspect(configuration: configuration, work: work, state: reload(configuration), targetOnly: true)
        let attempts = max(1, retryPolicy.maximumAttempts)

        for attempt in 1...attempts {
            do {
                switch try canvas.performDesiredState(
                    desiredState,
                    operationID: operationID,
                    configuration: configuration,
                    work: work,
                    reason: reason,
                    context: transactionContext,
                    clearBasis: clearBasis,
                    reload: reload
                ) {
                case let .changed(result):
                    return CanvasAttentionOperationResult(operationID: operationID, workID: work.id, desiredState: desiredState, clearBasis: clearBasis, disposition: .changed, appendedEvents: result.appendedEvents)
                case .alreadyDesired:
                    return CanvasAttentionOperationResult(operationID: operationID, workID: work.id, desiredState: desiredState, clearBasis: clearBasis, disposition: .alreadyDesired, appendedEvents: [])
                }
            } catch CanvasWorkTransactionError.lockUnavailable where attempt < attempts {
                if retryPolicy.delay > 0 { sleep(retryPolicy.delay) }
            } catch let error as CanvasWorkTransactionError {
                switch error {
                case .replacementFailed:
                    return try reconcileAfterInterruptedResponse(
                        operationID: operationID,
                        interruptedEvidence: .possibleCommit,
                        desiredState: desiredState,
                        configuration: configuration,
                        work: work,
                        before: before,
                        reload: reload
                    )
                case .reloadFailed:
                    return try reconcileAfterInterruptedResponse(
                        operationID: operationID,
                        interruptedEvidence: .historicallyCommittedWithCurrentStateUncertain,
                        desiredState: desiredState,
                        configuration: configuration,
                        work: work,
                        before: before,
                        reload: reload
                    )
                default:
                    throw error
                }
            }
        }
        throw CanvasWorkTransactionError.lockUnavailable
    }

    func reconcile(
        operationID: UUID,
        desiredState: CanvasDesiredState,
        configuration: ProductionsConfiguration,
        work: WorkItem,
        reader: any ProductionsReading = LocalFileSystem()
    ) throws -> CanvasAttentionReconciliationStatus {
        guard let journal = try canvas.journalStore.journal(transactionID: operationID) else {
            return .uncertain("No recovery journal exists for this operation identity.")
        }
        guard journal.workID == work.id, journal.action == desiredState.action else {
            return .uncertain("The recovery journal does not match the requested target and desired state.")
        }
        if let durableStatus = durableReconciliationStatus(for: journal) { return durableStatus }
        let state = ProductionsLoader(reader: reader).load(configuration: configuration)
        let inspection: CanvasOperationInspection
        do { inspection = try canvas.inspect(configuration: configuration, work: work, state: state, targetOnly: true) }
        catch {
            let diagnostic = "Canonical state could not be inspected safely: \(error.localizedDescription)"
            return historicalUncertaintyIfProven(journal: journal, diagnostic: diagnostic) ?? .uncertain(diagnostic)
        }
        guard journal.targetHash == nil || journal.targetHash == inspection.targetHash else {
            return historicalUncertaintyIfProven(
                journal: journal,
                diagnostic: "The operation is historically committed, but the canonical target changed, so its current state is uncertain."
            ) ?? .targetChanged
        }
        return reconciliationStatus(journal: journal, desiredState: desiredState, inspection: inspection)
    }

    private func reconcileAfterInterruptedResponse(
        operationID: UUID,
        interruptedEvidence: CanvasInterruptedMutationCommitEvidence,
        desiredState: CanvasDesiredState,
        configuration: ProductionsConfiguration,
        work: WorkItem,
        before: CanvasOperationInspection,
        reload: (ProductionsConfiguration) throws -> ProductionsState
    ) throws -> CanvasAttentionOperationResult {
        let loadedJournal: CanvasWorkTransactionJournal?
        do { loadedJournal = try canvas.journalStore.journal(transactionID: operationID) }
        catch {
            throw CanvasOperationOutcomeError.interruptedMutationJournalReadFailed(
                operationID,
                interruptedEvidence,
                error.localizedDescription
            )
        }
        guard var journal = loadedJournal else {
            throw CanvasOperationOutcomeError.interruptedMutationJournalReadFailed(
                operationID,
                interruptedEvidence,
                "no recovery journal was available for the operation identity"
            )
        }
        let after: CanvasOperationInspection
        do { after = try canvas.inspect(configuration: configuration, work: work, state: try reload(configuration), targetOnly: true) }
        catch {
            journal.transition(to: .uncertain, diagnostic: "Canonical state could not be inspected safely: \(error.localizedDescription)")
            try? canvas.journalStore.update(journal)
            throw CanvasAttentionOperationError.uncertain(operationID, journal.diagnostic!)
        }
        guard after.targetHash == before.targetHash, journal.targetHash == nil || journal.targetHash == after.targetHash else {
            journal.transition(to: .uncertain, diagnostic: "The canonical target changed during reconciliation.")
            try? canvas.journalStore.update(journal)
            if journal.terminalState?.provesHistoricalCommit == true {
                throw CanvasAttentionOperationError.uncertain(operationID, journal.diagnostic!)
            }
            throw CanvasAttentionOperationError.targetChanged(operationID)
        }
        switch reconciliationStatus(journal: journal, desiredState: desiredState, inspection: after) {
        case .committedAndCurrentlySatisfied:
            try finalizeProvenCommit(
                journal: &journal,
                terminalState: .reconciledCommit,
                commitStatus: .committedAndCurrentlySatisfied,
                diagnostic: "The exact journal-bound Canvas replacement is committed and remains the current requested boundary."
            )
            return CanvasAttentionOperationResult(operationID: operationID, workID: work.id, desiredState: desiredState, clearBasis: journal.clearBasis, disposition: .reconciled, appendedEvents: [])
        case .historicallyCommittedAndSuperseded:
            try finalizeProvenCommit(
                journal: &journal,
                terminalState: .historicalCommitSuperseded,
                commitStatus: .historicallyCommittedAndSuperseded,
                diagnostic: "The exact journal-bound commit exists historically, but a later target boundary superseded it."
            )
            throw CanvasAttentionOperationError.historicalCommitSuperseded(operationID)
        case let .historicallyCommittedWithCurrentStateUncertain(diagnostic):
            throw CanvasAttentionOperationError.uncertain(operationID, diagnostic)
        case .notCommitted:
            let journalFinalized: Bool
            if journal.terminalState == .definiteNoCommit {
                journalFinalized = true
            } else {
                journal.transition(to: .definiteNoCommit, diagnostic: "Canonical Canvas matches the operation preimage; no commit occurred.")
                journalFinalized = (try? canvas.journalStore.update(journal)) != nil
            }
            if journal.terminalState?.provesHistoricalCommit == true {
                throw CanvasAttentionOperationError.uncertain(operationID, journal.diagnostic!)
            }
            throw CanvasOperationOutcomeError.definiteNoCommit(operationID, journalFinalized: journalFinalized)
        case .targetChanged:
            journal.transition(to: .uncertain, diagnostic: "The canonical target changed during reconciliation.")
            try? canvas.journalStore.update(journal)
            if journal.terminalState?.provesHistoricalCommit == true {
                throw CanvasAttentionOperationError.uncertain(operationID, journal.diagnostic!)
            }
            throw CanvasAttentionOperationError.targetChanged(operationID)
        case .alreadyDesired:
            throw CanvasAttentionOperationError.uncertain(operationID, "An interrupted mutating operation cannot reconcile as an already-desired no-op.")
        case let .uncertain(diagnostic):
            journal.transition(to: .uncertain, diagnostic: diagnostic)
            try? canvas.journalStore.update(journal)
            throw CanvasAttentionOperationError.uncertain(operationID, journal.diagnostic!)
        }
    }

    private func finalizeProvenCommit(
        journal: inout CanvasWorkTransactionJournal,
        terminalState: CanvasWorkTransactionTerminalState,
        commitStatus: CanvasProvenCommitStatus,
        diagnostic: String
    ) throws {
        journal.transition(to: terminalState, diagnostic: diagnostic)
        do { try canvas.journalStore.update(journal) }
        catch {
            journal.transition(
                to: commitStatus.journalFailureTerminalState,
                diagnostic: "\(commitStatus.diagnostic) The journal failed to reach its correct terminal state: \(error.localizedDescription). The operation must not be retried."
            )
            let fallbackRecorded = (try? canvas.journalStore.update(journal)) != nil
            throw CanvasOperationOutcomeError.journalFinalizationFailed(journal.transactionID, commitStatus, fallbackRecorded: fallbackRecorded)
        }
    }

    private func reconciliationStatus(
        journal: CanvasWorkTransactionJournal,
        desiredState: CanvasDesiredState,
        inspection: CanvasOperationInspection
    ) -> CanvasAttentionReconciliationStatus {
        if journal.terminalState == .definiteNoCommit { return .notCommitted }
        if journal.appendedEvents.isEmpty {
            if let historical = historicalUncertaintyIfProven(
                journal: journal,
                diagnostic: "The journal proves a historical commit but contains no intended event sequence, so its current state cannot be reconciled safely."
            ) { return historical }
            guard journal.terminalState == .alreadyDesired,
                  let before = try? CanvasMarkdown.parse(String(decoding: journal.canvasPreimage, as: UTF8.self)),
                  targetRows(in: before.rows, workID: journal.workID) == targetRows(in: inspection.rows, workID: journal.workID),
                  desiredState.matches(isCurrent: inspection.isCurrent) else {
                return .uncertain("The no-op journal is present, but unchanged requested-target state is not proven.")
            }
            return .alreadyDesired
        }
        if inspection.canvasHash == journal.canvasHash {
            if let historical = historicalUncertaintyIfProven(
                journal: journal,
                diagnostic: "Canonical Canvas now matches the operation preimage even though the journal proves a historical commit. Append-only history is inconsistent, so the operation's current state is uncertain."
            ) { return historical }
            return .notCommitted
        }
        switch operationEvidence(from: journal, in: inspection.rows) {
        case .current: return .committedAndCurrentlySatisfied
        case .superseded: return .historicallyCommittedAndSuperseded
        case .absent:
            if let historical = historicalUncertaintyIfProven(
                journal: journal,
                diagnostic: "The journal proves a historical commit, but canonical Canvas no longer proves whether that commit is currently satisfied or superseded."
            ) { return historical }
            return .uncertain("Canonical Canvas differs from the preimage, but the exact journal-bound replacement and current requested boundary are not proven.")
        }
    }

    private func historicalUncertaintyIfProven(
        journal: CanvasWorkTransactionJournal,
        diagnostic: String
    ) -> CanvasAttentionReconciliationStatus? {
        guard journal.terminalState?.provesHistoricalCommit == true else { return nil }
        return .historicallyCommittedWithCurrentStateUncertain(
            "The operation is proven historically committed, but its current state is uncertain. \(diagnostic) The historical commit must not be retried."
        )
    }

    func durableReconciliationStatus(
        for journal: CanvasWorkTransactionJournal
    ) -> CanvasAttentionReconciliationStatus? {
        journal.terminalState == .definiteNoCommit ? .notCommitted : nil
    }

    private enum OperationEvidence { case absent, current, superseded }

    private func operationEvidence(from journal: CanvasWorkTransactionJournal, in rows: [[String: String]]) -> OperationEvidence {
        let expectedEvents = journal.action == .start ? ["Placed", "Engaged"] : ["Cleared"]
        guard journal.appendedEvents == expectedEvents,
              let reason = journal.reason, let context = journal.context,
              let before = try? CanvasMarkdown.parse(String(decoding: journal.canvasPreimage, as: UTF8.self)),
              !before.isFragmented,
              rows.count >= before.rows.count + journal.appendedEvents.count else { return .absent }
        guard Array(rows.prefix(before.rows.count)) == before.rows else { return .absent }
        let startIndex = before.rows.count
        let occurred = ISO8601DateFormatter().string(from: journal.timestamp)
        let operationRows = rows.dropFirst(startIndex).prefix(journal.appendedEvents.count)
        guard zip(operationRows, journal.appendedEvents).allSatisfy({ row, event in
            row["Occurred"] == occurred && row["Work ID"] == journal.workID && row["Event"] == event && row["Reason"] == reason && row["Context"] == context
        }) else { return .absent }
        guard let relativeBoundary = journal.appendedEvents.firstIndex(where: { $0 == "Placed" || $0 == "Cleared" }) else { return .absent }
        let operationBoundary = startIndex + relativeBoundary
        let latestBoundary = rows.indices.last { index in
            rows[index]["Work ID"] == journal.workID && ["Placed", "Cleared"].contains(rows[index]["Event"] ?? "")
        }
        return latestBoundary == operationBoundary ? .current : .superseded
    }

    private func targetRows(in rows: [[String: String]], workID: String) -> [[String: String]] {
        rows.filter { $0["Work ID"] == workID }
    }
}
