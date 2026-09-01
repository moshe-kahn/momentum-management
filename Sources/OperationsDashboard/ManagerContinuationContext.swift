import CryptoKit
import Foundation

protocol ManagerCanonicalContextResolving: Sendable {
    func resolve(productionsRootPath: String, taskID: String) throws -> ManagerCanonicalContextBinding
}

protocol ManagerCanonicalContextLocking: Sendable {
    func acquire(productionsRootPath: String) -> AnyObject?
}

private final class ManagerCanonicalContextLockToken: NSObject {
    let registry: AnyObject
    let canvas: AnyObject
    init(registry: AnyObject, canvas: AnyObject) { self.registry = registry; self.canvas = canvas }
}

struct LiveManagerCanonicalContextLock: ManagerCanonicalContextLocking, @unchecked Sendable {
    let registryLocking: any TaskCheckpointLocking
    let canvasLocking: any CanvasWorkTransactionLocking

    init(
        registryLocking: any TaskCheckpointLocking = LocalTaskCheckpointLocking(),
        canvasLocking: any CanvasWorkTransactionLocking = LocalCanvasWorkTransactionLocking()
    ) {
        self.registryLocking = registryLocking
        self.canvasLocking = canvasLocking
    }

    func acquire(productionsRootPath: String) -> AnyObject? {
        guard TaskCheckpointCanonicalRoot.isExact(productionsRootPath) else { return nil }
        let root = TaskCheckpointCanonicalRoot.url(productionsRootPath)
        guard let registry = registryLocking.acquire(
            registryURL: root.appending(path: ProductionsPath.tasks.rawValue)
        ), let canvas = canvasLocking.acquire(
            canvasURL: root.appending(path: ProductionsPath.canvas.rawValue)
        ) else { return nil }
        return ManagerCanonicalContextLockToken(registry: registry, canvas: canvas)
    }
}

struct LiveManagerCanonicalContextResolver: ManagerCanonicalContextResolving, @unchecked Sendable {
    private let reader: any ProductionsReading
    private let contractValidator: any OfficeV112ContractValidating
    private let manager: FileManager

    init(
        reader: any ProductionsReading = LocalFileSystem(),
        contractValidator: any OfficeV112ContractValidating = AdoptedOfficeV112ContractValidator(),
        manager: FileManager = .default
    ) {
        self.reader = reader
        self.contractValidator = contractValidator
        self.manager = manager
    }

    func resolve(productionsRootPath: String, taskID: String) throws -> ManagerCanonicalContextBinding {
        guard taskID.range(of: #"^TASK-[0-9]{4,}$"#, options: .regularExpression) != nil else {
            throw ManagerRoutingError.invalidInput("A canonical continuation context requires an exact Task ID.")
        }
        let configuration = try ProductionsConfiguration(
            schemaVersion: ProductionsConfiguration.schemaVersion,
            productionsRootPath: productionsRootPath
        ).validated()
        try contractValidator.validate(configuration: configuration)
        let root = configuration.taskCheckpointRootURL
        let registryURL = configuration.taskCheckpointURL(ProductionsPath.tasks.rawValue)
        let canvasURL = configuration.taskCheckpointURL(ProductionsPath.canvas.rawValue)
        let registryData = try strictData(registryURL, root: root, label: ProductionsPath.tasks.rawValue)
        let canvasData = try strictData(canvasURL, root: root, label: ProductionsPath.canvas.rawValue)
        let registryText = try strictUTF8(registryData, label: ProductionsPath.tasks.rawValue)
        let canvasText = try strictUTF8(canvasData, label: ProductionsPath.canvas.rawValue)
        let rows = try MarkdownTable.parse(registryText, required: [
            "Task ID", "Title", "State", "Priority", "Current lead", "Initiative", "Project",
            "Depends on", "Review after", "Short description", "Workspace"
        ])
        let matches = rows.filter { ManagerRoutingUTF8.equal($0["Task ID"] ?? "", taskID) }
        guard matches.count == 1, let row = matches.first else {
            throw ManagerRoutingError.storageCorrupt("The Task Registry does not contain one exact continuation target.")
        }
        let workspacePath = MarkdownTable.resolvedPath(row["Workspace"] ?? "", relativeTo: "Office/Registry")
        guard ManagerRoutingUTF8.equal(workspacePath, "Workspace/\(taskID)/\(taskID).md") else {
            throw ManagerRoutingError.storageCorrupt("The continuation target Workspace link is not canonical.")
        }
        let workspaceURL = configuration.taskCheckpointURL(workspacePath)
        let workspaceData = try strictData(workspaceURL, root: root, label: workspacePath)
        let workspaceText = try strictUTF8(workspaceData, label: workspacePath)
        try validateTaskIdentity(workspaceText, taskID: taskID, title: row["Title"] ?? "")
        let workspace = try WorkspaceMarkdown.parse(workspaceText)
        guard ManagerRoutingUTF8.equal(workspace.field("ID"), taskID),
              ManagerRoutingUTF8.equal(workspace.field("Type"), "Task"),
              ManagerRoutingUTF8.equal(workspace.field("Title"), row["Title"] ?? "") else {
            throw ManagerRoutingError.storageCorrupt("The continuation target Registry and Workspace identity disagree.")
        }
        let canvasRows = try CanvasMarkdown.parse(canvasText)
        guard !canvasRows.isFragmented else {
            throw ManagerRoutingError.storageCorrupt("Canvas is fragmented; continuation is blocked.")
        }
        var current = false
        for event in canvasRows.rows where ManagerRoutingUTF8.equal(event["Work ID"] ?? "", taskID) {
            switch event["Event"] {
            case "Placed": current = true
            case "Cleared": current = false
            default: break
            }
        }
        let instructionPaths = [
            "AGENTS.md", "PRODUCTIONS_COORDINATOR.md", "PRODUCTIONS_MANAGER.md",
            "PRODUCTIONS_ADMINISTRATOR.md", "PRODUCTIONS_OFFICE_ADMINISTRATOR.md", "PRODUCTIONS_ARCHITECT.md"
        ]
        var instructionHashes: [String: String] = [:]
        for path in instructionPaths {
            let url = configuration.taskCheckpointURL(path)
            guard reader.exists(at: url) else { continue }
            instructionHashes[path] = sha256(try strictData(url, root: root, label: path))
        }
        guard instructionHashes["AGENTS.md"] != nil,
              instructionHashes["PRODUCTIONS_COORDINATOR.md"] != nil,
              instructionHashes["PRODUCTIONS_OFFICE_ADMINISTRATOR.md"] != nil || instructionHashes["PRODUCTIONS_ADMINISTRATOR.md"] != nil else {
            throw ManagerRoutingError.storageCorrupt("Required Productions instructions are unavailable.")
        }
        return .init(
            productionsRootPath: productionsRootPath,
            taskRegistrySHA256: sha256(registryData), workspaceSHA256: sha256(workspaceData),
            canvasSHA256: sha256(canvasData), instructionSHA256: instructionHashes,
            taskLifecycle: row["State"] ?? "", taskPriority: row["Priority"] ?? "", canvasCurrent: current
        )
    }

