import Foundation

enum HeadlessOfficeCommandLine {
    static let usage = """
    Usage: OperationsDashboard task checkpoint --productions-root <path> --task <TASK-ID> --expected-workspace-sha256 <64-lowercase-hex> --expected-registry-sha256 <64-lowercase-hex> --unfinished-step <S##> --evidence <one-line accepted evidence> [--evidence <value> ...] --next-step <complete replacement text> --last-validated-state <complete replacement text>
           OperationsDashboard review accept-handoff --productions-root <path> --source <TASK-ID> --dependent <TASK-ID> --source-commit <40-lowercase-hex> --marker <marker> --accepted-at <ISO-8601> --evidence <canonical-location> --expected-workspace-sha256 <64-lowercase-hex> --expected-dependent-workspace-sha256 <64-lowercase-hex> --expected-registry-sha256 <64-lowercase-hex>
           OperationsDashboard office reconcile preview --productions-root <path> --work <DURABLE-ID> --priority-rule <registry|maximum> --expected-workspace-sha256 <64-lowercase-hex> --expected-registry-sha256 <64-lowercase-hex> [--state <value>] [--priority <value>] [--corrects-operation <UUID>]
           OperationsDashboard office reconcile apply --productions-root <path> --work <DURABLE-ID> --priority-rule <registry|maximum> --expected-workspace-sha256 <64-lowercase-hex> --expected-registry-sha256 <64-lowercase-hex> [--state <value>] [--priority <value>] [--corrects-operation <UUID>] --confirm <token>
           OperationsDashboard office reconciliation list --productions-root <path>
           OperationsDashboard office reconciliation acknowledge --productions-root <path> --operation <UUID>
           OperationsDashboard office inspect --productions-root <path> --operation <UUID>
    """

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        service: TaskCheckpointService = TaskCheckpointService(),
        acceptedHandoffService: AcceptedHandoffService = AcceptedHandoffService(),
        lifecyclePriorityService: LifecyclePriorityService = LifecyclePriorityService(),
        inspector: (any OfficeWorkspaceInspecting)? = nil,
        write: (String) -> Void = { print($0) }
    ) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard let command = values.first, command == "task" || command == "review" || command == "office" else { return nil }
        do {
            let invocation = try parse(values)
            switch invocation {
            case let .checkpoint(request, configuration):
                let result = try service.perform(request: request, configuration: configuration)
                write(try render(result))
                return exitCode(for: result.outcome)
            case let .acceptHandoff(request, configuration):
                let result = try acceptedHandoffService.perform(request: request, configuration: configuration)
                write(try render(result))
                return exitCode(for: result.outcome)
            case let .reconcilePreview(request, configuration):
                write(try render(lifecyclePriorityService.preview(request: request, configuration: configuration)))
                return 0
            case let .reconcileApply(request, token, configuration):
                let result = try lifecyclePriorityService.perform(request: request, confirmationToken: token, configuration: configuration)
                write(try render(result))
                return exitCode(for: result.outcome)
            case let .reconciliationList(configuration):
                write(try render(lifecyclePriorityService.pendingEntries(configuration: configuration)))
                return 0
            case let .reconciliationAcknowledge(operationID, configuration):
                let result = try lifecyclePriorityService.acknowledge(operationID: operationID, configuration: configuration)
                write(try render(result))
                return exitCode(for: result.outcome)
            case let .inspect(operationID, configuration):
                let resolved = try (inspector ?? ServiceBackedOfficeWorkspaceInspector(
                    checkpointService: service, acceptedHandoffService: acceptedHandoffService,
                    lifecyclePriorityService: lifecyclePriorityService
                )).inspect(operationID: operationID, configuration: configuration)
                switch resolved {
                case let .checkpoint(result): write(try render(result))
                case let .acceptedHandoff(result): write(try render(result))
                case let .lifecyclePriority(result): write(try render(result))
                }
                return 0
            }
        } catch let failure as TaskCheckpointCommandFailure {
            write((try? render(failure.result)) ?? failure.result.diagnostic ?? "Task checkpoint failed.")
            return failure.exitCode
        } catch let failure as AcceptedHandoffCommandFailure {
            write((try? render(failure.result)) ?? failure.result.diagnostic ?? "Accepted handoff failed.")
            return failure.exitCode
        } catch let failure as LifecyclePriorityCommandFailure {
            write((try? render(failure.result)) ?? failure.result.diagnostic ?? "Lifecycle/priority reconciliation failed.")
            return failure.exitCode
        } catch let dispatch as OfficeWorkspaceInspectionDispatchError {
            let suppliedOperationID = values.count == 6 && values[0] == "office" && values[1] == "inspect" &&
                values[4] == "--operation" ? UUID(uuidString: values[5]) : nil
            let result = TaskCheckpointCommandResult(
                outcome: "uncertain", operationUUID: suppliedOperationID, taskID: nil, completedStep: nil,
                workspaceSHA256Before: nil, workspaceSHA256After: nil, registrySHA256: nil,
                nextGate: nil, canvasState: nil, classification: "journal-read-failed",
                journalFinalized: false, fallbackRecorded: false, historicalCommitProven: false,
                inspectCommand: nil, diagnostic: dispatch.localizedDescription
            )
            write((try? render(result)) ?? dispatch.localizedDescription)
            return 3
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
        case acceptHandoff(AcceptedHandoffRequest, ProductionsConfiguration)
        case reconcilePreview(LifecyclePriorityRequest, ProductionsConfiguration)
        case reconcileApply(LifecyclePriorityRequest, String, ProductionsConfiguration)
        case reconciliationList(ProductionsConfiguration)
        case reconciliationAcknowledge(UUID, ProductionsConfiguration)
        case inspect(UUID, ProductionsConfiguration)
    }

    static func parse(_ values: [String]) throws -> Invocation {
        if values.first == "office" {
            if values.count == 5, values[1] == "reconciliation", values[2] == "list", values[3] == "--productions-root", !values[4].isEmpty {
                return .reconciliationList(ProductionsConfiguration(schemaVersion: 2, productionsRootPath: values[4]))
            }
            if values.count == 7, values[1] == "reconciliation", values[2] == "acknowledge", values[3] == "--productions-root", !values[4].isEmpty,
               values[5] == "--operation", let operationID = UUID(uuidString: values[6]) {
                return .reconciliationAcknowledge(operationID, ProductionsConfiguration(schemaVersion: 2, productionsRootPath: values[4]))
            }
            if values.count >= 2, values[1] == "reconcile" { return try parseReconcile(values) }
            guard values.count == 6, values[1] == "inspect",
                  values[2] == "--productions-root", !values[3].isEmpty,
                  values[4] == "--operation", let operationID = UUID(uuidString: values[5]) else {
                throw HeadlessOfficeUsageError(usage)
            }
            return .inspect(operationID, ProductionsConfiguration(schemaVersion: 2, productionsRootPath: values[3]))
        }
        if values.first == "review" {
            guard values.count >= 2, values[1] == "accept-handoff" else {
                throw HeadlessOfficeUsageError(usage)
            }
            var options: [String: String] = [:]
            let allowed = Set([
                "--productions-root", "--source", "--dependent", "--source-commit", "--marker",
                "--accepted-at", "--evidence", "--expected-workspace-sha256",
                "--expected-dependent-workspace-sha256", "--expected-registry-sha256",
            ])
            var index = 2
            while index < values.count {
                let option = values[index]
                guard allowed.contains(option), index + 1 < values.count, options[option] == nil else {
                    throw HeadlessOfficeUsageError(usage)
                }
                options[option] = values[index + 1]
                index += 2
            }
            guard allowed.allSatisfy({ options[$0] != nil }) else { throw HeadlessOfficeUsageError(usage) }
            return .acceptHandoff(
                AcceptedHandoffRequest(
                    sourceID: options["--source"]!, dependentID: options["--dependent"]!,
                    sourceCommit: options["--source-commit"]!, marker: options["--marker"]!,
                    acceptedAt: options["--accepted-at"]!, evidence: options["--evidence"]!,
                    expectedWorkspaceSHA256: options["--expected-workspace-sha256"]!,
                    expectedDependentWorkspaceSHA256: options["--expected-dependent-workspace-sha256"]!,
                    expectedRegistrySHA256: options["--expected-registry-sha256"]!
                ),
                ProductionsConfiguration(schemaVersion: 2, productionsRootPath: options["--productions-root"]!)
            )
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

    private static func parseReconcile(_ values: [String]) throws -> Invocation {
        guard values.count >= 3, ["preview", "apply"].contains(values[2]) else { throw HeadlessOfficeUsageError(usage) }
        let action = values[2]
        let allowed = Set(["--productions-root", "--work", "--priority-rule", "--expected-workspace-sha256", "--expected-registry-sha256", "--state", "--priority", "--corrects-operation", "--confirm"])
        var options: [String: String] = [:], index = 3
        while index < values.count {
            guard allowed.contains(values[index]), index + 1 < values.count, options[values[index]] == nil else { throw HeadlessOfficeUsageError(usage) }
            options[values[index]] = values[index + 1]; index += 2
        }
        let required = ["--productions-root", "--work", "--priority-rule", "--expected-workspace-sha256", "--expected-registry-sha256"]
        guard required.allSatisfy({ options[$0] != nil }), let rule = LifecyclePriorityRule(rawValue: options["--priority-rule"]!) else { throw HeadlessOfficeUsageError(usage) }
        if action == "preview", options["--confirm"] != nil { throw HeadlessOfficeUsageError(usage) }
        if action == "apply", options["--confirm"] == nil { throw HeadlessOfficeUsageError(usage) }
        let corrects: UUID?
        if let raw = options["--corrects-operation"] {
            guard let parsed = UUID(uuidString: raw) else { throw HeadlessOfficeUsageError(usage) }
            corrects = parsed
        } else { corrects = nil }
        let request = LifecyclePriorityRequest(workID: options["--work"]!, expectedRegistrySHA256: options["--expected-registry-sha256"]!, expectedWorkspaceSHA256: options["--expected-workspace-sha256"]!, priorityRule: rule, desiredLifecycle: options["--state"], desiredPriority: options["--priority"], correctsOperation: corrects)
        let configuration = ProductionsConfiguration(schemaVersion: 2, productionsRootPath: options["--productions-root"]!)
        return action == "preview" ? .reconcilePreview(request, configuration) : .reconcileApply(request, options["--confirm"]!, configuration)
    }

    private static func exitCode(for outcome: String) -> Int32 {
        switch outcome {
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

    private static func render(_ result: AcceptedHandoffCommandResult) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(result), as: UTF8.self)
    }

    private static func render(_ result: LifecyclePriorityPreview) throws -> String { try renderValue(result) }
    private static func render(_ result: LifecyclePriorityCommandResult) throws -> String { try renderValue(result) }
    private static func render(_ result: [LifecyclePriorityQueueEntry]) throws -> String { try renderValue(result) }
    private static func renderValue<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

private struct HeadlessOfficeUsageError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
