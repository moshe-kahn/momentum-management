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
    let confirmation: ConfirmedCommand?

    init(action: CanvasWorkAction, workID: String, reason: String, context: String, confirmation: ConfirmedCommand? = nil) {
        self.action = action; self.workID = workID; self.reason = reason; self.context = context; self.confirmation = confirmation
    }
}

struct CanvasCommandPreview: Codable, Equatable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let productionsRoot: String
    let action: CanvasWorkAction
    let targetID: String
    let targetTitle: String
    let reason: String
    let context: String
    let canvasSHA256: String

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
}

struct CanvasAttentionOperationDiagnostic: Codable, Equatable {
    let operationID: UUID
    let workID: String
    let desiredState: CanvasDesiredState
    let terminalState: CanvasWorkTransactionTerminalState?
    let canvasPreimageSHA256: String
    let expectedCanvasSHA256: String?
    let appendedEvents: [String]
    let reconciliation: String
    let historicalCommitProven: Bool
    let currentRequestedBoundaryProven: Bool
    let diagnostic: String?
}

struct HeadlessCanvasAttentionCommandAdapter {
    let attention: CanvasAttentionOperationService
    let reader: any ProductionsReading

    init(attention: CanvasAttentionOperationService = CanvasAttentionOperationService(), reader: any ProductionsReading = LocalFileSystem()) {
        self.attention = attention
        self.reader = reader
    }

    func execute(_ command: HeadlessCanvasAttentionCommand, configuration: ProductionsConfiguration) throws -> CanvasAttentionOperationResult {
        let loader = ProductionsLoader(reader: reader)
        let state = loader.load(configuration: configuration)
        guard let work = state.work.first(where: { $0.id == command.workID }), work.workspace != nil else {
            throw HeadlessCanvasCommandError.targetUnavailable("The requested Registry-backed work item is unavailable or malformed: \(command.workID).")
        }
        guard command.desiredState != .focused || !work.lifecycle.hasPrefix("Done") else {
            throw HeadlessCanvasCommandError.startUnavailable("Focus is unavailable for completed work: \(work.id).")
        }
        return try attention.perform(desiredState: command.desiredState, configuration: configuration, work: work, reason: command.reason, context: command.context, reload: loader.load)
    }

