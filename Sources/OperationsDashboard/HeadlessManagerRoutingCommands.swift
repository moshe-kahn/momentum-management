import Foundation

enum HeadlessManagerRoutingCommandLine {
    static let usage = """
    Usage: OperationsDashboard manager route create --task <TASK-ID> --manager-thread <thread-id> --target-thread <thread-id> --action <text> --authority <text> --timeout-at <ISO-8601> [--next-target-thread <thread-id> --next-action <text> --next-authority <text> --next-timeout-at <ISO-8601>]
           OperationsDashboard manager route acknowledge --operation <UUID> --target-thread <thread-id>
           OperationsDashboard manager route running --operation <UUID> --target-thread <thread-id>
           OperationsDashboard manager route terminal --operation <UUID> --target-thread <thread-id> --classification <completed|blocked|uncertain> --summary <text> --evidence <text> [--evidence <text> ...] --next-gate <text> --unperformed <text> [--unperformed <text> ...]
           OperationsDashboard manager routing status
           OperationsDashboard manager routing inspect --operation <UUID>
           OperationsDashboard manager routing idle-check
           OperationsDashboard manager routing reconcile preview --operation <UUID> --observation <silent-completion|empty-final-output|target-interrupted|timeout>
           OperationsDashboard manager routing reconcile apply --operation <UUID> --observation <value> --expected-ledger-sha256 <64-lowercase-hex> --confirm <token>
    """

