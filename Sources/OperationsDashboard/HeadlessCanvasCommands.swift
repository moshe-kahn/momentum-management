import CryptoKit
import Foundation

struct ConfirmedCommand: Equatable {
    let confirmation: String

    static func token(preview: CanvasCommandPreview) throws -> String {
        let data = try preview.canonicalData()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "confirm:\(hash)"
    }

    func require(preview: CanvasCommandPreview) throws {
        guard confirmation == (try Self.token(preview: preview)) else {
            throw HeadlessCanvasCommandError.confirmationRequired("The command no longer matches its preview. Re-run canvas preview and use its new confirmation token.")
        }
    }
}

struct HeadlessCanvasCommand: Equatable {
    let action: CanvasWorkAction
    let workID: String
    let reason: String
    let context: String
    let clearBasis: CanvasClearBasis?
    let confirmation: ConfirmedCommand?

    init(action: CanvasWorkAction, workID: String, reason: String, context: String, clearBasis: CanvasClearBasis? = nil, confirmation: ConfirmedCommand? = nil) {
        self.action = action; self.workID = workID; self.reason = reason; self.context = context; self.clearBasis = clearBasis; self.confirmation = confirmation
    }
}

struct CanvasCommandPreview: Codable, Equatable {
    static let schemaVersion = 2
    let schemaVersion: Int
    let productionsRoot: String
    let action: CanvasWorkAction
    let targetID: String
    let targetTitle: String
    let reason: String
    let context: String
    let clearBasis: CanvasClearBasis?
    let canvasSHA256: String

    init(schemaVersion: Int, productionsRoot: String, action: CanvasWorkAction, targetID: String, targetTitle: String, reason: String, context: String, clearBasis: CanvasClearBasis? = nil, canvasSHA256: String) {
        self.schemaVersion = schemaVersion
        self.productionsRoot = productionsRoot
        self.action = action
        self.targetID = targetID
        self.targetTitle = targetTitle
        self.reason = reason
        self.context = context
        self.clearBasis = clearBasis
        self.canvasSHA256 = canvasSHA256
    }

    func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

enum HeadlessCanvasCommandOutcome: Equatable {
    case stopped(CanvasWorkTransactionResult)
    case started(CanvasWorkTransactionResult, SessionPackage)
    case startCanvasCommittedPackageFailed(String)
}

enum HeadlessCanvasCommandError: LocalizedError, Equatable {
    case confirmationRequired(String)
    case usage(String)
    case targetUnavailable(String)
    case startUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .confirmationRequired(message), let .usage(message), let .targetUnavailable(message), let .startUnavailable(message): message
        }
    }
}

struct HeadlessCanvasAttentionCommand: Equatable {
    let desiredState: CanvasDesiredState
    let workID: String
    let reason: String
    let context: String
    let clearBasis: CanvasClearBasis?

    init(desiredState: CanvasDesiredState, workID: String, reason: String, context: String, clearBasis: CanvasClearBasis? = nil) {
        self.desiredState = desiredState
        self.workID = workID
        self.reason = reason
        self.context = context
        self.clearBasis = clearBasis
    }
}

struct CanvasAttentionOperationDiagnostic: Codable, Equatable {
    let operationID: UUID
    let workID: String
    let desiredState: CanvasDesiredState
    let clearBasis: CanvasClearBasis?
    let terminalState: CanvasWorkTransactionTerminalState?
    let canvasPreimageSHA256: String
    let expectedCanvasSHA256: String?
    let appendedEvents: [String]
    let reconciliation: String
    let historicalCommitProven: Bool
    let currentRequestedBoundaryProven: Bool
    let diagnostic: String?
}

/// The ordinary Focus/Clear writer deliberately reads only the target contract.
/// The read model remains responsible for reporting optional Workspace-section
/// diagnostics; those diagnostics must not make an otherwise canonical Canvas
/// target unavailable.
private struct CanvasAttentionTargetLoader {
    let reader: any ProductionsReading

