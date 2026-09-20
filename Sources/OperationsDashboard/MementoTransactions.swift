import CryptoKit
import Darwin
import Foundation

struct MementoDraft: Equatable, Sendable {
    let summary: String
    let currentState: String
    let naturalResumePoint: String
    let openCrumbs: [String]
    let extendedPayload: String?
}

enum MementoTransactionAction: String, Codable, Equatable { case create, supersede, resolve }
enum MementoTransactionTerminalState: String, Codable, Equatable {
    case preCommitFailure
    case committed
    case rolledBack
    case identifierRetiredRolledBack
    case recoveryRequired
    case committedReloadFailed
}

struct MementoTransactionJournal: Codable, Equatable {
    let transactionID: UUID
    let timestamp: Date
    let action: MementoTransactionAction
    let productionsRootPath: String?
    let targetID: String
    let mementoID: String
    let targetPath: String
    let identifierHash: String?
    let mementoLedgerHash: String
    let targetHash: String
    let identifierPreimage: Data?
    let mementoLedgerPreimage: Data
    let targetPreimage: Data
    let payloadPath: String?
    let payloadPreimage: Data?
    var terminalState: MementoTransactionTerminalState?
    var diagnostic: String?
}

protocol MementoTransactionJournalStore {
    func persist(_ journal: MementoTransactionJournal) throws
    func update(_ journal: MementoTransactionJournal) throws
    func incomplete() throws -> [MementoTransactionJournal]
}

struct ApplicationSupportMementoTransactionJournalStore: MementoTransactionJournalStore {
    private let manager = FileManager.default
    private var directory: URL {
        RecoveryJournalRoot.directory(named: "Memento Transaction Recovery", manager: manager)
    }
    func persist(_ journal: MementoTransactionJournal) throws { try write(journal) }
    func update(_ journal: MementoTransactionJournal) throws { try write(journal) }
    func incomplete() throws -> [MementoTransactionJournal] {
        guard manager.fileExists(atPath: directory.path) else { return [] }
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).compactMap { url in
            let journal = try JSONDecoder().decode(MementoTransactionJournal.self, from: Data(contentsOf: url))
            return [.committed, .rolledBack, .identifierRetiredRolledBack, .committedReloadFailed].contains(journal.terminalState) ? nil : journal
        }
    }
    private func write(_ journal: MementoTransactionJournal) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try DurableReplacement(manager: manager).replace(data: try JSONEncoder().encode(journal), at: directory.appending(path: "\(journal.transactionID.uuidString).json"))
    }
}

