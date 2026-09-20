import CryptoKit
import Foundation

struct MementoCommand: Equatable {
    let action: MementoTransactionAction
    let targetID: String
    let draft: MementoDraft?
    let confirmation: String?
}

struct MementoCommandPreview: Codable, Equatable {
    let schemaVersion: Int
    let productionsRoot: String
    let action: MementoTransactionAction
    let targetID: String
    let liveMementoID: String?
    let liveMemento: LiveMemento?
    let draft: PreviewDraft?
    let resolutionIntent: Bool
    let targetSHA256: String
    let mementosSHA256: String
    let identifierLedgerSHA256: String

    struct PreviewDraft: Codable, Equatable {
        let summary: String
        let currentState: String
        let naturalResumePoint: String
        let openCrumbs: [String]
        let extendedPayload: String?
        let extendedPayloadSHA256: String?
    }

    struct LiveMemento: Codable, Equatable {
        let id: String
        let summary: String
        let currentState: String
        let naturalResumePoint: String
        let openCrumbs: [String]
        let extendedPayloadPath: String?
        let extendedPayloadSHA256: String?
    }

    func confirmationToken() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(self)
        return "confirm:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

enum HeadlessMementoCommandError: LocalizedError, Equatable {
    case confirmationRequired(String), usage(String), unavailable(String)
    var errorDescription: String? { switch self { case let .confirmationRequired(message), let .usage(message), let .unavailable(message): message } }
}

/// Read-only previewing plus confirmed dispatch; MementoTransactionService owns every canonical write.
struct HeadlessMementoCommandAdapter {
    let service: MementoTransactionService
    let reader: any ProductionsReading

    init(service: MementoTransactionService = MementoTransactionService(), reader: any ProductionsReading = LocalFileSystem()) {
        self.service = service; self.reader = reader
    }

    func preview(for command: MementoCommand, configuration: ProductionsConfiguration) throws -> MementoCommandPreview {
        let state = ProductionsLoader(reader: reader).load(configuration: configuration)
        guard state.issues.isEmpty else { throw HeadlessMementoCommandError.unavailable("Productions has contract issues; resolve them before changing Mementos.") }
        let targetPath: String
        if let work = state.work.first(where: { $0.id == command.targetID }) { targetPath = work.workspacePath }
        else if let bundle = state.processing.first(where: { $0.flowID == command.targetID }), let id = bundle.flowID { targetPath = "\(bundle.location)/\(id).md" }
        else { throw HeadlessMementoCommandError.unavailable("The requested Memento target is unavailable: \(command.targetID).") }
        let live = state.mementos.first(where: { $0.target == command.targetID })
        guard (command.action == .create && live == nil) || (command.action != .create && live != nil) else { throw HeadlessMementoCommandError.unavailable(command.action == .create ? "The target already has a current Memento." : "The target has no current Memento.") }
        let draft: MementoCommandPreview.PreviewDraft?
        switch command.action {
        case .resolve:
            guard command.draft == nil else { throw HeadlessMementoCommandError.usage("Resolve does not accept a Memento draft.") }
            draft = nil
        case .create, .supersede:
            guard let value = command.draft else { throw HeadlessMementoCommandError.usage("Create and supersede require a complete Memento draft.") }
            draft = .init(summary: value.summary, currentState: value.currentState, naturalResumePoint: value.naturalResumePoint, openCrumbs: value.openCrumbs, extendedPayload: value.extendedPayload, extendedPayloadSHA256: value.extendedPayload.map { digest(Data($0.utf8)) })
        }
        let livePreview = live.map { value in MementoCommandPreview.LiveMemento(id: value.id, summary: value.summary, currentState: value.currentState, naturalResumePoint: value.naturalResumePoint, openCrumbs: value.openCrumbs, extendedPayloadPath: value.extendedPayloadPath, extendedPayloadSHA256: value.extendedPayloadContent.map { digest(Data($0.utf8)) }) }
        return .init(schemaVersion: 1, productionsRoot: configuration.rootURL.standardizedFileURL.path, action: command.action, targetID: command.targetID, liveMementoID: live?.id, liveMemento: livePreview, draft: draft, resolutionIntent: command.action == .resolve, targetSHA256: try digest(Data(contentsOf: configuration.url(targetPath))), mementosSHA256: try digest(Data(contentsOf: configuration.url(ProductionsPath.mementos.rawValue))), identifierLedgerSHA256: try digest(Data(contentsOf: configuration.url("Warehouse/Reference/Identifier Ledger.md"))))
    }

