import CryptoKit
import Darwin
import Foundation

/// TASK-0040's only Productions write capability. It replaces only the
/// Identifier Ledger and Flow files; an Inbox payload is never mutated.
struct FlowRegistrationMetadata: Equatable, Sendable {
    var label: String
    var type: String
    var summary: String
    var nextDisposition: String
    var priority = "Unranked"
    var steward = "Office"
    var department = "Unassigned"
    var product = "—"
    var source = "—"
    var relatedWork = "—"
}

enum FlowRegistrationTerminalState: String, Codable, Equatable {
    case preCommitFailure, ledgerCommitted, bothFilesCommitted, bothCommittedReloadFailed
}

struct FlowRegistrationJournal: Codable, Equatable {
    let transactionID: UUID
    let timestamp: Date
    let payloadPath: String
    let flowID: String
    let ledgerHash: String
    let flowHash: String
    let ledgerPreimage: Data
    let flowPreimage: Data
    var terminalState: FlowRegistrationTerminalState?
    var diagnostic: String?
}

enum FlowRegistrationError: LocalizedError, Equatable {
    case ineligible(String), invalidMetadata(String), conflict(String), lockUnavailable
    case journalFailed(String), ledgerWriteFailed(String), flowWriteFailed(String), reloadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .ineligible(message), let .invalidMetadata(message), let .conflict(message),
             let .journalFailed(message), let .ledgerWriteFailed(message),
             let .flowWriteFailed(message), let .reloadFailed(message): return message
        case .lockUnavailable: return "Another Productions write transaction is in progress."
        }
    }
}

struct FlowRegistrationPreview: Equatable {
    let flowID: String
    let row: String
    let payloadPath: String
    let payloadState: FlowRegistrationPayloadState
    let ledgerHash: String
    let flowHash: String
}

/// Exact lstat snapshot of the Inbox payload that a Flow preview selected.
/// Commit must revalidate it under the transaction lock before issuing an ID.
struct FlowRegistrationPayloadState: Codable, Equatable {
    let mode: UInt32
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
}

protocol FlowRegistrationJournalStore {
    func persist(_ journal: FlowRegistrationJournal) throws
    func update(_ journal: FlowRegistrationJournal) throws
    func incomplete() throws -> [FlowRegistrationJournal]
}

protocol AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws
}

/// The durable replacement protocol is intentionally narrow so tests can
/// exercise each interruption boundary without touching Productions.
struct DurableReplacement: AtomicFileReplacing {
    let manager: FileManager
    init(manager: FileManager = .default) { self.manager = manager }

    func replace(data: Data, at target: URL) throws {
        let directory = target.deletingLastPathComponent()
        let temporary = directory.appending(path: ".\(target.lastPathComponent).tmp-\(UUID().uuidString)")
        let mode = (try? manager.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let fileDescriptor = open(temporary.path, O_RDONLY)
        guard fileDescriptor >= 0 else { try? manager.removeItem(at: temporary); throw CocoaError(.fileWriteUnknown) }
        defer { close(fileDescriptor) }
        guard fsync(fileDescriptor) == 0 else { try? manager.removeItem(at: temporary); throw CocoaError(.fileWriteUnknown) }
        guard rename(temporary.path, target.path) == 0 else { try? manager.removeItem(at: temporary); throw CocoaError(.fileWriteUnknown) }
        let directoryDescriptor = open(directory.path, O_RDONLY)
        guard directoryDescriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct ApplicationSupportFlowRegistrationJournalStore: FlowRegistrationJournalStore {
    private let manager = FileManager.default
    private var directory: URL {
        manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/Flow Registration Recovery", directoryHint: .isDirectory)
    }

    func persist(_ journal: FlowRegistrationJournal) throws { try write(journal) }
    func update(_ journal: FlowRegistrationJournal) throws { try write(journal) }
    func incomplete() throws -> [FlowRegistrationJournal] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            let journal = try JSONDecoder().decode(FlowRegistrationJournal.self, from: Data(contentsOf: url))
            return journal.terminalState == .bothFilesCommitted || journal.terminalState == .bothCommittedReloadFailed ? nil : journal
        }
    }

    private func write(_ journal: FlowRegistrationJournal) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "\(journal.transactionID.uuidString).json")
        let bytes = try JSONEncoder().encode(journal)
        try DurableReplacement(manager: manager).replace(data: bytes, at: target)
    }
}