    func load(workID: String, configuration: ProductionsConfiguration) throws -> WorkItem {
        let specification: (kind: WorkKind, registry: ProductionsPath, idHeader: String, lifecycleHeader: String)
        if workID.hasPrefix("TASK-") {
            specification = (.task, .tasks, "Task ID", "State")
        } else if workID.hasPrefix("IDEA-") {
            specification = (.idea, .ideas, "Idea ID", "Disposition")
        } else if workID.hasPrefix("PROJ-") {
            specification = (.project, .projects, "Project ID", "State")
        } else if workID.hasPrefix("INIT-") {
            specification = (.initiative, .initiatives, "Initiative ID", "State")
        } else {
            throw unavailable(workID, "Registry identity", "the identifier prefix is unsupported")
        }

        let registryPath = specification.registry.rawValue
        let registryURL = configuration.url(registryPath)
        guard reader.exists(at: registryURL), reader.isReadable(at: registryURL) else {
            throw unavailable(workID, registryPath, "the Registry record is missing or unreadable")
        }

        let rows: [[String: String]]
        do {
            rows = try MarkdownTable.parse(
                String(decoding: reader.readData(at: registryURL), as: UTF8.self),
                required: [specification.idHeader, "Title", specification.lifecycleHeader, "Priority", "Current lead", "Workspace"]
            )
        } catch {
            throw unavailable(workID, registryPath, error.localizedDescription)
        }
        let matches = rows.filter { $0[specification.idHeader] == workID }
        guard matches.count == 1, let row = matches.first else {
            throw unavailable(workID, registryPath, matches.isEmpty ? "no matching Registry row exists" : "multiple matching Registry rows exist")
        }

        let requiredFields = ["Title", specification.lifecycleHeader, "Priority", "Current lead"]
        for field in requiredFields where (row[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw unavailable(workID, "\(registryPath) row \(workID) field \(field)", "the required fingerprint field is blank")
        }
        let expectedWorkspace = "Workspace/\(workID)/\(workID).md"
        let workspace = MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry")
        guard workspace == expectedWorkspace else {
            throw unavailable(workID, "\(registryPath) row \(workID) field Workspace", "expected canonical link \(expectedWorkspace), found \(workspace.isEmpty ? "an empty value" : workspace)")
        }
        let workspaceURL = configuration.url(workspace)
        guard reader.exists(at: workspaceURL), reader.isReadable(at: workspaceURL) else {
            throw unavailable(workID, workspace, "the canonical Workspace record is missing or unreadable")
        }
        return WorkItem(
            id: workID,
            kind: specification.kind,
            title: row["Title"]!,
            lifecycle: row[specification.lifecycleHeader]!,
            priority: row["Priority"]!,
            lead: row["Current lead"]!,
            department: "",
            product: "",
            workspacePath: workspace,
            related: [],
            dependencies: [],
            registryDescription: row["Short description"] ?? "",
            content: nil,
            workspace: nil
        )
    }

    func state(workID: String, configuration: ProductionsConfiguration) throws -> ProductionsState {
        let work = try load(workID: workID, configuration: configuration)
        let canvasURL = configuration.url(ProductionsPath.canvas.rawValue)
        guard reader.exists(at: canvasURL), reader.isReadable(at: canvasURL) else {
            throw unavailable(workID, ProductionsPath.canvas.rawValue, "the Canvas record is missing or unreadable")
        }
        let rows: [[String: String]]
        do {
            rows = try CanvasMarkdown.parse(String(decoding: reader.readData(at: canvasURL), as: UTF8.self)).rows
        } catch {
            throw unavailable(workID, ProductionsPath.canvas.rawValue, error.localizedDescription)
        }
        let membershipWork = try canvasMembershipWork(rows: rows, selected: work, configuration: configuration)
        let formatter = ISO8601DateFormatter()
        let events = try rows.enumerated().map { index, row -> CanvasEvent in
            guard let occurred = formatter.date(from: row["Occurred"] ?? "") else {
                throw unavailable(workID, "\(ProductionsPath.canvas.rawValue) row \(index + 1) field Occurred", "the timestamp is malformed")
            }
            return CanvasEvent(occurred: occurred, workID: row["Work ID"] ?? "", event: row["Event"] ?? "", reason: row["Reason"] ?? "", context: row["Context"] ?? "", sequence: index)
        }
        return ProductionsState(
            configuration: configuration,
            inbox: [], processing: [], work: membershipWork, canvas: events, crumbs: [], mementos: [], issues: []
        )
    }

    private func canvasMembershipWork(
        rows: [[String: String]],
        selected: WorkItem,
        configuration: ProductionsConfiguration
    ) throws -> [WorkItem] {
        var result = [selected]
        for id in Set(rows.compactMap { $0["Work ID"] }).subtracting([selected.id]) {
            let specification: (kind: WorkKind, registry: ProductionsPath, idHeader: String)
            if id.hasPrefix("TASK-") { specification = (.task, .tasks, "Task ID") }
            else if id.hasPrefix("IDEA-") { specification = (.idea, .ideas, "Idea ID") }
            else if id.hasPrefix("PROJ-") { specification = (.project, .projects, "Project ID") }
            else if id.hasPrefix("INIT-") { specification = (.initiative, .initiatives, "Initiative ID") }
            else { throw unavailable(selected.id, "\(ProductionsPath.canvas.rawValue) field Work ID", "\(id) has an unsupported identifier prefix") }
            let registryURL = configuration.url(specification.registry.rawValue)
            guard reader.exists(at: registryURL), reader.isReadable(at: registryURL) else {
                throw unavailable(selected.id, "\(ProductionsPath.canvas.rawValue) field Work ID", "\(id) cannot resolve because \(specification.registry.rawValue) is unavailable")
            }
            let matches: [[String: String]]
            do {
                matches = try MarkdownTable.parse(String(decoding: reader.readData(at: registryURL), as: UTF8.self), required: [specification.idHeader]).filter { $0[specification.idHeader] == id }
            } catch {
                throw unavailable(selected.id, "\(ProductionsPath.canvas.rawValue) field Work ID", "\(id) cannot resolve because \(specification.registry.rawValue) is malformed: \(error.localizedDescription)")
            }
            guard matches.count == 1 else {
                throw unavailable(selected.id, "\(ProductionsPath.canvas.rawValue) field Work ID", "\(id) resolves to \(matches.isEmpty ? "no" : "multiple") Registry identity rows")
            }
            result.append(WorkItem(id: id, kind: specification.kind, title: "", lifecycle: "", priority: "", lead: "", department: "", product: "", workspacePath: "", related: [], content: nil))
        }
        return result
    }

    private func unavailable(_ workID: String, _ record: String, _ detail: String) -> HeadlessCanvasCommandError {
        .targetUnavailable("Canvas target \(workID) is unavailable: \(record): \(detail).")
    }
}

struct HeadlessCanvasAttentionCommandAdapter {
    let attention: CanvasAttentionOperationService
    let reader: any ProductionsReading

