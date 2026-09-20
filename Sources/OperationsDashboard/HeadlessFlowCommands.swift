import CryptoKit
import Foundation

struct FlowRegisterCommand: Equatable {
    let payloadPath: String
    let metadata: FlowRegistrationMetadata
    let occurredAt: Date
    let confirmation: String?
}

struct FlowRegisterCommandPreview: Codable, Equatable {
    let schemaVersion: Int
    let productionsRoot: String
    let payloadPath: String
    let payloadState: FlowRegistrationPayloadState
    let metadata: FlowMetadataPreview
    let occurredAt: String
    let proposedFlowID: String
    let proposedRow: String
    let flowSHA256: String
    let identifierLedgerSHA256: String

    struct FlowMetadataPreview: Codable, Equatable {
        let label, type, summary, nextDisposition, priority, steward, department, product, source, relatedWork: String
        init(_ value: FlowRegistrationMetadata) { label = value.label; type = value.type; summary = value.summary; nextDisposition = value.nextDisposition; priority = value.priority; steward = value.steward; department = value.department; product = value.product; source = value.source; relatedWork = value.relatedWork }
    }

    func confirmationToken() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "confirm:" + SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

enum HeadlessFlowCommandError: LocalizedError, Equatable {
    case confirmationRequired(String), usage(String), unavailable(String)
    var errorDescription: String? { switch self { case let .confirmationRequired(message), let .usage(message), let .unavailable(message): message } }
}

/// Confirmed command boundary for FlowRegistrationService; this layer never writes canonical files directly.
struct HeadlessFlowCommandAdapter {
    let reader: any ProductionsReading
    let makeService: (Date) -> FlowRegistrationService

    init(reader: any ProductionsReading = LocalFileSystem(), makeService: @escaping (Date) -> FlowRegistrationService = { timestamp in FlowRegistrationService(now: { timestamp }) }) {
        self.reader = reader; self.makeService = makeService
    }

    func preview(for command: FlowRegisterCommand, configuration: ProductionsConfiguration) throws -> FlowRegisterCommandPreview {
        let state = ProductionsLoader(reader: reader).load(configuration: configuration)
        guard state.issues.isEmpty else { throw HeadlessFlowCommandError.unavailable("Productions has contract issues; resolve them before registering Inbox payloads.") }
        guard let payload = state.inbox.first(where: { $0.location == command.payloadPath }) else { throw HeadlessFlowCommandError.unavailable("The requested Inbox payload is unavailable: \(command.payloadPath).") }
        let preview = try makeService(command.occurredAt).preview(configuration: configuration, payload: payload, metadata: command.metadata)
        return .init(schemaVersion: 1, productionsRoot: configuration.rootURL.standardizedFileURL.path, payloadPath: preview.payloadPath, payloadState: preview.payloadState, metadata: .init(command.metadata), occurredAt: ISO8601DateFormatter().string(from: command.occurredAt), proposedFlowID: preview.flowID, proposedRow: preview.row, flowSHA256: preview.flowHash, identifierLedgerSHA256: preview.ledgerHash)
    }

