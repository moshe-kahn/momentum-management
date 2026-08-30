import CryptoKit
import Darwin
import Foundation

private enum AcceptedHandoffMarkdown {
    static func anchors(in text: String) -> Set<String> {
        var result = Set<String>()
        var fence: (character: Character, minimumRun: Int)?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if let run = fenceRun(in: line) {
                if let active = fence {
                    if run.character == active.character, run.count >= active.minimumRun, run.restIsWhitespace {
                        fence = nil
                    }
                } else {
                    fence = (run.character, run.count)
                }
                continue
            }
            guard fence == nil, let title = atxHeadingTitle(in: line) else { continue }
            let lowered = title.lowercased()
            let allowed = lowered.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0) || $0 == "-"
            }
            let anchor = String(String.UnicodeScalarView(allowed))
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: "-")
            if !anchor.isEmpty { result.insert(anchor) }
        }
        return result
    }

    private static func fenceRun(in line: String) -> (character: Character, count: Int, restIsWhitespace: Bool)? {
        var index = line.startIndex, leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard leadingSpaces <= 3, index < line.endIndex,
              line[index] == "`" || line[index] == "~" else { return nil }
        let character = line[index]
        var count = 0
        while index < line.endIndex, line[index] == character {
            count += 1
            index = line.index(after: index)
        }
        guard count >= 3 else { return nil }
        return (character, count, line[index...].allSatisfy(\.isWhitespace))
    }

    private static func atxHeadingTitle(in line: String) -> String? {
        var index = line.startIndex, leadingSpaces = 0
        while index < line.endIndex, line[index] == " ", leadingSpaces < 4 {
            leadingSpaces += 1
            index = line.index(after: index)
        }
        guard leadingSpaces <= 3, index < line.endIndex, line[index] == "#" else { return nil }
        var hashCount = 0
        while index < line.endIndex, line[index] == "#" {
            hashCount += 1
            index = line.index(after: index)
        }
        guard (1...6).contains(hashCount),
              index == line.endIndex || line[index] == " " || line[index] == "\t" else { return nil }
        var title = String(line[index...]).trimmingCharacters(in: .whitespaces)
        if let range = title.range(of: #"[ \t]+#+[ \t]*$"#, options: .regularExpression) {
            title.removeSubrange(range)
            title = title.trimmingCharacters(in: .whitespaces)
        }
        return title.isEmpty ? nil : title
    }
}

struct AcceptedHandoffRequest: Equatable {
    let sourceID: String
    let dependentID: String
    let sourceCommit: String
    let marker: String
    let acceptedAt: String
    let evidence: String
    let expectedWorkspaceSHA256: String
    let expectedDependentWorkspaceSHA256: String
    let expectedRegistrySHA256: String
}

struct AcceptedHandoffEligibleHook: Codable, Equatable, Comparable {
    let candidateID: String
    let hook: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.candidateID == rhs.candidateID ? lhs.hook < rhs.hook : lhs.candidateID < rhs.candidateID
    }
}

struct AcceptedHandoffCommandResult: Codable, Equatable {
    let outcome: String
    let operationUUID: UUID?
    let sourceID: String?
    let dependentID: String?
    let sourceCommit: String?
    let marker: String?
    let workspaceSHA256Before: String?
    let workspaceSHA256After: String?
    let dependentWorkspaceSHA256: String?
    let registrySHA256: String?
    let classification: String?
    let journalFinalized: Bool
    let fallbackRecorded: Bool
    let historicalCommitProven: Bool
    let discoveryOutcome: String?
    let newlyEligibleHooks: [AcceptedHandoffEligibleHook]?
    let inspectCommand: String?
    let diagnostic: String?
}

struct AcceptedHandoffCommandFailure: Error, Equatable {
    let result: AcceptedHandoffCommandResult
    let exitCode: Int32
}

enum AcceptedHandoffValidationError: LocalizedError, Equatable {
    case invalidInput(String)
    case targetContractInvalid(String)
    case hashMismatch(String)
    case lockUnavailable

    var errorDescription: String? {
        switch self {
        case let .invalidInput(message): "invalidInput: \(message)"
        case let .targetContractInvalid(message): "targetContractInvalid: \(message)"
        case let .hashMismatch(message): "hashMismatch: \(message)"
        case .lockUnavailable: "Another Task Registry-and-Workspace transaction is in progress."
        }
    }
}

struct AcceptedHandoffJournal: Codable, Equatable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let operationUUID: UUID
    let productionsRootPath: String
    let operationKind: String
    let sourceID: String
    let dependentID: String
    let sourceCommit: String
    let marker: String
    let acceptedAt: String
    let evidence: String
    let evidencePath: String
    let evidenceFingerprint: String
    let registryPath: String
    let registrySHA256: String
    let registryPreimage: Data
    let workspacePath: String
    let workspaceSHA256Before: String
    let workspacePreimage: Data
    let workspaceSHA256ExpectedAfter: String
    let workspaceExpectedAfter: Data
    let dependentWorkspacePath: String
    let dependentWorkspaceSHA256: String
    let dependentWorkspacePreimage: Data
    let targetFingerprint: String
    private(set) var terminalState: OfficeWorkspaceTerminalState?
    private(set) var journalFinalized: Bool
    private(set) var fallbackRecorded: Bool
    private(set) var diagnostic: String?

    mutating func transition(to proposed: OfficeWorkspaceTerminalState, diagnostic: String?, finalized: Bool) {
        terminalState = .merging(current: terminalState, proposed: proposed)
        journalFinalized = finalized
        self.diagnostic = diagnostic
    }

    mutating func markFallback(_ state: OfficeWorkspaceTerminalState, diagnostic: String) {
        terminalState = .merging(current: terminalState, proposed: state)
        journalFinalized = false
        fallbackRecorded = true
        self.diagnostic = diagnostic
    }
}

protocol AcceptedHandoffJournalStore {
    func persist(_ journal: AcceptedHandoffJournal) throws
    func update(_ journal: AcceptedHandoffJournal) throws
    func recordFallback(_ journal: AcceptedHandoffJournal) throws
    func journal(operationID: UUID) throws -> AcceptedHandoffJournal?
    func incomplete() throws -> [AcceptedHandoffJournal]
}

enum AcceptedHandoffJournalEnvelopeError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case let .invalid(message): "Invalid accepted-handoff journal envelope: \(message)" }
    }
}

struct ApplicationSupportAcceptedHandoffJournalStore: AcceptedHandoffJournalStore {
    private let manager: FileManager
    private let directoryOverride: URL?

    init(manager: FileManager = .default, directory: URL? = nil) {
        self.manager = manager
        directoryOverride = directory
    }

    var directory: URL {
        directoryOverride ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/Office Workspace Transaction Recovery", directoryHint: .isDirectory)
    }

    func persist(_ journal: AcceptedHandoffJournal) throws {
        try journal.validateEnvelope(requestedOperationID: journal.operationUUID)
        guard journal.terminalState == nil, !journal.journalFinalized,
              !journal.fallbackRecorded, journal.diagnostic == nil else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("An initial journal must be unfinalized, nonfallback, and nonterminal.")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try matchingURLs(operationID: journal.operationUUID).isEmpty else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("A journal already exists for the issued operation UUID.")
        }
        try writeUnchecked(journal)
    }

    func update(_ journal: AcceptedHandoffJournal) throws {
        try journal.validateEnvelope(requestedOperationID: journal.operationUUID)
        guard let durable = try self.journal(operationID: journal.operationUUID) else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("The bound recovery journal is unavailable for update.")
        }
        try journal.validateUpdate(from: durable, requiresFallback: false)
        try writeUnchecked(journal)
    }

    func recordFallback(_ journal: AcceptedHandoffJournal) throws {
        try journal.validateEnvelope(requestedOperationID: journal.operationUUID)
        guard let durable = try self.journal(operationID: journal.operationUUID) else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("The bound recovery journal is unavailable for fallback recording.")
        }
        try journal.validateUpdate(from: durable, requiresFallback: true)
        try writeUnchecked(journal)
    }

    func journal(operationID: UUID) throws -> AcceptedHandoffJournal? {
        let matches = try matchingURLs(operationID: operationID)
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1,
              TaskCheckpointUTF8.equal(matches[0].lastPathComponent, "\(operationID.uuidString).json") else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("The durable journal filename does not exactly bind the requested operation UUID.")
        }
        return try readBoundJournal(at: matches[0], operationID: operationID)
    }

    func incomplete() throws -> [AcceptedHandoffJournal] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let stem = url.deletingPathExtension().lastPathComponent
                guard let operationID = UUID(uuidString: stem),
                      TaskCheckpointUTF8.equal(url.lastPathComponent, "\(operationID.uuidString).json") else {
                    throw AcceptedHandoffJournalEnvelopeError.invalid("A startup journal filename is not one exact canonical UUID.")
                }
                let data = try Data(contentsOf: url)
                guard Self.operationKind(in: data) == "accepted-handoff" else { return nil }
                let journal = try readBoundJournal(at: url, operationID: operationID)
                return journal.terminalState == nil || journal.terminalState?.isStartupIncomplete == true ? journal : nil
            }
    }

    static func operationKind(in data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["operationKind"] as? String
    }

    private func matchingURLs(operationID: UUID) throws -> [URL] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let expected = "\(operationID.uuidString).json"
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.caseInsensitiveCompare(expected) == .orderedSame }
    }

    private func readBoundJournal(at url: URL, operationID: UUID) throws -> AcceptedHandoffJournal {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("The durable journal is not a non-followed regular file.")
        }
        let data = try Data(contentsOf: url)
        guard Self.operationKind(in: data) == "accepted-handoff" else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("The durable journal operation kind is not accepted-handoff.")
        }
        let value = try JSONDecoder().decode(AcceptedHandoffJournal.self, from: data)
        try value.validateEnvelope(requestedOperationID: operationID)
        return value
    }

    private func writeUnchecked(_ journal: AcceptedHandoffJournal) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try DurableReplacement(manager: manager).replace(
            data: try encoder.encode(journal),
            at: directory.appending(path: "\(journal.operationUUID.uuidString).json")
        )
    }
}