    init(attention: CanvasAttentionOperationService = CanvasAttentionOperationService(), reader: any ProductionsReading = LocalFileSystem()) {
        self.attention = attention
        self.reader = reader
    }

    func execute(_ command: HeadlessCanvasAttentionCommand, configuration: ProductionsConfiguration) throws -> CanvasAttentionOperationResult {
        try CanvasContinuityPolicy.validateShape(
            desiredState: command.desiredState,
            clearBasis: command.clearBasis,
            workID: command.workID
        )
        let targetLoader = CanvasAttentionTargetLoader(reader: reader)
        let work = try targetLoader.load(workID: command.workID, configuration: configuration)
        guard command.desiredState != .focused || !work.lifecycle.hasPrefix("Done") else {
            throw HeadlessCanvasCommandError.startUnavailable("Focus is unavailable for completed work: \(work.id).")
        }
        return try attention.perform(desiredState: command.desiredState, configuration: configuration, work: work, reason: command.reason, context: command.context, clearBasis: command.clearBasis) {
            try targetLoader.state(workID: command.workID, configuration: $0)
        }
    }

    func inspect(operationID: UUID, configuration: ProductionsConfiguration) throws -> CanvasAttentionOperationDiagnostic {
        guard let journal = try attention.canvas.journalStore.journal(transactionID: operationID) else {
            throw HeadlessCanvasCommandError.targetUnavailable("No Canvas operation journal exists for \(operationID.uuidString).")
        }
        let desiredState: CanvasDesiredState = journal.action == .start ? .focused : .clear
        if let durableStatus = attention.durableReconciliationStatus(for: journal) {
            return diagnostic(journal: journal, desiredState: desiredState, status: durableStatus)
        }
        let targetLoader = CanvasAttentionTargetLoader(reader: reader)
        let work: WorkItem
        do {
            work = try targetLoader.load(workID: journal.workID, configuration: configuration)
        } catch {
            if journal.terminalState?.provesHistoricalCommit == true {
                let status = CanvasAttentionReconciliationStatus.historicallyCommittedWithCurrentStateUncertain(
                    "The journal proves a historical commit, but the canonical target is unavailable, so current state is uncertain. The historical commit must not be retried."
                )
                return diagnostic(journal: journal, desiredState: desiredState, status: status)
            }
            throw error
        }
        let status = try attention.reconcile(operationID: operationID, desiredState: desiredState, configuration: configuration, work: work, reader: reader)
        return diagnostic(journal: journal, desiredState: desiredState, status: status)
    }

