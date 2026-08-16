import Foundation

/// The v1.1 contract deliberately exposes only read operations. There is no mutation
/// protocol for Productions, which keeps write-capable services out of this path.
protocol ProductionsReading {
    func exists(at url: URL) -> Bool
    func isReadable(at url: URL) -> Bool
    func isSymbolicLink(at url: URL) throws -> Bool
    func isDirectory(at url: URL) throws -> Bool
    func directoryEntries(at url: URL) throws -> [FileSystemEntry]
    func readData(at url: URL) throws -> Data
}

extension LocalFileSystem: ProductionsReading {
    func isSymbolicLink(at url: URL) throws -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}

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
struct WorkspaceRecord: Equatable {
    let fields: [String: String]
    let sections: [String: String]
    let currentMemento: CurrentMemento?

    func field(_ name: String) -> String { fields[name] ?? "" }
    func section(_ name: String) -> String { sections[name] ?? "" }
}

struct CurrentMemento: Equatable {
    let id: String
    let created: String
    let currentState: String
    let naturalResumePoint: String
    let openCrumbs: [String]
    let extendedPayload: String?
}

struct ProductRecord: Identifiable, Equatable {
    let id: String
    let name: String
    let lifecycle: String
    let lead: String
    let related: [String]
    let canonicalWorkspace: String
}

struct WorkItem: Identifiable, Equatable {
    let id: String
    let kind: WorkKind
    let title: String
    let lifecycle: String
    let priority: String
    let lead: String
    let department: String
    let product: String
    let workspacePath: String
    let related: [String]
    let dependencies: [String]
    let registryDescription: String
    let content: String?
    let workspace: WorkspaceRecord?

    init(id: String, kind: WorkKind, title: String, lifecycle: String, priority: String, lead: String, department: String, product: String, workspacePath: String, related: [String], dependencies: [String] = [], registryDescription: String = "", content: String?, workspace: WorkspaceRecord? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.lifecycle = lifecycle
        self.priority = priority; self.lead = lead; self.department = department; self.product = product
        self.workspacePath = workspacePath; self.related = related; self.dependencies = dependencies
        self.registryDescription = registryDescription; self.content = content; self.workspace = workspace
    }
}
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
struct Memento: Identifiable, Equatable {
    let id, target, summary, resumePoint, created, location: String
    let currentState, naturalResumePoint: String
    let openCrumbs: [String]
    let extendedPayloadPath: String?
    let extendedPayloadContent: String?
}
struct ProductionsState: Equatable {
    let configuration: ProductionsConfiguration
    let inbox: [FlowItem]
    let processing: [FlowItem]
    let work: [WorkItem]
    let products: [ProductRecord]
    let canvas: [CanvasEvent]
    let crumbs: [Crumb]
    let mementos: [Memento]
    let issues: [ProductionsIssue]