    func inspect(operationID: UUID, configuration: ProductionsConfiguration) throws -> CanvasAttentionOperationDiagnostic {
        guard let journal = try attention.canvas.journalStore.journal(transactionID: operationID) else {
            throw HeadlessCanvasCommandError.targetUnavailable("No Canvas operation journal exists for \(operationID.uuidString).")
        }
        let desiredState: CanvasDesiredState = journal.action == .start ? .focused : .clear
        if let durableStatus = attention.durableReconciliationStatus(for: journal) {
            return diagnostic(journal: journal, desiredState: desiredState, status: durableStatus)
        }
        let state = ProductionsLoader(reader: reader).load(configuration: configuration)
        guard let work = state.work.first(where: { $0.id == journal.workID }) else {
            if journal.terminalState?.provesHistoricalCommit == true {
                let status = CanvasAttentionReconciliationStatus.historicallyCommittedWithCurrentStateUncertain(
                    "The journal proves a historical commit, but the canonical target is unavailable, so current state is uncertain. The historical commit must not be retried."
                )
                return diagnostic(journal: journal, desiredState: desiredState, status: status)
            }
            throw HeadlessCanvasCommandError.targetUnavailable("The journal target is unavailable in canonical Productions: \(journal.workID).")
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
        let state = ProductionsLoader(reader: reader).load(configuration: configuration)
        guard state.issues.isEmpty else { throw HeadlessCanvasCommandError.targetUnavailable("Productions has contract issues; resolve them before changing Canvas.") }
        guard let work = state.work.first(where: { $0.id == command.workID }) else { throw HeadlessCanvasCommandError.targetUnavailable("The requested Registry-backed work item is unavailable: \(command.workID).") }
        guard command.action != .start || !work.lifecycle.hasPrefix("Done") else { throw HeadlessCanvasCommandError.startUnavailable("Start work is unavailable for completed work: \(work.id).") }
        let canvasData = try Data(contentsOf: configuration.url(ProductionsPath.canvas.rawValue))
        let canvasHash = SHA256.hash(data: canvasData).map { String(format: "%02x", $0) }.joined()
        return CanvasCommandPreview(schemaVersion: CanvasCommandPreview.schemaVersion, productionsRoot: configuration.rootURL.standardizedFileURL.path, action: command.action, targetID: work.id, targetTitle: work.title, reason: command.reason, context: command.context, canvasSHA256: canvasHash)
    }

    func execute(_ command: HeadlessCanvasCommand, configuration: ProductionsConfiguration) throws -> HeadlessCanvasCommandOutcome {
        let preview = try preview(for: command, configuration: configuration)
        guard let confirmation = command.confirmation else { throw HeadlessCanvasCommandError.confirmationRequired("Run canvas preview and supply its confirmation token with --confirm.") }
        try confirmation.require(preview: preview)
        let loader = ProductionsLoader(reader: reader)
        guard let work = loader.load(configuration: configuration).work.first(where: { $0.id == command.workID }) else { throw HeadlessCanvasCommandError.targetUnavailable("The requested Registry-backed work item is unavailable: \(command.workID).") }
        switch command.action {
        case .stop:
            return .stopped(try canvas.perform(action: .stop, configuration: configuration, work: work, reason: command.reason, context: command.context, reload: loader.load))
        case .start:
            let outcome = try SessionPreparationCoordinator(canvas: canvas, renderer: renderer, reader: reader).startWorkAndPrepare(configuration: configuration, work: work, reason: command.reason, context: command.context, authorization: authorization, recommendedModel: recommendedModel, reasoningLevel: reasoningLevel)
            switch outcome {
            case let .prepared(result, package): return .started(result, package)
            case let .canvasCommittedPackageFailed(diagnostic): return .startCanvasCommittedPackageFailed("Canvas start committed for \(work.id), but session package preparation failed and Canvas must not be retried: \(diagnostic)")
            }
        }
    }
}

enum HeadlessCanvasInvocation: Equatable { case preview(HeadlessCanvasCommand, ProductionsConfiguration), execute(HeadlessCanvasCommand, ProductionsConfiguration) }

enum HeadlessCanvasCommandLine {
    static let partialSuccessExitCode: Int32 = 3
    static let usage = "Usage: OperationsDashboard canvas <focus|clear> --productions-root <path> --work <ID> --reason <text> --context <text>\n       OperationsDashboard canvas inspect --productions-root <path> --operation <UUID>\n       OperationsDashboard canvas preview <start|stop> --productions-root <path> --work <ID> --reason <text> --context <text>\n       OperationsDashboard canvas <start|stop> --productions-root <path> --work <ID> --reason <text> --context <text> --confirm <preview token>"

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
                write(try renderDiagnostic(attentionAdapter.inspect(operationID: operationID, configuration: configuration)))
                return 0
            } catch {
                write(error.localizedDescription)
                return 2
            }
        }
        if values.count > 1, values[1] == "focus" || values[1] == "clear" {
            do {
                let (command, configuration) = try parseAttention(values)
                write(try attentionAdapter.execute(command, configuration: configuration).compactDescription)
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
                let preview = try adapter.preview(for: command, configuration: configuration)
                write(try renderPreview(preview, token: ConfirmedCommand.token(preview: preview)))
                return 0
            case let .execute(command, configuration):
                switch try adapter.execute(command, configuration: configuration) {
                case let .started(_, package): write(try renderPackage(package)); return 0
                case let .stopped(result): write("Canvas stop committed for \(result.workID): \(result.appendedEvents.joined(separator: ", "))."); return 0
                case let .startCanvasCommittedPackageFailed(diagnostic): write(diagnostic); return partialSuccessExitCode
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
        let options = try parseOptions(Array(arguments.dropFirst(2)), permitsConfirmation: false)
        guard let root = options["--productions-root"], !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let workID = options["--work"], !workID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let reason = options["--reason"], let context = options["--context"] else {
            throw HeadlessCanvasCommandError.usage(usage)
        }
        return (
            HeadlessCanvasAttentionCommand(desiredState: desiredState, workID: workID, reason: reason, context: context),
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
        let options = try parseOptions(Array(arguments.dropFirst(actionIndex + 1)), permitsConfirmation: !isPreview)
        guard let root = options["--productions-root"], !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let workID = options["--work"], !workID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let reason = options["--reason"], let context = options["--context"] else { throw HeadlessCanvasCommandError.usage(usage) }
        let command = HeadlessCanvasCommand(action: action, workID: workID, reason: reason, context: context, confirmation: options["--confirm"].map(ConfirmedCommand.init))
        let configuration = ProductionsConfiguration(schemaVersion: 2, productionsRootPath: root)
        if isPreview { return .preview(command, configuration) }
        guard command.confirmation != nil else { throw HeadlessCanvasCommandError.usage(usage) }
        return .execute(command, configuration)
    }

    private static func parseOptions(_ arguments: [String], permitsConfirmation: Bool) throws -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        let allowed = permitsConfirmation ? ["--productions-root", "--work", "--reason", "--context", "--confirm"] : ["--productions-root", "--work", "--reason", "--context"]
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