protocol FlowRegistrationLocking {
    func acquire(ledgerURL: URL) -> AnyObject?
}

private final class ProductionsWriteLock: NSObject {
    private let descriptor: Int32
    init?(ledgerURL: URL) {
        descriptor = open(ledgerURL.path, O_RDWR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            return nil
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

struct LocalFlowRegistrationLocking: FlowRegistrationLocking {
    func acquire(ledgerURL: URL) -> AnyObject? { ProductionsWriteLock(ledgerURL: ledgerURL) }
}

struct FlowRegistrationService {
    let journalStore: any FlowRegistrationJournalStore
    let manager: FileManager
    let replacer: any AtomicFileReplacing
    let locking: any FlowRegistrationLocking
    let now: () -> Date

    init(journalStore: any FlowRegistrationJournalStore = ApplicationSupportFlowRegistrationJournalStore(), manager: FileManager = .default, replacer: (any AtomicFileReplacing)? = nil, locking: any FlowRegistrationLocking = LocalFlowRegistrationLocking(), now: @escaping () -> Date = Date.init) {
        self.journalStore = journalStore
        self.manager = manager
        self.replacer = replacer ?? DurableReplacement(manager: manager)
        self.locking = locking
        self.now = now
    }

    /// Startup only reports recoverable diagnostics. It never retries or rolls
    /// back an incomplete transaction, because a committed identifier is retired.
    func startupRecovery() -> [FlowRegistrationJournal] { (try? journalStore.incomplete()) ?? [] }

    /// The human Inbox intake path establishes custody only. Enrichment remains
    /// possible for authorized callers through the regular metadata argument.
    func automaticDefaults(configuration: ProductionsConfiguration, payload: FlowItem) throws -> FlowRegistrationMetadata {
        let path = try eligiblePayload(payload, paths: Paths(configuration))
        let url = configuration.rootURL.appending(path: path)
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw FlowRegistrationError.ineligible("Inbox payload no longer exists.") }
        let type = (status.st_mode & S_IFMT) == S_IFDIR ? "Unclassified folder" : "Unclassified file"
        return FlowRegistrationMetadata(
            label: url.lastPathComponent,
            type: type,
            summary: "Unclassified Inbox payload awaiting review.",
            nextDisposition: "Review and route to Processing or a durable destination.",
            priority: "Unranked",
            steward: "Office",
            department: "Unassigned",
            product: "Unassigned",
            source: "Inbox filesystem intake",
            relatedWork: "—"
        )
    }

    func preview(configuration: ProductionsConfiguration, payload: FlowItem, metadata: FlowRegistrationMetadata) throws -> FlowRegistrationPreview {
        try validate(metadata)
        let paths = Paths(configuration)
        let payloadPath = try eligiblePayload(payload, paths: paths)
        let payloadState = try payloadState(at: paths.root.appending(path: payloadPath))
        let ledger = try Data(contentsOf: paths.ledger)
        let flow = try Data(contentsOf: paths.flow)
        guard !flowReferences(payloadPath, in: String(decoding: flow, as: UTF8.self)) else { throw FlowRegistrationError.conflict("The Inbox payload is already registered.") }
        let id = try nextFlowID(in: String(decoding: ledger, as: UTF8.self))
        let row = try makeRow(id: id, payloadPath: payloadPath, metadata: metadata, timestamp: now())
        try validateFlowReplacement(try append(row: row, to: String(decoding: flow, as: UTF8.self)), appendedRow: row)
        return FlowRegistrationPreview(flowID: id, row: row, payloadPath: payloadPath, payloadState: payloadState, ledgerHash: hash(ledger), flowHash: hash(flow))
    }

    /// Must be called only after the exact preview has received final user confirmation.
    func commit(configuration: ProductionsConfiguration, payload: FlowItem, metadata: FlowRegistrationMetadata, preview: FlowRegistrationPreview, expectedPayloadState: FlowRegistrationPayloadState, reload: (ProductionsConfiguration) -> ProductionsState) throws {
        try validate(metadata)
        let paths = Paths(configuration)
        guard let lock = locking.acquire(ledgerURL: paths.ledger) else { throw FlowRegistrationError.lockUnavailable }
        defer { _ = lock }
        let timestamp = now() // one timestamp, captured while holding the exclusive lock
        do {
                let payloadPath = try eligiblePayload(payload, paths: paths)
                guard payloadPath == preview.payloadPath else { throw FlowRegistrationError.conflict("The selected Inbox payload changed.") }
                guard expectedPayloadState == preview.payloadState,
                      try payloadState(at: paths.root.appending(path: payloadPath)) == expectedPayloadState else {
                    throw FlowRegistrationError.conflict("The selected Inbox payload filesystem state changed since preview.")
                }
                let ledger = try Data(contentsOf: paths.ledger)
                let flow = try Data(contentsOf: paths.flow)
                guard hash(ledger) == preview.ledgerHash, hash(flow) == preview.flowHash else {
                    throw FlowRegistrationError.conflict("Identifier Ledger or Flow changed since preview.")
                }
                let flowID = try nextFlowID(in: String(decoding: ledger, as: UTF8.self))
                guard flowID == preview.flowID else { throw FlowRegistrationError.conflict("FLOW high-water changed since preview.") }
                guard !flowReferences(payloadPath, in: String(decoding: flow, as: UTF8.self)) else { throw FlowRegistrationError.conflict("The Inbox payload is already registered.") }

                let row = try makeRow(id: flowID, payloadPath: payloadPath, metadata: metadata, timestamp: timestamp)
                let nextLedger = try incrementFlowCounter(in: String(decoding: ledger, as: UTF8.self), to: flowID)
                let nextFlow = try append(row: row, to: String(decoding: flow, as: UTF8.self))
                try validateFlowReplacement(nextFlow, appendedRow: row)

                var journal = FlowRegistrationJournal(transactionID: UUID(), timestamp: timestamp, payloadPath: payloadPath, flowID: flowID, ledgerHash: hash(ledger), flowHash: hash(flow), ledgerPreimage: ledger, flowPreimage: flow, terminalState: nil, diagnostic: nil)
                do { try journalStore.persist(journal) }
                catch { throw FlowRegistrationError.journalFailed("Could not persist recovery journal: \(error.localizedDescription)") }

                do { try replacer.replace(data: Data(nextLedger.utf8), at: paths.ledger) }
                catch {
                    journal.terminalState = .preCommitFailure
                    journal.diagnostic = "Identifier Ledger replacement failed: \(error.localizedDescription)"
                    try? journalStore.update(journal)
                    throw FlowRegistrationError.ledgerWriteFailed(journal.diagnostic!)
                }

                journal.terminalState = .ledgerCommitted
                journal.diagnostic = "Identifier Ledger committed; FLOW ID is permanently retired unless Flow commits."
                try? journalStore.update(journal)

                do { try replacer.replace(data: Data(nextFlow.utf8), at: paths.flow) }
                catch {
                    journal.diagnostic = "Identifier Ledger committed; Flow replacement failed. \(error.localizedDescription)"
                    try? journalStore.update(journal)
                    throw FlowRegistrationError.flowWriteFailed(journal.diagnostic!)
                }

                journal.terminalState = .bothFilesCommitted
                journal.diagnostic = nil
                try? journalStore.update(journal)
                let state = reload(configuration)
                guard state.issues.isEmpty else {
                    journal.terminalState = .bothCommittedReloadFailed
                    journal.diagnostic = state.issues.map(\.message).joined(separator: " · ")
                    try? journalStore.update(journal)
                    throw FlowRegistrationError.reloadFailed("Registration committed but contract reload needs investigation: \(journal.diagnostic!)")
                }
        }
    }

    private struct Paths {
        let root: URL
        let inbox, flow, ledger: URL
        init(_ configuration: ProductionsConfiguration) {
            root = configuration.rootURL
            inbox = configuration.url("Office/Inbox", directory: true)
            flow = configuration.url("Office/Flow.md")
            ledger = configuration.url("Warehouse/Reference/Identifier Ledger.md")
        }
    }

    private func eligiblePayload(_ payload: FlowItem, paths: Paths) throws -> String {
        guard payload.isUnregistered else { throw FlowRegistrationError.ineligible("Only Unregistered Inbox payloads can be registered.") }
        let prefix = "Office/Inbox/"
        guard payload.stage == "Inbox", payload.location.hasPrefix(prefix) else { throw FlowRegistrationError.ineligible("Payload is not an immediate Inbox item.") }
        let name = String(payload.location.dropFirst(prefix.count))
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw FlowRegistrationError.ineligible("Hidden or nested Inbox payloads cannot be registered.") }
        let url = paths.root.appending(path: payload.location)
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw FlowRegistrationError.ineligible("Inbox payload no longer exists.") }
        guard (status.st_mode & S_IFMT) != S_IFLNK else { throw FlowRegistrationError.ineligible("Inbox symlinks cannot be registered.") }
        return payload.location
    }