    init(configuration: ProductionsConfiguration, inbox: [FlowItem], processing: [FlowItem], work: [WorkItem], products: [ProductRecord] = [], canvas: [CanvasEvent], crumbs: [Crumb], mementos: [Memento], issues: [ProductionsIssue]) {
        self.configuration = configuration; self.inbox = inbox; self.processing = processing
        self.work = work; self.products = products; self.canvas = canvas; self.crumbs = crumbs
        self.mementos = mementos; self.issues = issues
    }
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
        let duplicateWorkIDs = Dictionary(grouping: work, by: \.id).filter { $0.value.count > 1 }.keys
        for id in duplicateWorkIDs { issues.append(.duplicate("Registry work ID \(id)")) }
        work = work.reduce(into: []) { result, item in if !result.contains(where: { $0.id == item.id }) { result.append(item) } }
        let products = parseProducts(table(at: .products, configuration: validated, required: ["Product ID", "Product", "Lifecycle", "Current lead", "Related initiatives / products", "Canonical workspace"], issues: &issues), issues: &issues)
        _ = table(at: .departments, configuration: validated, required: ["Department", "Function"], issues: &issues)
        let workByID = Dictionary(uniqueKeysWithValues: work.map { ($0.id, $0) })
        let flow = parseFlow(flowRows, configuration: validated, issues: &issues)
        let inbox = assembleInbox(flow: flow.filter { $0.stage == "Inbox" }, configuration: validated, issues: &issues)
        let canvas = parseCanvas(canvasRows(configuration: validated, issues: &issues), work: workByID, issues: &issues)
        let validTargets = Set(workByID.keys).union(flow.filter { $0.stage == "Processing" }.map(\.id))
        let crumbs = parseCrumbs(table(at: .crumbs, configuration: validated, required: ["Crumb ID", "Kind", "Target", "Priority", "Summary", "Created", "Location"], issues: &issues), targets: validTargets, configuration: validated, issues: &issues)
        let mementos = parseMementos(table(at: .mementos, configuration: validated, required: ["Memento ID", "Target", "Summary", "Resume point", "Created", "Location"], issues: &issues), work: workByID, processing: flow.filter { $0.stage == "Processing" }, crumbs: crumbs, configuration: validated, issues: &issues)
        return ProductionsState(configuration: validated, inbox: inbox, processing: flow.filter { $0.stage == "Processing" }, work: work, products: products, canvas: canvas, crumbs: crumbs, mementos: mementos, issues: issues)
    }

    private func validatePath(_ path: ProductionsPath, configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) { let url = configuration.url(path.rawValue, directory: path == .inbox || path == .processing); if !reader.exists(at: url) { issues.append(.missing(path.rawValue)) } else if !reader.isReadable(at: url) { issues.append(.unreadable(path.rawValue)) } }
    private func table(at path: ProductionsPath, configuration: ProductionsConfiguration, required: [String], issues: inout [ProductionsIssue]) -> [[String: String]] {
        let url = configuration.url(path.rawValue); guard reader.exists(at: url), reader.isReadable(at: url) else { return [] }
        do { return try MarkdownTable.parse(String(decoding: reader.readData(at: url), as: UTF8.self), required: required) }
        catch { issues.append(.malformed("\(path.rawValue): \(error.localizedDescription)")); return [] }
    }
    private func canvasRows(configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [[String: String]] {
        let path = ProductionsPath.canvas.rawValue
        let url = configuration.url(path)
        guard reader.exists(at: url), reader.isReadable(at: url) else { return [] }
        do {
            let result = try CanvasMarkdown.parse(String(decoding: reader.readData(at: url), as: UTF8.self))
            if result.isFragmented { issues.append(.malformed("\(path): fragmented or orphaned Canvas rows")) }
            return result.rows
        } catch {
            issues.append(.malformed("\(path): \(error.localizedDescription)"))
            return []
        }
    }
    private func parseWork(_ rows: [[String: String]], kind: WorkKind, configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [WorkItem] { rows.compactMap { row in
        let id = row["\(kind.rawValue) ID"] ?? ""; guard identifier(id, prefix: kind.identifierPrefix) else { issues.append(.malformed("invalid \(kind.rawValue) ID \(id)")); return nil }
        let workspace = MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry"); let expected = "Workspace/\(id)/\(id).md"; guard workspace == expected else { issues.append(.mismatch("\(id) Workspace link")); return nil }
        let url = configuration.url(workspace); guard safeRootPath(workspace, configuration: configuration), reader.exists(at: url), reader.isReadable(at: url) else { issues.append(.unresolved("\(id) Workspace")); return nil }
        let content = try? String(decoding: reader.readData(at: url), as: UTF8.self)
        let parsedWorkspace: WorkspaceRecord?
        do { parsedWorkspace = try content.map(WorkspaceMarkdown.parse) }
        catch { issues.append(.malformed("\(id) Workspace: \(error.localizedDescription)")); parsedWorkspace = nil }
        let lifecycle = row["State"] ?? row["Disposition"] ?? ""
        let directRelated = MarkdownTable.values(row["Related records"] ?? "") + MarkdownTable.values(row["Source artifacts"] ?? "")
        let structuralRelated = MarkdownTable.values(row["Initiative"] ?? "") + MarkdownTable.values(row["Project"] ?? "")
        let dependencies = MarkdownTable.values(row["Depends on"] ?? "")
        let product = parsedWorkspace?.field("Associated product(s)").nilIfEmpty ?? parsedWorkspace?.field("Associated product").nilIfEmpty ?? ""
        let department = parsedWorkspace?.field("Primary department").nilIfEmpty ?? ""
        return WorkItem(id: id, kind: kind, title: row["Title"] ?? "", lifecycle: lifecycle, priority: row["Priority"] ?? "", lead: row["Current lead"] ?? "", department: department, product: product, workspacePath: workspace, related: directRelated + structuralRelated, dependencies: dependencies, registryDescription: row["Short description"] ?? "", content: content, workspace: parsedWorkspace)
    } }

    private func parseProducts(_ rows: [[String: String]], issues: inout [ProductionsIssue]) -> [ProductRecord] {
        var ids = Set<String>()
        return rows.compactMap { row in
            let id = row["Product ID"] ?? ""
            guard identifier(id, prefix: "PROD") else { issues.append(.malformed("invalid Product ID \(id)")); return nil }
            guard ids.insert(id).inserted else { issues.append(.duplicate("Product \(id)")); return nil }
            let workspace = MarkdownTable.rootPath(row["Canonical workspace"] ?? "")
            guard !workspace.isEmpty else { issues.append(.malformed("Product \(id) canonical workspace")); return nil }
            return ProductRecord(id: id, name: row["Product"] ?? "", lifecycle: row["Lifecycle"] ?? "", lead: row["Current lead"] ?? "", related: MarkdownTable.values(row["Related initiatives / products"] ?? ""), canonicalWorkspace: workspace)
        }
    }
    private func parseFlow(_ rows: [[String: String]], configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [FlowItem] { rows.compactMap { row in
        let id = row["Entry ID"] ?? ""; let stage = row["Stage"] ?? ""; guard (stage == "Inbox" && identifier(id, prefix: "FLOW")) || (stage == "Processing" && identifier(id, prefix: "BND")) else { issues.append(.malformed("Flow \(id) stage or identifier")); return nil }
        let rawLocation = MarkdownTable.rootPath(row["Location"] ?? "")
        let location = stage == "Processing" ? rawLocation.trimmingCharacters(in: CharacterSet(charactersIn: "/")) : rawLocation
        let url = configuration.url(location, directory: stage == "Processing"); guard safeRootPath(location, configuration: configuration), reader.exists(at: url) else { issues.append(.unresolved("Flow \(id) location")); return nil }
        if stage == "Inbox", !isImmediateInboxPayload(location) { issues.append(.mismatch("Flow \(id) Inbox location")); return nil }
        if stage == "Processing", location.hasPrefix("Office/Inbox/") { issues.append(.mismatch("Flow \(id) Processing location")); return nil }
        var bundle: String?; if stage == "Processing" { let recordPath = "\(location)/\(id).md", record = configuration.url(recordPath); guard safeRootPath(recordPath, configuration: configuration), reader.exists(at: record), reader.isReadable(at: record) else { issues.append(.unresolved("\(id) bundle record")); return nil }; bundle = try? String(decoding: reader.readData(at: record), as: UTF8.self); if !(bundle?.contains("## Bundle Record") == true && bundle?.contains("## Processing State") == true && bundle?.contains("## Contents") == true) { issues.append(.malformed("\(id) bundle sections")) } }
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
    private func parseCrumbs(_ rows: [[String: String]], targets: Set<String>, configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [Crumb] {
        var seen = Set<String>()
        return rows.compactMap { row in
            let id = row["Crumb ID"] ?? "", target = row["Target"] ?? ""
            guard seen.insert(id).inserted else { issues.append(.duplicate("Crumb ID \(id)")); return nil }
            guard identifier(id, prefix: "CRMB"), targets.contains(target), ["Idea", "Decision", "Action"].contains(row["Kind"] ?? ""),
                  let location = resolveCrumbLocation(row["Location"] ?? "", configuration: configuration) else {
                issues.append(.malformed("Crumb \(id)")); return nil
            }
            return Crumb(id: id, kind: row["Kind"]!, target: target, priority: row["Priority"] ?? "", summary: row["Summary"] ?? "", location: location)
        }
    }
    private func resolveCrumbLocation(_ value: String, configuration: ProductionsConfiguration) -> String? {
        guard let reference = MarkdownTable.locationReference(value) else { return nil }
        let root = configuration.rootURL.standardizedFileURL
        let base = reference.isRootRelative ? root : root.appending(path: "Office/Threads", directoryHint: .isDirectory)
        guard let target = lexicallyResolvedURL(reference.path, relativeTo: base) else { return nil }
        guard target.path != root.path,
              target.path.hasPrefix(root.path + "/"),
              target.pathExtension.lowercased() == "md",
              reader.exists(at: target),
              reader.isReadable(at: target),
              (try? reader.isDirectory(at: target)) == false else { return nil }
        let relativeComponents = target.pathComponents.dropFirst(root.pathComponents.count)
        var componentURL = root
        for component in relativeComponents {
            componentURL.append(path: component)
            guard (try? reader.isSymbolicLink(at: componentURL)) == false else { return nil }
        }
        if let anchor = reference.anchor {
            guard let data = try? reader.readData(at: target),
                  MarkdownTable.contains(anchor: anchor, in: String(decoding: data, as: UTF8.self)) else { return nil }
        }
        let relativePath = relativeComponents.joined(separator: "/")
        return relativePath + (reference.anchor.map { "#\($0)" } ?? "")
    }
    private func lexicallyResolvedURL(_ relativePath: String, relativeTo base: URL) -> URL? {
        guard !relativePath.hasPrefix("/") else { return nil }
        var components = base.pathComponents
        for component in relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            switch component {
            case "", ".": continue
            case "..":
                guard components.count > 1 else { return nil }
                components.removeLast()
            default: components.append(component)
            }
        }
        guard components.count > 1 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: components), isDirectory: false)
    }
    private struct MementoTarget {
        let path: String
        let record: WorkspaceRecord
    }

    private func parseMementos(_ rows: [[String: String]], work: [String: WorkItem], processing: [FlowItem], crumbs: [Crumb], configuration: ProductionsConfiguration, issues: inout [ProductionsIssue]) -> [Memento] {
        var targets: [String: MementoTarget] = [:]
        for item in work {
            if let record = item.value.workspace { targets[item.key] = MementoTarget(path: item.value.workspacePath, record: record) }
        }
        for bundle in processing {
            guard let id = bundle.flowID, let content = bundle.bundleContent else { continue }
            do { targets[id] = MementoTarget(path: "\(bundle.location)/\(id).md", record: try WorkspaceMarkdown.parse(content)) }
            catch { issues.append(.malformed("\(id) bundle Memento state: \(error.localizedDescription)")) }
        }

        var seenTargets = Set<String>()
        var seenIDs = Set<String>()
        var matchedTargets = Set<String>()
        let crumbsByID = Dictionary(uniqueKeysWithValues: crumbs.map { ($0.id, $0) })
        let parsed: [Memento] = rows.compactMap { row in
            let id = row["Memento ID"] ?? "", targetID = row["Target"] ?? ""
            guard identifier(id, prefix: "MEM"), let target = targets[targetID] else { issues.append(.malformed("Memento \(id)")); return nil }
            guard seenIDs.insert(id).inserted else { issues.append(.duplicate("Memento ID \(id)")); return nil }
            guard seenTargets.insert(targetID).inserted else { issues.append(.duplicate("current Memento target \(targetID)")); return nil }
            guard let location = resolveMementoLocation(row["Location"] ?? "", configuration: configuration) else { issues.append(.malformed("Memento \(id)")); return nil }
            let locationPath = location.split(separator: "#", maxSplits: 1).first.map(String.init) ?? location
            guard locationPath == target.path else { issues.append(.mismatch("Memento \(id) target location")); return nil }
            guard let current = target.record.currentMemento else { issues.append(.mismatch("Memento \(id) has no target Current Memento section")); return nil }
            let created = row["Created"] ?? "", resume = row["Resume point"] ?? ""
            guard current.id == id, current.created == created, continuation(resume, agreesWith: current.naturalResumePoint) else { issues.append(.mismatch("Memento \(id) ledger and target")); return nil }
            guard current.openCrumbs.allSatisfy({ crumbsByID[$0]?.target == targetID }) else { issues.append(.unresolved("Memento \(id) Open Crumbs")); return nil }
            let payload: (String, String)?
            do { payload = try resolveExtendedPayload(current.extendedPayload, mementoID: id, targetPath: target.path, configuration: configuration) }
            catch { issues.append(.unresolved("Memento \(id) extended payload: \(error.localizedDescription)")); return nil }
            matchedTargets.insert(targetID)
            return Memento(id: id, target: targetID, summary: row["Summary"] ?? "", resumePoint: resume, created: created, location: location, currentState: current.currentState, naturalResumePoint: current.naturalResumePoint, openCrumbs: current.openCrumbs, extendedPayloadPath: payload?.0, extendedPayloadContent: payload?.1)
        }
        for (targetID, target) in targets where target.record.currentMemento != nil && !matchedTargets.contains(targetID) {
            issues.append(.mismatch("\(targetID) Current Memento has no matching live ledger row"))
        }
        return parsed
    }

    private func continuation(_ ledger: String, agreesWith substantive: String) -> Bool {
        let lhs = ledger.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let rhs = substantive.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return !lhs.isEmpty && !rhs.isEmpty && (lhs == rhs || lhs.contains(rhs) || rhs.contains(lhs))
    }

    private func resolveExtendedPayload(_ value: String?, mementoID: String, targetPath: String, configuration: ProductionsConfiguration) throws -> (String, String)? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value != "—" else { return nil }
        guard let reference = MarkdownTable.locationReference(value), reference.anchor == nil else { throw ProductionsConfigurationError.malformed("payload reference") }
        let targetDirectory = configuration.url(targetPath).deletingLastPathComponent().standardizedFileURL
        let payload = (reference.isRootRelative ? configuration.rootURL : targetDirectory).appending(path: reference.path).standardizedFileURL
        guard payload.deletingLastPathComponent() == targetDirectory, payload.lastPathComponent == "\(mementoID).md", reader.exists(at: payload), reader.isReadable(at: payload), (try? reader.isDirectory(at: payload)) == false, (try? reader.isSymbolicLink(at: payload)) == false else { throw ProductionsConfigurationError.malformed("payload must be a readable root-level \(mementoID).md file") }
        let relative = payload.pathComponents.dropFirst(configuration.rootURL.pathComponents.count).joined(separator: "/")
        return (relative, String(decoding: try reader.readData(at: payload), as: UTF8.self))
    }
    private func resolveMementoLocation(_ value: String, configuration: ProductionsConfiguration) -> String? {
        guard let reference = MarkdownTable.locationReference(value) else { return nil }
        let root = configuration.rootURL.standardizedFileURL
        let base = reference.isRootRelative ? root : root.appending(path: "Office/Threads", directoryHint: .isDirectory)
        let target = base.appending(path: reference.path, directoryHint: .notDirectory).standardizedFileURL
        guard target.path != root.path, target.path.hasPrefix(root.path + "/"), target.pathExtension.lowercased() == "md", reader.exists(at: target), reader.isReadable(at: target), (try? reader.isDirectory(at: target)) == false else { return nil }
        let relativeComponents = target.pathComponents.dropFirst(root.pathComponents.count)
        var componentURL = root
        for component in relativeComponents {
            componentURL.append(path: component)
            guard (try? reader.isSymbolicLink(at: componentURL)) == false else { return nil }
        }
        if let anchor = reference.anchor {
            guard let data = try? reader.readData(at: target), MarkdownTable.contains(anchor: anchor, in: String(decoding: data, as: UTF8.self)) else { return nil }
        }
        let relativePath = relativeComponents.joined(separator: "/")
        return relativePath + (reference.anchor.map { "#\($0)" } ?? "")
    }
    private func identifier(_ value: String, prefix: String) -> Bool {
        let minimumWidth = ["FLOW", "BND", "CRMB", "MEM"].contains(prefix) ? 6 : 4
        return value.range(of: "^\(prefix)-[0-9]{\(minimumWidth),}$", options: .regularExpression) != nil
    }

    private func safeRootPath(_ path: String, configuration: ProductionsConfiguration) -> Bool {
        let root = configuration.rootURL.standardizedFileURL, target = configuration.url(path).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return false }
        var component = root
        for name in target.pathComponents.dropFirst(root.pathComponents.count) {
            component.append(path: name)
            if (try? reader.isSymbolicLink(at: component)) != false { return false }
        }
        return true
    }
}

