import Foundation

enum HeadlessOfficeCommandLine {
    static let usage = """
    Usage: OperationsDashboard task checkpoint --productions-root <path> --task <TASK-ID> --expected-workspace-sha256 <64-lowercase-hex> --expected-registry-sha256 <64-lowercase-hex> --unfinished-step <S##> --evidence <one-line accepted evidence> [--evidence <value> ...] --next-step <complete replacement text> --last-validated-state <complete replacement text>
           OperationsDashboard office inspect --productions-root <path> --operation <UUID>
    """

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        service: TaskCheckpointService = TaskCheckpointService(),
        write: (String) -> Void = { print($0) }
    ) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard let command = values.first, command == "task" || command == "office" else { return nil }
        do {
            let invocation = try parse(values)
            let result: TaskCheckpointCommandResult
            switch invocation {
            case let .checkpoint(request, configuration):
                result = try service.perform(request: request, configuration: configuration)
            case let .inspect(operationID, configuration):
                result = try service.inspect(operationID: operationID, configuration: configuration)
            }
            write(try render(result))
            if case .inspect = invocation { return 0 }
            return exitCode(for: result)
        } catch let failure as TaskCheckpointCommandFailure {
            write((try? render(failure.result)) ?? failure.result.diagnostic ?? "Task checkpoint failed.")
            return failure.exitCode
        } catch {
            let result = TaskCheckpointCommandResult(
                outcome: "not-committed", operationUUID: nil, taskID: nil, completedStep: nil,
                workspaceSHA256Before: nil, workspaceSHA256After: nil, registrySHA256: nil,
                nextGate: nil, canvasState: nil, classification: "usage",
                journalFinalized: false, fallbackRecorded: false, historicalCommitProven: false,
                inspectCommand: nil, diagnostic: error.localizedDescription
            )
            write((try? render(result)) ?? usage)
            return 2
        }
    }

    enum Invocation: Equatable {
        case checkpoint(TaskCheckpointRequest, ProductionsConfiguration)
        case inspect(UUID, ProductionsConfiguration)
    }

    static func parse(_ values: [String]) throws -> Invocation {
        if values.first == "office" {
            guard values.count == 6, values[1] == "inspect",
                  values[2] == "--productions-root", !values[3].isEmpty,
                  values[4] == "--operation", let operationID = UUID(uuidString: values[5]) else {
                throw HeadlessOfficeUsageError(usage)
            }
            return .inspect(operationID, ProductionsConfiguration(schemaVersion: 2, productionsRootPath: values[3]))
        }
        guard values.count >= 2, values[0] == "task", values[1] == "checkpoint" else {
            throw HeadlessOfficeUsageError(usage)
        }
        var singular: [String: String] = [:]
        var evidence: [String] = []
        let allowed = Set([
            "--productions-root", "--task", "--expected-workspace-sha256",
            "--expected-registry-sha256", "--unfinished-step", "--evidence",
            "--next-step", "--last-validated-state",
        ])
        var index = 2
        while index < values.count {
            let option = values[index]
            guard allowed.contains(option), index + 1 < values.count else {
                throw HeadlessOfficeUsageError(usage)
            }
            let value = values[index + 1]
            if option == "--evidence" {
                evidence.append(value)
            } else {
                guard singular[option] == nil else { throw HeadlessOfficeUsageError("Duplicate option \(option).\n\(usage)") }
                singular[option] = value
            }
            index += 2
        }
        let required = [
            "--productions-root", "--task", "--expected-workspace-sha256",
            "--expected-registry-sha256", "--unfinished-step", "--next-step",
            "--last-validated-state",
        ]
        guard required.allSatisfy({ singular[$0] != nil }), !evidence.isEmpty else {
            throw HeadlessOfficeUsageError(usage)
        }
        let request = TaskCheckpointRequest(
            taskID: singular["--task"]!,
            expectedWorkspaceSHA256: singular["--expected-workspace-sha256"]!,
            expectedRegistrySHA256: singular["--expected-registry-sha256"]!,
            unfinishedStep: singular["--unfinished-step"]!,
            acceptedEvidence: evidence,
            nextStep: singular["--next-step"]!,
            lastValidatedState: singular["--last-validated-state"]!
        )
        return .checkpoint(request, ProductionsConfiguration(schemaVersion: 2, productionsRootPath: singular["--productions-root"]!))
    }

    private static func exitCode(for result: TaskCheckpointCommandResult) -> Int32 {
        switch result.outcome {
        case "committed": 0
        case "not-committed": 2
        default: 3
        }
    }

    private static func render(_ result: TaskCheckpointCommandResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }
}

private struct HeadlessOfficeUsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