    private func diagnostic(
        journal: CanvasWorkTransactionJournal,
        desiredState: CanvasDesiredState,
        status: CanvasAttentionReconciliationStatus
    ) -> CanvasAttentionOperationDiagnostic {
        var diagnosticParts = [journal.diagnostic, status.diagnostic].compactMap { $0 }
        if journal.terminalState == .definiteNoCommit {
            diagnosticParts.append("The durable journal proves definite no-commit; mutable Canvas and target state were not inspected.")
        }
        if journal.terminalState == nil {
            diagnosticParts.append(
                status == .notCommitted
                    ? "No commit is proven, but the journal failed to reach a terminal state. Do not retry until this inspection evidence has been reviewed."
                    : "The journal failed to reach a terminal state. The operation must not be retried."
            )
        }
        return CanvasAttentionOperationDiagnostic(
            operationID: journal.transactionID,
            workID: journal.workID,
            desiredState: desiredState,
            clearBasis: journal.clearBasis,
            terminalState: journal.terminalState,
            canvasPreimageSHA256: journal.canvasHash,
            expectedCanvasSHA256: journal.expectedCanvasHash,
            appendedEvents: journal.appendedEvents,
            reconciliation: status.label,
            historicalCommitProven: status.historicalCommitProven,
            currentRequestedBoundaryProven: status.currentRequestedBoundaryProven,
            diagnostic: diagnosticParts.isEmpty ? nil : diagnosticParts.joined(separator: " ")
        )
    }
}

/// A command client for the existing Canvas transaction service. This type
/// reads only enough canonical state to construct a confirmation preview; all
/// canonical mutation remains within CanvasWorkTransactionService.
struct HeadlessCanvasCommandAdapter {
    let canvas: CanvasWorkTransactionService
    let renderer: SessionPackageRenderer
    let reader: any ProductionsReading
    let authorization: SessionAuthorizationMode
    let recommendedModel: String
    let reasoningLevel: String

    init(canvas: CanvasWorkTransactionService = CanvasWorkTransactionService(), renderer: SessionPackageRenderer = SessionPackageRenderer(), reader: any ProductionsReading = LocalFileSystem(), authorization: SessionAuthorizationMode = .readOnly, recommendedModel: String = "Codex", reasoningLevel: String = "high") {
        self.canvas = canvas; self.renderer = renderer; self.reader = reader
        self.authorization = authorization; self.recommendedModel = recommendedModel; self.reasoningLevel = reasoningLevel
    }