enum MarkdownTable {
    struct LocationReference {
        let path: String
        let anchor: String?
        let isRootRelative: Bool
    }

    static func parse(_ text: String, required: [String]) throws -> [[String: String]] { let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init); guard let headerIndex = lines.firstIndex(where: { line in let headers = cells(line); return line.hasPrefix("|") && line.hasSuffix("|") && required.allSatisfy(headers.contains) }) else { throw ProductionsConfigurationError.malformed("required table header not found") }; let headers = cells(lines[headerIndex]); guard headerIndex + 1 < lines.count, lines[headerIndex + 1].contains("---") else { throw ProductionsConfigurationError.malformed("table separator missing") }; return try lines.dropFirst(headerIndex + 2).prefix { $0.hasPrefix("|") }.map { line in let values = cells(line); guard values.count == headers.count else { throw ProductionsConfigurationError.malformed("malformed table row") }; return Dictionary(uniqueKeysWithValues: zip(headers, values)) } }
    static func cells(_ line: String) -> [String] { line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) } }
    static func rootPath(_ value: String) -> String { rawPath(value).trimmingCharacters(in: CharacterSet(charactersIn: "` ")) }
    static func resolvedPath(_ value: String, relativeTo base: String) -> String { let url = URL(fileURLWithPath: "/\(base)", isDirectory: true).appending(path: rawPath(value).trimmingCharacters(in: CharacterSet(charactersIn: "` "))).standardizedFileURL; return url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    static func locationReference(_ value: String) -> LocationReference? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOpeningBacktick = trimmed.hasPrefix("`")
        let hasClosingBacktick = trimmed.hasSuffix("`")
        let isRootRelative = hasOpeningBacktick && hasClosingBacktick
        guard hasOpeningBacktick == hasClosingBacktick else { return nil }
        let raw: String
        if isRootRelative {
            guard trimmed.count > 2 else { return nil }
            raw = String(trimmed.dropFirst().dropLast())
            guard !raw.contains("`") else { return nil }
        } else {
            raw = rawPath(trimmed)
        }
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let anchor = parts.count == 2 ? String(parts[1]) : nil
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), anchor?.isEmpty != true, anchor?.contains("#") != true else { return nil }
        return LocationReference(path: path, anchor: anchor, isRootRelative: isRootRelative)
    }
    static func contains(anchor: String, in markdown: String) -> Bool {
        var occurrences: [String: Int] = [:]
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let markerCount = trimmed.prefix(while: { $0 == "#" }).count
            guard (1...6).contains(markerCount) else { continue }
            let titleStart = trimmed.index(trimmed.startIndex, offsetBy: markerCount)
            guard titleStart < trimmed.endIndex, trimmed[titleStart] == " " || trimmed[titleStart] == "\t" else { continue }
            var title = String(trimmed[titleStart...]).trimmingCharacters(in: .whitespaces)
            if let closing = title.range(of: #"\s+#+\s*$"#, options: .regularExpression) { title.removeSubrange(closing) }
            let base = markdownAnchor(for: title)
            guard !base.isEmpty else { continue }
            let count = occurrences[base, default: 0]
            occurrences[base] = count + 1
            if anchor == (count == 0 ? base : "\(base)-\(count)") { return true }
        }
        return false
    }
    private static func markdownAnchor(for heading: String) -> String {
        let lowered = heading.lowercased()
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let scalars = lowered.unicodeScalars.filter(allowed.contains)
        return String(String.UnicodeScalarView(scalars)).replacingOccurrences(of: " ", with: "-")
    }
    private static func rawPath(_ value: String) -> String { if let match = value.range(of: #"\]\(([^)]+)\)"#, options: .regularExpression) { return String(String(value[match]).dropFirst(2).dropLast()) }; return value }
    static func values(_ value: String) -> [String] { value == "—" ? [] : value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) } }
}

