import Foundation

/// The v1.1 contract deliberately exposes only read operations. There is no mutation
/// protocol for Productions, which keeps write-capable services out of this path.
protocol ProductionsReading {
    func exists(at url: URL) -> Bool
    func isReadable(at url: URL) -> Bool
    func isDirectory(at url: URL) throws -> Bool
    func directoryEntries(at url: URL) throws -> [FileSystemEntry]
    func readData(at url: URL) throws -> Data
}

extension LocalFileSystem: ProductionsReading {}

struct ProductionsConfiguration: Codable, Equatable, Sendable {
    static let schemaVersion = 2
    let schemaVersion: Int
    let productionsRootPath: String

    func validated() throws -> ProductionsConfiguration {
        guard schemaVersion == Self.schemaVersion else { throw ProductionsConfigurationError.unsupportedVersion(schemaVersion) }
        guard !productionsRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProductionsConfigurationError.emptyRoot }
        return self
    }

    var rootURL: URL { URL(fileURLWithPath: productionsRootPath, isDirectory: true).standardizedFileURL }
    func url(_ relativePath: String, directory: Bool = false) -> URL {
        rootURL.appending(path: relativePath, directoryHint: directory ? .isDirectory : .notDirectory)
    }
}

enum ProductionsConfigurationError: LocalizedError, Equatable {
    case absent, emptyRoot, unsupportedVersion(Int), malformed(String)
    var errorDescription: String? {
        switch self {
        case .absent: "Productions configuration is absent."
        case .emptyRoot: "Productions root is required."
        case let .unsupportedVersion(version): "Unsupported Productions configuration version \(version)."
        case let .malformed(message): "Malformed Productions configuration: \(message)"
        }
    }
}

struct ProductionsConfigurationStore {
    let fileManager: FileManager = .default
    var configurationURL: URL {
        if let override = ProcessInfo.processInfo.environment["OPERATIONS_DASHBOARD_PRODUCTIONS_CONFIG"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: false).standardizedFileURL
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard", directoryHint: .isDirectory)
            .appending(path: "productions-config-v2.json", directoryHint: .notDirectory)
    }
    func load() throws -> ProductionsConfiguration? {
        guard fileManager.fileExists(atPath: configurationURL.path) else { return nil }
        do { return try JSONDecoder().decode(ProductionsConfiguration.self, from: Data(contentsOf: configurationURL)).validated() }
        catch let error as ProductionsConfigurationError { throw error }
        catch { throw ProductionsConfigurationError.malformed(error.localizedDescription) }
    }
    func save(_ configuration: ProductionsConfiguration) throws {
        let data = try JSONEncoder().encode(configuration.validated())
        try fileManager.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configurationURL, options: .atomic)
    }
}

enum ProductionsPath: String, CaseIterable {
    case flow = "Office/Flow.md", inbox = "Office/Inbox", processing = "Office/Processing"
    case tasks = "Office/Registry/Tasks.md", ideas = "Office/Registry/Ideas.md", projects = "Office/Registry/Projects.md", initiatives = "Office/Registry/Initiatives.md", products = "Office/Registry/Products.md", departments = "Office/Registry/Departments.md"
    case canvas = "Office/Threads/Canvas.md", crumbs = "Office/Threads/Crumbs.md", mementos = "Office/Threads/Mementos.md"
}

enum ProductionsIssue: Equatable, Identifiable {
    case missing(String), unreadable(String), malformed(String), duplicate(String), unresolved(String), mismatch(String)
    var id: String { message }
    var message: String {
        switch self {
        case let .missing(value): "Missing: \(value)"
        case let .unreadable(value): "Unreadable: \(value)"
        case let .malformed(value): "Malformed: \(value)"
        case let .duplicate(value): "Duplicate: \(value)"
        case let .unresolved(value): "Unresolved: \(value)"
        case let .mismatch(value): "Mismatched: \(value)"
        }
    }
}

