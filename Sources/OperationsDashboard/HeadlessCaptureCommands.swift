import CryptoKit
import Foundation

struct CaptureNoteCommand: Equatable {
    let text: String
    let timestamp: Date
    let confirmation: String?
}

enum HeadlessCaptureCommandError: LocalizedError, Equatable {
    case confirmationRequired(String), usage(String)
    var errorDescription: String? { switch self { case let .confirmationRequired(message), let .usage(message): return message } }
}

/// Confirmed command boundary for typed Inbox notes. This adapter never writes
/// the Inbox itself and has no Flow or Identifier Ledger access.
struct HeadlessCaptureCommandAdapter {
    let makeService: () -> ProductionsInboxCaptureService

    init(makeService: @escaping () -> ProductionsInboxCaptureService = { ProductionsInboxCaptureService() }) { self.makeService = makeService }

    func preview(for command: CaptureNoteCommand, configuration: ProductionsConfiguration) throws -> TypedNoteCapturePreview {
        try makeService().previewTypedNote(text: command.text, productionsRoot: rawRoot(configuration), timestamp: command.timestamp)
    }

    func execute(_ command: CaptureNoteCommand, configuration: ProductionsConfiguration) throws -> URL {
        let current = try confirmedPreview(command, configuration: configuration)
        guard !current.requiresRecovery else { throw TypedNoteCaptureError.recoveryRequired("Temporary Quick Capture residue requires the recovery-aware command path. No cleanup or publication was attempted.") }
        return try makeService().commitTypedNote(text: command.text, productionsRoot: rawRoot(configuration), timestamp: command.timestamp, preview: current)
    }

    func executeConfirmed(_ command: CaptureNoteCommand, configuration: ProductionsConfiguration) throws -> TypedNoteCommandExecutionOutcome {
        let current = try confirmedPreview(command, configuration: configuration)
        let service = makeService()
        if current.requiresRecovery {
            return .recovered(try service.recoverTypedNoteResidue(text: command.text, productionsRoot: rawRoot(configuration), timestamp: command.timestamp, preview: current))
        }
        return .captured(try service.commitTypedNote(text: command.text, productionsRoot: rawRoot(configuration), timestamp: command.timestamp, preview: current))
    }

    private func confirmedPreview(_ command: CaptureNoteCommand, configuration: ProductionsConfiguration) throws -> TypedNoteCapturePreview {
        let current = try preview(for: command, configuration: configuration)
        guard let confirmation = command.confirmation else { throw HeadlessCaptureCommandError.confirmationRequired("Run capture note preview and supply its confirmation token with --confirm.") }
        guard confirmation == (try current.confirmationToken()) else { throw HeadlessCaptureCommandError.confirmationRequired("The command no longer matches its preview. Re-run capture note preview and use its new confirmation token.") }
        return current
    }

    private func rawRoot(_ configuration: ProductionsConfiguration) -> URL { URL(fileURLWithPath: configuration.productionsRootPath, isDirectory: true) }
}

extension TypedNoteCapturePreview {
    func confirmationToken() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "confirm:" + SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

enum HeadlessCaptureCommandLine {
    static let verificationFailureExitCode: Int32 = 3

    static func runIfRequested(arguments: [String] = CommandLine.arguments, adapter: HeadlessCaptureCommandAdapter = HeadlessCaptureCommandAdapter(), write: (String) -> Void = { print($0) }) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard values.first == "capture" else { return nil }
        do {
            let (previewMode, command, configuration) = try parse(values)
            if previewMode {
                struct Output: Codable { let preview: TypedNoteCaptureRedactedPreview; let confirmationToken: String }
                let preview = try adapter.preview(for: command, configuration: configuration)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                write(String(decoding: try encoder.encode(Output(preview: .init(preview), confirmationToken: try preview.confirmationToken())), as: UTF8.self))
            } else {
                switch try adapter.executeConfirmed(command, configuration: configuration) {
                case let .captured(destination):
                    write("Quick Capture committed to \(destination.path). No identifier was issued; the payload is Unregistered and awaits Office processing.")
                case let .recovered(recovery):
                    write("Quick Capture recovery \(recovery.operationFingerprint) quarantined \(recovery.removedOperationFingerprints.count) stale temporary operation(s) without deletion as \(recovery.quarantineNames.joined(separator: ", ")). No payload was published. Re-run preview before capture.")
                }
            }
            return 0
        } catch let error as TypedNoteCaptureError {
            switch error {
            case let .verificationFailed(diagnostic), let .namespaceUncertain(diagnostic), let .recoveryRequired(diagnostic):
                write(diagnostic)
                return verificationFailureExitCode
            default: write(error.localizedDescription); return 2
            }
        } catch { write(error.localizedDescription); return 2 }
    }

    private static func parse(_ arguments: [String]) throws -> (Bool, CaptureNoteCommand, ProductionsConfiguration) {
        let preview = arguments.dropFirst().first == "preview"; let verbIndex = preview ? 2 : 1
        guard arguments.count > verbIndex, arguments[verbIndex] == "note" else { throw HeadlessCaptureCommandError.usage("Usage: OperationsDashboard capture [preview] note --productions-root <path> --text <note> --occurred-at <ISO-8601> [--confirm <token>]") }
        let allowed = ["--productions-root", "--text", "--occurred-at", "--confirm"]
        var values: [String: String] = [:]; var index = verbIndex + 1
        while index < arguments.count { let key = arguments[index]; guard allowed.contains(key), index + 1 < arguments.count, values[key] == nil else { throw HeadlessCaptureCommandError.usage("Invalid capture note command options.") }; values[key] = arguments[index + 1]; index += 2 }
        guard let root = values["--productions-root"], !root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let text = values["--text"], let timestampText = values["--occurred-at"], let timestamp = ISO8601DateFormatter().date(from: timestampText) else { throw HeadlessCaptureCommandError.usage("A root, note text, and valid occurred-at timestamp are required.") }
        if !preview && values["--confirm"] == nil { throw HeadlessCaptureCommandError.usage("A preview confirmation token is required.") }
        return (preview, .init(text: text, timestamp: timestamp, confirmation: values["--confirm"]), .init(schemaVersion: 2, productionsRootPath: root))
    }
}