struct CanvasMarkdownResult {
    let rows: [[String: String]]
    let isFragmented: Bool
}

enum CanvasMarkdown {
    static let headers = ["Occurred", "Work ID", "Event", "Reason", "Context"]
    private static let events = ["Placed", "Engaged", "Cleared"]

    static func parse(_ markdown: String) throws -> CanvasMarkdownResult {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.firstIndex(where: { MarkdownTable.cells($0) == headers }),
              headerIndex + 1 < lines.count,
              isSeparator(lines[headerIndex + 1]) else {
            throw ProductionsConfigurationError.malformed("required table header not found")
        }

        var rows: [[String: String]] = []
        var isFragmented = false
        var withinCanonicalTable = true
        for line in lines.dropFirst(headerIndex + 2) {
            if withinCanonicalTable {
                guard line.hasPrefix("|") else {
                    withinCanonicalTable = false
                    continue
                }
                rows.append(try row(from: line))
                continue
            }

            guard resemblesCanvasRow(line) else { continue }
            isFragmented = true
            let values = MarkdownTable.cells(line)
            if values == headers || isSeparator(line) { continue }
            if values.count == headers.count {
                rows.append(Dictionary(uniqueKeysWithValues: zip(headers, values)))
            }
        }
        return CanvasMarkdownResult(rows: rows, isFragmented: isFragmented)
    }