protocol MementoTransactionLocking { func acquire(ledgerURL: URL) -> AnyObject? }
private final class MementoWriteLock: NSObject {
    private let descriptor: Int32
    init?(url: URL) {
        descriptor = open(url.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard descriptor >= 0, flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { if descriptor >= 0 { close(descriptor) }; return nil }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
struct LocalMementoTransactionLocking: MementoTransactionLocking {
    let manager: FileManager
    private let directoryOverride: URL?
    private var directory: URL {
        directoryOverride ?? RecoveryJournalRoot.directory(named: "Memento Transaction Locks", manager: manager)
    }

    init(manager: FileManager = .default, directory: URL? = nil) {
        self.manager = manager
        directoryOverride = directory
    }

    func acquire(ledgerURL: URL) -> AnyObject? {
        do { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return nil }
        let key = SHA256.hash(data: Data(ledgerURL.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return MementoWriteLock(url: directory.appending(path: "\(key).lock"))
    }
}

enum MementoTransactionError: LocalizedError, Equatable {
    case invalidInput(String), invalidTarget(String), conflict(String), journalFailed(String)
    case replacementFailed(String), recoveryRequired(String), reloadFailed(String), lockUnavailable
    var errorDescription: String? {
        switch self {
        case let .invalidInput(message), let .invalidTarget(message), let .conflict(message), let .journalFailed(message), let .replacementFailed(message), let .recoveryRequired(message), let .reloadFailed(message): message
        case .lockUnavailable: "Another Memento or identifier transaction is in progress."
        }
    }
}

struct MementoTransactionResult: Equatable {
    let action: MementoTransactionAction
    let targetID: String
    let mementoID: String
    let timestamp: Date
}

struct MementoTransactionService {
    let journalStore: any MementoTransactionJournalStore
    let manager: FileManager
    let replacer: any AtomicFileReplacing
    let locking: any MementoTransactionLocking
    let now: () -> Date

    init(journalStore: any MementoTransactionJournalStore = ApplicationSupportMementoTransactionJournalStore(), manager: FileManager = .default, replacer: (any AtomicFileReplacing)? = nil, locking: any MementoTransactionLocking = LocalMementoTransactionLocking(), now: @escaping () -> Date = Date.init) {
        self.journalStore = journalStore; self.manager = manager
        self.replacer = replacer ?? DurableReplacement(manager: manager); self.locking = locking; self.now = now
    }

    func startupRecovery() -> [MementoTransactionJournal] { (try? journalStore.incomplete()) ?? [] }

    func create(configuration: ProductionsConfiguration, targetID: String, draft: MementoDraft, reload: (ProductionsConfiguration) -> ProductionsState) throws -> MementoTransactionResult {
        try RecoveryJournalRoot.withProductionsRoot(configuration.productionsRootPath) {
            try issue(action: .create, configuration: configuration, targetID: targetID, draft: draft, reload: reload)
        }
    }

    func supersede(configuration: ProductionsConfiguration, targetID: String, draft: MementoDraft, reload: (ProductionsConfiguration) -> ProductionsState) throws -> MementoTransactionResult {
        try RecoveryJournalRoot.withProductionsRoot(configuration.productionsRootPath) {
            try issue(action: .supersede, configuration: configuration, targetID: targetID, draft: draft, reload: reload)
        }
    }

    func resolve(configuration: ProductionsConfiguration, targetID: String, reload: (ProductionsConfiguration) -> ProductionsState) throws -> MementoTransactionResult {
        try RecoveryJournalRoot.withProductionsRoot(configuration.productionsRootPath) {
            try resolveWithScopedRecoveryRoot(configuration: configuration, targetID: targetID, reload: reload)
        }
    }

    private func resolveWithScopedRecoveryRoot(configuration: ProductionsConfiguration, targetID: String, reload: (ProductionsConfiguration) -> ProductionsState) throws -> MementoTransactionResult {
        let paths = Paths(configuration)
        guard let lock = locking.acquire(ledgerURL: paths.identifier) else { throw MementoTransactionError.lockUnavailable }
        defer { _ = lock }
        try requireNoPendingRecovery(configuration)
        let state = reload(configuration)
        guard state.issues.isEmpty else { throw MementoTransactionError.conflict("Productions has contract issues; resolution is blocked.") }
        guard let existing = state.mementos.first(where: { $0.target == targetID }) else { throw MementoTransactionError.invalidTarget("The target has no validated current Memento to resolve.") }
        let targetPath = try canonicalTargetPath(targetID, state: state)
        let targetURL = try safeTarget(targetPath, configuration: configuration)
        let target = try Data(contentsOf: targetURL), ledger = try Data(contentsOf: paths.mementos)
        let nextTarget = try WorkspaceSectionEditing.removeCurrentMemento(from: String(decoding: target, as: UTF8.self))
        let nextLedger = try MementoLedgerEditing.removing(targetID: targetID, mementoID: existing.id, from: String(decoding: ledger, as: UTF8.self))
        let timestamp = now()
        var journal = MementoTransactionJournal(transactionID: UUID(), timestamp: timestamp, action: .resolve, productionsRootPath: configuration.rootURL.standardizedFileURL.path, targetID: targetID, mementoID: existing.id, targetPath: targetPath, identifierHash: nil, mementoLedgerHash: hash(ledger), targetHash: hash(target), identifierPreimage: nil, mementoLedgerPreimage: ledger, targetPreimage: target, payloadPath: existing.extendedPayloadPath, payloadPreimage: existing.extendedPayloadPath.flatMap { try? Data(contentsOf: configuration.url($0)) }, terminalState: nil, diagnostic: nil)
        do { try journalStore.persist(journal) } catch { throw MementoTransactionError.journalFailed("Could not persist Memento recovery journal: \(error.localizedDescription)") }
        guard hash(try Data(contentsOf: targetURL)) == journal.targetHash, hash(try Data(contentsOf: paths.mementos)) == journal.mementoLedgerHash else {
            journal.terminalState = .preCommitFailure; journal.diagnostic = "Target or Memento ledger changed after resolution was prepared."; try? journalStore.update(journal)
            throw MementoTransactionError.conflict(journal.diagnostic!)
        }
        do {
            try replacer.replace(data: Data(nextTarget.utf8), at: targetURL)
            try replacer.replace(data: Data(nextLedger.utf8), at: paths.mementos)
        } catch {
            recover(journal: &journal, targetURL: targetURL, mementosURL: paths.mementos, issuedIdentifier: false)
            throw journal.terminalState == .recoveryRequired ? MementoTransactionError.recoveryRequired(journal.diagnostic!) : MementoTransactionError.replacementFailed(journal.diagnostic!)
        }
        let reloaded = reload(configuration)
        guard reloaded.issues.isEmpty, !reloaded.mementos.contains(where: { $0.target == targetID }) else {
            recover(journal: &journal, targetURL: targetURL, mementosURL: paths.mementos, issuedIdentifier: false)
            throw MementoTransactionError.reloadFailed("Resolution did not validate; before-copies were restored when possible. \(journal.diagnostic ?? "")")
        }
        journal.terminalState = .committed; journal.diagnostic = "Extended payload handling: retained in place. Open Crumbs were not changed."; try? journalStore.update(journal)
        return MementoTransactionResult(action: .resolve, targetID: targetID, mementoID: existing.id, timestamp: timestamp)
    }

    private func issue(action: MementoTransactionAction, configuration: ProductionsConfiguration, targetID: String, draft: MementoDraft, reload: (ProductionsConfiguration) -> ProductionsState) throws -> MementoTransactionResult {
        precondition(action == .create || action == .supersede)
        try validate(draft)
        let paths = Paths(configuration)
        guard let lock = locking.acquire(ledgerURL: paths.identifier) else { throw MementoTransactionError.lockUnavailable }
        defer { _ = lock }
        try requireNoPendingRecovery(configuration)
        let state = reload(configuration)
        guard state.issues.isEmpty else { throw MementoTransactionError.conflict("Productions has contract issues; Memento issuance is blocked.") }
        let existing = state.mementos.first(where: { $0.target == targetID })
        guard (action == .create && existing == nil) || (action == .supersede && existing != nil) else {
            throw MementoTransactionError.conflict(action == .create ? "The target already has a current Memento; use explicit supersession." : "Supersession requires one validated current Memento.")
        }
        guard draft.openCrumbs.allSatisfy({ crumbID in state.crumbs.contains { $0.id == crumbID && $0.target == targetID } }) else {
            throw MementoTransactionError.invalidInput("Every Open Crumb must resolve to the same target; Crumbs are not automatically resolved.")
        }
        let targetPath = try canonicalTargetPath(targetID, state: state)
        let targetURL = try safeTarget(targetPath, configuration: configuration)
        let identifier = try Data(contentsOf: paths.identifier), ledger = try Data(contentsOf: paths.mementos), target = try Data(contentsOf: targetURL)
        let newID = try MementoIdentifierEditing.nextID(in: String(decoding: identifier, as: UTF8.self))
        let timestamp = now(), created = ISO8601DateFormatter().string(from: timestamp)
        let payloadPath = draft.extendedPayload.map { _ in targetURL.deletingLastPathComponent().appending(path: "\(newID).md").pathComponents.dropFirst(configuration.rootURL.pathComponents.count).joined(separator: "/") }
        if let payloadPath, manager.fileExists(atPath: configuration.url(payloadPath).path) { throw MementoTransactionError.conflict("The root-level extended payload already exists.") }
        let section = WorkspaceSectionEditing.render(id: newID, created: created, draft: draft, payloadPath: payloadPath)
        let nextTarget = try WorkspaceSectionEditing.settingCurrentMemento(section, in: String(decoding: target, as: UTF8.self), replacing: action == .supersede)
        let row = try MementoLedgerEditing.row(id: newID, targetID: targetID, draft: draft, created: created, targetPath: targetPath)
        let nextLedger = try MementoLedgerEditing.setting(row: row, targetID: targetID, replacingID: existing?.id, in: String(decoding: ledger, as: UTF8.self))
        let nextIdentifier = try MementoIdentifierEditing.retiring(newID, in: String(decoding: identifier, as: UTF8.self))
        var journal = MementoTransactionJournal(transactionID: UUID(), timestamp: timestamp, action: action, productionsRootPath: configuration.rootURL.standardizedFileURL.path, targetID: targetID, mementoID: newID, targetPath: targetPath, identifierHash: hash(identifier), mementoLedgerHash: hash(ledger), targetHash: hash(target), identifierPreimage: identifier, mementoLedgerPreimage: ledger, targetPreimage: target, payloadPath: payloadPath, payloadPreimage: nil, terminalState: nil, diagnostic: nil)
        do { try journalStore.persist(journal) } catch { throw MementoTransactionError.journalFailed("Could not persist Memento recovery journal: \(error.localizedDescription)") }
        guard hash(try Data(contentsOf: paths.identifier)) == journal.identifierHash,
              hash(try Data(contentsOf: paths.mementos)) == journal.mementoLedgerHash,
              hash(try Data(contentsOf: targetURL)) == journal.targetHash else {
            journal.terminalState = .preCommitFailure; journal.diagnostic = "Identifier Ledger, Memento ledger, or target changed after issuance was prepared."; try? journalStore.update(journal)
            throw MementoTransactionError.conflict(journal.diagnostic!)
        }
        do {
            try replacer.replace(data: Data(nextIdentifier.utf8), at: paths.identifier)
            if let payload = draft.extendedPayload, let payloadPath { try replacer.replace(data: Data(payload.utf8), at: configuration.url(payloadPath)) }
            try replacer.replace(data: Data(nextTarget.utf8), at: targetURL)
            try replacer.replace(data: Data(nextLedger.utf8), at: paths.mementos)
        } catch {
            recover(journal: &journal, targetURL: targetURL, mementosURL: paths.mementos, identifierURL: paths.identifier, issuedIdentifier: true, configuration: configuration)
            throw journal.terminalState == .recoveryRequired ? MementoTransactionError.recoveryRequired(journal.diagnostic!) : MementoTransactionError.replacementFailed(journal.diagnostic!)
        }
        let reloaded = reload(configuration)
        guard reloaded.issues.isEmpty, reloaded.mementos.contains(where: { $0.id == newID && $0.target == targetID }) else {
            recover(journal: &journal, targetURL: targetURL, mementosURL: paths.mementos, identifierURL: paths.identifier, issuedIdentifier: true, configuration: configuration)
            throw MementoTransactionError.reloadFailed("Memento ID \(newID) was retired, but the transaction did not validate; before-copies were restored when possible. \(journal.diagnostic ?? "")")
        }
        journal.terminalState = .committed; journal.diagnostic = nil; try? journalStore.update(journal)
        return MementoTransactionResult(action: action, targetID: targetID, mementoID: newID, timestamp: timestamp)
    }

    private func recover(journal: inout MementoTransactionJournal, targetURL: URL, mementosURL: URL, identifierURL: URL? = nil, issuedIdentifier: Bool, configuration: ProductionsConfiguration? = nil) {
        do {
            try replacer.replace(data: journal.targetPreimage, at: targetURL)
            try replacer.replace(data: journal.mementoLedgerPreimage, at: mementosURL)
            if let payloadPath = journal.payloadPath, journal.payloadPreimage == nil, let configuration, manager.fileExists(atPath: configuration.url(payloadPath).path) { try manager.removeItem(at: configuration.url(payloadPath)) }
            if issuedIdentifier {
                guard let identifierURL, let preimage = journal.identifierPreimage else {
                    throw MementoTransactionError.recoveryRequired("Identifier recovery metadata is incomplete.")
                }
                try ensureRetired(journal.mementoID, preimage: preimage, identifierURL: identifierURL)
            }
            journal.terminalState = issuedIdentifier ? .identifierRetiredRolledBack : .rolledBack
            journal.diagnostic = issuedIdentifier ? "Memento ID \(journal.mementoID) is permanently retired; target and live ledger before-copies were restored." : "Target and live ledger before-copies were restored."
        } catch {
            journal.terminalState = .recoveryRequired
            journal.diagnostic = "Explicit recovery is required from journal \(journal.transactionID): \(error.localizedDescription)"
        }
        try? journalStore.update(journal)
    }

    private func ensureRetired(_ id: String, preimage: Data, identifierURL: URL) throws {
        var current = try Data(contentsOf: identifierURL)
        if try MementoIdentifierEditing.isRetired(id, in: String(decoding: current, as: UTF8.self)) { return }
        guard hash(current) == hash(preimage) else {
            throw MementoTransactionError.recoveryRequired("The Identifier Ledger changed before retirement could be completed.")
        }
        let retired = try MementoIdentifierEditing.retiring(id, in: String(decoding: preimage, as: UTF8.self))
        try replacer.replace(data: Data(retired.utf8), at: identifierURL)
        current = try Data(contentsOf: identifierURL)
        guard try MementoIdentifierEditing.isRetired(id, in: String(decoding: current, as: UTF8.self)) else {
            throw MementoTransactionError.recoveryRequired("The Identifier Ledger did not validate permanent retirement of \(id).")
        }
    }

    private func requireNoPendingRecovery(_ configuration: ProductionsConfiguration) throws {
        let root = configuration.rootURL.standardizedFileURL.path
        let pending: [MementoTransactionJournal]
        do { pending = try journalStore.incomplete() }
        catch { throw MementoTransactionError.journalFailed("Could not inspect Memento recovery journals: \(error.localizedDescription)") }
        guard !pending.contains(where: {
            ($0.productionsRootPath == nil || $0.productionsRootPath == root)
                && ($0.terminalState == nil || $0.terminalState == .recoveryRequired)
        }) else {
            throw MementoTransactionError.recoveryRequired("An incomplete Memento transaction requires explicit recovery before another transaction can begin.")
        }
    }

    private func canonicalTargetPath(_ targetID: String, state: ProductionsState) throws -> String {
        if let work = state.work.first(where: { $0.id == targetID }) { return work.workspacePath }
        if let bundle = state.processing.first(where: { $0.flowID == targetID }), let id = bundle.flowID { return "\(bundle.location)/\(id).md" }
        throw MementoTransactionError.invalidTarget("Mementos require one existing canonical work or Processing bundle target.")
    }
    private func safeTarget(_ path: String, configuration: ProductionsConfiguration) throws -> URL {
        let root = configuration.rootURL.standardizedFileURL, url = configuration.url(path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), manager.fileExists(atPath: url.path) else { throw MementoTransactionError.invalidTarget("The canonical target is missing, escaping, or symlinked.") }
        var component = root
        for name in url.pathComponents.dropFirst(root.pathComponents.count) {
            component.append(path: name)
            guard (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw MementoTransactionError.invalidTarget("The canonical target is missing, escaping, or symlinked.") }
        }
        return url
    }
    private func validate(_ draft: MementoDraft) throws {
        for (name, value) in [("Summary", draft.summary), ("Natural resume point", draft.naturalResumePoint)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !value.contains("|"), !value.contains("\n"), !value.contains("\r") else { throw MementoTransactionError.invalidInput("\(name) is required and must fit one ledger cell.") }
        }
        guard !draft.currentState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MementoTransactionError.invalidInput("Current state is required.") }
        for value in [draft.summary, draft.currentState, draft.naturalResumePoint, draft.extendedPayload ?? ""] where value.unicodeScalars.contains(where: { $0.value < 9 || ($0.value > 13 && $0.value < 32) || $0.value == 127 }) { throw MementoTransactionError.invalidInput("Memento content contains control characters.") }
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private struct Paths {
        let identifier, mementos: URL
        init(_ configuration: ProductionsConfiguration) { identifier = configuration.url("Warehouse/Reference/Identifier Ledger.md"); mementos = configuration.url(ProductionsPath.mementos.rawValue) }
    }
}

enum MementoIdentifierEditing {
    static func nextID(in ledger: String) throws -> String {
        let rows: [[String: String]]
        if let canonical = try? MarkdownTable.parse(ledger, required: ["Type", "Prefix", "Minimum digits", "Last issued", "Next display"]) { rows = canonical }
        else { rows = try MarkdownTable.parse(ledger, required: ["Identifier type", "Prefix", "Minimum digits", "Last issued", "Next display"]) }
        guard let row = rows.first(where: { $0["Prefix"] == "MEM" }), let number = Int(row["Last issued"] ?? "") else { throw MementoTransactionError.conflict("The MEM high-water counter is unavailable or malformed.") }
        return String(format: "MEM-%06d", number + 1)
    }
    static func retiring(_ id: String, in ledger: String) throws -> String {
        let number = Int(id.dropFirst(4))!
        var found = false
        let lines = ledger.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
            let line = String(raw), cells = MarkdownTable.cells(line)
            guard cells.count == 5, cells[1] == "MEM" else { return line }
            found = true
            return "| \(cells[0]) | MEM | \(cells[2]) | \(number) | `MEM-\(String(format: "%06d", number + 1))` |"
        }
        guard found else { throw MementoTransactionError.conflict("The MEM high-water counter is unavailable.") }
        return lines.joined(separator: "\n")
    }
    static func isRetired(_ id: String, in ledger: String) throws -> Bool {
        let rows: [[String: String]]
        if let canonical = try? MarkdownTable.parse(ledger, required: ["Type", "Prefix", "Minimum digits", "Last issued", "Next display"]) { rows = canonical }
        else { rows = try MarkdownTable.parse(ledger, required: ["Identifier type", "Prefix", "Minimum digits", "Last issued", "Next display"]) }
        guard let row = rows.first(where: { $0["Prefix"] == "MEM" }),
              let lastIssued = Int(row["Last issued"] ?? ""),
              let requested = Int(id.dropFirst(4)) else {
            throw MementoTransactionError.conflict("The MEM high-water counter is unavailable or malformed.")
        }
        return lastIssued >= requested
    }
}

enum WorkspaceSectionEditing {
    static func render(id: String, created: String, draft: MementoDraft, payloadPath: String?) -> String {
        let crumbs = draft.openCrumbs.isEmpty ? "—" : draft.openCrumbs.joined(separator: "; ")
        let payload = payloadPath.map { "`\($0)`" } ?? "—"
        return "## Current Memento\n\nMemento ID: \(id)\nCreated: \(created)\nCurrent state: \(draft.currentState)\nNatural resume point: \(draft.naturalResumePoint)\nOpen Crumbs: \(crumbs)\nExtended payload: \(payload)"
    }
    static func settingCurrentMemento(_ section: String, in document: String, replacing: Bool) throws -> String {
        let ranges = currentRanges(document)
        guard ranges.count <= 1 else { throw MementoTransactionError.conflict("The target has duplicate Current Memento sections.") }
        if replacing {
            guard let range = ranges.first else { throw MementoTransactionError.conflict("Supersession requires one Current Memento section.") }
            return document.replacingCharacters(in: range, with: section + (document[range].hasSuffix("\n") ? "\n" : ""))
        }
        guard ranges.isEmpty else { throw MementoTransactionError.conflict("Creation cannot replace an existing Current Memento section.") }
        return document.trimmingCharacters(in: .newlines) + "\n\n" + section + "\n"
    }
    static func removeCurrentMemento(from document: String) throws -> String {
        let ranges = currentRanges(document)
        guard ranges.count == 1, let range = ranges.first else { throw MementoTransactionError.conflict("Resolution requires exactly one Current Memento section.") }
        var result = document.replacingCharacters(in: range, with: "")
        while result.contains("\n\n\n") { result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return result
    }
    private static func currentRanges(_ document: String) -> [Range<String.Index>] {
        let pattern = #"(?m)^## Current Memento\s*$[\s\S]*?(?=^##\s|\z)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: document, range: NSRange(document.startIndex..<document.endIndex, in: document)).compactMap { Range($0.range, in: document) }
    }
}

enum MementoLedgerEditing {
    static func row(id: String, targetID: String, draft: MementoDraft, created: String, targetPath: String) throws -> String {
        "| \(id) | \(targetID) | \(draft.summary) | \(draft.naturalResumePoint) | \(created) | `\(targetPath)#current-memento` |"
    }
    static func setting(row: String, targetID: String, replacingID: String?, in ledger: String) throws -> String {
        let base = replacingID == nil ? ledger : try removing(targetID: targetID, mementoID: replacingID!, from: ledger)
        var lines = base.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let header = lines.firstIndex(where: { MarkdownTable.cells($0) == ["Memento ID", "Target", "Summary", "Resume point", "Created", "Location"] }) else { throw MementoTransactionError.conflict("Memento ledger table is unavailable.") }
        var insertion = header + 2
        while insertion < lines.count, lines[insertion].hasPrefix("|") { insertion += 1 }
        lines.insert(row, at: insertion)
        return lines.joined(separator: "\n")
    }
    static func removing(targetID: String, mementoID: String, from ledger: String) throws -> String {
        var removed = 0
        let lines = ledger.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
            let line = String(raw), cells = MarkdownTable.cells(line)
            if cells.count == 6, cells[0] == mementoID, cells[1] == targetID { removed += 1; return nil }
            return line
        }
        guard removed == 1 else { throw MementoTransactionError.conflict("The exact live Memento ledger row was not found once.") }
        return lines.joined(separator: "\n")
    }
}