private extension AcceptedHandoffJournal {
    func validateEnvelope(requestedOperationID: UUID) throws {
        let hashPattern = #"^[0-9a-f]{64}$"#
        let taskPattern = #"^TASK-[0-9]{4,}$"#
        guard operationUUID == requestedOperationID,
              schemaVersion == Self.schemaVersion,
              operationKind == "accepted-handoff",
              sourceID.range(of: taskPattern, options: .regularExpression) != nil,
              dependentID.range(of: taskPattern, options: .regularExpression) != nil,
              !TaskCheckpointUTF8.equal(sourceID, dependentID),
              sourceCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil,
              marker.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil,
              AcceptedHandoffService.exactTimestamp(acceptedAt) != nil,
              !evidence.isEmpty, !evidencePath.isEmpty,
              registryPath == "Office/Registry/Tasks.md",
              workspacePath == "Workspace/\(sourceID)/\(sourceID).md",
              dependentWorkspacePath == "Workspace/\(dependentID)/\(dependentID).md",
              TaskCheckpointCanonicalRoot.isExact(productionsRootPath),
              [registrySHA256, workspaceSHA256Before, workspaceSHA256ExpectedAfter,
               dependentWorkspaceSHA256, evidenceFingerprint, targetFingerprint].allSatisfy({
                  $0.range(of: hashPattern, options: .regularExpression) != nil
              }),
              registrySHA256 == digest(registryPreimage),
              workspaceSHA256Before == digest(workspacePreimage),
              workspaceSHA256ExpectedAfter == digest(workspaceExpectedAfter),
              dependentWorkspaceSHA256 == digest(dependentWorkspacePreimage) else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("UUID, schema, kind, IDs, fixed paths, or bound hashes do not match.")
        }
        try validateTerminalFlags()
    }

    func validateUpdate(from durable: AcceptedHandoffJournal, requiresFallback: Bool) throws {
        guard immutableEnvelopeEquals(durable) else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("A journal update attempted to substitute an immutable operation-envelope field.")
        }
        guard let proposedState = terminalState,
              proposedState == OfficeWorkspaceTerminalState.merging(current: durable.terminalState, proposed: proposedState) else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("A journal update attempted a nonmonotonic or proving-to-nonproving terminal transition.")
        }
        try validateTerminalFlags()
        guard requiresFallback == fallbackRecorded else {
            throw AcceptedHandoffJournalEnvelopeError.invalid("Fallback state and update method disagree.")
        }
        if durable.fallbackRecorded {
            guard fallbackRecorded else {
                throw AcceptedHandoffJournalEnvelopeError.invalid("A durable fallback marker cannot be removed.")
            }
        }
    }

    func immutableEnvelopeEquals(_ other: Self) -> Bool {
        schemaVersion == other.schemaVersion && operationUUID == other.operationUUID &&
        TaskCheckpointUTF8.equal(productionsRootPath, other.productionsRootPath) &&
        TaskCheckpointUTF8.equal(operationKind, other.operationKind) &&
        TaskCheckpointUTF8.equal(sourceID, other.sourceID) &&
        TaskCheckpointUTF8.equal(dependentID, other.dependentID) &&
        TaskCheckpointUTF8.equal(sourceCommit, other.sourceCommit) &&
        TaskCheckpointUTF8.equal(marker, other.marker) &&
        TaskCheckpointUTF8.equal(acceptedAt, other.acceptedAt) &&
        TaskCheckpointUTF8.equal(evidence, other.evidence) &&
        TaskCheckpointUTF8.equal(evidencePath, other.evidencePath) &&
        TaskCheckpointUTF8.equal(evidenceFingerprint, other.evidenceFingerprint) &&
        TaskCheckpointUTF8.equal(registryPath, other.registryPath) &&
        TaskCheckpointUTF8.equal(registrySHA256, other.registrySHA256) && registryPreimage == other.registryPreimage &&
        TaskCheckpointUTF8.equal(workspacePath, other.workspacePath) &&
        TaskCheckpointUTF8.equal(workspaceSHA256Before, other.workspaceSHA256Before) &&
        workspacePreimage == other.workspacePreimage &&
        TaskCheckpointUTF8.equal(workspaceSHA256ExpectedAfter, other.workspaceSHA256ExpectedAfter) &&
        workspaceExpectedAfter == other.workspaceExpectedAfter &&
        TaskCheckpointUTF8.equal(dependentWorkspacePath, other.dependentWorkspacePath) &&
        TaskCheckpointUTF8.equal(dependentWorkspaceSHA256, other.dependentWorkspaceSHA256) &&
        dependentWorkspacePreimage == other.dependentWorkspacePreimage &&
        TaskCheckpointUTF8.equal(targetFingerprint, other.targetFingerprint)
    }

    func validateTerminalFlags() throws {
        switch terminalState {
        case nil:
            guard !journalFinalized, !fallbackRecorded else {
                throw AcceptedHandoffJournalEnvelopeError.invalid("A nonterminal journal cannot be finalized or fallback-recorded.")
            }
        case let state?:
            if state.hasFallback {
                guard !journalFinalized, fallbackRecorded else {
                    throw AcceptedHandoffJournalEnvelopeError.invalid("A fallback terminal requires finalized false and fallback true.")
                }
            } else {
                guard journalFinalized, !fallbackRecorded else {
                    throw AcceptedHandoffJournalEnvelopeError.invalid("A normal terminal requires finalized true and fallback false.")
                }
            }
        }
    }

    func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct AcceptedHandoffEvidence {
    let reference: String
    let relativePath: String
    let fingerprint: String
}

private struct AcceptedHandoffPreparedTarget {
    let registryURL: URL
    let registryData: Data
    let sourceRow: [String: String]
    let dependentRow: [String: String]
    let workspaceURL: URL
    let workspaceData: Data
    let replacementData: Data
    let dependentWorkspaceURL: URL
    let dependentWorkspaceData: Data
    let evidence: AcceptedHandoffEvidence
    let targetFingerprint: String
}

private struct AcceptedHandoffTaskWorkspace {
    struct Row: Equatable {
        let marker: String
        let acceptedAt: String
        let evidence: String
    }