    private func strictData(_ url: URL, root: URL, label: String) throws -> Data {
        guard TaskCheckpointUTF8.hasPrefix(url.path, root.path + "/"),
              reader.exists(at: url), reader.isReadable(at: url), !(try reader.isSymbolicLink(at: url)) else {
            throw ManagerRoutingError.storageUncertain("Canonical continuation input is unavailable or unsafe: \(label).")
        }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            guard let entries = try? manager.contentsOfDirectory(atPath: current.path),
                  entries.contains(where: { ManagerRoutingUTF8.equal($0, component) }) else {
                throw ManagerRoutingError.storageUncertain("Canonical continuation path spelling is unavailable: \(label).")
            }
            current.append(path: component)
            if (try? manager.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw ManagerRoutingError.storageUncertain("Canonical continuation path contains a symbolic link: \(label).")
            }
        }
        return try OfficeJournalAtomicCoordinator.readRegular(url)
    }

    private func strictUTF8(_ data: Data, label: String) throws -> String {
        guard let value = String(data: data, encoding: .utf8), !value.contains("\r") else {
            throw ManagerRoutingError.storageCorrupt("Canonical continuation input must be LF-only UTF-8: \(label).")
        }
        return value
    }

    private func validateTaskIdentity(_ text: String, taskID: String, title: String) throws {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var fenced = false
        var h1s: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle(); continue }
            if !fenced, line.hasPrefix("# "), !line.hasPrefix("## ") { h1s.append(String(line.dropFirst(2))) }
        }
        guard h1s.count == 1, ManagerRoutingUTF8.equal(h1s[0], title),
              lines.filter({ ManagerRoutingUTF8.equal($0, "Title: \(title)") }).count == 1,
              lines.filter({ ManagerRoutingUTF8.equal($0, "ID: \(taskID)") }).count == 1,
              lines.filter({ ManagerRoutingUTF8.equal($0, "Type: Task") }).count == 1,
              lines.filter({ ManagerRoutingUTF8.equal($0, "Status source: Office/Registry/Tasks.md") }).count == 1 else {
            throw ManagerRoutingError.storageCorrupt("The continuation target Workspace H1/Core identity is not exact.")
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ManagerCanonicalContextBinding {
    func bytewiseEquals(_ other: Self) -> Bool {
        ManagerRoutingUTF8.equal(productionsRootPath, other.productionsRootPath) &&
            ManagerRoutingUTF8.equal(taskRegistrySHA256, other.taskRegistrySHA256) &&
            ManagerRoutingUTF8.equal(workspaceSHA256, other.workspaceSHA256) &&
            ManagerRoutingUTF8.equal(canvasSHA256, other.canvasSHA256) &&
            ManagerRoutingUTF8.equal(taskLifecycle, other.taskLifecycle) &&
            ManagerRoutingUTF8.equal(taskPriority, other.taskPriority) &&
            canvasCurrent == other.canvasCurrent && exactHashes(instructionSHA256, other.instructionSHA256)
    }

    func onlyWorkspaceHashDiffers(from other: Self) -> Bool {
        ManagerRoutingUTF8.equal(productionsRootPath, other.productionsRootPath) &&
            ManagerRoutingUTF8.equal(taskRegistrySHA256, other.taskRegistrySHA256) &&
            ManagerRoutingUTF8.equal(canvasSHA256, other.canvasSHA256) &&
            ManagerRoutingUTF8.equal(taskLifecycle, other.taskLifecycle) &&
            ManagerRoutingUTF8.equal(taskPriority, other.taskPriority) &&
            canvasCurrent == other.canvasCurrent && exactHashes(instructionSHA256, other.instructionSHA256) &&
            !ManagerRoutingUTF8.equal(workspaceSHA256, other.workspaceSHA256)
    }

    private func exactHashes(_ lhs: [String: String], _ rhs: [String: String]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return lhs.allSatisfy { key, value in
            rhs.first(where: { ManagerRoutingUTF8.equal($0.key, key) })
                .map { ManagerRoutingUTF8.equal($0.value, value) } == true
        }
    }
}
