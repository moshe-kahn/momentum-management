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
    static let usage = "Usage: OperationsDashboard canvas preview <start|stop> --productions-root <path> --work <ID> --reason <text> --context <text>\n       OperationsDashboard canvas <start|stop> --productions-root <path> --work <ID> --reason <text> --context <text> --confirm <preview token>"

    static func runIfRequested(arguments: [String] = CommandLine.arguments, adapter: HeadlessCanvasCommandAdapter = HeadlessCanvasCommandAdapter(), write: (String) -> Void = { print($0) }) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard values.first == "canvas" else { return nil }
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
        } catch { write(error.localizedDescription); return 2 }
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
}