    func execute(_ command: FlowRegisterCommand, configuration: ProductionsConfiguration) throws {
        let bound = try preview(for: command, configuration: configuration)
        guard let confirmation = command.confirmation else { throw HeadlessFlowCommandError.confirmationRequired("Run flow register preview and supply its confirmation token with --confirm.") }
        guard confirmation == (try bound.confirmationToken()) else { throw HeadlessFlowCommandError.confirmationRequired("The command no longer matches its preview. Re-run flow register preview and use its new confirmation token.") }
        let state = ProductionsLoader(reader: reader).load(configuration: configuration)
        guard let payload = state.inbox.first(where: { $0.location == command.payloadPath }) else { throw HeadlessFlowCommandError.unavailable("The requested Inbox payload is unavailable: \(command.payloadPath).") }
        let servicePreview = FlowRegistrationPreview(flowID: bound.proposedFlowID, row: bound.proposedRow, payloadPath: bound.payloadPath, payloadState: bound.payloadState, ledgerHash: bound.identifierLedgerSHA256, flowHash: bound.flowSHA256)
        try makeService(command.occurredAt).commit(configuration: configuration, payload: payload, metadata: command.metadata, preview: servicePreview, expectedPayloadState: bound.payloadState, reload: ProductionsLoader(reader: reader).load)
    }
}

enum HeadlessFlowCommandLine {
    static let partialOrUncertainExitCode: Int32 = 3
    static func runIfRequested(arguments: [String] = CommandLine.arguments, adapter: HeadlessFlowCommandAdapter = HeadlessFlowCommandAdapter(), write: (String) -> Void = { print($0) }) -> Int32? {
        let values = Array(arguments.dropFirst()); guard values.first == "flow" else { return nil }
        do {
            let (previewMode, command, configuration) = try parse(values)
            try RecoveryJournalRoot.withProductionsRoot(configuration.productionsRootPath) {
                if previewMode {
                    struct Output: Codable { let preview: FlowRegisterCommandPreview; let confirmationToken: String }
                    let preview = try adapter.preview(for: command, configuration: configuration); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                    write(String(decoding: try encoder.encode(Output(preview: preview, confirmationToken: try preview.confirmationToken())), as: UTF8.self))
                } else { try adapter.execute(command, configuration: configuration); write("Flow registration committed for \(command.payloadPath).") }
            }
            return 0
        } catch let error as FlowRegistrationError {
            switch error {
            case let .flowWriteFailed(diagnostic):
                write("Identifier Ledger committed; Flow replacement failed. Do not retry automatically. Service diagnostic: \(diagnostic)")
                return partialOrUncertainExitCode
            case let .reloadFailed(diagnostic):
                write("Full Flow registration committed; only reload/verification failed. Do not retry automatically. Service diagnostic: \(diagnostic)")
                return partialOrUncertainExitCode
            default: write(error.localizedDescription); return 2
            }
        } catch { write(error.localizedDescription); return 2 }
    }

    private static func parse(_ arguments: [String]) throws -> (Bool, FlowRegisterCommand, ProductionsConfiguration) {
        let preview = arguments.dropFirst().first == "preview"; let verbIndex = preview ? 2 : 1
        guard arguments.count > verbIndex, arguments[verbIndex] == "register" else { throw HeadlessFlowCommandError.usage("Usage: OperationsDashboard flow [preview] register --productions-root <path> --payload <Office/Inbox/name> --occurred-at <ISO-8601> --label <text> --type <text> --summary <text> --next-disposition <text> --priority <text> --steward <text> --department <text> --product <text> --source <text> --related-work <text> [--confirm <token>]") }
        let allowed = ["--productions-root", "--payload", "--occurred-at", "--label", "--type", "--summary", "--next-disposition", "--priority", "--steward", "--department", "--product", "--source", "--related-work", "--confirm"]
        var values: [String: String] = [:]; var index = verbIndex + 1
        while index < arguments.count { let key = arguments[index]; guard allowed.contains(key), index + 1 < arguments.count, values[key] == nil else { throw HeadlessFlowCommandError.usage("Invalid Flow registration command options.") }; values[key] = arguments[index + 1]; index += 2 }
        let required = ["--productions-root", "--payload", "--occurred-at", "--label", "--type", "--summary", "--next-disposition", "--priority", "--steward", "--department", "--product", "--source", "--related-work"]
        guard required.allSatisfy({ values[$0]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }), let root = values["--productions-root"], let payload = values["--payload"], let text = values["--occurred-at"], let occurredAt = ISO8601DateFormatter().date(from: text) else { throw HeadlessFlowCommandError.usage("A root, exact payload, valid occurred-at timestamp, and complete metadata are required.") }
        if !preview && values["--confirm"] == nil { throw HeadlessFlowCommandError.usage("A preview confirmation token is required.") }
        let metadata = FlowRegistrationMetadata(label: values["--label"]!, type: values["--type"]!, summary: values["--summary"]!, nextDisposition: values["--next-disposition"]!, priority: values["--priority"]!, steward: values["--steward"]!, department: values["--department"]!, product: values["--product"]!, source: values["--source"]!, relatedWork: values["--related-work"]!)
        return (preview, .init(payloadPath: payload, metadata: metadata, occurredAt: occurredAt, confirmation: values["--confirm"]), .init(schemaVersion: 2, productionsRootPath: root))
    }
}