    func execute(_ command: MementoCommand, configuration: ProductionsConfiguration) throws -> MementoTransactionResult {
        let preview = try preview(for: command, configuration: configuration)
        guard let confirmation = command.confirmation else { throw HeadlessMementoCommandError.confirmationRequired("Run memento preview and supply its confirmation token with --confirm.") }
        guard confirmation == (try preview.confirmationToken()) else { throw HeadlessMementoCommandError.confirmationRequired("The command no longer matches its preview. Re-run memento preview and use its new confirmation token.") }
        let reload = ProductionsLoader(reader: reader).load
        switch command.action {
        case .create: return try service.create(configuration: configuration, targetID: command.targetID, draft: command.draft!, reload: reload)
        case .supersede: return try service.supersede(configuration: configuration, targetID: command.targetID, draft: command.draft!, reload: reload)
        case .resolve: return try service.resolve(configuration: configuration, targetID: command.targetID, reload: reload)
        }
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

enum HeadlessMementoCommandLine {
    static let uncertainExitCode: Int32 = 3

    static func runIfRequested(arguments: [String] = CommandLine.arguments, adapter: HeadlessMementoCommandAdapter = HeadlessMementoCommandAdapter(), write: (String) -> Void = { print($0) }) -> Int32? {
        let values = Array(arguments.dropFirst()); guard values.first == "memento" else { return nil }
        do {
            let (previewMode, command, configuration) = try parse(values)
            try RecoveryJournalRoot.withProductionsRoot(configuration.productionsRootPath) {
                if previewMode {
                    struct Output: Codable { let preview: MementoCommandPreview; let confirmationToken: String }
                    let preview = try adapter.preview(for: command, configuration: configuration)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    write(String(decoding: try encoder.encode(Output(preview: preview, confirmationToken: try preview.confirmationToken())), as: UTF8.self))
                }
                else { let result = try adapter.execute(command, configuration: configuration); write("Memento \(result.action.rawValue) committed for \(result.targetID): \(result.mementoID).") }
            }
            return 0
        } catch let error as MementoTransactionError {
            switch error {
            case let .replacementFailed(diagnostic):
                write("Memento replacement failed after mutation began; canonical state requires inspection. Do not retry automatically. Service diagnostic: \(diagnostic)")
                return uncertainExitCode
            case let .recoveryRequired(diagnostic):
                write("Memento transaction requires explicit recovery; canonical state may be partial or uncertain. Do not retry automatically. Service diagnostic: \(diagnostic)")
                return uncertainExitCode
            case let .reloadFailed(diagnostic):
                write("Memento mutation reached reload or verification after mutation; final canonical state requires inspection. Do not retry automatically. Service diagnostic: \(diagnostic)")
                return uncertainExitCode
            default:
                write(error.localizedDescription)
                return 2
            }
        } catch {
            write(error.localizedDescription)
            return 2
        }
    }

    private static func parse(_ arguments: [String]) throws -> (Bool, MementoCommand, ProductionsConfiguration) {
        let preview = arguments.dropFirst().first == "preview"; let actionIndex = preview ? 2 : 1
        guard arguments.count > actionIndex, let action = MementoTransactionAction(rawValue: arguments[actionIndex]) else { throw HeadlessMementoCommandError.usage("Usage: OperationsDashboard memento [preview] <create|supersede|resolve> --productions-root <path> --target <ID> [draft fields] [--confirm <token>]") }
        var values: [String: String] = [:]; var index = actionIndex + 1
        let allowed = ["--productions-root", "--target", "--summary", "--current-state", "--resume-point", "--open-crumbs", "--extended-payload", "--confirm"]
        while index < arguments.count { let key = arguments[index]; guard allowed.contains(key), index + 1 < arguments.count, values[key] == nil else { throw HeadlessMementoCommandError.usage("Invalid Memento command options.") }; values[key] = arguments[index + 1]; index += 2 }
        guard let root = values["--productions-root"], !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let target = values["--target"], !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw HeadlessMementoCommandError.usage("A Productions root and target are required.") }
        if !preview && values["--confirm"] == nil { throw HeadlessMementoCommandError.usage("A preview confirmation token is required.") }
        let draft: MementoDraft?
        if action == .resolve {
            let draftOnly = ["--summary", "--current-state", "--resume-point", "--open-crumbs", "--extended-payload"]
            guard draftOnly.allSatisfy({ values[$0] == nil }) else {
                throw HeadlessMementoCommandError.usage("Resolve does not accept Memento draft options.")
            }
            draft = nil
        }
        else { guard let summary = values["--summary"], let current = values["--current-state"], let resume = values["--resume-point"] else { throw HeadlessMementoCommandError.usage("Create and supersede require summary, current state, and resume point.") }; draft = .init(summary: summary, currentState: current, naturalResumePoint: resume, openCrumbs: values["--open-crumbs"].map { $0.split(separator: ",").map(String.init) } ?? [], extendedPayload: values["--extended-payload"]) }
        return (preview, .init(action: action, targetID: target, draft: draft, confirmation: values["--confirm"]), .init(schemaVersion: 2, productionsRootPath: root))
    }
}
