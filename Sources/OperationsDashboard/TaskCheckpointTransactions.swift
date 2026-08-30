import CryptoKit
import Darwin
import Foundation

enum OfficeWorkspaceTerminalState: String, Codable, CaseIterable, Equatable {
    case definiteNoCommit
    case committedAndCurrent
    case reconciledCommittedAndCurrent
    case historicallyCommittedAndSuperseded
    case historicallyCommittedWithCurrentStateUncertain
    case committedReloadFailed
    case uncertain
    case journalFinalizationFailedCommittedAndCurrent
    case journalFinalizationFailedHistoricallyCommittedAndSuperseded
    case journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain
    case journalFinalizationFailedDefiniteNoCommit

    var provesHistoricalCommit: Bool {
        switch self {
        case .committedAndCurrent, .reconciledCommittedAndCurrent,
             .historicallyCommittedAndSuperseded,
             .historicallyCommittedWithCurrentStateUncertain, .committedReloadFailed,
             .journalFinalizationFailedCommittedAndCurrent,
             .journalFinalizationFailedHistoricallyCommittedAndSuperseded,
             .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain:
            true
        case .definiteNoCommit, .uncertain, .journalFinalizationFailedDefiniteNoCommit:
            false
        }
    }

    var isStartupIncomplete: Bool {
        switch self {
        case .uncertain, .committedReloadFailed, .historicallyCommittedWithCurrentStateUncertain: true
        default: false
        }
    }

    private var proofClass: Int? {
        switch self {
        case .committedAndCurrent, .reconciledCommittedAndCurrent,
             .journalFinalizationFailedCommittedAndCurrent: 0
        case .historicallyCommittedAndSuperseded,
             .journalFinalizationFailedHistoricallyCommittedAndSuperseded: 1
        case .historicallyCommittedWithCurrentStateUncertain, .committedReloadFailed,
             .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain: 2
        case .definiteNoCommit, .uncertain, .journalFinalizationFailedDefiniteNoCommit: nil
        }
    }

    var hasFallback: Bool {
        switch self {
        case .journalFinalizationFailedCommittedAndCurrent,
             .journalFinalizationFailedHistoricallyCommittedAndSuperseded,
             .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain,
             .journalFinalizationFailedDefiniteNoCommit: true
        default: false
        }
    }

    static func merging(current: Self?, proposed: Self) -> Self {
        guard let current else { return proposed }
        if current == .definiteNoCommit || current == .journalFinalizationFailedDefiniteNoCommit {
            if proposed == .journalFinalizationFailedDefiniteNoCommit { return proposed }
            return current
        }
        guard current.provesHistoricalCommit else { return proposed }
        let joined = max(current.proofClass ?? 2, proposed.provesHistoricalCommit ? (proposed.proofClass ?? 2) : 2)
        if current.hasFallback || proposed.hasFallback {
            return switch joined {
            case 0: .journalFinalizationFailedCommittedAndCurrent
            case 1: .journalFinalizationFailedHistoricallyCommittedAndSuperseded
            default: .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain
            }
        }
        if current == .committedReloadFailed { return .committedReloadFailed }
        return switch joined {
        case 0: current
        case 1: .historicallyCommittedAndSuperseded
        default: .historicallyCommittedWithCurrentStateUncertain
        }
    }
}

struct TaskCheckpointRequest: Equatable {
    let taskID: String
    let expectedWorkspaceSHA256: String
    let expectedRegistrySHA256: String
    let unfinishedStep: String
    let acceptedEvidence: [String]
    let nextStep: String
    let lastValidatedState: String
}

struct TaskCheckpointJournal: Codable, Equatable {
    static let schemaVersion = 1
    let schemaVersion: Int
    let operationUUID: UUID
    let productionsRootPath: String
    let taskID: String
    let stepID: String
    let timestamp: Date
    let operationKind: String
    let registryPath: String
    let registrySHA256: String
    let registryPreimage: Data
    let workspacePath: String
    let workspaceSHA256Before: String
    let workspacePreimage: Data
    let workspaceSHA256ExpectedAfter: String
    let workspaceExpectedAfter: Data
    let targetFingerprint: String
    let acceptedEvidence: [String]
    let nextStep: String
    let lastValidatedState: String
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

protocol TaskCheckpointJournalStore {
    func persist(_ journal: TaskCheckpointJournal) throws
    func update(_ journal: TaskCheckpointJournal) throws
    func recordFallback(_ journal: TaskCheckpointJournal) throws
    func journal(operationID: UUID) throws -> TaskCheckpointJournal?
    func incomplete() throws -> [TaskCheckpointJournal]
}

struct ApplicationSupportTaskCheckpointJournalStore: TaskCheckpointJournalStore {
    private let manager: FileManager
    private let directoryOverride: URL?

    init(manager: FileManager = .default, directory: URL? = nil) {
        self.manager = manager
        directoryOverride = directory
    }

    private var directory: URL {
        directoryOverride ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/Office Workspace Transaction Recovery", directoryHint: .isDirectory)
    }

    func persist(_ journal: TaskCheckpointJournal) throws {
        try journal.validateEnvelope(requestedOperationID: journal.operationUUID)
        guard journal.terminalState == nil, !journal.journalFinalized,
              !journal.fallbackRecorded, journal.diagnostic == nil else {
            throw TaskCheckpointJournalEnvelopeError.invalid("An initial journal must be unfinalized, nonfallback, and nonterminal.")
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try matchingJournalURLs(operationID: journal.operationUUID).isEmpty else {
            throw TaskCheckpointJournalEnvelopeError.invalid("A journal already exists for the issued operation UUID.")
        }
        try writeUnchecked(journal)
    }

    func update(_ journal: TaskCheckpointJournal) throws {
        try journal.validateEnvelope(requestedOperationID: journal.operationUUID)
        guard let durable = try self.journal(operationID: journal.operationUUID) else {
            throw TaskCheckpointJournalEnvelopeError.invalid("The bound recovery journal is unavailable for update.")
        }
        try journal.validateUpdate(from: durable, requiresFallback: false)
        try writeUnchecked(journal)
    }

    func recordFallback(_ journal: TaskCheckpointJournal) throws {
        try journal.validateEnvelope(requestedOperationID: journal.operationUUID)
        guard let durable = try self.journal(operationID: journal.operationUUID) else {
            throw TaskCheckpointJournalEnvelopeError.invalid("The bound recovery journal is unavailable for fallback recording.")
        }
        try journal.validateUpdate(from: durable, requiresFallback: true)
        try writeUnchecked(journal)
    }

    func journal(operationID: UUID) throws -> TaskCheckpointJournal? {
        let matches = try matchingJournalURLs(operationID: operationID)
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1, matches[0].lastPathComponent == "\(operationID.uuidString).json" else {
            throw TaskCheckpointJournalEnvelopeError.invalid("The durable journal filename does not exactly bind the requested operation UUID.")
        }
        let value = try readBoundJournal(at: matches[0], requestedOperationID: operationID)
        return value
    }

    func incomplete() throws -> [TaskCheckpointJournal] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                let stem = url.deletingPathExtension().lastPathComponent
                guard let operationID = UUID(uuidString: stem), url.lastPathComponent == "\(operationID.uuidString).json" else {
                    throw TaskCheckpointJournalEnvelopeError.invalid("A startup journal filename is not one exact canonical UUID.")
                }
                let value = try readBoundJournal(at: url, requestedOperationID: operationID)
                return value.terminalState == nil || value.terminalState?.isStartupIncomplete == true ? value : nil
            }
    }

    private func matchingJournalURLs(operationID: UUID) throws -> [URL] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let expected = "\(operationID.uuidString).json"
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.caseInsensitiveCompare(expected) == .orderedSame }
    }

    private func readBoundJournal(at url: URL, requestedOperationID: UUID) throws -> TaskCheckpointJournal {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw TaskCheckpointJournalEnvelopeError.invalid("The durable journal is not a non-followed regular file.")
        }
        let value = try JSONDecoder().decode(TaskCheckpointJournal.self, from: Data(contentsOf: url))
        try value.validateEnvelope(requestedOperationID: requestedOperationID)
        return value
    }

    private func writeUnchecked(_ journal: TaskCheckpointJournal) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try DurableReplacement(manager: manager).replace(
            data: try encoder.encode(journal),
            at: directory.appending(path: "\(journal.operationUUID.uuidString).json")
        )
    }
}

private enum TaskCheckpointJournalEnvelopeError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case let .invalid(message): "Invalid Task checkpoint journal envelope: \(message)" }
    }
}

private enum TaskCheckpointUTF8 {
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    static func hasPrefix(_ value: String, _ prefix: String) -> Bool {
        value.utf8.starts(with: prefix.utf8)
    }
}

private enum TaskCheckpointCanonicalRoot {
    static func isExact(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", !path.hasSuffix("/"),
              !path.contains("//"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({
                  !$0.isEmpty &&
                  !TaskCheckpointUTF8.equal(String($0), ".") &&
                  !TaskCheckpointUTF8.equal(String($0), "..")
              }) else {
            return false
        }
        return TaskCheckpointUTF8.equal(URL(fileURLWithPath: path, isDirectory: true).path, path)
    }

    static func url(_ path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
    }
}

private extension ProductionsConfiguration {
    var taskCheckpointRootURL: URL { TaskCheckpointCanonicalRoot.url(productionsRootPath) }