    private static func row(from line: String) throws -> [String: String] {
        let values = MarkdownTable.cells(line)
        guard values.count == headers.count else {
            throw ProductionsConfigurationError.malformed("malformed table row")
        }
        return Dictionary(uniqueKeysWithValues: zip(headers, values))
    }

    private static func resemblesCanvasRow(_ line: String) -> Bool {
        guard line.hasPrefix("|"), line.hasSuffix("|") else { return false }
        let values = MarkdownTable.cells(line)
        if values == headers || isSeparator(line) { return true }
        guard values.count == headers.count else {
            return line.range(of: #"^\|\s*[0-9]{4}-[0-9]{2}-[0-9]{2}"#, options: .regularExpression) != nil
        }
        return values[0].range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T"#, options: .regularExpression) != nil
            || values[1].range(of: #"^(TASK|IDEA|PROJ|INIT)-[0-9]{4,}$"#, options: .regularExpression) != nil
            || events.contains(values[2])
    }

    private static func isSeparator(_ line: String) -> Bool {
        let values = MarkdownTable.cells(line)
        return values.count == headers.count && values.allSatisfy {
            $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil
        }
    }
}

enum WorkspaceMarkdown {
    static func parse(_ markdown: String) throws -> WorkspaceRecord {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var ranges: [(name: String, start: Int, end: Int)] = []
        var headings: [(name: String, index: Int)] = []
        for (index, line) in lines.enumerated() {
            guard line.hasPrefix("## "), !line.hasPrefix("### ") else { continue }
            let name = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headings.append((name, index))
        }
        for (offset, heading) in headings.enumerated() {
            let end = offset + 1 < headings.count ? headings[offset + 1].index : lines.count
            ranges.append((heading.name, heading.index + 1, end))
        }
        let grouped = Dictionary(grouping: ranges, by: \.name)
        if let duplicate = grouped.first(where: { $0.value.count > 1 }) {
            throw ProductionsConfigurationError.malformed("duplicate Workspace section \(duplicate.key)")
        }
        var sections: [String: String] = [:]
        for range in ranges {
            sections[range.name] = lines[range.start..<range.end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let core = sections["Core Record"] ?? ""
        let fields = parseFields(core)
        let current: CurrentMemento?
        if let text = sections["Current Memento"] { current = try parseCurrentMemento(text) }
        else { current = nil }
        return WorkspaceRecord(fields: fields, sections: sections, currentMemento: current)
    }

    private static func parseFields(_ text: String) -> [String: String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String: String] = [:]
        var currentKey: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { continue }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                if key.range(of: #"^[A-Za-z][A-Za-z0-9 /()_-]*$"#, options: .regularExpression) != nil {
                    currentKey = key
                    result[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    continue
                }
            }
            if let currentKey, !trimmed.isEmpty {
                let existing = result[currentKey] ?? ""
                result[currentKey] = existing.isEmpty ? trimmed : existing + "\n" + trimmed
            }
        }
        return result
    }

    private static func parseCurrentMemento(_ text: String) throws -> CurrentMemento {
        let required = ["Memento ID", "Created", "Current state", "Natural resume point", "Open Crumbs", "Extended payload"]
        let fields = try parseNamedFields(text, names: required)
        guard required.allSatisfy({ fields[$0] != nil }) else { throw ProductionsConfigurationError.malformed("partial Current Memento section") }
        let id = fields["Memento ID"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = fields["Created"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = fields["Current state"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        let resume = fields["Natural resume point"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.range(of: #"^MEM-[0-9]{6,}$"#, options: .regularExpression) != nil,
              created.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:T.+)?$"#, options: .regularExpression) != nil,
              !state.isEmpty, !resume.isEmpty else {
            throw ProductionsConfigurationError.malformed("malformed Current Memento fields")
        }
        let crumbs = MarkdownTable.values(fields["Open Crumbs"]!).flatMap { value in
            value.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        }
        guard crumbs.allSatisfy({ $0.range(of: #"^CRMB-[0-9]{6,}$"#, options: .regularExpression) != nil }) else {
            throw ProductionsConfigurationError.malformed("invalid Current Memento Open Crumbs")
        }
        let extended = fields["Extended payload"]!.trimmingCharacters(in: .whitespacesAndNewlines)
        return CurrentMemento(id: id, created: created, currentState: state, naturalResumePoint: resume, openCrumbs: crumbs, extendedPayload: extended == "—" || extended.isEmpty ? nil : extended)
    }

    private static func parseNamedFields(_ text: String, names: [String]) throws -> [String: String] {
        var result: [String: String] = [:], current: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if let match = names.first(where: { line.hasPrefix("\($0):") }) {
                guard result[match] == nil else { throw ProductionsConfigurationError.malformed("duplicate Current Memento field \(match)") }
                current = match
                result[match] = String(line.dropFirst(match.count + 1)).trimmingCharacters(in: .whitespaces)
            } else if let current, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                result[current, default: ""] += (result[current]!.isEmpty ? "" : "\n") + line.trimmingCharacters(in: .whitespaces)
            }
        }
        return result
    }
}

private extension String {
    var nilIfEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "—" ? nil : value
    }
}
