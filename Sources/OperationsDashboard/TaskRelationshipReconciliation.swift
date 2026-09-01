import Foundation

struct TaskRelationshipMirrorRepairPlan: Equatable {
    let workspaceAfter: Data
    let repairs: [LifecyclePriorityRepair]
}

/// Repairs display-only Task relationship drift inside an already-authorized
/// checkpoint or accepted-handoff transaction. Registry semantics always win;
/// a changed identifier/hook set is a blocker, never a repair.
enum TaskRelationshipMirrorReconciler {
    private struct FieldRule {
        let name: String
        let registryHeader: String
        let tokenPattern: String
    }

    private static let rules = [
        FieldRule(name: "Initiative", registryHeader: "Initiative", tokenPattern: #"INIT-[0-9]{4,}"#),
        FieldRule(name: "Project", registryHeader: "Project", tokenPattern: #"PROJ-[0-9]{4,}"#),
        FieldRule(name: "Depends on", registryHeader: "Depends on", tokenPattern: #"TASK-[0-9]{4,}"#),
        FieldRule(
            name: "Review after", registryHeader: "Review after",
            tokenPattern: #"(?:TASK|IDEA|PROJ|INIT)-[0-9]{4,}@(done-complete|accepted-handoff:[a-z0-9][a-z0-9._-]{0,63})"#
        ),
    ]

    static func task(
        registryRow: [String: String], workspaceData: Data
    ) throws -> TaskRelationshipMirrorRepairPlan {
        guard let text = String(data: workspaceData, encoding: .utf8), !text.contains("\r") else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Task Workspace relationship mirrors must be LF-only UTF-8.")
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var section: String?
        var fenced = false
        var fields: [String: [(index: Int, value: String)]] = [:]
        for (index, line) in lines.enumerated() {
            if !fenced, line.hasPrefix("## "), !line.hasPrefix("### ") {
                section = String(line.dropFirst(3))
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                fenced.toggle()
                continue
            }
            guard fenced, section == "Core Record" else { continue }
            for rule in rules where line.hasPrefix("\(rule.name):") {
                let value = String(line.dropFirst(rule.name.count + 1)).trimmingCharacters(in: .whitespaces)
                fields[rule.name, default: []].append((index, value))
            }
        }

        var repairs: [LifecyclePriorityRepair] = []
        for rule in rules {
            let expected = registryRow[rule.registryHeader] ?? ""
            let occurrences = fields[rule.name] ?? []
            if occurrences.isEmpty {
                if expected == "—" || expected.isEmpty { continue }
                throw LifecyclePriorityValidationError.targetContractInvalid("Workspace lacks required \(rule.name) relationship mirror.")
            }
            guard occurrences.count == 1, let occurrence = occurrences.first else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Workspace contains duplicate \(rule.name) relationship mirrors.")
            }
            let registryTokens = try semanticTokens(expected, pattern: rule.tokenPattern, field: rule.name)
            let workspaceTokens = try semanticTokens(occurrence.value, pattern: rule.tokenPattern, field: rule.name)
            guard registryTokens == workspaceTokens else {
                throw LifecyclePriorityValidationError.targetContractInvalid("Workspace \(rule.name) semantics disagree with the Task Registry.")
            }
            guard !TaskCheckpointUTF8.equal(occurrence.value, expected) else { continue }
            repairs.append(.init(
                field: "relationship:\(rule.name)", registryValueBefore: expected,
                workspaceValuesBefore: [occurrence.value], chosenValue: expected,
                rule: "registry-display", provenance: "hash-bound Task Registry relationship semantics"
            ))
            lines[occurrence.index] = "\(rule.name): \(expected)"
        }
        let output = Data(lines.joined(separator: "\n").utf8)
        if repairs.isEmpty, output != workspaceData {
            throw LifecyclePriorityValidationError.targetContractInvalid("Relationship reconciliation changed unrelated Workspace bytes.")
        }
        return .init(workspaceAfter: output, repairs: repairs)
    }

    private static func semanticTokens(
        _ value: String, pattern: String, field: String
    ) throws -> [String] {
        if value.isEmpty || value == "—" { return [] }
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: (value as NSString).length)
        let tokens = expression.matches(in: value, range: range).map { (value as NSString).substring(with: $0.range(at: 0)) }
        guard !tokens.isEmpty, Set(tokens).count == tokens.count else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Workspace/Registry \(field) contains missing or duplicate durable relationship tokens.")
        }
        let allDurable = try NSRegularExpression(pattern: #"(?:TASK|IDEA|PROJ|INIT)-[0-9]{4,}(?:@[a-z0-9:._-]+)?"#)
            .matches(in: value, range: range).map { (value as NSString).substring(with: $0.range(at: 0)) }
        guard allDurable == tokens else {
            throw LifecyclePriorityValidationError.targetContractInvalid("Workspace/Registry \(field) contains wrong-kind or malformed relationship semantics.")
        }
        return tokens.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
}