    func taskCheckpointURL(_ relativePath: String, directory: Bool = false) -> URL {
        taskCheckpointRootURL.appending(
            path: relativePath,
            directoryHint: directory ? .isDirectory : .notDirectory
        )
    }
}

private extension TaskCheckpointJournal {
    func validateEnvelope(requestedOperationID: UUID) throws {
        let hashPattern = #"^[0-9a-f]{64}$"#
        guard operationUUID == requestedOperationID,
              schemaVersion == Self.schemaVersion,
              operationKind == "task-checkpoint",
              taskID.range(of: #"^TASK-[0-9]{4,}$"#, options: .regularExpression) != nil,
              stepID.range(of: #"^S[0-9]{2}$"#, options: .regularExpression) != nil,
              registryPath == "Office/Registry/Tasks.md",
              workspacePath == "Workspace/\(taskID)/\(taskID).md",
              TaskCheckpointCanonicalRoot.isExact(productionsRootPath),
              registrySHA256.range(of: hashPattern, options: .regularExpression) != nil,
              workspaceSHA256Before.range(of: hashPattern, options: .regularExpression) != nil,
              workspaceSHA256ExpectedAfter.range(of: hashPattern, options: .regularExpression) != nil,
              targetFingerprint.range(of: hashPattern, options: .regularExpression) != nil,
              registrySHA256 == envelopeSHA256(registryPreimage),
              workspaceSHA256Before == envelopeSHA256(workspacePreimage),
              workspaceSHA256ExpectedAfter == envelopeSHA256(workspaceExpectedAfter) else {
            throw TaskCheckpointJournalEnvelopeError.invalid("UUID, schema, operation kind, fixed path/ID grammar, or bound pre/post hashes do not match.")
        }
        try validateTerminalFlags()
    }

    func validateUpdate(from durable: TaskCheckpointJournal, requiresFallback: Bool) throws {
        guard immutableEnvelopeEquals(durable) else {
            throw TaskCheckpointJournalEnvelopeError.invalid("A journal update attempted to substitute an immutable operation-envelope field.")
        }
        guard let proposedState = terminalState,
              proposedState == OfficeWorkspaceTerminalState.merging(current: durable.terminalState, proposed: proposedState) else {
            throw TaskCheckpointJournalEnvelopeError.invalid("A journal update attempted a nonmonotonic or proving-to-nonproving terminal transition.")
        }
        try validateTerminalFlags()
        guard requiresFallback == fallbackRecorded else {
            throw TaskCheckpointJournalEnvelopeError.invalid(requiresFallback
                ? "Fallback recording requires an exact sticky fallback terminal state."
                : "Normal journal update cannot record a fallback terminal state.")
        }
        if durable.fallbackRecorded {
            guard fallbackRecorded, proposedState.hasFallback else {
                throw TaskCheckpointJournalEnvelopeError.invalid("Fallback proof and fallbackRecorded are sticky.")
            }
        }
        if durable.terminalState?.provesHistoricalCommit == true {
            guard proposedState.provesHistoricalCommit else {
                throw TaskCheckpointJournalEnvelopeError.invalid("Historical commit proof cannot be downgraded.")
            }
        }
    }

    private func immutableEnvelopeEquals(_ other: TaskCheckpointJournal) -> Bool {
        schemaVersion == other.schemaVersion &&
        operationUUID == other.operationUUID &&
        TaskCheckpointUTF8.equal(productionsRootPath, other.productionsRootPath) &&
        taskID == other.taskID &&
        stepID == other.stepID &&
        timestamp == other.timestamp &&
        operationKind == other.operationKind &&
        registryPath == other.registryPath &&
        registrySHA256 == other.registrySHA256 &&
        registryPreimage == other.registryPreimage &&
        workspacePath == other.workspacePath &&
        workspaceSHA256Before == other.workspaceSHA256Before &&
        workspacePreimage == other.workspacePreimage &&
        workspaceSHA256ExpectedAfter == other.workspaceSHA256ExpectedAfter &&
        workspaceExpectedAfter == other.workspaceExpectedAfter &&
        targetFingerprint == other.targetFingerprint &&
        acceptedEvidence == other.acceptedEvidence &&
        nextStep == other.nextStep &&
        lastValidatedState == other.lastValidatedState
    }

    private func validateTerminalFlags() throws {
        switch terminalState {
        case nil:
            guard !journalFinalized, !fallbackRecorded else {
                throw TaskCheckpointJournalEnvelopeError.invalid("A nonterminal journal cannot be finalized or fallback-recorded.")
            }
        case let state?:
            if state.hasFallback {
                guard !journalFinalized, fallbackRecorded else {
                    throw TaskCheckpointJournalEnvelopeError.invalid("A fallback terminal requires journalFinalized false and fallbackRecorded true.")
                }
            } else {
                guard journalFinalized, !fallbackRecorded else {
                    throw TaskCheckpointJournalEnvelopeError.invalid("A normal terminal requires journalFinalized true and fallbackRecorded false.")
                }
            }
        }
    }

    private func envelopeSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

protocol TaskCheckpointLocking {
    func acquire(registryURL: URL) -> AnyObject?
}

private final class TaskCheckpointFileLock: NSObject {
    private let descriptor: Int32

    init?(registryURL: URL) {
        descriptor = open(registryURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var status = stat()
        guard descriptor >= 0,
              fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            return nil
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

struct LocalTaskCheckpointLocking: TaskCheckpointLocking {
    func acquire(registryURL: URL) -> AnyObject? { TaskCheckpointFileLock(registryURL: registryURL) }
}

protocol OfficeV112ContractValidating {
    func validate(configuration: ProductionsConfiguration) throws
}

enum OfficeContractValidationError: LocalizedError, Equatable {
    case contractNotAdopted(String)

    var errorDescription: String? {
        switch self {
        case let .contractNotAdopted(message): "contractNotAdopted: \(message)"
        }
    }
}

struct AdoptedOfficeV112ContractValidator: OfficeV112ContractValidating {
    static let immutableSHA256: [String: String] = [
        "Warehouse/Reference/Canonical Work Record Template.md": "3c7f3784904a9d4ac2b85e45d53089dcbf8c1e73ad37c8c1cbddc40e5a386353",
        "Warehouse/Reference/Momentum Management Filesystem Contract.md": "998e56b888c87a226fa5fe253fadfef975f5171e5663a1441e61930f3bb8fafa",
        "Warehouse/Reference/Task Status and Continuity Protocol.md": "8d8583cd859fbff3f861dbf38635aabf7aa5fd9eeeccaeca18103e8f00a4e4a7",
        "Warehouse/Reference/Task Intake and Promotion Policy.md": "7df7bf0e5de24cefa4807e48a5313671b2b9342460e788527a3988f0efc9b978",
        "AGENTS.md": "e4706789b22eca6861b6559514c54090a4003988da8f67efb5c7b6870c1f1ce5",
        "PRODUCTIONS_COORDINATOR.md": "aefd79d6b33b9a91f9f0f3a34811126c9a2467b92df1839baa3e37dd851576ce",
        "PRODUCTIONS_OFFICE_ADMINISTRATOR.md": "187c06aa6821f86556192c48185e639ab77280e8d5097cfbff481113f46d681e",
    ]
    let manager: FileManager
    init(manager: FileManager = .default) { self.manager = manager }

    func validate(configuration: ProductionsConfiguration) throws {
        guard TaskCheckpointCanonicalRoot.isExact(configuration.productionsRootPath) else {
            throw OfficeContractValidationError.contractNotAdopted(
                "The supplied Productions root must use one exact absolute spelling without dot segments, repeated separators, a trailing separator, or control characters."
            )
        }
        let root = configuration.taskCheckpointRootURL
        try requireSafeDirectory(root, label: "Productions root")
        for (path, expectedHash) in Self.immutableSHA256 {
            let data = try readSafeData(root: root, path: path)
            guard sha256(data) == expectedHash else {
                throw OfficeContractValidationError.contractNotAdopted("The immutable adopted v1.12 identity for \(path) does not match.")
            }
        }

        let documentRegistry = try readSafeText(root: root, path: "Warehouse/Reference/Document Registry.md")
        try validateDocumentRegistry(documentRegistry)

        let headers: [(String, [String])] = [
            ("Office/Registry/Tasks.md", TaskRegistryDocument.headers),
            ("Office/Registry/Ideas.md", ["Idea ID", "Title", "Disposition", "Priority", "Current lead", "Related records", "Review after", "Source artifacts", "Short description", "Workspace"]),
            ("Office/Registry/Projects.md", ["Project ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"]),
            ("Office/Registry/Initiatives.md", ["Initiative ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"]),
        ]
        for (path, expected) in headers {
            let text = try readSafeText(root: root, path: path)
            try validateRegistry(text, path: path, headers: expected)
        }

        let ideas = try readSafeText(root: root, path: "Office/Registry/Ideas.md")
        let ideaRows = try MarkdownTable.parse(ideas, required: ["Idea ID", "Title", "Review after", "Workspace"])
        guard ideaRows.filter({ $0["Idea ID"] == "IDEA-0006" }).count == 1,
              let ideaRow = ideaRows.first(where: { $0["Idea ID"] == "IDEA-0006" }),
              ideaRow["Review after"] == "TASK-0017@done-complete" else {
            throw OfficeContractValidationError.contractNotAdopted("The IDEA-0006 Registry migration is incomplete.")
        }
        let tasks = try readSafeText(root: root, path: "Office/Registry/Tasks.md")
        let taskRows = try MarkdownTable.parse(tasks, required: ["Task ID", "Title", "Workspace"])
        guard taskRows.filter({ $0["Task ID"] == "TASK-0017" }).count == 1,
              let taskRow = taskRows.first(where: { $0["Task ID"] == "TASK-0017" }) else {
            throw OfficeContractValidationError.contractNotAdopted("The fixed TASK-0017 Registry identity is unavailable or ambiguous.")
        }
        let ideaWorkspace = try readSafeText(root: root, path: "Workspace/IDEA-0006/IDEA-0006.md")
        let sourceWorkspace = try readSafeText(root: root, path: "Workspace/TASK-0017/TASK-0017.md")
        try validateFixedMigrationRecords(
            ideaRow: ideaRow, taskRow: taskRow,
            ideaWorkspace: ideaWorkspace, taskWorkspace: sourceWorkspace
        )
        try validateProvisionalHookMigration(ideaWorkspace: ideaWorkspace, sourceWorkspace: sourceWorkspace)
    }

    private func readSafeText(root: URL, path: String) throws -> String {
        String(decoding: try readSafeData(root: root, path: path), as: UTF8.self)
    }

    private func readSafeData(root: URL, path: String) throws -> Data {
        let url = root.appending(path: path)
        try requireSafeFile(url, inside: root, label: path)
        return try Data(contentsOf: url)
    }

    private func validateDocumentRegistry(_ text: String) throws {
        let headers = ["Document ID", "Title", "Status", "Canonical owner", "Location", "Notes"]
        guard !text.contains("\r") else {
            throw OfficeContractValidationError.contractNotAdopted("Document Registry is not canonical LF-only text.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.filter({ $0 == "# Reference Document Registry" }).count == 1,
              lines.filter({ $0 == "Document ID: DOC-0002" }).count == 1,
              lines.filter({ $0 == "Status: Current" }).count == 1,
              lines.filter({ $0 == "Revision date: 2026-08-29" }).count == 1,
              lines.filter({ $0 == "Canonical owner: Office" }).count == 1 else {
            throw OfficeContractValidationError.contractNotAdopted("Document Registry metadata does not exactly identify the adopted 2026-08-29 revision.")
        }
        let exactHeader = "| " + headers.joined(separator: " | ") + " |"
        let exactDelimiter = "| " + Array(repeating: "---", count: headers.count).joined(separator: " | ") + " |"
        let matches = lines.indices.filter { lines[$0] == exactHeader }
        guard matches.count == 1, let header = matches.first, header + 1 < lines.count else {
            throw OfficeContractValidationError.contractNotAdopted("Document Registry must contain one exact header.")
        }
        guard lines[header + 1] == exactDelimiter else {
            throw OfficeContractValidationError.contractNotAdopted("Document Registry delimiter width is malformed.")
        }
        var rows: [[String: String]] = []
        var index = header + 2
        while index < lines.count, lines[index].hasPrefix("|") {
            let values = MarkdownTable.cells(lines[index])
            guard values.count == headers.count else {
                throw OfficeContractValidationError.contractNotAdopted("Document Registry contains a wrong-width row.")
            }
            rows.append(Dictionary(uniqueKeysWithValues: zip(headers, values)))
            index += 1
        }
        for later in lines.dropFirst(index) where later.range(of: #"^\|\s*DOC-[0-9]{4,}\s*\|"#, options: .regularExpression) != nil {
            throw OfficeContractValidationError.contractNotAdopted("Document Registry contains a fragmented or hidden later row.")
        }
        let expected: [String: [String: String]] = [
            "DOC-0004": [
                "Title": "Canonical Work Record Template", "Status": "Current", "Canonical owner": "Office",
                "Location": "`Warehouse/Reference/Canonical Work Record Template.md`",
                "Notes": "Minimal same-ID Workspace record, optional substantive and machine-facing checkpoint/handoff/review sections, Crumbs, Memento, and supporting-file rules; revised 2026-08-29 for DOC-0016 v1.12.",
            ],
            "DOC-0005": [
                "Title": "Task Status and Continuity Protocol", "Status": "Current", "Canonical owner": "Office",
                "Location": "`Warehouse/Reference/Task Status and Continuity Protocol.md`",
                "Notes": "Lifecycle state, continuity, owner-authorized checkpoint, post-write phase-release, and canonical-location guidance; revised 2026-08-29 for DOC-0016 v1.12.",
            ],
            "DOC-0010": [
                "Title": "Task Intake and Promotion Policy", "Status": "Current", "Canonical owner": "Office",
                "Location": "`Warehouse/Reference/Task Intake and Promotion Policy.md`",
                "Notes": "Boundary among intake, Ideas, Tasks, advisory eligibility review, and owner-authorized promotion; revised 2026-08-29 for DOC-0016 v1.12.",
            ],
            "DOC-0016": [
                "Title": "Momentum Management Filesystem Contract", "Status": "Current", "Canonical owner": "Office and Momentum Management",
                "Location": "`Warehouse/Reference/Momentum Management Filesystem Contract.md`",
                "Notes": "Version 1.12 application paths, ordinary idempotent Canvas Focus/Clear and recovery, Task checkpoint, accepted-handoff and eligibility-review transactions, schemas, validation, and bounded write authority; effective 2026-08-29.",
            ],
        ]
        for (id, fields) in expected {
            let matches = rows.filter { $0["Document ID"] == id }
            guard matches.count == 1, let row = matches.first,
                  fields.allSatisfy({ row[$0.key] == $0.value }) else {
                throw OfficeContractValidationError.contractNotAdopted("Document Registry row \(id) does not exactly match the adopted v1.12 identity.")
            }
        }
    }

    private func validateRegistry(_ text: String, path: String, headers: [String]) throws {
        guard !text.contains("\r") else {
            throw OfficeContractValidationError.contractNotAdopted("\(path) is not canonical LF-only text.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let exactHeader = "| " + headers.joined(separator: " | ") + " |"
        let exactDelimiter = "| " + Array(repeating: "---", count: headers.count).joined(separator: " | ") + " |"
        let matches = lines.indices.filter { lines[$0] == exactHeader }
        guard matches.count == 1, let header = matches.first, header + 1 < lines.count else {
            throw OfficeContractValidationError.contractNotAdopted("\(path) does not contain its one exact v1.12 header.")
        }
        guard lines[header + 1] == exactDelimiter else {
            throw OfficeContractValidationError.contractNotAdopted("\(path) has a delimiter width that disagrees with its header.")
        }
        var index = header + 2
        var ids = Set<String>()
        let durablePrefix = switch headers[0] {
        case "Task ID": "TASK"
        case "Idea ID": "IDEA"
        case "Project ID": "PROJ"
        case "Initiative ID": "INIT"
        default: ""
        }
        let idPattern = "^\(durablePrefix)-[0-9]{4,}$"
        while index < lines.count, lines[index].hasPrefix("|") {
            let values = MarkdownTable.cells(lines[index])
            guard values.count == headers.count, let id = values.first,
                  id.range(of: idPattern, options: .regularExpression) != nil,
                  ids.insert(id).inserted else {
                throw OfficeContractValidationError.contractNotAdopted("\(path) has a malformed, duplicate, or wrong-width durable row.")
            }
            index += 1
        }
        for later in lines.dropFirst(index) where later.range(of: "^\\|\\s*\(durablePrefix)-[0-9]{4,}\\s*\\|", options: .regularExpression) != nil {
            throw OfficeContractValidationError.contractNotAdopted("\(path) contains a fragmented or hidden later durable row.")
        }
    }

    private func validateProvisionalHookMigration(ideaWorkspace: String, sourceWorkspace: String) throws {
        let eligibilityHeader = ["Hook", "Review question", "Disposition", "Decided at", "Reconsider after", "Replacement"]
        let expectedRow = [
            "TASK-0017@done-complete",
            "Confirm TASK-0015 remains stable enough for a bounded tool decision.",
            "Pending", "—", "—", "—",
        ]
        let ideaSections = topLevelSections(ideaWorkspace)
        let sourceSections = topLevelSections(sourceWorkspace)
        guard !ideaWorkspace.contains("\r"), !sourceWorkspace.contains("\r"),
              ideaSections.filter({ $0.title == "Eligibility Reviews" }).count == 1,
              ideaSections.allSatisfy({ $0.title != "Provisional Completion-Review Hook" }),
              sourceSections.allSatisfy({ $0.title != "Provisional Completion-Review Hook" && $0.title != "Eligibility Reviews" }),
              let section = ideaSections.first(where: { $0.title == "Eligibility Reviews" }) else {
            throw OfficeContractValidationError.contractNotAdopted("The provisional IDEA-0006/TASK-0017 Workspace section migration is incomplete or parallel prose remains.")
        }
        let lines = ideaWorkspace.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let headerMatches = section.body.filter { MarkdownTable.cells(lines[$0]) == eligibilityHeader }
        guard headerMatches.count == 1, let header = headerMatches.first, header + 1 < section.body.upperBound,
              MarkdownTable.cells(lines[header + 1]).count == eligibilityHeader.count,
              MarkdownTable.cells(lines[header + 1]).allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else {
            throw OfficeContractValidationError.contractNotAdopted("IDEA-0006 Eligibility Reviews does not contain one exact adopted table header and delimiter.")
        }
        var rows: [[String]] = []
        var index = header + 2
        while index < section.body.upperBound, lines[index].hasPrefix("|") {
            let values = MarkdownTable.cells(lines[index])
            guard values.count == eligibilityHeader.count else {
                throw OfficeContractValidationError.contractNotAdopted("IDEA-0006 Eligibility Reviews contains a wrong-width row.")
            }
            rows.append(values)
            index += 1
        }
        guard rows == [expectedRow],
              !lines[index..<section.body.upperBound].contains(where: {
                  $0.range(of: #"^\|\s*TASK-0017@done-complete\s*\|"#, options: .regularExpression) != nil
              }) else {
            throw OfficeContractValidationError.contractNotAdopted("IDEA-0006 Eligibility Reviews does not contain exactly the adopted pending hook row.")
        }
    }

    private func validateFixedMigrationRecords(
        ideaRow: [String: String],
        taskRow: [String: String],
        ideaWorkspace: String,
        taskWorkspace: String
    ) throws {
        let ideaTitle = "Explore Product Provisioning and Repair Tool"
        let taskTitle = "Decide Repository and Reference-Storage Structure"
        guard ideaRow["Title"] == ideaTitle,
              ideaRow["Workspace"] == "[IDEA-0006](../../Workspace/IDEA-0006/IDEA-0006.md)",
              taskRow["Title"] == taskTitle,
              taskRow["Workspace"] == "[TASK-0017](../../Workspace/TASK-0017/TASK-0017.md)" else {
            throw OfficeContractValidationError.contractNotAdopted("The fixed IDEA-0006/TASK-0017 Registry title or Workspace link is not exact.")
        }
        let ideaLines = ideaWorkspace.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let taskLines = taskWorkspace.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let ideaSections = topLevelSections(ideaWorkspace)
        let taskSections = topLevelSections(taskWorkspace)
        guard nonFencedH1s(ideaWorkspace) == [ideaTitle],
              ideaSections.filter({ $0.title == "Idea Record" }).count == 1,
              let ideaRecord = ideaSections.first(where: { $0.title == "Idea Record" }),
              exactField("Idea ID", lines: ideaLines, range: ideaRecord.body) == "IDEA-0006",
              exactField("Disposition", lines: ideaLines, range: ideaRecord.body) == ideaRow["Disposition"],
              exactField("Priority", lines: ideaLines, range: ideaRecord.body) == ideaRow["Priority"],
              exactField("Current lead", lines: ideaLines, range: ideaRecord.body) == ideaRow["Current lead"],
              exactField("Workspace", lines: ideaLines, range: ideaRecord.body) == "`Workspace/IDEA-0006/`." else {
            throw OfficeContractValidationError.contractNotAdopted("The fixed IDEA-0006 H1, Idea record type, ID, title, or canonical Workspace identity is not exact.")
        }
        guard nonFencedH1s(taskWorkspace) == [taskTitle],
              taskSections.filter({ $0.title == "Core Record" }).count == 1,
              let taskRecord = taskSections.first(where: { $0.title == "Core Record" }),
              exactField("Title", lines: taskLines, range: taskRecord.body) == taskTitle,
              exactField("Task ID", lines: taskLines, range: taskRecord.body) == "TASK-0017",
              exactField("Status source", lines: taskLines, range: taskRecord.body) == "Productions/Office/Registry/Tasks.md" else {
            throw OfficeContractValidationError.contractNotAdopted("The fixed TASK-0017 H1, Task record type, ID, title, or status-source identity is not exact.")
        }
    }

    private func nonFencedH1s(_ text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var values: [String] = []
        var insideFence = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
            } else if !insideFence, line.hasPrefix("# "), !line.hasPrefix("## ") {
                values.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        return values
    }

    private func exactField(_ name: String, lines: [String], range: Range<Int>) -> String? {
        let prefix = "\(name):"
        let matches = range.compactMap { index -> String? in
            guard lines[index].hasPrefix(prefix) else { return nil }
            return String(lines[index].dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func topLevelSections(_ text: String) -> [(title: String, body: Range<Int>)] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var headings: [(String, Int)] = []
        var insideFence = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
            } else if !insideFence, line.hasPrefix("## "), !line.hasPrefix("### ") {
                headings.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), index))
            }
        }
        return headings.enumerated().map { offset, heading in
            (heading.0, (heading.1 + 1)..<(offset + 1 < headings.count ? headings[offset + 1].1 : lines.count))
        }
    }

    private func requireSafeDirectory(_ url: URL, label: String) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw OfficeContractValidationError.contractNotAdopted("\(label) is unavailable.")
        }
        try requireNoSymlinkComponents(url)
    }

    private func requireSafeFile(_ url: URL, inside root: URL, label: String) throws {
        let canonicalRoot = root.path
        let target = url
        guard TaskCheckpointUTF8.hasPrefix(target.path, canonicalRoot + "/"),
              manager.isReadableFile(atPath: target.path) else {
            throw OfficeContractValidationError.contractNotAdopted("\(label) is unavailable or outside Productions.")
        }
        var status = stat()
        guard lstat(target.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG else {
            throw OfficeContractValidationError.contractNotAdopted("\(label) is not a readable regular file.")
        }
        try requireNoSymlinkComponents(target)
    }

    private func requireNoSymlinkComponents(_ url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            guard let entries = try? manager.contentsOfDirectory(atPath: current.path),
                  entries.contains(where: { TaskCheckpointUTF8.equal($0, component) }) else {
                throw OfficeContractValidationError.contractNotAdopted(
                    "A governed path component does not use exact canonical spelling: \(current.appending(path: component).path)."
                )
            }
            current.append(path: component)
            if (try? manager.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw OfficeContractValidationError.contractNotAdopted("A governed path contains a symbolic link: \(current.path).")
            }
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum TaskCheckpointValidationError: LocalizedError, Equatable {
    case invalidInput(String)
    case targetContractInvalid(String)
    case hashMismatch(String)
    case lockUnavailable
    case journalCreateFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(message): "invalidInput: \(message)"
        case let .targetContractInvalid(message): "targetContractInvalid: \(message)"
        case let .hashMismatch(message): "hashMismatch: \(message)"
        case .lockUnavailable: "Another Task Registry-and-Workspace transaction is in progress."
        case let .journalCreateFailed(message): "journalCreateFailed: \(message)"
        }
    }
}

struct TaskCheckpointCommandResult: Codable, Equatable {
    let outcome: String
    let operationUUID: UUID?
    let taskID: String?
    let completedStep: String?
    let workspaceSHA256Before: String?
    let workspaceSHA256After: String?
    let registrySHA256: String?
    let nextGate: String?
    let canvasState: String?
    let classification: String?
    let journalFinalized: Bool
    let fallbackRecorded: Bool
    let historicalCommitProven: Bool
    let inspectCommand: String?
    let diagnostic: String?
}

struct TaskCheckpointCommandFailure: Error, Equatable {
    let result: TaskCheckpointCommandResult
    let exitCode: Int32
}

private struct TaskCheckpointPreparedTarget {
    let registryData: Data
    let registry: TaskRegistryDocument
    let row: [String: String]
    let workspaceURL: URL
    let workspaceData: Data
    let workspace: TaskWorkspaceDocument
    let replacementData: Data
    let targetFingerprint: String
}

struct TaskCheckpointService {
    let journalStore: any TaskCheckpointJournalStore
    let replacer: any AtomicFileReplacing
    let locking: any TaskCheckpointLocking
    let contractValidator: any OfficeV112ContractValidating
    let manager: FileManager
    let now: () -> Date
    let makeOperationID: () -> UUID

    init(
        journalStore: any TaskCheckpointJournalStore = ApplicationSupportTaskCheckpointJournalStore(),
        replacer: (any AtomicFileReplacing)? = nil,
        locking: any TaskCheckpointLocking = LocalTaskCheckpointLocking(),
        contractValidator: any OfficeV112ContractValidating = AdoptedOfficeV112ContractValidator(),
        manager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeOperationID: @escaping () -> UUID = UUID.init
    ) {
        self.journalStore = journalStore
        self.replacer = replacer ?? DurableReplacement(manager: manager)
        self.locking = locking
        self.contractValidator = contractValidator
        self.manager = manager
        self.now = now
        self.makeOperationID = makeOperationID
    }

    func startupRecovery() -> [TaskCheckpointJournal] { (try? journalStore.incomplete()) ?? [] }

    func perform(request: TaskCheckpointRequest, configuration: ProductionsConfiguration) throws -> TaskCheckpointCommandResult {
        do {
            guard TaskCheckpointCanonicalRoot.isExact(configuration.productionsRootPath) else {
                throw OfficeContractValidationError.contractNotAdopted(
                    "The supplied Productions root must use one exact absolute spelling without dot segments, repeated separators, a trailing separator, or control characters."
                )
            }
            try contractValidator.validate(configuration: configuration)
        }
        catch {
            throw failure(
                outcome: "not-committed", operationID: nil, request: request,
                classification: "contractNotAdopted", journalFinalized: false, fallbackRecorded: false,
                historicalCommitProven: false,
                diagnostic: error.localizedDescription + " No operation journal was created.", exitCode: 2
            )
        }
        let operationID = makeOperationID()
        do { try validateRequest(request) }
        catch {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                classification: "invalidInput", journalFinalized: false, fallbackRecorded: false,
                historicalCommitProven: false,
                diagnostic: error.localizedDescription + " No operation journal was created.", exitCode: 2
            )
        }

        let registryURL = configuration.taskCheckpointURL(ProductionsPath.tasks.rawValue)
        do { try requireSafeCanonicalFile(registryURL, root: configuration.taskCheckpointRootURL, label: "Task Registry") }
        catch {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                classification: classification(for: error), journalFinalized: false, fallbackRecorded: false,
                historicalCommitProven: false,
                diagnostic: error.localizedDescription + " No operation journal was created.", exitCode: 2
            )
        }
        guard let lock = locking.acquire(registryURL: registryURL) else {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                classification: "lockUnavailable", journalFinalized: false, fallbackRecorded: false,
                historicalCommitProven: false,
                diagnostic: TaskCheckpointValidationError.lockUnavailable.localizedDescription + " No operation journal was created.", exitCode: 2
            )
        }
        defer { _ = lock }

        let timestamp = now()
        let prepared: TaskCheckpointPreparedTarget
        do { prepared = try prepare(request: request, configuration: configuration, operationID: operationID, timestamp: timestamp) }
        catch {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                classification: classification(for: error), journalFinalized: false, fallbackRecorded: false,
                historicalCommitProven: false,
                diagnostic: error.localizedDescription + " No operation journal was created.", exitCode: 2
            )
        }

        var journal = TaskCheckpointJournal(
            schemaVersion: TaskCheckpointJournal.schemaVersion,
            operationUUID: operationID,
            productionsRootPath: configuration.productionsRootPath,
            taskID: request.taskID,
            stepID: request.unfinishedStep,
            timestamp: timestamp,
            operationKind: "task-checkpoint",
            registryPath: ProductionsPath.tasks.rawValue,
            registrySHA256: hash(prepared.registryData),
            registryPreimage: prepared.registryData,
            workspacePath: "Workspace/\(request.taskID)/\(request.taskID).md",
            workspaceSHA256Before: hash(prepared.workspaceData),
            workspacePreimage: prepared.workspaceData,
            workspaceSHA256ExpectedAfter: hash(prepared.replacementData),
            workspaceExpectedAfter: prepared.replacementData,
            targetFingerprint: prepared.targetFingerprint,
            acceptedEvidence: request.acceptedEvidence,
            nextStep: request.nextStep,
            lastValidatedState: request.lastValidatedState,
            terminalState: nil,
            journalFinalized: false,
            fallbackRecorded: false,
            diagnostic: nil
        )
        do { try journalStore.persist(journal) }
        catch {
            throw failure(
                outcome: "not-committed", operationID: operationID, request: request,
                before: hash(prepared.workspaceData), registry: hash(prepared.registryData),
                classification: "journalCreateFailed", journalFinalized: false, fallbackRecorded: false,
                historicalCommitProven: false,
                diagnostic: "Initial recovery journal could not be persisted; no canonical replacement was attempted and no durable operation journal was created: \(error.localizedDescription)", exitCode: 2
            )
        }

        do {
            try requireSafeCanonicalFile(registryURL, root: configuration.taskCheckpointRootURL, label: "Task Registry")
            try requireSafeCanonicalFile(prepared.workspaceURL, root: configuration.taskCheckpointRootURL, label: "Task Workspace")
            let currentRegistry = try Data(contentsOf: registryURL)
            let currentWorkspace = try Data(contentsOf: prepared.workspaceURL)
            guard currentRegistry == prepared.registryData, currentWorkspace == prepared.workspaceData else {
                return try finishDefiniteNoCommit(
                    journal: &journal, request: request,
                    diagnostic: "Registry or Workspace changed after preparation; no replacement was attempted."
                )
            }
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

        do {
            _ = try fullyValidatePostimage(journal: journal, configuration: configuration)
        } catch {
            let diagnostic = "Workspace replacement returned success, but committed reload validation failed: \(error.localizedDescription)"
            do {
                guard let loaded = try journalStore.journal(operationID: operationID) else {
                    throw TaskCheckpointValidationError.targetContractInvalid("No recovery journal exists for the issued operation UUID.")
                }
                journal = loaded
            } catch {
                throw failure(
                    outcome: "uncertain", operationID: operationID, request: request,
                    before: journal.workspaceSHA256Before, after: journal.workspaceSHA256ExpectedAfter,
                    registry: journal.registrySHA256,
                    classification: "historically-committed-current-state-uncertain",
                    journalFinalized: false, fallbackRecorded: false, historicalCommitProven: true,
                    diagnostic: "Workspace replacement returned success, reload failed, and the recovery journal could not be read: \(error.localizedDescription). Do not retry automatically.",
                    journalRootPath: journal.productionsRootPath,
                    exitCode: 3
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
                diagnostic: "The Workspace commit is proven current, but normal terminal journal finalization failed: \(error.localizedDescription)"
            )
        }
        return committedResult(journal: journal, request: request, configuration: configuration)
    }

    func inspect(operationID: UUID, configuration: ProductionsConfiguration) throws -> TaskCheckpointCommandResult {
        let journal: TaskCheckpointJournal
        do {
            guard let found = try journalStore.journal(operationID: operationID) else {
                throw TaskCheckpointValidationError.targetContractInvalid("No Task checkpoint journal exists for \(operationID.uuidString).")
            }
            journal = found
        } catch {
            throw failure(
                outcome: "uncertain", operationID: operationID, request: nil,
                classification: "journal-read-failed", journalFinalized: false, fallbackRecorded: false,
                historicalCommitProven: false,
                diagnostic: "The operation journal could not be read: \(error.localizedDescription). Do not retry automatically.", exitCode: 3
            )
        }

        if journal.terminalState == .definiteNoCommit || journal.terminalState == .journalFinalizationFailedDefiniteNoCommit {
            return result(
                outcome: "not-committed", journal: journal,
                classification: "definite-no-commit", canvasState: nil,
                diagnostic: journal.diagnostic
            )
        }
        let historicalProof = journal.terminalState?.provesHistoricalCommit == true
        guard TaskCheckpointCanonicalRoot.isExact(configuration.productionsRootPath),
              TaskCheckpointUTF8.equal(configuration.productionsRootPath, journal.productionsRootPath) else {
            return inspectionUncertain(
                journal: journal,
                historicalProof: historicalProof,
                diagnostic: "The supplied canonical Productions root does not match the immutable journal-bound root. No live target was read and no journal state was reconciled."
            )
        }
        let registryURL = configuration.taskCheckpointURL(journal.registryPath)
        let workspaceURL = configuration.taskCheckpointURL(journal.workspacePath)
        let currentRegistry: Data
        let currentWorkspace: Data
        do {
            try requireSafeCanonicalFile(registryURL, root: configuration.taskCheckpointRootURL, label: "Task Registry")
            try requireSafeCanonicalFile(workspaceURL, root: configuration.taskCheckpointRootURL, label: "Task Workspace")
            currentRegistry = try Data(contentsOf: registryURL)
            currentWorkspace = try Data(contentsOf: workspaceURL)
        } catch {
            return inspectionUncertain(journal: journal, historicalProof: historicalProof, diagnostic: "The bound canonical target is unavailable or unreadable: \(error.localizedDescription)")
        }

        if historicalProof {
            if currentWorkspace == journal.workspacePreimage {
                return inspectionUncertain(journal: journal, historicalProof: true, diagnostic: "Canonical Workspace bytes returned to the journal preimage after a proven commit; history is inconsistent.")
            }
            if currentWorkspace == journal.workspaceExpectedAfter, currentRegistry == journal.registryPreimage {
                do {
                    _ = try fullyValidatePostimage(journal: journal, configuration: configuration)
                    return result(outcome: "committed", journal: journal, classification: "committed-and-current", canvasState: observeCanvas(taskID: journal.taskID, configuration: configuration), diagnostic: journal.diagnostic)
                } catch {
                    return inspectionUncertain(journal: journal, historicalProof: true, diagnostic: "Exact postimage bytes exist but complete validation failed: \(error.localizedDescription)")
                }
            }
            do {
                let currentDocument = try TaskWorkspaceDocument(data: currentWorkspace)
                let registry = try TaskRegistryDocument(data: currentRegistry)
                let row = try registry.identityRow(taskID: journal.taskID)
                try currentDocument.validateIdentityAndRelationships(taskID: journal.taskID, registryRow: row)
                return result(outcome: "committed", journal: journal, classification: "historically-committed-and-superseded", canvasState: observeCanvas(taskID: journal.taskID, configuration: configuration), diagnostic: "The historical commit is proven and a later valid canonical mutation superseded its exact postimage.")
            } catch {
                return inspectionUncertain(journal: journal, historicalProof: true, diagnostic: "Historical commit remains proven, but current target identity or Registry agreement is uncertain: \(error.localizedDescription)")
            }
        }

        if currentWorkspace == journal.workspacePreimage, currentRegistry == journal.registryPreimage {
            return result(outcome: "not-committed", journal: journal, classification: "definite-no-commit", canvasState: nil, diagnostic: "The exact preimage and unchanged Registry prove no commit.")
        }
        if currentWorkspace == journal.workspaceExpectedAfter, currentRegistry == journal.registryPreimage {
            do {
                _ = try fullyValidatePostimage(journal: journal, configuration: configuration)
                var reconciled = journal
                reconciled.transition(to: .reconciledCommittedAndCurrent, diagnostic: "Inspection reconciled the exact postimage as committed.", finalized: true)
                try journalStore.update(reconciled)
                return result(outcome: "committed", journal: reconciled, classification: "committed-and-current", canvasState: observeCanvas(taskID: journal.taskID, configuration: configuration), diagnostic: reconciled.diagnostic)
            } catch {
                return inspectionUncertain(journal: journal, historicalProof: false, diagnostic: "Exact postimage bytes could not be fully validated: \(error.localizedDescription)")
            }
        }
        return inspectionUncertain(journal: journal, historicalProof: false, diagnostic: "Neither the exact preimage nor a completely valid exact postimage is current.")
    }

    private func prepare(
        request: TaskCheckpointRequest,
        configuration: ProductionsConfiguration,
        operationID: UUID,
        timestamp: Date
    ) throws -> TaskCheckpointPreparedTarget {
        let registryURL = configuration.taskCheckpointURL(ProductionsPath.tasks.rawValue)
        try requireSafeCanonicalFile(registryURL, root: configuration.taskCheckpointRootURL, label: "Task Registry")
        let registryData = try Data(contentsOf: registryURL)
        guard hash(registryData) == request.expectedRegistrySHA256 else {
            throw TaskCheckpointValidationError.hashMismatch("Task Registry SHA-256 does not match the authorized preimage.")
        }
        let registry = try TaskRegistryDocument(data: registryData)
        let row = try registry.uniqueRow(taskID: request.taskID)
        let workspacePath = "Workspace/\(request.taskID)/\(request.taskID).md"
        guard MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry") == workspacePath else {
            throw TaskCheckpointValidationError.targetContractInvalid("The Task Registry Workspace link is not the exact same-ID canonical record.")
        }
        let workspaceURL = configuration.taskCheckpointURL(workspacePath)
        try requireSafeCanonicalFile(workspaceURL, root: configuration.taskCheckpointRootURL, label: "Task Workspace")
        let workspaceData = try Data(contentsOf: workspaceURL)
        guard hash(workspaceData) == request.expectedWorkspaceSHA256 else {
            throw TaskCheckpointValidationError.hashMismatch("Task Workspace SHA-256 does not match the authorized preimage.")
        }
        let workspace = try TaskWorkspaceDocument(data: workspaceData)
        try workspace.validateIdentityAndRelationships(taskID: request.taskID, registryRow: row)
        let replacement = try workspace.checkpointReplacement(
            stepID: request.unfinishedStep,
            operationID: operationID,
            timestamp: timestamp,
            evidence: request.acceptedEvidence,
            nextStep: request.nextStep,
            lastValidatedState: request.lastValidatedState
        )
        let replacementDocument = try TaskWorkspaceDocument(data: replacement)
        try replacementDocument.validateIdentityAndRelationships(taskID: request.taskID, registryRow: row)
        try workspace.validateCheckpointPostimage(
            replacementDocument,
            replacementData: replacement,
            stepID: request.unfinishedStep,
            operationID: operationID,
            evidence: request.acceptedEvidence,
            nextStep: request.nextStep,
            lastValidatedState: request.lastValidatedState
        )
        return TaskCheckpointPreparedTarget(
            registryData: registryData, registry: registry, row: row,
            workspaceURL: workspaceURL, workspaceData: workspaceData, workspace: workspace,
            replacementData: replacement,
            targetFingerprint: targetFingerprint(row: row, workspacePath: workspacePath)
        )
    }

    private func fullyValidatePostimage(journal: TaskCheckpointJournal, configuration: ProductionsConfiguration) throws -> String {
        let registryURL = configuration.taskCheckpointURL(journal.registryPath)
        let workspaceURL = configuration.taskCheckpointURL(journal.workspacePath)
        try requireSafeCanonicalFile(registryURL, root: configuration.taskCheckpointRootURL, label: "Task Registry")
        try requireSafeCanonicalFile(workspaceURL, root: configuration.taskCheckpointRootURL, label: "Task Workspace")
        let registryData = try Data(contentsOf: registryURL)
        guard registryData == journal.registryPreimage else {
            throw TaskCheckpointValidationError.targetContractInvalid("Task Registry changed after the checkpoint was prepared.")
        }
        let workspaceData = try Data(contentsOf: workspaceURL)
        guard workspaceData == journal.workspaceExpectedAfter else {
            throw TaskCheckpointValidationError.targetContractInvalid("Workspace does not equal the journal-bound expected postimage.")
        }
        let registry = try TaskRegistryDocument(data: registryData)
        let row = try registry.uniqueRow(taskID: journal.taskID)
        guard targetFingerprint(row: row, workspacePath: journal.workspacePath) == journal.targetFingerprint else {
            throw TaskCheckpointValidationError.targetContractInvalid("The bound Task identity or Registry relationship changed.")
        }
        let before = try TaskWorkspaceDocument(data: journal.workspacePreimage)
        let after = try TaskWorkspaceDocument(data: workspaceData)
        try after.validateIdentityAndRelationships(taskID: journal.taskID, registryRow: row)
        try before.validateCheckpointPostimage(
            after, replacementData: workspaceData, stepID: journal.stepID,
            operationID: journal.operationUUID, evidence: journal.acceptedEvidence,
            nextStep: journal.nextStep, lastValidatedState: journal.lastValidatedState
        )
        return observeCanvas(taskID: journal.taskID, configuration: configuration)
    }

    private func reconcileReplacementException(
        journal: inout TaskCheckpointJournal,
        request: TaskCheckpointRequest,
        configuration: ProductionsConfiguration,
        replacementDiagnostic: String
    ) throws -> TaskCheckpointCommandResult {
        let durable: TaskCheckpointJournal
        do {
            guard let loaded = try journalStore.journal(operationID: journal.operationUUID) else {
                throw TaskCheckpointValidationError.targetContractInvalid("No recovery journal exists for the issued operation UUID.")
            }
            durable = loaded
        } catch {
            throw failure(
                outcome: "uncertain", operationID: journal.operationUUID, request: request,
                before: journal.workspaceSHA256Before, after: nil, registry: journal.registrySHA256,
                classification: "possible-commit", journalFinalized: false, fallbackRecorded: false,
                historicalCommitProven: false,
                diagnostic: "Replacement threw and the journal could not be read: \(error.localizedDescription). Do not retry automatically.",
                journalRootPath: journal.productionsRootPath, exitCode: 3
            )
        }
        journal = durable
        let currentWorkspace: Data
        let currentRegistry: Data
        do {
            try requireSafeCanonicalFile(configuration.taskCheckpointURL(journal.workspacePath), root: configuration.taskCheckpointRootURL, label: "Task Workspace")
            try requireSafeCanonicalFile(configuration.taskCheckpointURL(journal.registryPath), root: configuration.taskCheckpointRootURL, label: "Task Registry")
            currentWorkspace = try Data(contentsOf: configuration.taskCheckpointURL(journal.workspacePath))
            currentRegistry = try Data(contentsOf: configuration.taskCheckpointURL(journal.registryPath))
        } catch {
            return try finishUncertain(
                journal: &journal, request: request,
                diagnostic: "Replacement threw and canonical bytes could not be read: \(error.localizedDescription). Do not retry automatically."
            )
        }
        if currentWorkspace == journal.workspacePreimage, currentRegistry == journal.registryPreimage {
            return try finishDefiniteNoCommit(
                journal: &journal, request: request,
                diagnostic: "Replacement threw before publication; exact preimage and unchanged Registry prove no commit. \(replacementDiagnostic) Do not retry automatically."
            )
        }
        if currentWorkspace == journal.workspaceExpectedAfter, currentRegistry == journal.registryPreimage {
            do {
                _ = try fullyValidatePostimage(journal: journal, configuration: configuration)
                do {
                    journal.transition(to: .reconciledCommittedAndCurrent, diagnostic: "Replacement threw after publication; exact postimage and complete validation reconcile the commit. Do not retry automatically.", finalized: true)
                    try journalStore.update(journal)
                    return result(outcome: "committed", journal: journal, classification: "committed-and-current", canvasState: observeCanvas(taskID: journal.taskID, configuration: configuration), diagnostic: journal.diagnostic)
                } catch {
                    return try finishJournalFailure(
                        journal: &journal, request: request,
                        fallback: .journalFinalizationFailedCommittedAndCurrent,
                        classification: "committed-and-current",
                        diagnostic: "The reconciled commit is proven current, but journal finalization failed: \(error.localizedDescription)"
                    )
                }
            } catch {
                return try finishUncertain(journal: &journal, request: request, diagnostic: "Replacement may have published the expected bytes, but complete reload validation failed: \(error.localizedDescription). Do not retry automatically.")
            }
        }
        return try finishUncertain(journal: &journal, request: request, diagnostic: "Replacement threw and canonical state is partial, foreign, unreadable, or Registry-divergent. Do not retry automatically.")
    }

    private func finishDefiniteNoCommit(
        journal: inout TaskCheckpointJournal,
        request: TaskCheckpointRequest,
        diagnostic: String
    ) throws -> TaskCheckpointCommandResult {
        do {
            journal.transition(to: .definiteNoCommit, diagnostic: diagnostic, finalized: true)
            try journalStore.update(journal)
            return result(outcome: "not-committed", journal: journal, classification: "definite-no-commit", canvasState: nil, diagnostic: diagnostic)
        } catch {
            return try finishJournalFailure(
                journal: &journal, request: request,
                fallback: .journalFinalizationFailedDefiniteNoCommit,
                classification: "definite-no-commit",
                diagnostic: "No commit is proven, but normal terminal journal finalization failed: \(error.localizedDescription)"
            )
        }
    }

    private func finishUncertain(
        journal: inout TaskCheckpointJournal,
        request: TaskCheckpointRequest,
        diagnostic: String
    ) throws -> TaskCheckpointCommandResult {
        do {
            journal.transition(to: .uncertain, diagnostic: diagnostic, finalized: true)
            try journalStore.update(journal)
            return result(outcome: "uncertain", journal: journal, classification: "uncertain", canvasState: nil, diagnostic: diagnostic)
        } catch {
            throw failure(
                outcome: "uncertain", operationID: journal.operationUUID, request: request,
                before: journal.workspaceSHA256Before, after: nil, registry: journal.registrySHA256,
                classification: "uncertain", journalFinalized: false, fallbackRecorded: false,
                historicalCommitProven: false,
                diagnostic: "Canonical outcome and terminal journal state are uncertain: \(error.localizedDescription). Do not retry automatically.",
                journalRootPath: journal.productionsRootPath, exitCode: 3
            )
        }
    }

    private func finishProvenFailure(
        journal: inout TaskCheckpointJournal,
        request: TaskCheckpointRequest,
        state: OfficeWorkspaceTerminalState,
        classification: String,
        diagnostic: String
    ) throws -> TaskCheckpointCommandResult {
        do {
            journal.transition(to: state, diagnostic: diagnostic, finalized: true)
            try journalStore.update(journal)
            return result(outcome: "uncertain", journal: journal, classification: classification, canvasState: nil, diagnostic: diagnostic + " Do not retry automatically.")
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
        journal: inout TaskCheckpointJournal,
        request: TaskCheckpointRequest,
        fallback: OfficeWorkspaceTerminalState,
        classification: String,
        diagnostic: String
    ) throws -> TaskCheckpointCommandResult {
        var fallbackJournal = journal
        fallbackJournal.markFallback(fallback, diagnostic: diagnostic + " Do not retry automatically.")
        let fallbackRecorded: Bool
        do {
            try journalStore.recordFallback(fallbackJournal)
            journal = fallbackJournal
            fallbackRecorded = true
        } catch {
            fallbackRecorded = false
        }
        let proving = fallback.provesHistoricalCommit || journal.terminalState?.provesHistoricalCommit == true
        throw failure(
            outcome: proving ? "uncertain" : "not-committed",
            operationID: journal.operationUUID, request: request,
            before: journal.workspaceSHA256Before,
            after: proving ? journal.workspaceSHA256ExpectedAfter : nil,
            registry: journal.registrySHA256,
            classification: classification, journalFinalized: false,
            fallbackRecorded: fallbackRecorded, historicalCommitProven: proving,
            diagnostic: diagnostic + " Do not retry automatically.", journalRootPath: journal.productionsRootPath,
            exitCode: proving ? 3 : 2
        )
    }

    private func committedResult(journal: TaskCheckpointJournal, request: TaskCheckpointRequest, configuration: ProductionsConfiguration) -> TaskCheckpointCommandResult {
        result(
            outcome: "committed", journal: journal,
            classification: "committed-and-current",
            canvasState: observeCanvas(taskID: request.taskID, configuration: configuration),
            diagnostic: nil
        )
    }

    private func result(
        outcome: String,
        journal: TaskCheckpointJournal,
        classification: String,
        canvasState: String?,
        diagnostic: String?
    ) -> TaskCheckpointCommandResult {
        TaskCheckpointCommandResult(
            outcome: outcome,
            operationUUID: journal.operationUUID,
            taskID: journal.taskID,
            completedStep: journal.stepID,
            workspaceSHA256Before: journal.workspaceSHA256Before,
            workspaceSHA256After: outcome == "committed" || journal.terminalState?.provesHistoricalCommit == true ? journal.workspaceSHA256ExpectedAfter : nil,
            registrySHA256: journal.registrySHA256,
            nextGate: journal.nextStep,
            canvasState: canvasState,
            classification: classification,
            journalFinalized: journal.journalFinalized,
            fallbackRecorded: journal.fallbackRecorded,
            historicalCommitProven: journal.terminalState?.provesHistoricalCommit == true,
            inspectCommand: "OperationsDashboard office inspect --productions-root \(journal.productionsRootPath) --operation \(journal.operationUUID.uuidString)",
            diagnostic: diagnostic
        )
    }

    private func inspectionUncertain(journal: TaskCheckpointJournal, historicalProof: Bool, diagnostic: String) -> TaskCheckpointCommandResult {
        TaskCheckpointCommandResult(
            outcome: "uncertain", operationUUID: journal.operationUUID, taskID: journal.taskID,
            completedStep: journal.stepID, workspaceSHA256Before: journal.workspaceSHA256Before,
            workspaceSHA256After: historicalProof ? journal.workspaceSHA256ExpectedAfter : nil,
            registrySHA256: journal.registrySHA256, nextGate: journal.nextStep, canvasState: nil,
            classification: historicalProof ? "historically-committed-current-state-uncertain" : "uncertain",
            journalFinalized: journal.journalFinalized, fallbackRecorded: journal.fallbackRecorded,
            historicalCommitProven: historicalProof,
            inspectCommand: "OperationsDashboard office inspect --productions-root \(journal.productionsRootPath) --operation \(journal.operationUUID.uuidString)",
            diagnostic: diagnostic + " Do not retry automatically."
        )
    }

    private func failure(
        outcome: String,
        operationID: UUID?,
        request: TaskCheckpointRequest?,
        before: String? = nil,
        after: String? = nil,
        registry: String? = nil,
        classification: String,
        journalFinalized: Bool,
        fallbackRecorded: Bool,
        historicalCommitProven: Bool,
        diagnostic: String,
        journalRootPath: String? = nil,
        exitCode: Int32
    ) -> TaskCheckpointCommandFailure {
        TaskCheckpointCommandFailure(
            result: TaskCheckpointCommandResult(
                outcome: outcome, operationUUID: operationID, taskID: request?.taskID,
                completedStep: request?.unfinishedStep, workspaceSHA256Before: before,
                workspaceSHA256After: after, registrySHA256: registry,
                nextGate: request?.nextStep, canvasState: nil, classification: classification,
                journalFinalized: journalFinalized, fallbackRecorded: fallbackRecorded,
                historicalCommitProven: historicalCommitProven,
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
        case TaskCheckpointValidationError.hashMismatch: "hashMismatch"
        case TaskCheckpointValidationError.targetContractInvalid: "targetContractInvalid"
        case TaskCheckpointValidationError.invalidInput: "invalidInput"
        default: "not-committed"
        }
    }

    private func validateRequest(_ request: TaskCheckpointRequest) throws {
        guard request.taskID.range(of: #"^TASK-[0-9]{4,}$"#, options: .regularExpression) != nil else {
            throw TaskCheckpointValidationError.invalidInput("Task ID must be an exact durable Task identifier.")
        }
        guard request.unfinishedStep.range(of: #"^S[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw TaskCheckpointValidationError.invalidInput("Unfinished Step must match exact S## grammar.")
        }
        for (name, value) in [("Workspace hash", request.expectedWorkspaceSHA256), ("Registry hash", request.expectedRegistrySHA256)] {
            guard value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                throw TaskCheckpointValidationError.invalidInput("\(name) must be 64 lowercase hexadecimal characters.")
            }
        }
        guard !request.acceptedEvidence.isEmpty else {
            throw TaskCheckpointValidationError.invalidInput("At least one accepted-evidence value is required.")
        }
        for evidence in request.acceptedEvidence {
            let trimmed = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !evidence.contains("\n"), !evidence.contains("\r"),
                  !trimmed.hasPrefix("#"), !containsControl(evidence, permitsNewlines: false) else {
                throw TaskCheckpointValidationError.invalidInput("Accepted evidence must be one nonblank line without controls or Markdown headings.")
            }
        }
        for (name, value) in [("Next step", request.nextStep), ("Last validated state", request.lastValidatedState)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !containsControl(value, permitsNewlines: true) else {
                throw TaskCheckpointValidationError.invalidInput("\(name) must be complete nonblank UTF-8 text without disallowed controls.")
            }
        }
    }

    private func containsControl(_ value: String, permitsNewlines: Bool) -> Bool {
        value.unicodeScalars.contains { scalar in
            if permitsNewlines, scalar.value == 10 { return false }
            return scalar.value < 32 || scalar.value == 127
        }
    }

    private func requireSafeCanonicalFile(_ url: URL, root: URL, label: String) throws {
        let rootPath = root.path
        let target = url
        guard TaskCheckpointUTF8.hasPrefix(target.path, rootPath + "/") else {
            throw TaskCheckpointValidationError.targetContractInvalid("\(label) is outside the configured Productions root.")
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in target.pathComponents.dropFirst() {
            guard let entries = try? manager.contentsOfDirectory(atPath: current.path),
                  entries.contains(where: { TaskCheckpointUTF8.equal($0, component) }) else {
                throw TaskCheckpointValidationError.targetContractInvalid(
                    "\(label) path does not use exact canonical spelling at \(current.appending(path: component).path)."
                )
            }
            current.append(path: component)
            if (try? manager.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw TaskCheckpointValidationError.targetContractInvalid("\(label) path contains a symbolic link at \(current.path).")
            }
        }
        var status = stat()
        guard lstat(target.path, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              manager.isReadableFile(atPath: target.path) else {
            throw TaskCheckpointValidationError.targetContractInvalid("\(label) is not a readable regular file.")
        }
    }

    private func observeCanvas(taskID: String, configuration: ProductionsConfiguration) -> String {
        guard let data = try? Data(contentsOf: configuration.taskCheckpointURL(ProductionsPath.canvas.rawValue)),
              let parsed = try? CanvasMarkdown.parse(String(decoding: data, as: UTF8.self)),
              !parsed.isFragmented else { return "unknown" }
        let boundary = parsed.rows.last(where: { $0["Work ID"] == taskID && ["Placed", "Cleared"].contains($0["Event"] ?? "") })?["Event"]
        return boundary == "Placed" ? "focused" : "clear"
    }

    private func targetFingerprint(row: [String: String], workspacePath: String) -> String {
        let ordered = TaskRegistryDocument.headers.map { "\($0)=\(row[$0] ?? "")" }.joined(separator: "\u{1f}")
        return hash(Data((ordered + "\u{1e}" + workspacePath).utf8))
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct TaskRegistryDocument {
    static let headers = ["Task ID", "Title", "State", "Priority", "Current lead", "Initiative", "Project", "Depends on", "Review after", "Short description", "Workspace"]
    let rows: [[String: String]]

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\r") else {
            throw TaskCheckpointValidationError.targetContractInvalid("Task Registry must be valid LF-only UTF-8.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let exactHeader = "| " + Self.headers.joined(separator: " | ") + " |"
        let exactDelimiter = "| " + Array(repeating: "---", count: Self.headers.count).joined(separator: " | ") + " |"
        let headerIndices = lines.indices.filter { lines[$0] == exactHeader }
        guard headerIndices.count == 1, let header = headerIndices.first, header + 1 < lines.count else {
            throw TaskCheckpointValidationError.targetContractInvalid("Task Registry must contain one exact v1.12 header.")
        }
        guard lines[header + 1] == exactDelimiter else {
            throw TaskCheckpointValidationError.targetContractInvalid("Task Registry delimiter width does not match its header.")
        }
        var parsed: [[String: String]] = []
        var index = header + 2
        while index < lines.count, lines[index].hasPrefix("|") {
            let values = MarkdownTable.cells(lines[index])
            guard values.count == Self.headers.count else {
                throw TaskCheckpointValidationError.targetContractInvalid("Task Registry contains a row with the wrong field count.")
            }
            parsed.append(Dictionary(uniqueKeysWithValues: zip(Self.headers, values)))
            index += 1
        }
        for later in lines.dropFirst(index) where later.range(of: #"^\|\s*TASK-[0-9]{4,}\s*\|"#, options: .regularExpression) != nil {
            throw TaskCheckpointValidationError.targetContractInvalid("Task Registry contains a hidden or fragmented later Task row.")
        }
        rows = parsed
    }

    func uniqueRow(taskID: String) throws -> [String: String] {
        let row = try identityRow(taskID: taskID)
        guard !(row["State"] ?? "").hasPrefix("Done") else {
            throw TaskCheckpointValidationError.targetContractInvalid("Task lifecycle is not checkpoint-eligible.")
        }
        return row
    }

    func identityRow(taskID: String) throws -> [String: String] {
        let matches = rows.filter { $0["Task ID"] == taskID }
        guard matches.count == 1, let row = matches.first else {
            throw TaskCheckpointValidationError.targetContractInvalid("Task Registry must contain exactly one row for \(taskID).")
        }
        let states = ["Active / Current", "Active / Paused", "Active / Blocked", "Pending / Review", "Pending / Deferred", "Done / Complete", "Done / Obsolete"]
        let priorities = ["Highest", "High", "Medium", "Low", "Unranked"]
        guard states.contains(row["State"] ?? ""),
              priorities.contains(row["Priority"] ?? ""), !(row["Current lead"] ?? "").isEmpty else {
            throw TaskCheckpointValidationError.targetContractInvalid("Task lifecycle, priority, or current lead is invalid.")
        }
        return row
    }
}

struct TaskWorkspaceDocument {
    private let lines: [String]
    private let finalNewline: Bool
    private let topLevelTitle: String
    private let sections: [String: Range<Int>]
    private let coreFields: [String: Range<Int>]
    private let stepLines: [String: (index: Int, checked: Bool)]
    let data: Data

    init(data: Data) throws {
        guard let text = String(data: data, encoding: .utf8), !text.contains("\r") else {
            throw TaskCheckpointValidationError.targetContractInvalid("Task Workspace must be valid LF-only UTF-8.")
        }
        self.data = data
        finalNewline = text.hasSuffix("\n")
        lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var headings: [(String, Int)] = []
        var h1Titles: [String] = []
        var insideFence = false
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            guard !insideFence else { continue }
            if line.hasPrefix("# "), !line.hasPrefix("## ") {
                h1Titles.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("## "), !line.hasPrefix("### ") {
                headings.append((String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), index))
            }
        }
        guard h1Titles.count == 1, let h1 = h1Titles.first, !h1.isEmpty else {
            throw TaskCheckpointValidationError.targetContractInvalid("Workspace must contain exactly one non-fenced top-level H1 title.")
        }
        topLevelTitle = h1
        let grouped = Dictionary(grouping: headings, by: { $0.0 })
        if let duplicate = grouped.first(where: { $0.value.count > 1 }) {
            throw TaskCheckpointValidationError.targetContractInvalid("Duplicate Workspace section: \(duplicate.key).")
        }
        var ranges: [String: Range<Int>] = [:]
        for (offset, heading) in headings.enumerated() {
            ranges[heading.0] = (heading.1 + 1)..<(offset + 1 < headings.count ? headings[offset + 1].1 : lines.count)
        }
        guard ranges["Core Record"] != nil, ranges["Steps"] != nil else {
            throw TaskCheckpointValidationError.targetContractInvalid("Workspace requires unique Core Record and Steps sections.")
        }
        sections = ranges

        var fields: [String: Range<Int>] = [:]
        let coreRange = ranges["Core Record"]!
        let fieldPattern = try! NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z0-9, /()_-]*):"#)
        var fieldStarts: [(String, Int)] = []
        for index in coreRange {
            let line = lines[index]
            let ns = line as NSString
            guard let match = fieldPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            fieldStarts.append((ns.substring(with: match.range(at: 1)), index))
        }
        let fieldGroups = Dictionary(grouping: fieldStarts, by: { $0.0 })
        if let duplicate = fieldGroups.first(where: { $0.value.count > 1 }) {
            throw TaskCheckpointValidationError.targetContractInvalid("Duplicate Core Record field: \(duplicate.key).")
        }
        for (offset, field) in fieldStarts.enumerated() {
            fields[field.0] = field.1..<(offset + 1 < fieldStarts.count ? fieldStarts[offset + 1].1 : coreRange.upperBound)
        }
        coreFields = fields

        let stepPattern = try! NSRegularExpression(pattern: #"^- \[([ xX])\] \*\*(S[0-9]{2})\b"#)
        var steps: [String: (Int, Bool)] = [:]
        for index in ranges["Steps"]! {
            let line = lines[index], ns = line as NSString
            guard let match = stepPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let id = ns.substring(with: match.range(at: 2))
            guard steps[id] == nil else {
                throw TaskCheckpointValidationError.targetContractInvalid("Duplicate Workspace Step key \(id).")
            }
            steps[id] = (index, ns.substring(with: match.range(at: 1)) != " ")
        }
        stepLines = steps
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

    func validateIdentityAndRelationships(taskID: String, registryRow: [String: String]) throws {
        let exact: [(String, String)] = [
            ("Title", registryRow["Title"] ?? ""), ("ID", taskID), ("Type", "Task"),
            ("Current lead", registryRow["Current lead"] ?? ""), ("Status source", "Office/Registry/Tasks.md"),
        ]
        guard exact.allSatisfy({ !$0.1.isEmpty && field($0.0) == $0.1 }) else {
            throw TaskCheckpointValidationError.targetContractInvalid("Workspace identity, title, lead, type, or status source disagrees with the Task Registry.")
        }
        guard topLevelTitle == registryRow["Title"] else {
            throw TaskCheckpointValidationError.targetContractInvalid("Workspace top-level H1 title disagrees with the Task Registry and Core Title.")
        }
        for name in ["Initiative", "Project"] {
            guard normalizedRelationship(field(name)) == normalizedRelationship(registryRow[name] ?? "") else {
                throw TaskCheckpointValidationError.targetContractInvalid("Workspace \(name) disagrees with the Task Registry.")
            }
        }
        guard normalizedDependencies(field("Depends on")) == normalizedDependencies(registryRow["Depends on"] ?? "") else {
            throw TaskCheckpointValidationError.targetContractInvalid("Workspace Depends on identifiers disagree with the Task Registry.")
        }
    }

    func checkpointReplacement(
        stepID: String,
        operationID: UUID,
        timestamp: Date,
        evidence: [String],
        nextStep: String,
        lastValidatedState: String
    ) throws -> Data {
        let targetPattern = try! NSRegularExpression(pattern: #"\b"# + NSRegularExpression.escapedPattern(for: stepID) + #"\b"#)
        let targetOccurrences = sections["Steps"]!.reduce(into: 0) { count, index in
            let line = lines[index]
            count += targetPattern.numberOfMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length))
        }
        guard targetOccurrences == 1 else {
            throw TaskCheckpointValidationError.targetContractInvalid("The requested Step ID must occur exactly once in the Steps section, including malformed Step-like lines.")
        }
        guard let step = stepLines[stepID], !step.checked else {
            throw TaskCheckpointValidationError.targetContractInvalid("The exact requested Workspace Step is absent or already checked.")
        }
        guard coreFields["Next step"] != nil, coreFields["Last validated state"] != nil else {
            throw TaskCheckpointValidationError.targetContractInvalid("Workspace Core Record lacks a unique Next step or Last validated state field.")
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stanza = [
            "### \(stepID) - \(operationID.uuidString)", "",
            "Recorded: \(formatter.string(from: timestamp))", "", "Accepted evidence:", "",
        ] + evidence.map { "- \($0)" }
        var edits: [(range: Range<Int>, replacement: [String])] = [
            (step.index..<(step.index + 1), [lines[step.index].replacingOccurrences(of: "- [ ]", with: "- [x]", options: [.anchored])]),
            (coreFields["Next step"]!, replacementLines(field: "Next step", value: nextStep)),
            (coreFields["Last validated state"]!, replacementLines(field: "Last validated state", value: lastValidatedState)),
        ]
        if let evidenceRange = sections["Checkpoint Evidence"] {
            let atDocumentEnd = evidenceRange.upperBound == lines.count
            let insertion = atDocumentEnd && finalNewline && lines.last == "" ? lines.count - 1 : evidenceRange.upperBound
            let leading = insertion > evidenceRange.lowerBound && lines[insertion - 1] != "" ? [""] : []
            let trailing = atDocumentEnd ? [] : [""]
            edits.append((insertion..<insertion, leading + stanza + trailing))
        } else {
            let insertion = finalNewline && lines.last == "" ? lines.count - 1 : lines.count
            let leading = insertion > 0 && lines[insertion - 1] != "" ? [""] : []
            edits.append((insertion..<insertion, leading + ["## Checkpoint Evidence", ""] + stanza))
        }
        var output = lines
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            output.replaceSubrange(edit.range, with: edit.replacement)
        }
        return Data(output.joined(separator: "\n").utf8)
    }

    func validateCheckpointPostimage(
        _ after: TaskWorkspaceDocument,
        replacementData: Data,
        stepID: String,
        operationID: UUID,
        evidence: [String],
        nextStep: String,
        lastValidatedState: String
    ) throws {
        guard after.stepLines[stepID]?.checked == true,
              after.field("Next step") == nextStep,
              after.field("Last validated state") == lastValidatedState else {
            throw TaskCheckpointValidationError.targetContractInvalid("Prepared checkpoint does not contain the exact requested Step and Core replacements.")
        }
        for (otherID, before) in stepLines where otherID != stepID {
            guard after.stepLines[otherID]?.checked == before.checked else {
                throw TaskCheckpointValidationError.targetContractInvalid("Prepared checkpoint changed an unrelated Step.")
            }
        }
        let text = String(decoding: replacementData, as: UTF8.self)
        let heading = "### \(stepID) - \(operationID.uuidString)"
        guard text.components(separatedBy: heading).count == 2 else {
            throw TaskCheckpointValidationError.targetContractInvalid("Prepared checkpoint must contain exactly one operation evidence stanza.")
        }
        var cursor = text.range(of: heading)!.upperBound
        for value in evidence {
            guard let range = text.range(of: "- \(value)", range: cursor..<text.endIndex) else {
                throw TaskCheckpointValidationError.targetContractInvalid("Prepared checkpoint evidence is missing or out of order.")
            }
            cursor = range.upperBound
        }
        let rebuilt = try checkpointReplacement(
            stepID: stepID, operationID: operationID,
            timestamp: extractTimestamp(from: text, operationHeading: heading), evidence: evidence,
            nextStep: nextStep, lastValidatedState: lastValidatedState
        )
        guard rebuilt == replacementData else {
            throw TaskCheckpointValidationError.targetContractInvalid("Prepared checkpoint changed bytes outside the authorized editor regions.")
        }
    }

    private func replacementLines(field name: String, value: String) -> [String] {
        let valueLines = value.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return ["\(name): \(valueLines.first ?? "")"] + valueLines.dropFirst()
    }

    private func normalizedRelationship(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "—" { return "—" }
        if let id = trimmed.range(of: #"^(INIT|PROJ)-[0-9]{4,}"#, options: .regularExpression) {
            return String(trimmed[id])
        }
        return trimmed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func normalizedDependencies(_ value: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"TASK-[0-9]{4,}"#)
        return value.split(separator: ";").map { raw in
            let item = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = item as NSString
            if let match = pattern.firstMatch(in: item, range: NSRange(location: 0, length: ns.length)) {
                return ns.substring(with: match.range)
            }
            return item.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty && $0 != "—" }
    }

    private func extractTimestamp(from text: String, operationHeading: String) throws -> Date {
        guard let heading = text.range(of: operationHeading),
              let recorded = text.range(of: "Recorded: ", range: heading.upperBound..<text.endIndex),
              let end = text[recorded.upperBound...].firstIndex(of: "\n") else {
            throw TaskCheckpointValidationError.targetContractInvalid("Prepared checkpoint evidence timestamp is malformed.")
        }
        let raw = String(text[recorded.upperBound..<end])
        guard let date = ISO8601DateFormatter().date(from: raw) else {
            throw TaskCheckpointValidationError.targetContractInvalid("Prepared checkpoint evidence timestamp is malformed.")
        }
        return date
    }
}