enum WorkKind: String, CaseIterable, Identifiable {
    case task = "Task", idea = "Idea", project = "Project", initiative = "Initiative"
    var id: String { rawValue }
    var identifierPrefix: String {
        switch self {
        case .task: "TASK"
        case .idea: "IDEA"
        case .project: "PROJ"
        case .initiative: "INIT"
        }
    }
}
struct WorkItem: Identifiable, Equatable { let id: String; let kind: WorkKind; let title, lifecycle, priority, lead, department, product, workspacePath: String; let related: [String]; let content: String? }
struct FlowItem: Identifiable, Equatable {
    /// `id` is a view identity only. Unregistered payloads have no Flow identifier.
    let viewIdentity: String
    let flowID: String?
    let label, type, stage, priority, location, summary: String
    let bundleContent: String?
    var id: String { viewIdentity }
    var isUnregistered: Bool { flowID == nil }
}
struct CanvasEvent: Equatable { let occurred: Date; let workID, event, reason, context: String; let sequence: Int }
struct Crumb: Identifiable, Equatable { let id, kind, target, priority, summary, location: String }
struct Memento: Identifiable, Equatable { let id, target, summary, resumePoint, location: String }
struct ProductionsState: Equatable {
    let configuration: ProductionsConfiguration; let inbox: [FlowItem]; let processing: [FlowItem]; let work: [WorkItem]; let canvas: [CanvasEvent]; let crumbs: [Crumb]; let mementos: [Memento]; let issues: [ProductionsIssue]
    var canvasCurrentIDs: Set<String> { Set(canvas.sorted { $0.sequence < $1.sequence }.reduce(into: [String: String]()) { if $1.event == "Placed" || $1.event == "Cleared" { $0[$1.workID] = $1.event } }.filter { $0.value == "Placed" }.map(\.key)) }
}

struct ProductionsLoader {
    let reader: any ProductionsReading
    private let dateFormatter = ISO8601DateFormatter()

    func load(configuration: ProductionsConfiguration) -> ProductionsState {
        var issues: [ProductionsIssue] = []
        let validated: ProductionsConfiguration
        do { validated = try configuration.validated() } catch { return ProductionsState(configuration: configuration, inbox: [], processing: [], work: [], canvas: [], crumbs: [], mementos: [], issues: [.malformed(error.localizedDescription)]) }
        for path in ProductionsPath.allCases { validatePath(path, configuration: validated, issues: &issues) }
        let flowRows = table(at: .flow, configuration: validated, required: ["Entry ID", "Label", "Type", "Stage", "Priority", "Location", "Summary"], issues: &issues)
        let registryDefinitions: [(ProductionsPath, WorkKind, [String])] = [(.tasks, .task, ["Task ID", "Title", "State", "Priority", "Current lead", "Initiative", "Project", "Depends on", "Workspace"]), (.ideas, .idea, ["Idea ID", "Title", "Disposition", "Priority", "Current lead", "Related records", "Workspace"]), (.projects, .project, ["Project ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Workspace"]), (.initiatives, .initiative, ["Initiative ID", "Title", "State", "Priority", "Current lead", "Related records", "Workspace"])]
        var work: [WorkItem] = []
        for (path, kind, headers) in registryDefinitions { work += parseWork(table(at: path, configuration: validated, required: headers, issues: &issues), kind: kind, configuration: validated, issues: &issues) }
        _ = table(at: .products, configuration: validated, required: ["Product ID", "Product", "Lifecycle", "Current lead", "Related initiatives / products", "Canonical workspace"], issues: &issues)
        _ = table(at: .departments, configuration: validated, required: ["Department", "Function"], issues: &issues)
        let workByID = Dictionary(uniqueKeysWithValues: work.map { ($0.id, $0) })
        let flow = parseFlow(flowRows, configuration: validated, issues: &issues)
        let inbox = assembleInbox(flow: flow.filter { $0.stage == "Inbox" }, configuration: validated, issues: &issues)
        let canvas = parseCanvas(table(at: .canvas, configuration: validated, required: ["Occurred", "Work ID", "Event", "Reason", "Context"], issues: &issues), work: workByID, issues: &issues)
        let validTargets = Set(workByID.keys).union(flow.filter { $0.stage == "Processing" }.map(\.id))
        let crumbs = parseCrumbs(table(at: .crumbs, configuration: validated, required: ["Crumb ID", "Kind", "Target", "Priority", "Summary", "Created", "Location"], issues: &issues), targets: validTargets, configuration: validated, issues: &issues)
        let mementos = parseMementos(table(at: .mementos, configuration: validated, required: ["Memento ID", "Target", "Summary", "Resume point", "Created", "Location"], issues: &issues), targets: validTargets, configuration: validated, issues: &issues)
        return ProductionsState(configuration: validated, inbox: inbox, processing: flow.filter { $0.stage == "Processing" }, work: work, canvas: canvas, crumbs: crumbs, mementos: mementos, issues: issues)
    }