    static func runIfRequested(
        arguments: [String] = CommandLine.arguments,
        service: ManagerRoutingService = ManagerRoutingService(),
        write: (String) -> Void = { print($0) }
    ) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard values.first == "manager" else { return nil }
        do {
            let invocation = try parse(values)
            switch invocation {
            case let .create(request): write(try render(service.create(request)))
            case let .acknowledge(id, target): write(try render(service.acknowledge(operationID: id, targetThreadID: target)))
            case let .running(id, target): write(try render(service.markRunning(operationID: id, targetThreadID: target)))
            case let .terminal(id, target, handoff): write(try render(service.receiveTerminal(operationID: id, targetThreadID: target, handoff: handoff)))
            case .status: write(try render(service.status()))
            case let .inspect(id): write(try render(service.inspection(operationID: id)))
            case .idleCheck: write(try render(service.assertMayIdle()))
            case let .reconcilePreview(id, observation): write(try render(service.reconciliationPreview(operationID: id, observation: observation)))
            case let .reconcileApply(id, observation, expected, confirmation):
                let plan = try service.reconciliationPreview(operationID: id, observation: observation)
                guard ManagerRoutingUTF8.equal(plan.expectedLedgerSHA256, expected) else {
                    throw ManagerRoutingError.staleLedger("The durable routing ledger changed. Inspect; do not retry automatically.")
                }
                write(try render(service.applyReconciliation(plan, confirmationToken: confirmation)))
            }
            return 0
        } catch {
            let noRetry = error is ManagerRoutingError && shouldNotRetry(error as! ManagerRoutingError)
            let generatedOperationID = (error as? ManagerRoutingError)?.operationUUID ?? operationID(in: values)
            let result = ManagerRoutingCommandResult(
                outcome: noRetry ? "uncertain" : "not-committed", operationUUID: generatedOperationID,
                state: nil, waitingFor: nil, ledgerSHA256: nil, nextRouteOperationUUID: nil,
                classification: noRetry ? "inspection-required" : "invalid-request",
                diagnostic: (error.localizedDescription.isEmpty ? usage : error.localizedDescription) + (noRetry ? " Do not retry automatically." : ""),
                inspectionCommand: generatedOperationID.map { "manager routing inspect --operation \($0.uuidString)" },
                noRetry: noRetry
            )
            write((try? render(result)) ?? usage)
            return noRetry ? 3 : 2
        }
    }

    enum Invocation: Equatable {
        case create(ManagerRouteCreateRequest)
        case acknowledge(UUID, String)
        case running(UUID, String)
        case terminal(UUID, String, ManagerTerminalHandoff)
        case status
        case inspect(UUID)
        case idleCheck
        case reconcilePreview(UUID, ManagerRouteObservation)
        case reconcileApply(UUID, ManagerRouteObservation, String, String)
    }

    static func parse(_ values: [String]) throws -> Invocation {
        guard values.first == "manager", values.count >= 3 else { throw ManagerRoutingError.invalidInput(usage) }
        if values[1] == "route" {
            switch values[2] {
            case "create":
                let parsed = try options(Array(values.dropFirst(3)), repeated: [])
                let allowed = Set(["--task", "--manager-thread", "--target-thread", "--action", "--authority", "--timeout-at", "--next-target-thread", "--next-action", "--next-authority", "--next-timeout-at"])
                let required = ["--task", "--manager-thread", "--target-thread", "--action", "--authority", "--timeout-at"]
                guard Set(parsed.values.keys).isSubset(of: allowed), required.allSatisfy({ parsed.values[$0] != nil }),
                      let timeout = date(parsed.values["--timeout-at"]!) else { throw ManagerRoutingError.invalidInput(usage) }
                let nextTimeout: Date?
                if let rawNextTimeout = parsed.values["--next-timeout-at"] {
                    guard let parsedNextTimeout = date(rawNextTimeout) else {
                        throw ManagerRoutingError.invalidInput("--next-timeout-at must be an exact whole-second ISO-8601 timestamp.")
                    }
                    nextTimeout = parsedNextTimeout
                } else {
                    nextTimeout = nil
                }
                return .create(.init(
                    taskID: parsed.values["--task"]!, managerThreadID: parsed.values["--manager-thread"]!,
                    targetThreadID: parsed.values["--target-thread"]!, action: parsed.values["--action"]!,
                    authorityReference: parsed.values["--authority"]!, timeoutAt: timeout,
                    nextTargetThreadID: parsed.values["--next-target-thread"], nextAction: parsed.values["--next-action"],
                    nextAuthorityReference: parsed.values["--next-authority"],
                    nextTimeoutAt: nextTimeout
                ))
            case "acknowledge", "running":
                let parsed = try options(Array(values.dropFirst(3)), repeated: [])
                guard parsed.values.count == 2, let id = parsed.values["--operation"].flatMap(UUID.init(uuidString:)),
                      let target = parsed.values["--target-thread"] else { throw ManagerRoutingError.invalidInput(usage) }
                return values[2] == "acknowledge" ? .acknowledge(id, target) : .running(id, target)
            case "terminal":
                let parsed = try options(Array(values.dropFirst(3)), repeated: ["--evidence", "--unperformed"])
                let allowed = Set(["--operation", "--target-thread", "--classification", "--summary", "--next-gate"])
                guard Set(parsed.values.keys).isSubset(of: allowed),
                      Set(parsed.repeated.keys).isSubset(of: ["--evidence", "--unperformed"]),
                      let id = parsed.values["--operation"].flatMap(UUID.init(uuidString:)),
                      let target = parsed.values["--target-thread"],
                      let raw = parsed.values["--classification"], let classification = ManagerRouteTerminalClassification(rawValue: raw),
                      let summary = parsed.values["--summary"], let next = parsed.values["--next-gate"],
                      !parsed.repeated["--evidence", default: []].isEmpty,
                      !parsed.repeated["--unperformed", default: []].isEmpty else { throw ManagerRoutingError.invalidInput(usage) }
                return .terminal(id, target, .init(
                    classification: classification, summary: summary,
                    evidence: parsed.repeated["--evidence", default: []], nextGate: next,
                    unperformedBoundaries: parsed.repeated["--unperformed", default: []]
                ))
            default: throw ManagerRoutingError.invalidInput(usage)
            }
        }
        guard values[1] == "routing" else { throw ManagerRoutingError.invalidInput(usage) }
        switch values[2] {
        case "status" where values.count == 3: return .status
        case "idle-check" where values.count == 3: return .idleCheck
        case "inspect":
            guard values.count == 5, values[3] == "--operation", let id = UUID(uuidString: values[4]) else { throw ManagerRoutingError.invalidInput(usage) }
            return .inspect(id)
        case "reconcile":
            guard values.count >= 4, values[3] == "preview" || values[3] == "apply" else { throw ManagerRoutingError.invalidInput(usage) }
            let parsed = try options(Array(values.dropFirst(4)), repeated: [])
            guard let id = parsed.values["--operation"].flatMap(UUID.init(uuidString:)),
                  let observation = parsed.values["--observation"].flatMap(ManagerRouteObservation.init(rawValue:)) else {
                throw ManagerRoutingError.invalidInput(usage)
            }
            if values[3] == "preview" {
                guard parsed.values.count == 2 else { throw ManagerRoutingError.invalidInput(usage) }
                return .reconcilePreview(id, observation)
            }
            guard parsed.values.count == 4,
                  let expected = parsed.values["--expected-ledger-sha256"], expected.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil,
                  let confirmation = parsed.values["--confirm"] else { throw ManagerRoutingError.invalidInput(usage) }
            return .reconcileApply(id, observation, expected, confirmation)
        default: throw ManagerRoutingError.invalidInput(usage)
        }
    }

    private static func options(
        _ values: [String], repeated: Set<String>
    ) throws -> (values: [String: String], repeated: [String: [String]]) {
        var singles: [String: String] = [:]
        var multiples: [String: [String]] = [:]
        var index = 0
        while index < values.count {
            let option = values[index]
            guard option.hasPrefix("--"), index + 1 < values.count, !values[index + 1].hasPrefix("--") else {
                throw ManagerRoutingError.invalidInput(usage)
            }
            if repeated.contains(option) { multiples[option, default: []].append(values[index + 1]) }
            else {
                guard singles[option] == nil else { throw ManagerRoutingError.invalidInput(usage) }
                singles[option] = values[index + 1]
            }
            index += 2
        }
        return (singles, multiples)
    }

    private static func date(_ value: String) -> Date? { ISO8601DateFormatter().date(from: value) }

    private static func render<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func operationID(in values: [String]) -> UUID? {
        guard let index = values.firstIndex(of: "--operation"), index + 1 < values.count else { return nil }
        return UUID(uuidString: values[index + 1])
    }

    private static func shouldNotRetry(_ error: ManagerRoutingError) -> Bool {
        switch error {
        case .duplicateTerminal, .staleLedger, .storageCorrupt, .storageUncertain,
             .createStorageUncertain, .idleInvariant: true
        default: false
        }
    }
}