    private let lines: [String]
    private let finalNewline: Bool
    private let topLevelTitle: String
    private let sections: [String: Range<Int>]
    private let coreFields: [String: Range<Int>]
    let data: Data
    let acceptedRows: [Row]

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\r") else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Task Workspace must be valid LF-only UTF-8.")
        }
        self.data = data
        finalNewline = text.hasSuffix("\n")
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var insideFence = false
        var h1s: [String] = []
        var headings: [(String, Int)] = []
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { insideFence.toggle(); continue }
            guard !insideFence else { continue }
            if line.hasPrefix("# "), !line.hasPrefix("## ") {
                h1s.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("## "), !line.hasPrefix("### ") {
                headings.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), index))
            }
        }
        guard h1s.count == 1, let h1 = h1s.first, !h1.isEmpty else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Workspace must contain exactly one non-fenced H1 title.")
        }
        topLevelTitle = h1
        let grouped = Dictionary(grouping: headings, by: { $0.0 })
        if let duplicate = grouped.first(where: { $0.value.count > 1 }) {
            throw AcceptedHandoffValidationError.targetContractInvalid("Duplicate Workspace section: \(duplicate.key).")
        }
        var ranges: [String: Range<Int>] = [:]
        for (offset, heading) in headings.enumerated() {
            ranges[heading.0] = (heading.1 + 1)..<(offset + 1 < headings.count ? headings[offset + 1].1 : lines.count)
        }
        guard let coreRange = ranges["Core Record"] else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Workspace requires one Core Record section.")
        }
        sections = ranges
        let fieldPattern = try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9, /()_-]*):"#)
        var starts: [(String, Int)] = []
        for index in coreRange {
            let line = lines[index], ns = line as NSString
            if let match = fieldPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                starts.append((ns.substring(with: match.range(at: 1)), index))
            }
        }
        if let duplicate = Dictionary(grouping: starts, by: { $0.0 }).first(where: { $0.value.count > 1 }) {
            throw AcceptedHandoffValidationError.targetContractInvalid("Duplicate Core Record field: \(duplicate.key).")
        }
        var fields: [String: Range<Int>] = [:]
        for (offset, field) in starts.enumerated() {
            fields[field.0] = field.1..<(offset + 1 < starts.count ? starts[offset + 1].1 : coreRange.upperBound)
        }
        coreFields = fields
        acceptedRows = try Self.parseAcceptedRows(lines: lines, section: ranges["Accepted Handoffs"])
    }

    func field(_ name: String) -> String {
        guard let range = coreFields[name], let first = range.first else { return "" }
        let prefix = "\(name):"
        var values = [String(lines[first].dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)]
        for line in lines[range.dropFirst()] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed != "```" { values.append(trimmed) }
        }
        return values.joined(separator: "\n")
    }

    func validateIdentity(taskID: String, row: [String: String]) throws {
        let exact = [
            ("Title", row["Title"] ?? ""), ("ID", taskID), ("Type", "Task"),
            ("Current lead", row["Current lead"] ?? ""), ("Status source", "Office/Registry/Tasks.md"),
        ]
        guard exact.allSatisfy({ !$0.1.isEmpty && field($0.0) == $0.1 }),
              topLevelTitle == row["Title"] else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Workspace H1, identity, title, lead, type, or status source disagrees with the Task Registry.")
        }
        for relationship in ["Initiative", "Project"] {
            guard Self.normalizedRelationship(field(relationship)) == Self.normalizedRelationship(row[relationship] ?? "") else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Workspace \(relationship) disagrees with the Task Registry.")
            }
        }
        guard Self.taskIDs(in: field("Depends on")) == Self.taskIDs(in: row["Depends on"] ?? "") else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Workspace Depends on identifiers disagree with the Task Registry.")
        }
    }

    func containsRelatedTask(_ taskID: String) -> Bool {
        Self.taskIDs(in: field("Related records")).contains(taskID)
    }

    func depends(on taskID: String) -> Bool {
        Self.taskIDs(in: field("Depends on")).contains(taskID)
    }

    func replacement(marker: String, acceptedAt: String, evidence: String) throws -> Data {
        guard !acceptedRows.contains(where: { $0.marker == marker }) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Accepted handoff marker already exists and is immutable.")
        }
        let row = "| \(marker) | \(acceptedAt) | \(evidence) |"
        var output = lines
        if let range = sections["Accepted Handoffs"] {
            let header = "| Marker | Accepted at | Evidence |"
            guard let headerIndex = range.first(where: { lines[$0] == header }) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs table is unavailable.")
            }
            var insertion = headerIndex + 2
            while insertion < range.upperBound, lines[insertion].hasPrefix("|") { insertion += 1 }
            output.insert(row, at: insertion)
        } else {
            let insertion = finalNewline && output.last == "" ? output.count - 1 : output.count
            let leading = insertion > 0 && output[insertion - 1] != "" ? [""] : []
            output.insert(contentsOf: leading + [
                "## Accepted Handoffs", "", "| Marker | Accepted at | Evidence |",
                "| --- | --- | --- |", row,
            ], at: insertion)
        }
        return Data(output.joined(separator: "\n").utf8)
    }

    func validatePostimage(_ after: Self, marker: String, acceptedAt: String, evidence: String, replacement: Data) throws {
        guard after.acceptedRows == acceptedRows + [Row(marker: marker, acceptedAt: acceptedAt, evidence: evidence)] else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Prepared accepted-handoff row is not one exact immutable append.")
        }
        guard try self.replacement(marker: marker, acceptedAt: acceptedAt, evidence: evidence) == replacement else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Prepared accepted-handoff replacement changed unrelated bytes.")
        }
    }

    static func taskIDs(in value: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"TASK-[0-9]{4,}"#)
        let ns = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private static func parseAcceptedRows(lines: [String], section: Range<Int>?) throws -> [Row] {
        guard let section else { return [] }
        let header = "| Marker | Accepted at | Evidence |"
        let delimiter = "| --- | --- | --- |"
        let matches = section.filter { lines[$0] == header }
        guard matches.count == 1, let headerIndex = matches.first,
              headerIndex + 1 < section.upperBound, lines[headerIndex + 1] == delimiter else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs requires one exact header and delimiter.")
        }
        guard lines[section.lowerBound..<headerIndex].allSatisfy(\.isEmpty) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs permits only blank spacing before its exact table.")
        }
        var rows: [Row] = []
        var index = headerIndex + 2
        while index < section.upperBound, lines[index].hasPrefix("|") {
            let cells = MarkdownTable.cells(lines[index])
            guard cells.count == 3,
                  cells[0].range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil,
                  AcceptedHandoffService.exactTimestamp(cells[1]) != nil,
                  !cells[2].isEmpty,
                  TaskCheckpointUTF8.equal(lines[index], "| \(cells[0]) | \(cells[1]) | \(cells[2]) |") else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs contains a malformed row.")
            }
            rows.append(Row(marker: cells[0], acceptedAt: cells[1], evidence: cells[2]))
            index += 1
        }
        guard Set(rows.map(\.marker)).count == rows.count else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs markers must be unique.")
        }
        for later in lines[index..<section.upperBound] {
            if later.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs contains a fragmented or later table-like row.")
            }
        }
        return rows
    }

    private static func normalizedRelationship(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "—" { return "—" }
        if let range = trimmed.range(of: #"^(INIT|PROJ)-[0-9]{4,}"#, options: .regularExpression) {
            return String(trimmed[range])
        }
        return trimmed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct AcceptedHandoffService {
    let journalStore: any AcceptedHandoffJournalStore
    let replacer: any AtomicFileReplacing
    let locking: any TaskCheckpointLocking
    let contractValidator: any OfficeV112ContractValidating
    let manager: FileManager
    let makeOperationID: () -> UUID
    let discover: (String, String, ProductionsConfiguration) throws -> [AcceptedHandoffEligibleHook]

    init(
        journalStore: any AcceptedHandoffJournalStore = ApplicationSupportAcceptedHandoffJournalStore(),
        replacer: (any AtomicFileReplacing)? = nil,
        locking: any TaskCheckpointLocking = LocalTaskCheckpointLocking(),
        contractValidator: any OfficeV112ContractValidating = AdoptedOfficeV112ContractValidator(),
        manager: FileManager = .default,
        makeOperationID: @escaping () -> UUID = UUID.init,
        discover: @escaping (String, String, ProductionsConfiguration) throws -> [AcceptedHandoffEligibleHook] = AcceptedHandoffDiscovery.newlyEligible
    ) {
        self.journalStore = journalStore
        self.replacer = replacer ?? DurableReplacement(manager: manager)
        self.locking = locking
        self.contractValidator = contractValidator
        self.manager = manager
        self.makeOperationID = makeOperationID
        self.discover = discover
    }

    func startupRecovery() -> [AcceptedHandoffJournal] { (try? journalStore.incomplete()) ?? [] }

    func perform(request: AcceptedHandoffRequest, configuration: ProductionsConfiguration) throws -> AcceptedHandoffCommandResult {
        do {
            guard TaskCheckpointCanonicalRoot.isExact(configuration.productionsRootPath) else {
                throw OfficeContractValidationError.contractNotAdopted("The supplied Productions root must use one exact absolute spelling.")
            }
            try contractValidator.validate(configuration: configuration)
        } catch {
            throw failure(
                outcome: "not-committed", operationID: nil, request: request,
                classification: "contractNotAdopted", diagnostic: error.localizedDescription + " No operation journal was created.",
                exitCode: 2
            )
        }

        let operationID = makeOperationID()
        do { try validateRequest(request) }
        catch {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                classification: "invalidInput", diagnostic: error.localizedDescription + " No operation journal was created.",
                exitCode: 2
            )
        }

        let registryURL = configuration.taskCheckpointURL(ProductionsPath.tasks.rawValue)
        do { try requireSafeFile(registryURL, root: configuration.taskCheckpointRootURL, label: "Task Registry") }
        catch {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                classification: "targetContractInvalid", diagnostic: error.localizedDescription + " No operation journal was created.",
                exitCode: 2
            )
        }
        guard let lock = locking.acquire(registryURL: registryURL) else {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                classification: "lockUnavailable", diagnostic: AcceptedHandoffValidationError.lockUnavailable.localizedDescription + " No operation journal was created.",
                exitCode: 2
            )
        }
        defer { _ = lock }

        let prepared: AcceptedHandoffPreparedTarget
        do { prepared = try prepare(request: request, configuration: configuration) }
        catch {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                classification: classification(for: error), diagnostic: error.localizedDescription + " No operation journal was created.",
                exitCode: 2
            )
        }

        var journal = AcceptedHandoffJournal(
            schemaVersion: AcceptedHandoffJournal.schemaVersion,
            operationUUID: operationID,
            productionsRootPath: configuration.productionsRootPath,
            operationKind: "accepted-handoff",
            sourceID: request.sourceID,
            dependentID: request.dependentID,
            sourceCommit: request.sourceCommit,
            marker: request.marker,
            acceptedAt: request.acceptedAt,
            evidence: request.evidence,
            evidencePath: prepared.evidence.relativePath,
            evidenceFingerprint: prepared.evidence.fingerprint,
            registryPath: ProductionsPath.tasks.rawValue,
            registrySHA256: digest(prepared.registryData),
            registryPreimage: prepared.registryData,
            workspacePath: "Workspace/\(request.sourceID)/\(request.sourceID).md",
            workspaceSHA256Before: digest(prepared.workspaceData),
            workspacePreimage: prepared.workspaceData,
            workspaceSHA256ExpectedAfter: digest(prepared.replacementData),
            workspaceExpectedAfter: prepared.replacementData,
            dependentWorkspacePath: "Workspace/\(request.dependentID)/\(request.dependentID).md",
            dependentWorkspaceSHA256: digest(prepared.dependentWorkspaceData),
            dependentWorkspacePreimage: prepared.dependentWorkspaceData,
            targetFingerprint: prepared.targetFingerprint,
            terminalState: nil, journalFinalized: false, fallbackRecorded: false, diagnostic: nil
        )
        do { try journalStore.persist(journal) }
        catch {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                before: journal.workspaceSHA256Before, dependent: journal.dependentWorkspaceSHA256,
                registry: journal.registrySHA256, classification: "journalCreateFailed",
                diagnostic: "Initial recovery journal could not be persisted; no canonical replacement was attempted and no durable operation journal was created: \(error.localizedDescription)",
                exitCode: 2
            )
        }

        do {
            try requireSafeFile(prepared.registryURL, root: configuration.taskCheckpointRootURL, label: "Task Registry")
            try requireSafeFile(prepared.workspaceURL, root: configuration.taskCheckpointRootURL, label: "Source Workspace")
            try requireSafeFile(prepared.dependentWorkspaceURL, root: configuration.taskCheckpointRootURL, label: "Dependent Workspace")
            guard try Data(contentsOf: prepared.registryURL) == prepared.registryData,
                  try Data(contentsOf: prepared.workspaceURL) == prepared.workspaceData,
                  try Data(contentsOf: prepared.dependentWorkspaceURL) == prepared.dependentWorkspaceData else {
                return try finishDefiniteNoCommit(journal: &journal, request: request, diagnostic: "Registry or Workspace bytes changed after preparation; no replacement was attempted.")
            }
            let currentEvidence = try resolveEvidence(
                request.evidence, sourceCommit: request.sourceCommit,
                sourceWorkspacePath: journal.workspacePath, configuration: configuration
            )
            guard TaskCheckpointUTF8.equal(currentEvidence.relativePath, prepared.evidence.relativePath),
                  TaskCheckpointUTF8.equal(currentEvidence.fingerprint, prepared.evidence.fingerprint) else {
                return try finishDefiniteNoCommit(journal: &journal, request: request, diagnostic: "Evidence changed after preparation; no replacement was attempted.")
            }
        } catch let failure as AcceptedHandoffCommandFailure {
            throw failure
        } catch {
            return try finishDefiniteNoCommit(
                journal: &journal, request: request,
                diagnostic: "Registry or Workspace could not be re-read before replacement; no replacement was attempted: \(error.localizedDescription)"
            )
        }

        do { try replacer.replace(data: prepared.replacementData, at: prepared.workspaceURL) }
        catch {
            return try reconcileReplacementException(
                journal: &journal, request: request, configuration: configuration,
                replacementDiagnostic: error.localizedDescription
            )
        }

        do { try fullyValidatePostimage(journal: journal, configuration: configuration) }
        catch {
            let diagnostic = "Source Workspace replacement returned success, but committed reload validation failed: \(error.localizedDescription)"
            do {
                guard let durable = try journalStore.journal(operationID: operationID) else {
                    throw AcceptedHandoffValidationError.targetContractInvalid("No recovery journal exists for the issued operation UUID.")
                }
                journal = durable
            } catch {
                throw failure(
                    outcome: "uncertain", operationID: operationID, request: request,
                    before: journal.workspaceSHA256Before, after: journal.workspaceSHA256ExpectedAfter,
                    dependent: journal.dependentWorkspaceSHA256, registry: journal.registrySHA256,
                    classification: "historically-committed-current-state-uncertain",
                    historicalCommitProven: true,
                    diagnostic: "Workspace replacement returned success, reload failed, and the recovery journal could not be read: \(error.localizedDescription). Do not retry automatically.",
                    journalRootPath: journal.productionsRootPath, exitCode: 3
                )
            }
            return try finishProvenFailure(
                journal: &journal, request: request, state: .committedReloadFailed,
                classification: "historically-committed-current-state-uncertain", diagnostic: diagnostic
            )
        }

        do {
            journal.transition(to: .committedAndCurrent, diagnostic: nil, finalized: true)
            try journalStore.update(journal)
        } catch {
            return try finishJournalFailure(
                journal: &journal, request: request,
                fallback: .journalFinalizationFailedCommittedAndCurrent,
                classification: "committed-and-current",
                diagnostic: "The accepted-handoff commit is proven current, but normal terminal journal finalization failed: \(error.localizedDescription)"
            )
        }

        do {
            return try committedWithDiscovery(journal: journal)
        } catch {
            return discoveryFailure(journal: journal, error: error)
        }
    }

    func inspect(operationID: UUID, configuration: ProductionsConfiguration) throws -> AcceptedHandoffCommandResult {
        let journal: AcceptedHandoffJournal
        do {
            guard let found = try journalStore.journal(operationID: operationID) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("No accepted-handoff journal exists for \(operationID.uuidString).")
            }
            journal = found
        } catch {
            throw failure(
                outcome: "uncertain", operationID: operationID, request: nil,
                classification: "journal-read-failed",
                diagnostic: "The operation journal could not be read: \(error.localizedDescription). Do not retry automatically.",
                exitCode: 3
            )
        }
        if journal.terminalState == .definiteNoCommit || journal.terminalState == .journalFinalizationFailedDefiniteNoCommit {
            return result(
                outcome: "not-committed", journal: journal, classification: "definite-no-commit",
                discoveryOutcome: nil, hooks: nil, diagnostic: journal.diagnostic
            )
        }
        let historicalProof = journal.terminalState?.provesHistoricalCommit == true
        guard TaskCheckpointCanonicalRoot.isExact(configuration.productionsRootPath),
              TaskCheckpointUTF8.equal(configuration.productionsRootPath, journal.productionsRootPath) else {
            return inspectionUncertain(
                journal: journal, historicalProof: historicalProof,
                diagnostic: "The supplied canonical Productions root does not match the immutable journal-bound root. No live target was read and no journal state was reconciled."
            )
        }
        let current: (registry: Data, source: Data, dependent: Data)
        do { current = try currentBytes(journal: journal, configuration: configuration) }
        catch {
            return inspectionUncertain(journal: journal, historicalProof: historicalProof, diagnostic: "The bound canonical target is unavailable or unreadable: \(error.localizedDescription)")
        }
        if historicalProof {
            if current.source == journal.workspacePreimage {
                return inspectionUncertain(journal: journal, historicalProof: true, diagnostic: "Canonical Workspace bytes returned to the journal preimage after a proven commit; history is inconsistent.")
            }
            if current.source == journal.workspaceExpectedAfter,
               current.registry == journal.registryPreimage,
               current.dependent == journal.dependentWorkspacePreimage {
                do {
                    try fullyValidatePostimage(journal: journal, configuration: configuration)
                    return result(outcome: "committed", journal: journal, classification: "committed-and-current", discoveryOutcome: nil, hooks: nil, diagnostic: journal.diagnostic)
                } catch {
                    return inspectionUncertain(journal: journal, historicalProof: true, diagnostic: "Exact postimage bytes exist but complete validation failed: \(error.localizedDescription)")
                }
            }
            do {
                try validateSupersedingState(journal: journal, configuration: configuration, current: current)
                return result(
                    outcome: "committed", journal: journal,
                    classification: "historically-committed-and-superseded", discoveryOutcome: nil, hooks: nil,
                    diagnostic: "The historical accepted-handoff commit is proven and a later valid canonical mutation superseded its exact postimage."
                )
            } catch {
                return inspectionUncertain(journal: journal, historicalProof: true, diagnostic: "Historical commit remains proven, but current target identity or marker history is uncertain: \(error.localizedDescription)")
            }
        }
        if current.source == journal.workspacePreimage,
           current.registry == journal.registryPreimage,
           current.dependent == journal.dependentWorkspacePreimage {
            return result(outcome: "not-committed", journal: journal, classification: "definite-no-commit", discoveryOutcome: nil, hooks: nil, diagnostic: "The exact preimages prove no commit.")
        }
        if current.source == journal.workspaceExpectedAfter,
           current.registry == journal.registryPreimage,
           current.dependent == journal.dependentWorkspacePreimage {
            do {
                try fullyValidatePostimage(journal: journal, configuration: configuration)
            } catch {
                return inspectionUncertain(journal: journal, historicalProof: false, diagnostic: "Exact postimage bytes could not be fully validated: \(error.localizedDescription)")
            }
            var reconciled = journal
            reconciled.transition(
                to: .reconciledCommittedAndCurrent,
                diagnostic: "Inspection reconciled the exact accepted-handoff postimage as committed.",
                finalized: true
            )
            do {
                try journalStore.update(reconciled)
                return result(
                    outcome: "committed", journal: reconciled,
                    classification: "committed-and-current", discoveryOutcome: nil, hooks: nil,
                    diagnostic: reconciled.diagnostic
                )
            } catch {
                let request = request(from: journal)
                return try finishJournalFailure(
                    journal: &reconciled, request: request,
                    fallback: .journalFinalizationFailedCommittedAndCurrent,
                    classification: "committed-and-current",
                    diagnostic: "Inspection proved the exact accepted-handoff postimage committed, but normal terminal journal finalization failed: \(error.localizedDescription)"
                )
            }
        }
        return inspectionUncertain(journal: journal, historicalProof: false, diagnostic: "Neither exact preimages nor a completely valid exact postimage are current.")
    }

    static func exactTimestamp(_ value: String) -> Date? {
        guard value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func prepare(request: AcceptedHandoffRequest, configuration: ProductionsConfiguration) throws -> AcceptedHandoffPreparedTarget {
        let root = configuration.taskCheckpointRootURL
        let registryURL = configuration.taskCheckpointURL(ProductionsPath.tasks.rawValue)
        try requireSafeFile(registryURL, root: root, label: "Task Registry")
        let registryData = try Data(contentsOf: registryURL)
        guard digest(registryData) == request.expectedRegistrySHA256 else {
            throw AcceptedHandoffValidationError.hashMismatch("Task Registry SHA-256 does not match the authorized preimage.")
        }
        let registry = try TaskRegistryDocument(data: registryData)
        let sourceRow = try registry.identityRow(taskID: request.sourceID)
        let dependentRow = try registry.uniqueRow(taskID: request.dependentID)
        let sourcePath = "Workspace/\(request.sourceID)/\(request.sourceID).md"
        let dependentPath = "Workspace/\(request.dependentID)/\(request.dependentID).md"
        guard MarkdownTable.resolvedPath(sourceRow["Workspace"] ?? "", relativeTo: "Office/Registry") == sourcePath,
              MarkdownTable.resolvedPath(dependentRow["Workspace"] ?? "", relativeTo: "Office/Registry") == dependentPath else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Source or dependent Workspace link is not the exact same-ID canonical record.")
        }
        let sourceURL = configuration.taskCheckpointURL(sourcePath)
        let dependentURL = configuration.taskCheckpointURL(dependentPath)
        try requireSafeFile(sourceURL, root: root, label: "Source Workspace")
        try requireSafeFile(dependentURL, root: root, label: "Dependent Workspace")
        let sourceData = try Data(contentsOf: sourceURL)
        let dependentData = try Data(contentsOf: dependentURL)
        guard digest(sourceData) == request.expectedWorkspaceSHA256 else {
            throw AcceptedHandoffValidationError.hashMismatch("Source Workspace SHA-256 does not match the authorized preimage.")
        }
        guard digest(dependentData) == request.expectedDependentWorkspaceSHA256 else {
            throw AcceptedHandoffValidationError.hashMismatch("Dependent Workspace SHA-256 does not match the authorized preimage.")
        }
        let source = try AcceptedHandoffTaskWorkspace(data: sourceData)
        let dependent = try AcceptedHandoffTaskWorkspace(data: dependentData)
        try source.validateIdentity(taskID: request.sourceID, row: sourceRow)
        try dependent.validateIdentity(taskID: request.dependentID, row: dependentRow)
        guard AcceptedHandoffTaskWorkspace.taskIDs(in: dependentRow["Depends on"] ?? "").filter({ $0 == request.sourceID }).count == 1,
              AcceptedHandoffTaskWorkspace.taskIDs(in: dependent.field("Depends on")).filter({ $0 == request.sourceID }).count == 1,
              AcceptedHandoffTaskWorkspace.taskIDs(in: source.field("Related records")).filter({ $0 == request.dependentID }).count == 1 else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Source and dependent do not have the exact reciprocal Related records / Depends on relationship.")
        }
        let evidence = try resolveEvidence(
            request.evidence, sourceCommit: request.sourceCommit,
            sourceWorkspacePath: sourcePath, configuration: configuration
        )
        let replacement = try source.replacement(marker: request.marker, acceptedAt: request.acceptedAt, evidence: request.evidence)
        let after = try AcceptedHandoffTaskWorkspace(data: replacement)
        try after.validateIdentity(taskID: request.sourceID, row: sourceRow)
        try source.validatePostimage(after, marker: request.marker, acceptedAt: request.acceptedAt, evidence: request.evidence, replacement: replacement)
        return AcceptedHandoffPreparedTarget(
            registryURL: registryURL, registryData: registryData,
            sourceRow: sourceRow, dependentRow: dependentRow,
            workspaceURL: sourceURL, workspaceData: sourceData, replacementData: replacement,
            dependentWorkspaceURL: dependentURL, dependentWorkspaceData: dependentData,
            evidence: evidence,
            targetFingerprint: targetFingerprint(
                sourceRow: sourceRow, dependentRow: dependentRow,
                evidencePath: evidence.relativePath, sourceCommit: request.sourceCommit
            )
        )
    }

    private func fullyValidatePostimage(journal: AcceptedHandoffJournal, configuration: ProductionsConfiguration) throws {
        let current = try currentBytes(journal: journal, configuration: configuration)
        guard current.registry == journal.registryPreimage,
              current.source == journal.workspaceExpectedAfter,
              current.dependent == journal.dependentWorkspacePreimage else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Registry, source postimage, or dependent guard bytes changed.")
        }
        let registry = try TaskRegistryDocument(data: current.registry)
        let sourceRow = try registry.identityRow(taskID: journal.sourceID)
        let dependentRow = try registry.uniqueRow(taskID: journal.dependentID)
        let before = try AcceptedHandoffTaskWorkspace(data: journal.workspacePreimage)
        let after = try AcceptedHandoffTaskWorkspace(data: current.source)
        let dependent = try AcceptedHandoffTaskWorkspace(data: current.dependent)
        try after.validateIdentity(taskID: journal.sourceID, row: sourceRow)
        try dependent.validateIdentity(taskID: journal.dependentID, row: dependentRow)
        guard AcceptedHandoffTaskWorkspace.taskIDs(in: dependentRow["Depends on"] ?? "").filter({ $0 == journal.sourceID }).count == 1,
              AcceptedHandoffTaskWorkspace.taskIDs(in: dependent.field("Depends on")).filter({ $0 == journal.sourceID }).count == 1,
              AcceptedHandoffTaskWorkspace.taskIDs(in: after.field("Related records")).filter({ $0 == journal.dependentID }).count == 1 else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Reciprocal source/dependent relationship changed.")
        }
        guard targetFingerprint(
            sourceRow: sourceRow, dependentRow: dependentRow,
            evidencePath: journal.evidencePath, sourceCommit: journal.sourceCommit
        ) == journal.targetFingerprint else {
            throw AcceptedHandoffValidationError.targetContractInvalid("The bound source/dependent identity or relationship changed.")
        }
        try before.validatePostimage(after, marker: journal.marker, acceptedAt: journal.acceptedAt, evidence: journal.evidence, replacement: current.source)
        let evidence = try resolveEvidence(journal.evidence, sourceCommit: journal.sourceCommit, sourceWorkspacePath: journal.workspacePath, configuration: configuration)
        guard TaskCheckpointUTF8.equal(evidence.relativePath, journal.evidencePath),
              TaskCheckpointUTF8.equal(evidence.fingerprint, journal.evidenceFingerprint) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Evidence identity changed after preparation.")
        }
    }

    private func validateSupersedingState(
        journal: AcceptedHandoffJournal,
        configuration: ProductionsConfiguration,
        current: (registry: Data, source: Data, dependent: Data)
    ) throws {
        let registry = try TaskRegistryDocument(data: current.registry)
        let sourceRow = try registry.identityRow(taskID: journal.sourceID)
        let dependentRow = try registry.identityRow(taskID: journal.dependentID)
        let source = try AcceptedHandoffTaskWorkspace(data: current.source)
        let dependent = try AcceptedHandoffTaskWorkspace(data: current.dependent)
        try source.validateIdentity(taskID: journal.sourceID, row: sourceRow)
        try dependent.validateIdentity(taskID: journal.dependentID, row: dependentRow)
        guard source.acceptedRows.contains(where: {
            TaskCheckpointUTF8.equal($0.marker, journal.marker) &&
            TaskCheckpointUTF8.equal($0.acceptedAt, journal.acceptedAt) &&
            TaskCheckpointUTF8.equal($0.evidence, journal.evidence)
        }) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("The immutable accepted-handoff row is absent or changed.")
        }
    }

    private func currentBytes(
        journal: AcceptedHandoffJournal,
        configuration: ProductionsConfiguration
    ) throws -> (registry: Data, source: Data, dependent: Data) {
        let root = configuration.taskCheckpointRootURL
        let registry = configuration.taskCheckpointURL(journal.registryPath)
        let source = configuration.taskCheckpointURL(journal.workspacePath)
        let dependent = configuration.taskCheckpointURL(journal.dependentWorkspacePath)
        try requireSafeFile(registry, root: root, label: "Task Registry")
        try requireSafeFile(source, root: root, label: "Source Workspace")
        try requireSafeFile(dependent, root: root, label: "Dependent Workspace")
        return (try Data(contentsOf: registry), try Data(contentsOf: source), try Data(contentsOf: dependent))
    }

    private func reconcileReplacementException(
        journal: inout AcceptedHandoffJournal,
        request: AcceptedHandoffRequest,
        configuration: ProductionsConfiguration,
        replacementDiagnostic: String
    ) throws -> AcceptedHandoffCommandResult {
        do {
            guard let durable = try journalStore.journal(operationID: journal.operationUUID) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("No recovery journal exists for the issued operation UUID.")
            }
            journal = durable
        } catch {
            throw failure(
                outcome: "uncertain", operationID: journal.operationUUID, request: request,
                before: journal.workspaceSHA256Before, dependent: journal.dependentWorkspaceSHA256,
                registry: journal.registrySHA256, classification: "possible-commit",
                diagnostic: "Replacement threw and the journal could not be read: \(error.localizedDescription). Do not retry automatically.",
                journalRootPath: journal.productionsRootPath, exitCode: 3
            )
        }
        let current: (registry: Data, source: Data, dependent: Data)
        do { current = try currentBytes(journal: journal, configuration: configuration) }
        catch {
            return try finishUncertain(journal: &journal, request: request, diagnostic: "Replacement threw and canonical bytes could not be read: \(error.localizedDescription). Do not retry automatically.")
        }
        if current.registry == journal.registryPreimage,
           current.source == journal.workspacePreimage,
           current.dependent == journal.dependentWorkspacePreimage {
            return try finishDefiniteNoCommit(
                journal: &journal, request: request,
                diagnostic: "Replacement threw before publication; exact preimages prove no commit. \(replacementDiagnostic) Do not retry automatically."
            )
        }
        if current.registry == journal.registryPreimage,
           current.source == journal.workspaceExpectedAfter,
           current.dependent == journal.dependentWorkspacePreimage {
            do {
                try fullyValidatePostimage(journal: journal, configuration: configuration)
                journal.transition(to: .reconciledCommittedAndCurrent, diagnostic: "Replacement threw after publication; exact postimage reconciles the commit. Do not retry automatically.", finalized: true)
                do {
                    try journalStore.update(journal)
                    return try committedWithDiscovery(journal: journal)
                } catch {
                    return try finishJournalFailure(
                        journal: &journal, request: request,
                        fallback: .journalFinalizationFailedCommittedAndCurrent,
                        classification: "committed-and-current",
                        diagnostic: "The reconciled commit is proven current, but journal finalization failed: \(error.localizedDescription)"
                    )
                }
            } catch let failure as AcceptedHandoffCommandFailure {
                throw failure
            } catch {
                return try finishUncertain(journal: &journal, request: request, diagnostic: "Replacement may have published expected bytes, but complete validation failed: \(error.localizedDescription). Do not retry automatically.")
            }
        }
        return try finishUncertain(journal: &journal, request: request, diagnostic: "Replacement threw and canonical state is partial, foreign, unreadable, or guard-divergent. Do not retry automatically.")
    }

    private func finishDefiniteNoCommit(
        journal: inout AcceptedHandoffJournal,
        request: AcceptedHandoffRequest,
        diagnostic: String
    ) throws -> AcceptedHandoffCommandResult {
        do {
            journal.transition(to: .definiteNoCommit, diagnostic: diagnostic, finalized: true)
            try journalStore.update(journal)
            return result(outcome: "not-committed", journal: journal, classification: "definite-no-commit", discoveryOutcome: nil, hooks: nil, diagnostic: diagnostic)
        } catch {
            return try finishJournalFailure(
                journal: &journal, request: request,
                fallback: .journalFinalizationFailedDefiniteNoCommit,
                classification: "definite-no-commit",
                diagnostic: "No commit is proven, but normal terminal journal finalization failed: \(error.localizedDescription)"
            )
        }
    }

    private func committedWithDiscovery(journal: AcceptedHandoffJournal) throws -> AcceptedHandoffCommandResult {
        do {
            let hooks = try discover(
                journal.sourceID, journal.marker,
                ProductionsConfiguration(schemaVersion: ProductionsConfiguration.schemaVersion, productionsRootPath: journal.productionsRootPath)
            ).sorted()
            return result(
                outcome: "committed", journal: journal, classification: "committed-and-current",
                discoveryOutcome: "complete", hooks: hooks, diagnostic: journal.diagnostic
            )
        } catch {
            return discoveryFailure(journal: journal, error: error)
        }
    }

    private func discoveryFailure(journal: AcceptedHandoffJournal, error: Error) -> AcceptedHandoffCommandResult {
        result(
            outcome: "committed-with-discovery-failure", journal: journal,
            classification: "committed-and-current", discoveryOutcome: "failed", hooks: nil,
            diagnostic: "Accepted-handoff Workspace commit is proven, but reverse discovery failed: \(error.localizedDescription). Correct the discovery inputs before a separately authorized read-only eligibility refresh. Do not retry automatically."
        )
    }

    private func finishUncertain(
        journal: inout AcceptedHandoffJournal,
        request: AcceptedHandoffRequest,
        diagnostic: String
    ) throws -> AcceptedHandoffCommandResult {
        do {
            journal.transition(to: .uncertain, diagnostic: diagnostic, finalized: true)
            try journalStore.update(journal)
            return result(outcome: "uncertain", journal: journal, classification: "uncertain", discoveryOutcome: nil, hooks: nil, diagnostic: diagnostic)
        } catch {
            throw failure(
                outcome: "uncertain", operationID: journal.operationUUID, request: request,
                before: journal.workspaceSHA256Before, dependent: journal.dependentWorkspaceSHA256,
                registry: journal.registrySHA256, classification: "uncertain",
                diagnostic: "Canonical outcome and terminal journal state are uncertain: \(error.localizedDescription). Do not retry automatically.",
                journalRootPath: journal.productionsRootPath, exitCode: 3
            )
        }
    }

    private func finishProvenFailure(
        journal: inout AcceptedHandoffJournal,
        request: AcceptedHandoffRequest,
        state: OfficeWorkspaceTerminalState,
        classification: String,
        diagnostic: String
    ) throws -> AcceptedHandoffCommandResult {
        do {
            journal.transition(to: state, diagnostic: diagnostic, finalized: true)
            try journalStore.update(journal)
            return result(outcome: "uncertain", journal: journal, classification: classification, discoveryOutcome: nil, hooks: nil, diagnostic: diagnostic + " Do not retry automatically.")
        } catch {
            let fallback: OfficeWorkspaceTerminalState = switch classification {
            case "committed-and-current": .journalFinalizationFailedCommittedAndCurrent
            case "historically-committed-and-superseded": .journalFinalizationFailedHistoricallyCommittedAndSuperseded
            default: .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain
            }
            return try finishJournalFailure(journal: &journal, request: request, fallback: fallback, classification: classification, diagnostic: diagnostic + " Normal terminal journal finalization also failed: \(error.localizedDescription)")
        }
    }

    private func finishJournalFailure(
        journal: inout AcceptedHandoffJournal,
        request: AcceptedHandoffRequest,
        fallback: OfficeWorkspaceTerminalState,
        classification: String,
        diagnostic: String
    ) throws -> AcceptedHandoffCommandResult {
        var fallbackJournal = journal
        fallbackJournal.markFallback(fallback, diagnostic: diagnostic + " Do not retry automatically.")
        let recorded: Bool
        do {
            try journalStore.recordFallback(fallbackJournal)
            journal = fallbackJournal
            recorded = true
        } catch { recorded = false }
        let proving = fallback.provesHistoricalCommit || journal.terminalState?.provesHistoricalCommit == true
        throw failure(
            outcome: proving ? "uncertain" : "not-committed",
            operationID: journal.operationUUID, request: request,
            before: journal.workspaceSHA256Before,
            after: proving ? journal.workspaceSHA256ExpectedAfter : nil,
            dependent: journal.dependentWorkspaceSHA256, registry: journal.registrySHA256,
            classification: classification, journalFinalized: false,
            fallbackRecorded: recorded, historicalCommitProven: proving,
            diagnostic: diagnostic + " Do not retry automatically.",
            journalRootPath: journal.productionsRootPath, exitCode: proving ? 3 : 2
        )
    }

    private func result(
        outcome: String,
        journal: AcceptedHandoffJournal,
        classification: String,
        discoveryOutcome: String?,
        hooks: [AcceptedHandoffEligibleHook]?,
        diagnostic: String?
    ) -> AcceptedHandoffCommandResult {
        AcceptedHandoffCommandResult(
            outcome: outcome, operationUUID: journal.operationUUID,
            sourceID: journal.sourceID, dependentID: journal.dependentID,
            sourceCommit: journal.sourceCommit, marker: journal.marker,
            workspaceSHA256Before: journal.workspaceSHA256Before,
            workspaceSHA256After: outcome == "committed" || outcome == "committed-with-discovery-failure" || journal.terminalState?.provesHistoricalCommit == true ? journal.workspaceSHA256ExpectedAfter : nil,
            dependentWorkspaceSHA256: journal.dependentWorkspaceSHA256,
            registrySHA256: journal.registrySHA256, classification: classification,
            journalFinalized: journal.journalFinalized, fallbackRecorded: journal.fallbackRecorded,
            historicalCommitProven: journal.terminalState?.provesHistoricalCommit == true,
            discoveryOutcome: discoveryOutcome, newlyEligibleHooks: hooks,
            inspectCommand: "OperationsDashboard office inspect --productions-root \(journal.productionsRootPath) --operation \(journal.operationUUID.uuidString)",
            diagnostic: diagnostic
        )
    }

    private func inspectionUncertain(journal: AcceptedHandoffJournal, historicalProof: Bool, diagnostic: String) -> AcceptedHandoffCommandResult {
        AcceptedHandoffCommandResult(
            outcome: "uncertain", operationUUID: journal.operationUUID,
            sourceID: journal.sourceID, dependentID: journal.dependentID,
            sourceCommit: journal.sourceCommit, marker: journal.marker,
            workspaceSHA256Before: journal.workspaceSHA256Before,
            workspaceSHA256After: historicalProof ? journal.workspaceSHA256ExpectedAfter : nil,
            dependentWorkspaceSHA256: journal.dependentWorkspaceSHA256,
            registrySHA256: journal.registrySHA256,
            classification: historicalProof ? "historically-committed-current-state-uncertain" : "uncertain",
            journalFinalized: journal.journalFinalized, fallbackRecorded: journal.fallbackRecorded,
            historicalCommitProven: historicalProof, discoveryOutcome: nil, newlyEligibleHooks: nil,
            inspectCommand: "OperationsDashboard office inspect --productions-root \(journal.productionsRootPath) --operation \(journal.operationUUID.uuidString)",
            diagnostic: diagnostic + " Do not retry automatically."
        )
    }

    private func failure(
        outcome: String,
        operationID: UUID?,
        request: AcceptedHandoffRequest?,
        before: String? = nil,
        after: String? = nil,
        dependent: String? = nil,
        registry: String? = nil,
        classification: String,
        journalFinalized: Bool = false,
        fallbackRecorded: Bool = false,
        historicalCommitProven: Bool = false,
        diagnostic: String,
        journalRootPath: String? = nil,
        exitCode: Int32
    ) -> AcceptedHandoffCommandFailure {
        AcceptedHandoffCommandFailure(
            result: AcceptedHandoffCommandResult(
                outcome: outcome, operationUUID: operationID,
                sourceID: request?.sourceID, dependentID: request?.dependentID,
                sourceCommit: request?.sourceCommit, marker: request?.marker,
                workspaceSHA256Before: before, workspaceSHA256After: after,
                dependentWorkspaceSHA256: dependent, registrySHA256: registry,
                classification: classification, journalFinalized: journalFinalized,
                fallbackRecorded: fallbackRecorded, historicalCommitProven: historicalCommitProven,
                discoveryOutcome: nil, newlyEligibleHooks: nil,
                inspectCommand: operationID.flatMap { operation in
                    journalRootPath.map { "OperationsDashboard office inspect --productions-root \($0) --operation \(operation.uuidString)" }
                },
                diagnostic: diagnostic
            ),
            exitCode: exitCode
        )
    }

    private func classification(for error: Error) -> String {
        switch error {
        case AcceptedHandoffValidationError.hashMismatch: "hashMismatch"
        case AcceptedHandoffValidationError.invalidInput: "invalidInput"
        case AcceptedHandoffValidationError.targetContractInvalid: "targetContractInvalid"
        default: "not-committed"
        }
    }

    private func validateRequest(_ request: AcceptedHandoffRequest) throws {
        let hashPattern = #"^[0-9a-f]{64}$"#
        guard request.sourceID.range(of: #"^TASK-[0-9]{4,}$"#, options: .regularExpression) != nil,
              request.dependentID.range(of: #"^TASK-[0-9]{4,}$"#, options: .regularExpression) != nil,
              request.sourceID != request.dependentID else {
            throw AcceptedHandoffValidationError.invalidInput("Source and dependent must be distinct exact Task IDs.")
        }
        guard request.sourceCommit.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil else {
            throw AcceptedHandoffValidationError.invalidInput("Source commit must be one lowercase 40-hex Git commit.")
        }
        guard request.marker.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil else {
            throw AcceptedHandoffValidationError.invalidInput("Marker does not match the adopted lowercase source-scoped grammar.")
        }
        guard Self.exactTimestamp(request.acceptedAt) != nil else {
            throw AcceptedHandoffValidationError.invalidInput("Accepted at must be ISO-8601 with explicit offset and second precision.")
        }
        guard !request.evidence.isEmpty, !request.evidence.contains("\n"), !request.evidence.contains("\r"), !request.evidence.contains("|") else {
            throw AcceptedHandoffValidationError.invalidInput("Evidence must be one nonblank table-safe canonical reference.")
        }
        guard [request.expectedWorkspaceSHA256, request.expectedDependentWorkspaceSHA256, request.expectedRegistrySHA256].allSatisfy({
            $0.range(of: hashPattern, options: .regularExpression) != nil
        }) else {
            throw AcceptedHandoffValidationError.invalidInput("Expected hashes must be lowercase 64-hex SHA-256 values.")
        }
    }

    private func request(from journal: AcceptedHandoffJournal) -> AcceptedHandoffRequest {
        AcceptedHandoffRequest(
            sourceID: journal.sourceID, dependentID: journal.dependentID,
            sourceCommit: journal.sourceCommit, marker: journal.marker,
            acceptedAt: journal.acceptedAt, evidence: journal.evidence,
            expectedWorkspaceSHA256: journal.workspaceSHA256Before,
            expectedDependentWorkspaceSHA256: journal.dependentWorkspaceSHA256,
            expectedRegistrySHA256: journal.registrySHA256
        )
    }

    private func resolveEvidence(
        _ reference: String,
        sourceCommit: String,
        sourceWorkspacePath: String,
        configuration: ProductionsConfiguration
    ) throws -> AcceptedHandoffEvidence {
        var destination = reference
        if destination.hasPrefix("`"), destination.hasSuffix("`"), destination.count > 2 {
            destination = String(destination.dropFirst().dropLast())
        } else if destination.hasPrefix("[") {
            let regex = try! NSRegularExpression(pattern: #"^\[[^\]\n]+\]\(([^)\n]+)\)$"#)
            let ns = destination as NSString
            guard let match = regex.firstMatch(in: destination, range: NSRange(location: 0, length: ns.length)) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Evidence Markdown link is malformed.")
            }
            destination = ns.substring(with: match.range(at: 1))
        }
        let pieces = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let relativePath = String(pieces[0])
        let anchor = pieces.count == 2 ? String(pieces[1]) : nil
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasSuffix("/"),
              !relativePath.contains("//"),
              relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
              }),
              relativePath != sourceWorkspacePath else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Evidence must be a contained, nonhidden, noncircular relative file path.")
        }
        let root = configuration.taskCheckpointRootURL
        var cursor = root
        for component in relativePath.split(separator: "/") {
            cursor.append(path: String(component))
            var status = stat()
            guard lstat(cursor.path, &status) == 0, status.st_mode & S_IFMT != S_IFLNK else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Evidence path is missing or contains a symbolic link.")
            }
        }
        var status = stat()
        guard lstat(cursor.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              manager.isReadableFile(atPath: cursor.path) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Evidence is not a readable non-followed regular file.")
        }
        let data = try Data(contentsOf: cursor)
        guard data.range(of: Data(sourceCommit.utf8)) != nil else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Evidence does not contain the exact authorized source commit.")
        }
        if let anchor {
            guard !anchor.isEmpty, let text = String(data: data, encoding: .utf8),
                  AcceptedHandoffMarkdown.anchors(in: text).contains(anchor) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Evidence Markdown anchor does not resolve exactly.")
            }
        }
        return AcceptedHandoffEvidence(reference: reference, relativePath: relativePath, fingerprint: digest(data))
    }

    private func requireSafeFile(_ target: URL, root: URL, label: String) throws {
        let rootPath = root.path
        let prefix = rootPath + "/"
        guard TaskCheckpointUTF8.hasPrefix(target.path, prefix), !TaskCheckpointUTF8.equal(target.path, rootPath) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("\(label) escapes the configured Productions root.")
        }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in target.path.split(separator: "/") {
            cursor.append(path: String(component))
            var status = stat()
            guard lstat(cursor.path, &status) == 0, status.st_mode & S_IFMT != S_IFLNK else {
                throw AcceptedHandoffValidationError.targetContractInvalid("\(label) path is missing or contains a symbolic link.")
            }
        }
        var status = stat()
        guard lstat(target.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              manager.isReadableFile(atPath: target.path) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("\(label) is not a readable regular file.")
        }
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func targetFingerprint(
        sourceRow: [String: String],
        dependentRow: [String: String],
        evidencePath: String,
        sourceCommit: String
    ) -> String {
        let input = TaskRegistryDocument.headers.map { sourceRow[$0] ?? "" }.joined(separator: "\u{1f}")
            + "\u{1e}" + TaskRegistryDocument.headers.map { dependentRow[$0] ?? "" }.joined(separator: "\u{1f}")
            + "\u{1e}" + evidencePath + "\u{1e}" + sourceCommit
        return digest(Data(input.utf8))
    }
}