    func preview(for command: HeadlessCanvasCommand, configuration: ProductionsConfiguration) throws -> CanvasCommandPreview {
        try validateShape(command)
        let state = ProductionsLoader(reader: reader).load(configuration: configuration)
        guard state.issues.isEmpty else { throw HeadlessCanvasCommandError.targetUnavailable("Productions has contract issues; resolve them before changing Canvas.") }
        guard let work = state.work.first(where: { $0.id == command.workID }) else { throw HeadlessCanvasCommandError.targetUnavailable("The requested Registry-backed work item is unavailable: \(command.workID).") }
        guard command.action != .start || !work.lifecycle.hasPrefix("Done") else { throw HeadlessCanvasCommandError.startUnavailable("Start work is unavailable for completed work: \(work.id).") }
        try CanvasContinuityPolicy.validate(
            desiredState: command.action == .start ? .focused : .clear,
            clearBasis: command.clearBasis,
            kind: work.kind,
            lifecycle: work.lifecycle
        )
        let canvasData = try Data(contentsOf: configuration.url(ProductionsPath.canvas.rawValue))
        let canvasHash = SHA256.hash(data: canvasData).map { String(format: "%02x", $0) }.joined()
        return CanvasCommandPreview(schemaVersion: CanvasCommandPreview.schemaVersion, productionsRoot: configuration.rootURL.standardizedFileURL.path, action: command.action, targetID: work.id, targetTitle: work.title, reason: command.reason, context: command.context, clearBasis: command.clearBasis, canvasSHA256: canvasHash)
    }

    func execute(_ command: HeadlessCanvasCommand, configuration: ProductionsConfiguration) throws -> HeadlessCanvasCommandOutcome {
        try validateShape(command)
        let preview = try preview(for: command, configuration: configuration)
        guard let confirmation = command.confirmation else { throw HeadlessCanvasCommandError.confirmationRequired("Run canvas preview and supply its confirmation token with --confirm.") }
        try confirmation.require(preview: preview)
        let loader = ProductionsLoader(reader: reader)
        guard let work = loader.load(configuration: configuration).work.first(where: { $0.id == command.workID }) else { throw HeadlessCanvasCommandError.targetUnavailable("The requested Registry-backed work item is unavailable: \(command.workID).") }
        switch command.action {
        case .stop:
            let context = command.clearBasis.map { "\($0.auditContextPrefix) \(command.context)" } ?? command.context
            return .stopped(try canvas.perform(action: .stop, configuration: configuration, work: work, reason: command.reason, context: context, clearBasis: command.clearBasis, reload: loader.load))
        case .start:
            let outcome = try SessionPreparationCoordinator(canvas: canvas, renderer: renderer, reader: reader).startWorkAndPrepare(configuration: configuration, work: work, reason: command.reason, context: command.context, authorization: authorization, recommendedModel: recommendedModel, reasoningLevel: reasoningLevel)
            switch outcome {
            case let .prepared(result, package): return .started(result, package)
            case let .canvasCommittedPackageFailed(diagnostic): return .startCanvasCommittedPackageFailed("Canvas start committed for \(work.id), but session package preparation failed and Canvas must not be retried: \(diagnostic)")
            }
        }
    }

