import CryptoKit
import Darwin
import Foundation

enum CanvasWorkAction: String, Codable, Equatable, Identifiable {
    case start
    case stop

    var id: String { rawValue }
    var title: String { self == .start ? "Start work" : "Stop work" }
}

enum CanvasWorkTransactionTerminalState: String, Codable, Equatable {
    case preCommitFailure
    case committed
    case committedReloadFailed
}

struct CanvasWorkTransactionJournal: Codable, Equatable {
    let transactionID: UUID
    let timestamp: Date
    let action: CanvasWorkAction
    let workID: String
    let canvasHash: String
    let canvasPreimage: Data
    let appendedEvents: [String]
    var terminalState: CanvasWorkTransactionTerminalState?
    var diagnostic: String?
}

protocol CanvasWorkTransactionJournalStore {
    func persist(_ journal: CanvasWorkTransactionJournal) throws
    func update(_ journal: CanvasWorkTransactionJournal) throws
    func incomplete() throws -> [CanvasWorkTransactionJournal]
}

struct ApplicationSupportCanvasWorkTransactionJournalStore: CanvasWorkTransactionJournalStore {
    private let manager = FileManager.default
    private var directory: URL {
        manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/Canvas Work Transaction Recovery", directoryHint: .isDirectory)
    }

    func persist(_ journal: CanvasWorkTransactionJournal) throws { try write(journal) }
    func update(_ journal: CanvasWorkTransactionJournal) throws { try write(journal) }
    func incomplete() throws -> [CanvasWorkTransactionJournal] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            let journal = try JSONDecoder().decode(CanvasWorkTransactionJournal.self, from: Data(contentsOf: url))
            return journal.terminalState == .committed || journal.terminalState == .committedReloadFailed ? nil : journal
        }
    }

    private func write(_ journal: CanvasWorkTransactionJournal) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: "\(journal.transactionID.uuidString).json")
        try DurableReplacement(manager: manager).replace(data: try JSONEncoder().encode(journal), at: target)
    }
}

protocol CanvasWorkTransactionLocking {
    func acquire(canvasURL: URL) -> AnyObject?
}

private final class CanvasWriteLock: NSObject {
    private let descriptor: Int32

    init?(canvasURL: URL) {
        descriptor = open(canvasURL.path, O_RDWR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            if descriptor >= 0 { close(descriptor) }
            return nil
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

struct LocalCanvasWorkTransactionLocking: CanvasWorkTransactionLocking {
    func acquire(canvasURL: URL) -> AnyObject? { CanvasWriteLock(canvasURL: canvasURL) }
}

enum CanvasWorkTransactionError: LocalizedError, Equatable {
    case invalidInput(String)
    case invalidTarget(String)
    case notCurrent
    case conflict(String)
    case lockUnavailable
    case journalFailed(String)
    case replacementFailed(String)
    case reloadFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(message), let .invalidTarget(message), let .conflict(message),
             let .journalFailed(message), let .replacementFailed(message), let .reloadFailed(message): message
        case .notCurrent: "Stop work is available only while the selected work is on Canvas."
        case .lockUnavailable: "Another Canvas write transaction is in progress."
        }
    }
}

struct CanvasWorkTransactionResult: Equatable {
    let workID: String
    let action: CanvasWorkAction
    let appendedEvents: [String]
    let timestamp: Date
}

struct CanvasWorkTransactionService {
    let journalStore: any CanvasWorkTransactionJournalStore
    let replacer: any AtomicFileReplacing
    let locking: any CanvasWorkTransactionLocking
    let now: () -> Date

    init(
        journalStore: any CanvasWorkTransactionJournalStore = ApplicationSupportCanvasWorkTransactionJournalStore(),
        replacer: (any AtomicFileReplacing)? = nil,
        locking: any CanvasWorkTransactionLocking = LocalCanvasWorkTransactionLocking(),
        now: @escaping () -> Date = Date.init
    ) {
        self.journalStore = journalStore
        self.replacer = replacer ?? DurableReplacement()
        self.locking = locking
        self.now = now
    }

    func startupRecovery() -> [CanvasWorkTransactionJournal] { (try? journalStore.incomplete()) ?? [] }