enum AcceptedHandoffDiscovery {
    private struct CandidateKind {
        let registryPath: String
        let headers: [String]
        let idField: String
        let lifecycleField: String
        let recordSection: String
        let workspaceIDField: String
        let workspaceType: String?
        let statusSource: String?
        let eligibleLifecycles: Set<String>
        let terminalLifecycles: Set<String>
    }

    private struct DiscoveryWorkspace {
        let topLevelTitle: String
        let fields: [String: String]

        init(text: String, recordSection: String) throws {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var insideFence = false
            var h1s: [String] = []
            var headings: [(String, Int)] = []
            for (index, line) in lines.enumerated() {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    insideFence.toggle()
                    continue
                }
                guard !insideFence else { continue }
                if line.hasPrefix("# "), !line.hasPrefix("## ") {
                    h1s.append(String(line.dropFirst(2)))
                } else if line.hasPrefix("## "), !line.hasPrefix("### ") {
                    headings.append((String(line.dropFirst(3)), index))
                }
            }
            guard h1s.count == 1, let h1 = h1s.first, !h1.isEmpty else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Workspace must contain exactly one non-fenced H1 title.")
            }
            topLevelTitle = h1
            let grouped = Dictionary(grouping: headings, by: { $0.0 })
            guard grouped.values.allSatisfy({ $0.count == 1 }),
                  let recordHeading = grouped[recordSection]?.first else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Workspace requires one exact \(recordSection) section and no duplicate sections.")
            }
            let nextHeading = headings.first(where: { $0.1 > recordHeading.1 })?.1 ?? lines.count
            let range = (recordHeading.1 + 1)..<nextHeading
            let fieldPattern = try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9, /()_-]*):"#)
            var starts: [(String, Int)] = []
            for index in range {
                let line = lines[index], ns = line as NSString
                if let match = fieldPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                    starts.append((ns.substring(with: match.range(at: 1)), index))
                }
            }
            guard Dictionary(grouping: starts, by: { $0.0 }).values.allSatisfy({ $0.count == 1 }) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Workspace contains a duplicate record field.")
            }
            var parsed: [String: String] = [:]
            for (offset, field) in starts.enumerated() {
                let fieldRange = field.1..<(offset + 1 < starts.count ? starts[offset + 1].1 : range.upperBound)
                let prefix = "\(field.0):"
                let firstRaw = String(lines[field.1].dropFirst(prefix.count))
                guard firstRaw.hasPrefix(" ") else {
                    throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Workspace record fields require one Markdown separator space.")
                }
                var values = [String(firstRaw.dropFirst())]
                for line in lines[fieldRange.dropFirst()] {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty, trimmed != "```" { values.append(line) }
                }
                parsed[field.0] = values.joined(separator: "\n")
            }
            fields = parsed
        }

        func field(_ name: String) -> String { fields[name] ?? "" }
    }

    private struct ReviewNode: Hashable {
        let candidateID: String
        let hook: String
    }

    private struct ReviewRow: Equatable {
        let hook: String
        let question: String
        let disposition: String
        let decidedAt: String
        let reconsiderAfter: String
        let replacement: String
    }

    private struct CandidateReview {
        let candidateID: String
        let lifecycleEligible: Bool
        let hooks: [String]
        let rows: [ReviewRow]
    }

    static func newlyEligible(
        sourceID: String,
        marker: String,
        configuration: ProductionsConfiguration
    ) throws -> [AcceptedHandoffEligibleHook] {
        let trigger = "\(sourceID)@accepted-handoff:\(marker)"
        guard try factSatisfied(trigger, configuration: configuration) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("The accepted-handoff source fact is not present in its exact canonical Workspace.")
        }
        var candidates: [String: CandidateReview] = [:]
        for kind in kinds {
            let registryText = try readSafeText(path: kind.registryPath, configuration: configuration)
            let rows = try MarkdownTable.parse(registryText, required: kind.headers)
            let IDs = rows.map { $0[kind.idField] ?? "" }
            guard Set(IDs).count == IDs.count else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Registry contains a duplicate durable identifier.")
            }
            for row in rows {
                let hooks = try parsedHooks(row["Review after"] ?? "—")
                let candidateID = row[kind.idField] ?? ""
                let lifecycle = row[kind.lifecycleField] ?? ""
                guard kind.eligibleLifecycles.contains(lifecycle) || kind.terminalLifecycles.contains(lifecycle) else {
                    throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility candidate has an unknown lifecycle or disposition.")
                }
                let expectedPath = "Workspace/\(candidateID)/\(candidateID).md"
                guard MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry") == expectedPath else {
                    throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility candidate Workspace link is not the exact same-ID record.")
                }
                let workspace = try readSafeText(path: expectedPath, configuration: configuration)
                let reviewRows = try reviewRows(in: workspace, required: !hooks.isEmpty)
                guard reviewRows.count == hooks.count, Set(reviewRows.map(\.hook)) == Set(hooks) else {
                    throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews and Registry Review after hooks disagree for \(candidateID).")
                }
                guard !hooks.isEmpty else { continue }
                try validateWorkspaceIdentity(text: workspace, candidateID: candidateID, row: row, kind: kind)
                guard candidates[candidateID] == nil else {
                    throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility candidate identifier is ambiguous across durable Registries.")
                }
                candidates[candidateID] = CandidateReview(
                    candidateID: candidateID,
                    lifecycleEligible: kind.eligibleLifecycles.contains(lifecycle),
                    hooks: hooks, rows: reviewRows
                )
            }
        }

        var deferSatisfied: [ReviewNode: Bool] = [:]
        var replacements: [ReviewNode: ReviewNode] = [:]
        for candidate in candidates.values {
            for row in candidate.rows {
                let node = ReviewNode(candidateID: candidate.candidateID, hook: row.hook)
                try validateReviewRow(row, node: node)
                switch row.disposition {
                case "Pending", "Proceed", "Decline": break
                case "Defer":
                    deferSatisfied[node] = try factSatisfied(row.reconsiderAfter, configuration: configuration)
                case "Replace":
                    replacements[node] = try replacementNode(row.replacement, source: node)
                default:
                    throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews contains an unknown disposition.")
                }
            }
        }
        let allNodes = Set(candidates.values.flatMap { candidate in
            candidate.rows.map { ReviewNode(candidateID: candidate.candidateID, hook: $0.hook) }
        })
        for (source, target) in replacements {
            guard allNodes.contains(target) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews Replace target is unresolved.")
            }
            guard source.candidateID != target.candidateID, source != target else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews rejects candidate or hook self-replacement.")
            }
        }
        try validateAcyclic(replacements)

        var result: [AcceptedHandoffEligibleHook] = []
        for candidate in candidates.values where candidate.lifecycleEligible && candidate.hooks.contains(trigger) {
            guard let target = candidate.rows.first(where: { $0.hook == trigger }) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews target hook is unavailable after exact-set validation.")
            }
            let node = ReviewNode(candidateID: candidate.candidateID, hook: trigger)
            let visible = target.disposition == "Pending" || (target.disposition == "Defer" && deferSatisfied[node] == true)
            if visible { result.append(.init(candidateID: candidate.candidateID, hook: trigger)) }
        }
        return result.sorted()
    }

    private static let kinds: [CandidateKind] = [
        .init(
            registryPath: "Office/Registry/Tasks.md", headers: TaskRegistryDocument.headers,
            idField: "Task ID", lifecycleField: "State",
            recordSection: "Core Record", workspaceIDField: "ID", workspaceType: "Task",
            statusSource: "Office/Registry/Tasks.md",
            eligibleLifecycles: ["Active / Current", "Active / Paused", "Active / Blocked", "Pending / Review", "Pending / Deferred"],
            terminalLifecycles: ["Done / Complete", "Done / Obsolete"]
        ),
        .init(
            registryPath: "Office/Registry/Ideas.md",
            headers: ["Idea ID", "Title", "Disposition", "Priority", "Current lead", "Related records", "Review after", "Source artifacts", "Short description", "Workspace"],
            idField: "Idea ID", lifecycleField: "Disposition",
            recordSection: "Idea Record", workspaceIDField: "Idea ID", workspaceType: nil, statusSource: nil,
            eligibleLifecycles: ["Open"],
            terminalLifecycles: ["Promoted", "Archived", "Discarded"]
        ),
        .init(
            registryPath: "Office/Registry/Projects.md",
            headers: ["Project ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"],
            idField: "Project ID", lifecycleField: "State",
            recordSection: "Core Record", workspaceIDField: "Project ID", workspaceType: nil,
            statusSource: "Productions/Office/Registry/Projects.md",
            eligibleLifecycles: ["Active / Current", "Active / Paused", "Active / Blocked", "Pending / Review", "Pending / Deferred"],
            terminalLifecycles: ["Done / Complete", "Done / Obsolete"]
        ),
        .init(
            registryPath: "Office/Registry/Initiatives.md",
            headers: ["Initiative ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"],
            idField: "Initiative ID", lifecycleField: "State",
            recordSection: "Core Record", workspaceIDField: "Initiative ID", workspaceType: nil,
            statusSource: "Productions/Office/Registry/Initiatives.md",
            eligibleLifecycles: ["Active / Current", "Active / Paused", "Active / Blocked", "Pending / Review", "Pending / Deferred"],
            terminalLifecycles: ["Done / Complete", "Done / Obsolete"]
        ),
    ]

    private static func validateWorkspaceIdentity(
        text: String,
        candidateID: String,
        row: [String: String],
        kind: CandidateKind
    ) throws {
        let workspace = try DiscoveryWorkspace(text: text, recordSection: kind.recordSection)
        guard TaskCheckpointUTF8.equal(workspace.topLevelTitle, row["Title"] ?? ""),
              TaskCheckpointUTF8.equal(workspace.field(kind.workspaceIDField), candidateID) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Workspace H1, title, or durable identifier disagrees with its Registry row.")
        }
        if kind.idField == "Idea ID" {
            guard TaskCheckpointUTF8.equal(workspace.field("Disposition"), row["Disposition"] ?? ""),
                  TaskCheckpointUTF8.equal(workspace.field("Priority"), row["Priority"] ?? ""),
                  TaskCheckpointUTF8.equal(workspace.field("Current lead"), row["Current lead"] ?? ""),
                  TaskCheckpointUTF8.equal(workspace.field("Workspace"), "`Workspace/\(candidateID)/`") else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Idea Workspace identity or authoritative Registry fields disagree.")
            }
        } else {
            guard TaskCheckpointUTF8.equal(workspace.field("Title"), row["Title"] ?? ""),
                  TaskCheckpointUTF8.equal(workspace.field("Current lead"), row["Current lead"] ?? ""),
                  workspace.field("Priority").isEmpty || TaskCheckpointUTF8.equal(workspace.field("Priority"), row["Priority"] ?? "") else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Workspace Core identity, title, lead, or priority disagrees with its Registry row.")
            }
            if let expectedType = kind.workspaceType, !TaskCheckpointUTF8.equal(workspace.field("Type"), expectedType) {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Workspace record type disagrees with its Registry kind.")
            }
            if let statusSource = kind.statusSource, !TaskCheckpointUTF8.equal(workspace.field("Status source"), statusSource) {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Workspace status source disagrees with its Registry kind.")
            }
        }
        if kind.idField == "Task ID" {
            for relationship in ["Initiative", "Project"] where
                normalizedDurableIDs(workspace.field(relationship)) != normalizedDurableIDs(row[relationship] ?? "") {
                throw AcceptedHandoffValidationError.targetContractInvalid("Task Workspace \(relationship) disagrees with its Registry row.")
            }
        }
        for (workspaceField, registryField) in [("Depends on", "Depends on"), ("Related records", "Related records")] where row[registryField] != nil {
            guard normalizedDurableIDs(workspace.field(workspaceField)) == normalizedDurableIDs(row[registryField] ?? "") else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Workspace \(workspaceField) disagrees with its Registry row.")
            }
        }
    }

    private static func normalizedDurableIDs(_ value: String) -> Set<String> {
        let regex = try! NSRegularExpression(pattern: #"\b(?:TASK|IDEA|PROJ|INIT)-[0-9]{4,}\b"#)
        let ns = value as NSString
        return Set(regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range)
        })
    }

    private static func parsedHooks(_ value: String) throws -> [String] {
        if value == "—" { return [] }
        let hooks = value.split(separator: ";").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !hooks.isEmpty, Set(hooks).count == hooks.count,
              hooks.allSatisfy({ hook in
                  hook.range(of: #"^(TASK|IDEA|PROJ|INIT)-[0-9]{4,}@(done-complete|accepted-handoff:[a-z0-9][a-z0-9-]{0,63})$"#, options: .regularExpression) != nil
              }) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Review after contains malformed or duplicate hooks.")
        }
        return hooks
    }

    private static func reviewRows(in workspace: String, required: Bool) throws -> [ReviewRow] {
        let lines = workspace.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var insideFence = false
        var headings: [Int] = []
        var levelTwoHeadings: [Int] = []
        for index in lines.indices {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { insideFence.toggle(); continue }
            guard !insideFence else { continue }
            if line.hasPrefix("## "), !line.hasPrefix("### ") {
                levelTwoHeadings.append(index)
                if line == "## Eligibility Reviews" { headings.append(index) }
            }
        }
        guard headings.count <= 1 else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Candidate has duplicate Eligibility Reviews sections.")
        }
        guard let heading = headings.first else {
            if required {
                throw AcceptedHandoffValidationError.targetContractInvalid("Candidate requires one Eligibility Reviews section.")
            }
            return []
        }
        let sectionEnd = levelTwoHeadings.first(where: { $0 > heading }) ?? lines.count
        let header = "| Hook | Review question | Disposition | Decided at | Reconsider after | Replacement |"
        let delimiter = "| --- | --- | --- | --- | --- | --- |"
        guard heading + 3 < sectionEnd, lines[heading + 1].isEmpty,
              lines[heading + 2] == header, lines[heading + 3] == delimiter else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews header or delimiter is malformed.")
        }
        var index = heading + 4
        var rows: [ReviewRow] = []
        while index < sectionEnd, lines[index].hasPrefix("|") {
            let cells = MarkdownTable.cells(lines[index])
            guard cells.count == 6, !cells[0].isEmpty, !cells[1].isEmpty,
                  TaskCheckpointUTF8.equal(lines[index], "| \(cells.joined(separator: " | ")) |") else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews contains a malformed row.")
            }
            rows.append(.init(
                hook: cells[0], question: cells[1], disposition: cells[2],
                decidedAt: cells[3], reconsiderAfter: cells[4], replacement: cells[5]
            ))
            index += 1
        }
        guard Set(rows.map(\.hook)).count == rows.count, !required || !rows.isEmpty else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews hooks must be unique and required tables must be nonempty.")
        }
        for later in lines[index..<sectionEnd] where later.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews contains a fragmented or later table-like row.")
        }
        return rows
    }

    private static func validateReviewRow(_ row: ReviewRow, node: ReviewNode) throws {
        let empty = "—"
        guard try parsedHooks(row.hook) == [row.hook], !row.question.isEmpty, row.question != empty else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews contains a malformed Hook or Review question.")
        }
        let hasDecisionTime = AcceptedHandoffService.exactTimestamp(row.decidedAt) != nil
        switch row.disposition {
        case "Pending":
            guard row.decidedAt == empty, row.reconsiderAfter == empty, row.replacement == empty else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Pending requires em dashes in every control field.")
            }
        case "Proceed", "Decline":
            guard hasDecisionTime, row.reconsiderAfter == empty, row.replacement == empty else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Proceed and Decline require an exact decision time and em-dash controls.")
            }
        case "Defer":
            guard hasDecisionTime, row.replacement == empty,
                  try parsedHooks(row.reconsiderAfter) == [row.reconsiderAfter],
                  !TaskCheckpointUTF8.equal(row.reconsiderAfter, node.hook) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Defer requires a decision time, one different reconsider hook, and em-dash replacement.")
            }
        case "Replace":
            guard hasDecisionTime, row.reconsiderAfter == empty, row.replacement != empty else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Replace requires a decision time, em-dash reconsider field, and exact replacement.")
            }
        default:
            throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews contains an unknown disposition.")
        }
    }

    private static func replacementNode(_ value: String, source: ReviewNode) throws -> ReviewNode {
        guard let separator = value.firstIndex(of: "@") else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews Replacement is malformed.")
        }
        let candidateID = String(value[..<separator])
        let hook = String(value[value.index(after: separator)...])
        guard candidateID.range(of: #"^(TASK|IDEA|PROJ|INIT)-[0-9]{4,}$"#, options: .regularExpression) != nil,
              try parsedHooks(hook) == [hook],
              TaskCheckpointUTF8.equal(value, "\(candidateID)@\(hook)") else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews Replacement must be exact candidate-ID@hook.")
        }
        let target = ReviewNode(candidateID: candidateID, hook: hook)
        guard source.candidateID != target.candidateID, source != target else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews rejects candidate or hook self-replacement.")
        }
        return target
    }

    private static func validateAcyclic(_ edges: [ReviewNode: ReviewNode]) throws {
        enum Visit { case visiting, visited }
        var visits: [ReviewNode: Visit] = [:]
        func visit(_ node: ReviewNode) throws {
            if visits[node] == .visiting {
                throw AcceptedHandoffValidationError.targetContractInvalid("Eligibility Reviews Replacement graph contains a cycle.")
            }
            if visits[node] == .visited { return }
            visits[node] = .visiting
            if let next = edges[node] { try visit(next) }
            visits[node] = .visited
        }
        for node in edges.keys { try visit(node) }
    }

    private static func factSatisfied(_ hook: String, configuration: ProductionsConfiguration) throws -> Bool {
        guard let separator = hook.firstIndex(of: "@") else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Reconsider after hook is malformed.")
        }
        let sourceID = String(hook[..<separator])
        let condition = String(hook[hook.index(after: separator)...])
        let matches = try sourceRows(sourceID: sourceID, configuration: configuration)
        guard matches.count == 1, let source = matches.first else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Reconsider after source is unresolved or ambiguous.")
        }
        if condition == "done-complete" {
            guard source.kind != "Idea" else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Idea cannot satisfy done-complete.")
            }
            return source.lifecycle == "Done / Complete"
        }
        let prefix = "accepted-handoff:"
        guard condition.hasPrefix(prefix) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Reconsider after condition is unsupported.")
        }
        let marker = String(condition.dropFirst(prefix.count))
        let sourceWorkspacePath = "Workspace/\(sourceID)/\(sourceID).md"
        let workspace = try readSafeText(path: sourceWorkspacePath, configuration: configuration)
        return try acceptedMarkers(
            in: workspace,
            sourceWorkspacePath: sourceWorkspacePath,
            configuration: configuration
        ).contains(marker)
    }

    private static func sourceRows(
        sourceID: String,
        configuration: ProductionsConfiguration
    ) throws -> [(kind: String, lifecycle: String)] {
        var values: [(String, String)] = []
        for kind in kinds {
            let registry = try readSafeText(path: kind.registryPath, configuration: configuration)
            for row in try MarkdownTable.parse(registry, required: kind.headers) where row[kind.idField] == sourceID {
                let expectedPath = "Workspace/\(sourceID)/\(sourceID).md"
                guard MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry") == expectedPath else {
                    throw AcceptedHandoffValidationError.targetContractInvalid("Reconsider-after source Workspace link is not the exact same-ID record.")
                }
                let workspace = try readSafeText(path: expectedPath, configuration: configuration)
                try validateWorkspaceIdentity(text: workspace, candidateID: sourceID, row: row, kind: kind)
                values.append((kind.idField == "Idea ID" ? "Idea" : "Durable", row[kind.lifecycleField] ?? ""))
            }
        }
        return values
    }

    private static func acceptedMarkers(
        in workspace: String,
        sourceWorkspacePath: String,
        configuration: ProductionsConfiguration
    ) throws -> Set<String> {
        let lines = workspace.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var insideFence = false
        var headings: [Int] = []
        var levelTwoHeadings: [Int] = []
        for index in lines.indices {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { insideFence.toggle(); continue }
            guard !insideFence else { continue }
            if line.hasPrefix("## "), !line.hasPrefix("### ") {
                levelTwoHeadings.append(index)
                if line == "## Accepted Handoffs" { headings.append(index) }
            }
        }
        guard headings.count <= 1 else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Source has duplicate Accepted Handoffs sections.")
        }
        guard let heading = headings.first else { return [] }
        let sectionEnd = levelTwoHeadings.first(where: { $0 > heading }) ?? lines.count
        guard heading + 3 < sectionEnd, lines[heading + 1].isEmpty,
              lines[heading + 2] == "| Marker | Accepted at | Evidence |",
              lines[heading + 3] == "| --- | --- | --- |" else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Source Accepted Handoffs table is malformed.")
        }
        var markers = Set<String>(), index = heading + 4
        while index < sectionEnd, lines[index].hasPrefix("|") {
            let cells = MarkdownTable.cells(lines[index])
            guard cells.count == 3,
                  cells[0].range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil,
                  AcceptedHandoffService.exactTimestamp(cells[1]) != nil,
                  !cells[2].isEmpty,
                  TaskCheckpointUTF8.equal(lines[index], "| \(cells[0]) | \(cells[1]) | \(cells[2]) |"),
                  markers.insert(cells[0]).inserted else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Source Accepted Handoffs row is malformed or duplicate.")
            }
            try validateEvidenceReference(
                cells[2], sourceWorkspacePath: sourceWorkspacePath, configuration: configuration
            )
            index += 1
        }
        for later in lines[index..<sectionEnd] where later.trimmingCharacters(in: .whitespaces).hasPrefix("|") {
            throw AcceptedHandoffValidationError.targetContractInvalid("Source Accepted Handoffs contains a fragmented or later table-like row.")
        }
        return markers
    }

    private static func validateEvidenceReference(
        _ reference: String,
        sourceWorkspacePath: String,
        configuration: ProductionsConfiguration
    ) throws {
        var destination = reference
        if destination.hasPrefix("`"), destination.hasSuffix("`"), destination.count > 2 {
            destination = String(destination.dropFirst().dropLast())
        } else if destination.hasPrefix("[") {
            let regex = try! NSRegularExpression(pattern: #"^\[[^\]\n]+\]\(([^)\n]+)\)$"#)
            let ns = destination as NSString
            guard let match = regex.firstMatch(in: destination, range: NSRange(location: 0, length: ns.length)) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs evidence Markdown link is malformed.")
            }
            destination = ns.substring(with: match.range(at: 1))
        }
        let pieces = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let relativePath = String(pieces[0])
        let anchor = pieces.count == 2 ? String(pieces[1]) : nil
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasSuffix("/"),
              !relativePath.contains("//"), relativePath != sourceWorkspacePath,
              relativePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
              }) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs evidence must be a contained, nonhidden, noncircular relative file path.")
        }
        let root = configuration.taskCheckpointRootURL
        var cursor = root
        for component in relativePath.split(separator: "/") {
            cursor.append(path: String(component))
            var status = stat()
            guard lstat(cursor.path, &status) == 0, status.st_mode & S_IFMT != S_IFLNK else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs evidence is missing or contains a symbolic link.")
            }
        }
        var status = stat()
        guard lstat(cursor.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              FileManager.default.isReadableFile(atPath: cursor.path) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs evidence is not a readable non-followed regular file.")
        }
        if let anchor {
            let data = try Data(contentsOf: cursor)
            guard !anchor.isEmpty, let text = String(data: data, encoding: .utf8),
                  AcceptedHandoffMarkdown.anchors(in: text).contains(anchor) else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Accepted Handoffs evidence Markdown anchor does not resolve exactly.")
            }
        }
    }

    private static func readSafeText(path: String, configuration: ProductionsConfiguration) throws -> String {
        let root = configuration.taskCheckpointRootURL
        let target = configuration.taskCheckpointURL(path)
        let prefix = root.path + "/"
        guard TaskCheckpointUTF8.hasPrefix(target.path, prefix) else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Discovery path escapes Productions.")
        }
        var cursor = URL(fileURLWithPath: "/", isDirectory: true)
        for component in target.path.split(separator: "/") {
            cursor.append(path: String(component))
            var status = stat()
            guard lstat(cursor.path, &status) == 0, status.st_mode & S_IFMT != S_IFLNK else {
                throw AcceptedHandoffValidationError.targetContractInvalid("Discovery path is missing or symlinked.")
            }
        }
        var status = stat()
        guard lstat(target.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Discovery target is not a regular file.")
        }
        let data = try Data(contentsOf: target)
        guard let text = String(data: data, encoding: .utf8), !text.contains("\r") else {
            throw AcceptedHandoffValidationError.targetContractInvalid("Discovery target must be valid LF-only UTF-8.")
        }
        return text
    }
}