    private func validatePath(_ path: ProductionsPath, configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) { let url = configuration.url(path.rawValue, directory: path == .inbox || path == .processing); if !reader.exists(at: url) { issues.append(.missing(path.rawValue)) } else if !reader.isReadable(at: url) { issues.append(.unreadable(path.rawValue)) } }
    private func table(at path: ProductionsPath, configuration: ProductionsConfiguration, required: [String], issues: inout [ProductionsIssue]) -> [[String: String]] {
        let url = configuration.url(path.rawValue); guard reader.exists(at: url), reader.isReadable(at: url) else { return [] }
        do { return try MarkdownTable.parse(String(decoding: reader.readData(at: url), as: UTF8.self), required: required) }
        catch { issues.append(.malformed("\(path.rawValue): \(error.localizedDescription)")); return [] }
    }
    private func parseWork(_ rows: [[String: String]], kind: WorkKind, configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [WorkItem] { rows.compactMap { row in
        let id = row["\(kind.rawValue) ID"] ?? ""; guard identifier(id, prefix: kind.identifierPrefix) else { issues.append(.malformed("invalid \(kind.rawValue) ID \(id)")); return nil }
        let workspace = MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry"); let expected = "Workspace/\(id)/\(id).md"; guard workspace == expected else { issues.append(.mismatch("\(id) Workspace link")); return nil }
        let url = configuration.url(workspace); guard reader.exists(at: url), reader.isReadable(at: url) else { issues.append(.unresolved("\(id) Workspace")); return nil }
        let content = try? String(decoding: reader.readData(at: url), as: UTF8.self)
        let lifecycle = row["State"] ?? row["Disposition"] ?? ""; let related = MarkdownTable.values(row["Related records"] ?? row["Depends on"] ?? "")
        return WorkItem(id: id, kind: kind, title: row["Title"] ?? "", lifecycle: lifecycle, priority: row["Priority"] ?? "", lead: row["Current lead"] ?? "", department: "", product: "", workspacePath: workspace, related: related, content: content)
    } }
    private func parseFlow(_ rows: [[String: String]], configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [FlowItem] { rows.compactMap { row in
        let id = row["Entry ID"] ?? ""; let stage = row["Stage"] ?? ""; guard (stage == "Inbox" && identifier(id, prefix: "FLOW")) || (stage == "Processing" && identifier(id, prefix: "BND")) else { issues.append(.malformed("Flow \(id) stage or identifier")); return nil }
        let location = MarkdownTable.rootPath(row["Location"] ?? ""); let url = configuration.url(location, directory: stage == "Processing"); guard reader.exists(at: url) else { issues.append(.unresolved("Flow \(id) location")); return nil }
        if stage == "Inbox", !isImmediateInboxPayload(location) { issues.append(.mismatch("Flow \(id) Inbox location")); return nil }
        if stage == "Processing", location.hasPrefix("Office/Inbox/") { issues.append(.mismatch("Flow \(id) Processing location")); return nil }
        var bundle: String?; if stage == "Processing" { let record = url.appending(path: "\(id).md"); guard reader.exists(at: record), reader.isReadable(at: record) else { issues.append(.unresolved("\(id) bundle record")); return nil }; bundle = try? String(decoding: reader.readData(at: record), as: UTF8.self); if !(bundle?.contains("## Bundle Record") == true && bundle?.contains("## Processing State") == true && bundle?.contains("## Contents") == true) { issues.append(.malformed("\(id) bundle sections")) } }
        return FlowItem(viewIdentity: "flow:\(id)", flowID: id, label: row["Label"] ?? "", type: row["Type"] ?? "", stage: stage, priority: row["Priority"] ?? "", location: location, summary: row["Summary"] ?? "", bundleContent: bundle)
    } }
    private func assembleInbox(flow: [FlowItem], configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [FlowItem] {
        let inboxURL = configuration.url(ProductionsPath.inbox.rawValue, directory: true)
        guard reader.exists(at: inboxURL) else { return [] }
        let entries: [FileSystemEntry]
        do { entries = try reader.directoryEntries(at: inboxURL) }
        catch { issues.append(.unreadable(ProductionsPath.inbox.rawValue)); return [] }
        let visible = entries.filter { !$0.name.hasPrefix(".") && ($0.isRegularFile || $0.isDirectory) }
        let registrations = Dictionary(grouping: flow, by: \.location)
        for (location, rows) in registrations where rows.count > 1 { issues.append(.duplicate("Inbox Flow reference \(location)")) }
        return visible.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { entry in
            let location = "Office/Inbox/\(entry.name)"
            if let registered = registrations[location]?.first { return registered }
            return FlowItem(viewIdentity: "inbox:\(location)", flowID: nil, label: entry.name, type: "Unregistered", stage: "Inbox", priority: "", location: location, summary: "Not yet referenced by an Inbox Flow row.", bundleContent: nil)
        }
    }
    private func isImmediateInboxPayload(_ location: String) -> Bool {
        let prefix = "Office/Inbox/"
        guard location.hasPrefix(prefix) else { return false }
        let remainder = location.dropFirst(prefix.count)
        return !remainder.isEmpty && !remainder.contains("/")
    }
    private func parseCanvas(_ rows: [[String: String]], work: [String: WorkItem], issues: inout [ProductionsIssue]) -> [CanvasEvent] { rows.enumerated().compactMap { index, row in let id = row["Work ID"] ?? ""; let event = row["Event"] ?? ""; guard work[id] != nil, ["Placed", "Engaged", "Cleared"].contains(event), let occurred = dateFormatter.date(from: row["Occurred"] ?? "") else { issues.append(.malformed("Canvas row \(index + 1)")); return nil }; return CanvasEvent(occurred: occurred, workID: id, event: event, reason: row["Reason"] ?? "", context: row["Context"] ?? "", sequence: index) } }
    private func parseCrumbs(_ rows: [[String: String]], targets: Set<String>, configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [Crumb] { rows.compactMap { row in let id = row["Crumb ID"] ?? "", target = row["Target"] ?? "", location = MarkdownTable.resolvedPath(row["Location"] ?? "", relativeTo: "Office/Threads"); guard identifier(id, prefix: "CRMB"), targets.contains(target), ["Idea", "Decision", "Action"].contains(row["Kind"] ?? ""), reader.exists(at: configuration.url(location)) else { issues.append(.malformed("Crumb \(id)")); return nil }; return Crumb(id: id, kind: row["Kind"]!, target: target, priority: row["Priority"] ?? "", summary: row["Summary"] ?? "", location: location) } }
    private func parseMementos(_ rows: [[String: String]], targets: Set<String>, configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [Memento] { var seen = Set<String>(); return rows.compactMap { row in let id = row["Memento ID"] ?? "", target = row["Target"] ?? "", location = MarkdownTable.resolvedPath(row["Location"] ?? "", relativeTo: "Office/Threads"); guard identifier(id, prefix: "MEM"), targets.contains(target), reader.exists(at: configuration.url(location)) else { issues.append(.malformed("Memento \(id)")); return nil }; guard seen.insert(target).inserted else { issues.append(.duplicate("current Memento target \(target)")); return nil }; return Memento(id: id, target: target, summary: row["Summary"] ?? "", resumePoint: row["Resume point"] ?? "", location: location) } }
    private func identifier(_ value: String, prefix: String) -> Bool {
        let minimumWidth = ["FLOW", "BND", "CRMB", "MEM"].contains(prefix) ? 6 : 4
        return value.range(of: "^\(prefix)-[0-9]{\(minimumWidth),}$", options: .regularExpression) != nil
    }
}

enum MarkdownTable {
    static func parse(_ text: String, required: [String]) throws -> [[String: String]] { let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init); guard let headerIndex = lines.firstIndex(where: { line in let headers = cells(line); return line.hasPrefix("|") && line.hasSuffix("|") && required.allSatisfy(headers.contains) }) else { throw ProductionsConfigurationError.malformed("required table header not found") }; let headers = cells(lines[headerIndex]); guard headerIndex + 1 < lines.count, lines[headerIndex + 1].contains("---") else { throw ProductionsConfigurationError.malformed("table separator missing") }; return try lines.dropFirst(headerIndex + 2).prefix { $0.hasPrefix("|") }.map { line in let values = cells(line); guard values.count == headers.count else { throw ProductionsConfigurationError.malformed("malformed table row") }; return Dictionary(uniqueKeysWithValues: zip(headers, values)) } }
    static func cells(_ line: String) -> [String] { line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) } }
    static func rootPath(_ value: String) -> String { rawPath(value).trimmingCharacters(in: CharacterSet(charactersIn: "` ")) }
    static func resolvedPath(_ value: String, relativeTo base: String) -> String { let url = URL(fileURLWithPath: "/\(base)", isDirectory: true).appending(path: rawPath(value).trimmingCharacters(in: CharacterSet(charactersIn: "` "))).standardizedFileURL; return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private static func rawPath(_ value: String) -> String { if let match = value.range(of: #"\]\(([^)]+)\)"#, options: .regularExpression) { return String(String(value[match]).dropFirst(2).dropLast()) }; return value }
    static func values(_ value: String) -> [String] { value == "—" ? [] : value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
}