    func perform(
        action: CanvasWorkAction,
        configuration: ProductionsConfiguration,
        work: WorkItem,
        reason: String,
        context: String,
        reload: (ProductionsConfiguration) -> ProductionsState
    ) throws -> CanvasWorkTransactionResult {
        try validateField(reason, name: "Reason")
        try validateField(context, name: "Context")
        let canvasURL = configuration.url(ProductionsPath.canvas.rawValue)
        guard let lock = locking.acquire(canvasURL: canvasURL) else { throw CanvasWorkTransactionError.lockUnavailable }
        defer { _ = lock }

        let baselineState = reload(configuration)
        guard baselineState.issues.isEmpty else {
            throw CanvasWorkTransactionError.conflict("Productions has contract issues; resolve them before changing Canvas.")
        }
        guard baselineState.work.contains(where: { $0.id == work.id && $0.kind == work.kind }) else {
            throw CanvasWorkTransactionError.invalidTarget("The selected work is no longer present in the canonical loaded state.")
        }
        try validateTarget(work, configuration: configuration)
        let preimage = try Data(contentsOf: canvasURL)
        let canvasHash = hash(preimage)
        let document = String(decoding: preimage, as: UTF8.self)
        let rows = try parseCanvasRows(document)
        let isCurrent = currentIDs(rows).contains(work.id)
        if action == .stop, !isCurrent { throw CanvasWorkTransactionError.notCurrent }

        let timestamp = now()
        let formatter = ISO8601DateFormatter()
        let occurred = formatter.string(from: timestamp)
        let events: [String]
        switch action {
        case .start:
            events = isCurrent ? ["Engaged"] : ["Placed", "Engaged"]
        case .stop:
            events = ["Cleared"]
        }
        let eventRows = try events.map { event in
            try makeRow(occurred: occurred, workID: work.id, event: event, reason: reason, context: context)
        }
        let replacement = try append(rows: eventRows, to: document)
        try validateReplacement(replacement, previousRows: rows, appendedRows: eventRows, workID: work.id, action: action)

        var journal = CanvasWorkTransactionJournal(
            transactionID: UUID(),
            timestamp: timestamp,
            action: action,
            workID: work.id,
            canvasHash: canvasHash,
            canvasPreimage: preimage,
            appendedEvents: events,
            terminalState: nil,
            diagnostic: nil
        )
        do { try journalStore.persist(journal) }
        catch { throw CanvasWorkTransactionError.journalFailed("Could not persist Canvas recovery journal: \(error.localizedDescription)") }

        let expectedCurrent = try Data(contentsOf: canvasURL)
        guard hash(expectedCurrent) == canvasHash else {
            journal.terminalState = .preCommitFailure
            journal.diagnostic = "Canvas changed after the transaction was prepared."
            try? journalStore.update(journal)
            throw CanvasWorkTransactionError.conflict(journal.diagnostic!)
        }

        do { try replacer.replace(data: Data(replacement.utf8), at: canvasURL) }
        catch {
            journal.terminalState = .preCommitFailure
            journal.diagnostic = "Canvas replacement failed: \(error.localizedDescription)"
            try? journalStore.update(journal)
            throw CanvasWorkTransactionError.replacementFailed(journal.diagnostic!)
        }

        journal.terminalState = .committed
        try? journalStore.update(journal)
        let state = reload(configuration)
        guard state.issues.isEmpty else {
            journal.terminalState = .committedReloadFailed
            journal.diagnostic = state.issues.map(\.message).joined(separator: " · ")
            try? journalStore.update(journal)
            throw CanvasWorkTransactionError.reloadFailed("Canvas committed but contract reload needs investigation: \(journal.diagnostic!)")
        }
        let shouldBeCurrent = action == .start
        guard state.canvasCurrentIDs.contains(work.id) == shouldBeCurrent else {
            journal.terminalState = .committedReloadFailed
            journal.diagnostic = "Reloaded Canvas membership does not match the committed \(action.title) action."
            try? journalStore.update(journal)
            throw CanvasWorkTransactionError.reloadFailed(journal.diagnostic!)
        }

        return CanvasWorkTransactionResult(workID: work.id, action: action, appendedEvents: events, timestamp: timestamp)
    }