enum OfficeWorkspaceInspectionPayload {
    case checkpoint(TaskCheckpointCommandResult)
    case acceptedHandoff(AcceptedHandoffCommandResult)
}

protocol OfficeWorkspaceInspecting {
    func inspect(operationID: UUID, configuration: ProductionsConfiguration) throws -> OfficeWorkspaceInspectionPayload
}

struct ServiceBackedOfficeWorkspaceInspector: OfficeWorkspaceInspecting {
    let checkpointService: TaskCheckpointService
    let acceptedHandoffService: AcceptedHandoffService

    func inspect(operationID: UUID, configuration: ProductionsConfiguration) throws -> OfficeWorkspaceInspectionPayload {
        var checkpointReadError: Error?
        do {
            if try checkpointService.journalStore.journal(operationID: operationID) != nil {
                return .checkpoint(try checkpointService.inspect(operationID: operationID, configuration: configuration))
            }
        } catch { checkpointReadError = error }

        do {
            if try acceptedHandoffService.journalStore.journal(operationID: operationID) != nil {
                return .acceptedHandoff(try acceptedHandoffService.inspect(operationID: operationID, configuration: configuration))
            }
        } catch {
            throw OfficeWorkspaceInspectionDispatchError.invalid(
                "Neither typed journal reader could validate the supplied operation envelope. " +
                "Checkpoint reader: \(checkpointReadError?.localizedDescription ?? "no matching journal"); " +
                "accepted-handoff reader: \(error.localizedDescription)."
            )
        }
        if let checkpointReadError {
            throw OfficeWorkspaceInspectionDispatchError.invalid(
                "The checkpoint journal reader rejected the supplied operation envelope: \(checkpointReadError.localizedDescription)"
            )
        }
        throw OfficeWorkspaceInspectionDispatchError.invalid("No Office Workspace journal exists for \(operationID.uuidString).")
    }
}