    private func payloadState(at url: URL) throws -> FlowRegistrationPayloadState {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw FlowRegistrationError.ineligible("Inbox payload no longer exists.") }
        return FlowRegistrationPayloadState(mode: UInt32(status.st_mode), device: UInt64(status.st_dev), inode: UInt64(status.st_ino), size: Int64(status.st_size), modifiedSeconds: Int64(status.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(status.st_mtimespec.tv_nsec))
    }

    private func validate(_ metadata: FlowRegistrationMetadata) throws {
        for value in [metadata.label, metadata.type, metadata.summary, metadata.nextDisposition, metadata.priority, metadata.steward, metadata.department, metadata.product, metadata.source, metadata.relatedWork] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw FlowRegistrationError.invalidMetadata("Required registration metadata is missing.") }
            guard !value.contains("|"), !value.contains("\n"), !value.contains("\r"), !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw FlowRegistrationError.invalidMetadata("Registration metadata cannot contain table-breaking characters.") }
        }
    }

    private func nextFlowID(in ledger: String) throws -> String {
        guard let row = ledger.split(separator: "\n").map(String.init).first(where: { $0.contains("| Inbox / routing entry | FLOW |") }) else { throw FlowRegistrationError.conflict("FLOW high-water counter is unavailable.") }
        let cells = MarkdownTable.cells(row)
        guard cells.count >= 4, let number = Int(cells[3].trimmingCharacters(in: .whitespaces)) else { throw FlowRegistrationError.conflict("FLOW high-water counter is malformed.") }
        return String(format: "FLOW-%06d", number + 1)
    }

    private func incrementFlowCounter(in ledger: String, to id: String) throws -> String {
        let number = Int(id.dropFirst("FLOW-".count))!
        var found = false
        let replaced = ledger.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let text = String(line)
            guard text.contains("| Inbox / routing entry | FLOW |") else { return text }
            var cells = MarkdownTable.cells(text)
            guard cells.count >= 5 else { return text }
            cells[3] = "\(number)"
            cells[4] = "`FLOW-\(String(format: "%06d", number + 1))`"
            found = true
            return "| " + cells.joined(separator: " | ") + " |"
        }.joined(separator: "\n")
        guard found else { throw FlowRegistrationError.conflict("FLOW high-water counter changed.") }
        return ledger.hasSuffix("\n") ? replaced + "\n" : replaced
    }

    private func makeRow(id: String, payloadPath: String, metadata: FlowRegistrationMetadata, timestamp: Date) throws -> String {
        let date = ISO8601DateFormatter().string(from: timestamp)
        let cells = [id, metadata.label, metadata.type, "Inbox", metadata.priority, metadata.steward, metadata.department, metadata.product, metadata.source, metadata.relatedWork, "`\(payloadPath)`", metadata.summary, metadata.nextDisposition, date, date]
        guard cells.count == 15 else { throw FlowRegistrationError.invalidMetadata("Flow schema is invalid.") }
        return "| " + cells.joined(separator: " | ") + " |"
    }

    private struct FlowLine {
        let content: String
        let range: Range<String.Index>
        let terminator: String
    }

    private struct FlowTableLayout {
        let lines: [FlowLine]
        let headerIndex: Int
        let separatorIndex: Int
        let boundaryIndex: Int

        var dataRange: Range<Int> { (separatorIndex + 1)..<boundaryIndex }
    }

    private var expectedFlowHeader: [String] {
        ["Entry ID", "Label", "Type", "Stage", "Priority", "Steward", "Department", "Product", "Source", "Related work", "Location", "Summary", "Next disposition", "Created", "Updated"]
    }

    private func append(row: String, to flow: String) throws -> String {
        let table = try flowTable(in: flow)
        let precedingLine = table.lines[table.boundaryIndex - 1]
        let tableLineEnding = table.lines[table.headerIndex].terminator.isEmpty
            ? table.lines[table.separatorIndex].terminator
            : table.lines[table.headerIndex].terminator
        let lineEnding = precedingLine.terminator.isEmpty
            ? (tableLineEnding.isEmpty ? "\n" : tableLineEnding)
            : precedingLine.terminator
        let insertion = precedingLine.terminator.isEmpty ? lineEnding + row : row + lineEnding
        var replacement = flow
        replacement.insert(contentsOf: insertion, at: precedingLine.range.upperBound)
        return replacement
    }

    private func validateFlowReplacement(_ flow: String, appendedRow: String) throws {
        guard MarkdownTable.cells(appendedRow).count == expectedFlowHeader.count else {
            throw FlowRegistrationError.invalidMetadata("Every Flow row must contain exactly 15 columns in the required schema.")
        }
        let table = try flowTable(in: flow)
        let occurrences = table.lines.enumerated().filter { $0.element.content == appendedRow }
        guard occurrences.count == 1, table.dataRange.contains(occurrences[0].offset) else {
            throw FlowRegistrationError.invalidMetadata("The appended Flow row must occur exactly once inside the canonical Flow table.")
        }
    }

    private func flowTable(in flow: String) throws -> FlowTableLayout {
        let lines = flowLines(in: flow)
        let flowHeaderIndexes = lines.indices.filter { index in
            let line = lines[index].content
            guard line.hasPrefix("|"), line.hasSuffix("|") else { return false }
            let cells = MarkdownTable.cells(line)
            return cells.count == expectedFlowHeader.count && Set(cells) == Set(expectedFlowHeader)
        }
        guard flowHeaderIndexes.count == 1,
              let headerIndex = flowHeaderIndexes.first,
              MarkdownTable.cells(lines[headerIndex].content) == expectedFlowHeader else {
            throw FlowRegistrationError.invalidMetadata("Flow must contain exactly one canonical 15-column table header.")
        }

        let separatorIndex = headerIndex + 1
        guard lines.indices.contains(separatorIndex), isCanonicalSeparator(lines[separatorIndex].content) else {
            throw FlowRegistrationError.invalidMetadata("The canonical Flow table separator is missing or malformed.")
        }

        var boundaryIndex = separatorIndex + 1
        while lines.indices.contains(boundaryIndex) {
            let line = lines[boundaryIndex].content
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { break }
            guard line.hasPrefix("|"), line.hasSuffix("|") else {
                throw FlowRegistrationError.invalidMetadata("The canonical Flow table has a noncanonical boundary.")
            }
            let cells = MarkdownTable.cells(line)
            guard cells.count == expectedFlowHeader.count,
                  cells != expectedFlowHeader,
                  !isSeparator(cells) else {
                throw FlowRegistrationError.invalidMetadata("Every Flow row must contain exactly 15 columns in the required schema.")
            }
            boundaryIndex += 1
        }

        let tableRange = headerIndex..<boundaryIndex
        for index in lines.indices where !tableRange.contains(index) {
            let line = lines[index].content.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("|"), line.hasSuffix("|"), let identifier = MarkdownTable.cells(line).first else { continue }
            if identifier.range(of: #"^(FLOW|BND)-[0-9]{6,}$"#, options: .regularExpression) != nil {
                throw FlowRegistrationError.invalidMetadata("A Flow data row occurs outside the canonical Flow table.")
            }
        }

        return FlowTableLayout(lines: lines, headerIndex: headerIndex, separatorIndex: separatorIndex, boundaryIndex: boundaryIndex)
    }

    private func isCanonicalSeparator(_ line: String) -> Bool {
        line.hasPrefix("|") && line.hasSuffix("|") && isSeparator(MarkdownTable.cells(line))
    }

    private func isSeparator(_ cells: [String]) -> Bool {
        cells.count == expectedFlowHeader.count && cells.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }

    private func flowLines(in text: String) -> [FlowLine] {
        var lines: [FlowLine] = []
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            var contentEnd = lineStart
            while contentEnd < text.endIndex, !text[contentEnd].isNewline {
                contentEnd = text.index(after: contentEnd)
            }
            var lineEnd = contentEnd
            if lineEnd < text.endIndex {
                lineEnd = text.index(after: lineEnd)
            }
            lines.append(FlowLine(content: String(text[lineStart..<contentEnd]), range: lineStart..<lineEnd, terminator: String(text[contentEnd..<lineEnd])))
            lineStart = lineEnd
        }
        return lines
    }

    private func flowReferences(_ payloadPath: String, in flow: String) -> Bool {
        flow.split(separator: "\n").contains { $0.contains("| Inbox |") && $0.contains("`\(payloadPath)`") }
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