    private func validateShape(_ command: HeadlessCanvasCommand) throws {
        try CanvasContinuityPolicy.validateShape(
            desiredState: command.action == .start ? .focused : .clear,
            clearBasis: command.clearBasis,
            workID: command.workID
        )
    }
}

enum HeadlessCanvasInvocation: Equatable { case preview(HeadlessCanvasCommand, ProductionsConfiguration), execute(HeadlessCanvasCommand, ProductionsConfiguration) }

enum HeadlessCanvasCommandLine {
    static let partialSuccessExitCode: Int32 = 3
    static let usage = "Usage: OperationsDashboard canvas focus --productions-root <path> --work <ID> --reason <text> --context <text>\n       OperationsDashboard canvas clear --productions-root <path> --work <TASK-ID> --clear-basis <owner-pause|owner-stop|completed|obsolete|indefinite-external-wait> --reason <text> --context <text>\n       OperationsDashboard canvas clear --productions-root <path> --work <IDEA|PROJ|INIT-ID> --reason <text> --context <text>\n       OperationsDashboard canvas inspect --productions-root <path> --operation <UUID>\n       OperationsDashboard canvas preview start --productions-root <path> --work <ID> --reason <text> --context <text>\n       OperationsDashboard canvas start --productions-root <path> --work <ID> --reason <text> --context <text> --confirm <preview token>\n       OperationsDashboard canvas preview stop --productions-root <path> --work <TASK-ID> --clear-basis <value> --reason <text> --context <text>\n       OperationsDashboard canvas stop --productions-root <path> --work <TASK-ID> --clear-basis <value> --reason <text> --context <text> --confirm <preview token>\n       OperationsDashboard canvas preview stop --productions-root <path> --work <IDEA|PROJ|INIT-ID> --reason <text> --context <text>\n       OperationsDashboard canvas stop --productions-root <path> --work <IDEA|PROJ|INIT-ID> --reason <text> --context <text> --confirm <preview token>"

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        adapter: HeadlessCanvasCommandAdapter = HeadlessCanvasCommandAdapter(),
        attentionAdapter: HeadlessCanvasAttentionCommandAdapter = HeadlessCanvasAttentionCommandAdapter(),
        write: (String) -> Void = { print($0) }
    ) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard values.first == "canvas" else { return nil }
        if values.count > 1, values[1] == "inspect" {
            do {
                let (operationID, configuration) = try parseInspection(values)
                try RecoveryJournalRoot.withProductionsRoot(configuration.productionsRootPath) {
                    write(try renderDiagnostic(attentionAdapter.inspect(operationID: operationID, configuration: configuration)))
                }
                return 0
            } catch {
                write(error.localizedDescription)
                return 2
            }
        }
        if values.count > 1, values[1] == "focus" || values[1] == "clear" {
            do {
                let (command, configuration) = try parseAttention(values)
                try RecoveryJournalRoot.withProductionsRoot(configuration.productionsRootPath) {
                    write(try attentionAdapter.execute(command, configuration: configuration).compactDescription)
                }
                return 0
            } catch let error as CanvasAttentionOperationError {
                write(error.localizedDescription)
                return partialSuccessExitCode
            } catch let error as CanvasOperationOutcomeError {
                write(error.localizedDescription)
                return error.requiresExitThree ? partialSuccessExitCode : 2
            } catch let error as CanvasWorkTransactionError {
                if case .reloadFailed = error {
                    write(error.localizedDescription)
                    return partialSuccessExitCode
                }
                write(error.localizedDescription)
                return 2
            } catch {
                write(error.localizedDescription)
                return 2
            }
        }
        do {
            switch try parse(values) {
            case let .preview(command, configuration):
                try RecoveryJournalRoot.withProductionsRoot(configuration.productionsRootPath) {
                    let preview = try adapter.preview(for: command, configuration: configuration)
                    write(try renderPreview(preview, token: ConfirmedCommand.token(preview: preview)))
                }
                return 0
            case let .execute(command, configuration):
                return try RecoveryJournalRoot.withProductionsRoot(configuration.productionsRootPath) {
                    switch try adapter.execute(command, configuration: configuration) {
                    case let .started(_, package): write(try renderPackage(package)); return 0
                    case let .stopped(result): write("Canvas stop committed for \(result.workID): \(result.appendedEvents.joined(separator: ", "))."); return 0
                    case let .startCanvasCommittedPackageFailed(diagnostic): write(diagnostic); return partialSuccessExitCode
                    }
                }
            }
        } catch let error as CanvasOperationOutcomeError {
            write(error.localizedDescription)
            return error.requiresExitThree ? partialSuccessExitCode : 2
        } catch let error as CanvasWorkTransactionError {
            if case let .reloadFailed(diagnostic) = error {
                write("Canvas mutation is committed, but canonical reload or verification failed. Do not retry automatically. Service diagnostic: \(diagnostic)")
                return partialSuccessExitCode
            }
            write(error.localizedDescription)
            return 2
        } catch {
            write(error.localizedDescription)
            return 2
        }
    }

    private static func parseAttention(_ arguments: [String]) throws -> (HeadlessCanvasAttentionCommand, ProductionsConfiguration) {
        guard arguments.count > 1 else { throw HeadlessCanvasCommandError.usage(usage) }
        let desiredState: CanvasDesiredState
        switch arguments[1] {
        case "focus": desiredState = .focused
        case "clear": desiredState = .clear
        default: throw HeadlessCanvasCommandError.usage(usage)
        }
        let options = try parseOptions(Array(arguments.dropFirst(2)), permitsConfirmation: false, permitsClearBasis: true)
        guard let root = options["--productions-root"], !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let workID = options["--work"], !workID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let reason = options["--reason"], let context = options["--context"] else {
            throw HeadlessCanvasCommandError.usage(usage)
        }
        let clearBasis = try parseClearBasis(options["--clear-basis"])
        do { try CanvasContinuityPolicy.validateShape(desiredState: desiredState, clearBasis: clearBasis, workID: workID) }
        catch { throw HeadlessCanvasCommandError.usage(usage) }
        return (
            HeadlessCanvasAttentionCommand(desiredState: desiredState, workID: workID, reason: reason, context: context, clearBasis: clearBasis),
            ProductionsConfiguration(schemaVersion: 2, productionsRootPath: root)
        )
    }

    private static func parseInspection(_ arguments: [String]) throws -> (UUID, ProductionsConfiguration) {
        guard arguments.count == 6,
              arguments[2] == "--productions-root",
              !arguments[3].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              arguments[4] == "--operation",
              let operationID = UUID(uuidString: arguments[5]) else {
            throw HeadlessCanvasCommandError.usage(usage)
        }
        return (operationID, ProductionsConfiguration(schemaVersion: 2, productionsRootPath: arguments[3]))
    }

    static func parse(_ arguments: [String]) throws -> HeadlessCanvasInvocation {
        guard arguments.first == "canvas" else { throw HeadlessCanvasCommandError.usage(usage) }
        let isPreview = arguments.dropFirst().first == "preview"
        let actionIndex = isPreview ? 2 : 1
        guard arguments.count > actionIndex, let action = CanvasWorkAction(rawValue: arguments[actionIndex]) else { throw HeadlessCanvasCommandError.usage(usage) }
        let options = try parseOptions(Array(arguments.dropFirst(actionIndex + 1)), permitsConfirmation: !isPreview, permitsClearBasis: true)
        guard let root = options["--productions-root"], !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let workID = options["--work"], !workID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let reason = options["--reason"], let context = options["--context"] else { throw HeadlessCanvasCommandError.usage(usage) }
        let clearBasis = try parseClearBasis(options["--clear-basis"])
        do {
            try CanvasContinuityPolicy.validateShape(
                desiredState: action == .start ? .focused : .clear,
                clearBasis: clearBasis,
                workID: workID
            )
        } catch { throw HeadlessCanvasCommandError.usage(usage) }
        let command = HeadlessCanvasCommand(action: action, workID: workID, reason: reason, context: context, clearBasis: clearBasis, confirmation: options["--confirm"].map(ConfirmedCommand.init))
        let configuration = ProductionsConfiguration(schemaVersion: 2, productionsRootPath: root)
        if isPreview { return .preview(command, configuration) }
        guard command.confirmation != nil else { throw HeadlessCanvasCommandError.usage(usage) }
        return .execute(command, configuration)
    }

    private static func parseClearBasis(_ rawValue: String?) throws -> CanvasClearBasis? {
        guard let rawValue else { return nil }
        guard let basis = CanvasClearBasis(rawValue: rawValue) else {
            throw HeadlessCanvasCommandError.usage(usage)
        }
        return basis
    }

    private static func parseOptions(_ arguments: [String], permitsConfirmation: Bool, permitsClearBasis: Bool) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        var allowed = permitsConfirmation ? ["--productions-root", "--work", "--reason", "--context", "--confirm"] : ["--productions-root", "--work", "--reason", "--context"]
        if permitsClearBasis { allowed.append("--clear-basis") }
        while index < arguments.count {
            let name = arguments[index]
            guard allowed.contains(name), index + 1 < arguments.count, options[name] == nil else { throw HeadlessCanvasCommandError.usage(usage) }
            options[name] = arguments[index + 1]; index += 2
        }
        return options
    }

    private static func renderPreview(_ preview: CanvasCommandPreview, token: String) throws -> String {
        struct Output: Codable { let preview: CanvasCommandPreview; let confirmationToken: String }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(Output(preview: preview, confirmationToken: token)), as: UTF8.self)
    }

    private static func renderPackage(_ package: SessionPackage) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(package), as: UTF8.self)
    }

    private static func renderDiagnostic(_ diagnostic: CanvasAttentionOperationDiagnostic) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(diagnostic), as: UTF8.self)
    }
}