struct ApplicationSupportOfficeWorkspaceInspector: OfficeWorkspaceInspecting {
    let manager: FileManager
    let directory: URL
    let checkpointService: TaskCheckpointService
    let acceptedHandoffService: AcceptedHandoffService

    init(
        manager: FileManager = .default,
        directory: URL? = nil,
        checkpointService: TaskCheckpointService = TaskCheckpointService(),
        acceptedHandoffService: AcceptedHandoffService = AcceptedHandoffService()
    ) {
        self.manager = manager
        self.directory = directory ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/Office Workspace Transaction Recovery", directoryHint: .isDirectory)
        self.checkpointService = checkpointService
        self.acceptedHandoffService = acceptedHandoffService
    }

    func inspect(operationID: UUID, configuration: ProductionsConfiguration) throws -> OfficeWorkspaceInspectionPayload {
        let url = directory.appending(path: "\(operationID.uuidString).json")
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              TaskCheckpointUTF8.equal(url.lastPathComponent, "\(operationID.uuidString).json") else {
            throw OfficeWorkspaceInspectionDispatchError.invalid("No exact regular Office Workspace journal exists for \(operationID.uuidString).")
        }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] as? Int == 1,
              object["operationUUID"] as? String == operationID.uuidString,
              let kind = object["operationKind"] as? String else {
            throw OfficeWorkspaceInspectionDispatchError.invalid("Journal UUID, schema, or operation kind is malformed.")
        }
        switch kind {
        case "task-checkpoint": return .checkpoint(try checkpointService.inspect(operationID: operationID, configuration: configuration))
        case "accepted-handoff": return .acceptedHandoff(try acceptedHandoffService.inspect(operationID: operationID, configuration: configuration))
        default: throw OfficeWorkspaceInspectionDispatchError.invalid("Unsupported Office Workspace journal kind \(kind).")
        }
    }
}

enum OfficeWorkspaceInspectionDispatchError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case let .invalid(message): "journal-read-failed: \(message) Do not retry automatically." }
    }
}