    private func validateTarget(_ work: WorkItem, configuration: ProductionsConfiguration) throws {
        let path: ProductionsPath
        let idHeader: String
        switch work.kind {
        case .task: path = .tasks; idHeader = "Task ID"
        case .idea: path = .ideas; idHeader = "Idea ID"
        case .project: path = .projects; idHeader = "Project ID"
        case .initiative: path = .initiatives; idHeader = "Initiative ID"
        }
        let data = try Data(contentsOf: configuration.url(path.rawValue))
        let registryRows: [[String: String]]
        do { registryRows = try MarkdownTable.parse(String(decoding: data, as: UTF8.self), required: [idHeader, "Workspace"]) }
        catch { throw CanvasWorkTransactionError.invalidTarget("The selected work Registry is malformed.") }
        guard let row = registryRows.first(where: { $0[idHeader] == work.id }) else {
            throw CanvasWorkTransactionError.invalidTarget("The selected work is no longer registered.")
        }
        let workspace = MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry")
        guard workspace == "Workspace/\(work.id)/\(work.id).md",
              FileManager.default.fileExists(atPath: configuration.url(workspace).path) else {
            throw CanvasWorkTransactionError.invalidTarget("The selected work does not resolve to its canonical Workspace record.")
        }
    }

    private func validateField(_ value: String, name: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CanvasWorkTransactionError.invalidInput("\(name) is required.") }
        guard !value.contains("|"), !value.contains("\n"), !value.contains("\r"),
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw CanvasWorkTransactionError.invalidInput("\(name) cannot contain table-breaking characters.")
        }
    }

    private func parseCanvasRows(_ canvas: String) throws -> [[String: String]] {
        do {
            let rows = try MarkdownTable.parse(canvas, required: ["Occurred", "Work ID", "Event", "Reason", "Context"])
            guard rows.allSatisfy({ ["Placed", "Engaged", "Cleared"].contains($0["Event"] ?? "") }) else {
                throw CanvasWorkTransactionError.conflict("Canvas contains an invalid event.")
            }
            return rows
        } catch let error as CanvasWorkTransactionError { throw error }
        catch { throw CanvasWorkTransactionError.conflict("Canvas table is malformed: \(error.localizedDescription)") }
    }

    private func currentIDs(_ rows: [[String: String]]) -> Set<String> {
        let boundaries = rows.reduce(into: [String: String]()) { result, row in
            if row["Event"] == "Placed" || row["Event"] == "Cleared" { result[row["Work ID"] ?? ""] = row["Event"] }
        }
        return Set(boundaries.filter { $0.value == "Placed" }.map(\.key))
    }

    private func makeRow(occurred: String, workID: String, event: String, reason: String, context: String) throws -> String {
        for value in [occurred, workID, event] { try validateField(value, name: "Canvas field") }
        return "| \([occurred, workID, event, reason, context].joined(separator: " | ")) |"
    }

    private func append(rows: [String], to canvas: String) throws -> String {
        var lines = canvas.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.firstIndex(where: { MarkdownTable.cells($0) == ["Occurred", "Work ID", "Event", "Reason", "Context"] }),
              headerIndex + 1 < lines.count,
              lines[headerIndex + 1].contains("---") else {
            throw CanvasWorkTransactionError.conflict("Canvas table header is unavailable.")
        }
        var insertionIndex = headerIndex + 2
        while insertionIndex < lines.count, lines[insertionIndex].hasPrefix("|") { insertionIndex += 1 }
        lines.insert(contentsOf: rows, at: insertionIndex)
        let joined = lines.joined(separator: "\n")
        return canvas.hasSuffix("\n") && !joined.hasSuffix("\n") ? joined + "\n" : joined
    }

    private func validateReplacement(_ canvas: String, previousRows: [[String: String]], appendedRows: [String], workID: String, action: CanvasWorkAction) throws {
        let rows = try parseCanvasRows(canvas)
        guard rows.count == previousRows.count + appendedRows.count else {
            throw CanvasWorkTransactionError.conflict("Canvas replacement changed an unexpected number of rows.")
        }
        let tail = Array(rows.suffix(appendedRows.count))
        guard tail.map({ $0["Work ID"] ?? "" }) == Array(repeating: workID, count: appendedRows.count),
              tail.map({ $0["Event"] ?? "" }) == (action == .start && appendedRows.count == 2 ? ["Placed", "Engaged"] : [action == .start ? "Engaged" : "Cleared"]) else {
            throw CanvasWorkTransactionError.conflict("Canvas replacement does not contain the exact authorized events.")
        }
    }

    private func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
