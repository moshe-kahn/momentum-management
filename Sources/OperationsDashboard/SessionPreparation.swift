import AppKit
import CryptoKit
import Foundation

enum SessionMode: String, Codable, Equatable { case start, resume }
enum SessionAuthorizationMode: String, CaseIterable, Codable, Identifiable, Equatable {
    case readOnly = "read-only"
    case diagnose
    case review
    case implement
    var id: String { rawValue }
}

struct SessionSourceFile: Codable, Equatable {
    let path: String
    let sha256: String
}

struct SessionSourceSnapshot: Codable, Equatable {
    let registry: SessionSourceFile
    let workspace: SessionSourceFile
    let mementoLedger: SessionSourceFile
    let extendedPayload: SessionSourceFile?
    var files: [SessionSourceFile] { [registry, workspace, mementoLedger] + [extendedPayload].compactMap { $0 } }
}

struct SessionBrief: Codable, Equatable {
    let workName, workID, workKind: String
    let sessionMode: SessionMode
    let authorizationMode: SessionAuthorizationMode
    let filesystemOrProjectRoot, recommendedModel, reasoningLevel: String
    let mementoName, mementoID: String?
    let currentStateOrLastValidatedState, naturalResumePointOrNextStep: String
    let requiredOutcome, verification, stoppingCondition: String
}

struct SessionContext: Codable, Equatable {
    let sessionIdentity, authorityAndScope: String
    let mementoContinuity: String?
    let canonicalObjectiveAndBoundaries, currentOrLastValidatedState: String
    let dependenciesAndRelationships, planAndRelevantLocations: String
    let executionInstructions, verificationRequirements: String
    let stoppingAndHandoffRequirements, canonicalSourceReferences: String
}

struct SessionPackage: Codable, Equatable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let preparedAt: Date
    let sourceSnapshot: SessionSourceSnapshot
    let brief: SessionBrief
    let context: SessionContext

    var briefText: String {
        var lines = [
            "# Brief",
            "Work: \(brief.workName) (\(brief.workID))",
            "Kind: \(brief.workKind)",
            "Session mode: \(brief.sessionMode.rawValue)",
            "Authorization: \(brief.authorizationMode.rawValue)",
            "Filesystem or project root: \(brief.filesystemOrProjectRoot)",
            "Recommended model: \(brief.recommendedModel)",
            "Reasoning level: \(brief.reasoningLevel)"
        ]
        if let name = brief.mementoName, let id = brief.mementoID { lines.append("Memento: \(name) (\(id))") }
        lines += [
            "Current or last validated state: \(brief.currentStateOrLastValidatedState)",
            "Natural resume point or next step: \(brief.naturalResumePointOrNextStep)",
            "Required outcome: \(brief.requiredOutcome)",
            "Verification: \(brief.verification)",
            "Stopping condition: \(brief.stoppingCondition)"
        ]
        return lines.joined(separator: "\n")
    }

    var contextText: String {
        var sections: [(String, String)] = [
            ("Session identity", context.sessionIdentity),
            ("Authority and scope", context.authorityAndScope)
        ]
        if let continuity = context.mementoContinuity { sections.append(("Memento continuity", continuity)) }
        sections += [
            ("Canonical objective and boundaries", context.canonicalObjectiveAndBoundaries),
            ("Current or last validated state", context.currentOrLastValidatedState),
            ("Dependencies and relationships", context.dependenciesAndRelationships),
            ("Plan and relevant locations", context.planAndRelevantLocations),
            ("Execution instructions", context.executionInstructions),
            ("Verification requirements", context.verificationRequirements),
            ("Stopping and handoff requirements", context.stoppingAndHandoffRequirements),
            ("Canonical source references", context.canonicalSourceReferences)
        ]
        return (["# Context"] + sections.flatMap { ["## \($0.0)", $0.1] }).joined(separator: "\n\n")
    }

    var displayedText: String { briefText + "\n\n" + contextText }
}

enum SessionPreparationError: LocalizedError, Equatable {
    case invalidInput(String)
    case contractConflict(String)
    case unresolved(String)
    case ambiguousRoots([String])
    case stalePreview(String)

    var errorDescription: String? {
        switch self {
        case let .invalidInput(message), let .contractConflict(message), let .unresolved(message), let .stalePreview(message): message
        case let .ambiguousRoots(paths): "Multiple validated roots remain. Select one before copying: \(paths.joined(separator: "; "))"
        }
    }
}

struct SessionPackageRenderer {
    let manager: FileManager
    let now: () -> Date

    init(manager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.manager = manager; self.now = now
    }

    private struct Subject {
        let id, name, kind, lifecycle, priority, product, recordPath, registryPath, registryDescription: String
        let related, dependencies: [String]
        let workspace: WorkspaceRecord
        let permitsStartFallback: Bool
    }

    func prepare(
        state: ProductionsState,
        workID: String,
        authorization: SessionAuthorizationMode = .readOnly,
        recommendedModel: String,
        reasoningLevel: String,
        selectedRoot: String? = nil
    ) throws -> SessionPackage {
        guard state.issues.isEmpty else { throw SessionPreparationError.contractConflict(state.issues.map(\.message).joined(separator: " · ")) }
        guard !recommendedModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reasoningLevel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SessionPreparationError.invalidInput("Recommended model and reasoning level are required ephemeral inputs.")
        }
        let subject: Subject
        if let work = state.work.first(where: { $0.id == workID }), let workspace = work.workspace {
            let registryPath: String
            switch work.kind {
            case .task: registryPath = ProductionsPath.tasks.rawValue
            case .idea: registryPath = ProductionsPath.ideas.rawValue
            case .project: registryPath = ProductionsPath.projects.rawValue
            case .initiative: registryPath = ProductionsPath.initiatives.rawValue
            }
            subject = Subject(id: work.id, name: work.title, kind: work.kind.rawValue, lifecycle: work.lifecycle, priority: work.priority, product: work.product, recordPath: work.workspacePath, registryPath: registryPath, registryDescription: work.registryDescription, related: work.related, dependencies: work.dependencies, workspace: workspace, permitsStartFallback: true)
        } else if let bundle = state.processing.first(where: { $0.flowID == workID }), let id = bundle.flowID, let content = bundle.bundleContent {
            subject = Subject(id: id, name: bundle.label, kind: "Processing bundle", lifecycle: "Processing", priority: bundle.priority, product: "", recordPath: "\(bundle.location)/\(id).md", registryPath: ProductionsPath.flow.rawValue, registryDescription: bundle.summary, related: [], dependencies: [], workspace: try WorkspaceMarkdown.parse(content), permitsStartFallback: false)
        } else {
            throw SessionPreparationError.unresolved("The selected Registry-backed work or Processing bundle record must resolve.")
        }
        let matching = state.mementos.filter { $0.target == workID }
        guard matching.count <= 1 else { throw SessionPreparationError.contractConflict("The selected work has duplicate live Mementos.") }
        let memento = matching.first
        guard memento != nil || subject.permitsStartFallback else { throw SessionPreparationError.contractConflict("Processing bundles require one validated current Memento; the no-Memento start fallback is Registry-only.") }
        let workspace = subject.workspace
        let root = try resolveRoot(subject: subject, workspace: workspace, memento: memento, products: state.products, productionsRoot: state.configuration.rootURL, selectedRoot: selectedRoot)
        let snapshot = try sourceSnapshot(subject: subject, memento: memento, configuration: state.configuration)

        let objective = value(workspace.field("Objective or question"), fallback: subject.registryDescription)
        let next = value(workspace.field("Next step"), fallback: "Revalidate the canonical record and choose the next bounded step.")
        let completion = value(workspace.field("Completion or resolution criterion"), fallback: "Satisfy the canonical completion or resolution criterion.")
        let lastValidated = value(workspace.field("Last validated state"), fallback: subject.registryDescription)
        let verification = firstNonempty([workspace.section("QA"), workspace.section("QA plan"), workspace.section("Acceptance Matrix")], fallback: "Run the verification required by the canonical record and report exact results.")
        let boundaries = firstNonempty([workspace.section("Delivery Boundary"), workspace.section("Boundaries"), workspace.section("Exclusions"), workspace.section("Protected state"), workspace.section("Protected Integration State")], fallback: "Do not exceed the canonical record or this explicit authorization mode.")
        let plan = firstNonempty([workspace.section("Plan"), workspace.section("Steps")], fallback: next)
        let locations = value(workspace.field("Relevant locations"), fallback: subject.recordPath)
        let capturedState = markMutable(memento?.currentState ?? lastValidated)
        let capturedNext = markMutable(memento?.naturalResumePoint ?? next)
        let stop = "Stop when the required outcome is verified, a canonical conflict is found, or further work needs new authority; leave an explicit handoff."
        let administrativeHandoff = """
        Administrative handoff boundary: Product and repository sessions do not improvise canonical Productions administration. Return an administrative request to the Productions Office Administrator as a structured handoff containing the requested operation; proposed durable target or an explicit statement that the thought is untargeted; concise title or summary; proposed Crumb kind and priority when applicable; current validated task and repository state; source or evidence location; exact continuation or next-action implication; and explicit boundaries on what was not authorized or performed. For a stray untargeted thought, use Quick Capture into `Office/Inbox/`; capture creates an unregistered payload only and does not approve, classify, register, or start work. Persistent administrator authority is defined at `/Users/kahntra/Productions/PRODUCTIONS_OFFICE_ADMINISTRATOR.md`; product sessions do not gain that authority and need not rediscover the charter through repository instructions merely to return a handoff.
        """
        let relationships = "Dependencies: \(list(subject.dependencies)). Relationships: \(list(subject.related)). Product: \(value(subject.product, fallback: "—"))."
        let sourceReferences = snapshot.files.map { "`\($0.path)` SHA-256 \($0.sha256)" }.joined(separator: "\n")
        let authority = "Authorization is ephemeral \(authorization.rawValue). Registry lifecycle, Workspace boundaries, and narrower canonical restrictions remain authoritative and are not modified by this package."
        let continuity = memento.map { item in
            var text = "Resume \(item.summary) (\(item.id)). Current state: \(markMutable(item.currentState)). Natural resume point: \(markMutable(item.naturalResumePoint)). Open Crumbs remain deliberate and unresolved: \(list(item.openCrumbs))."
            if let payload = item.extendedPayloadContent { text += " Supplementary extended payload (cannot override the target):\n\(markMutable(payload))" }
            return text
        }
        let brief = SessionBrief(
            workName: subject.name, workID: subject.id, workKind: subject.kind,
            sessionMode: memento == nil ? .start : .resume, authorizationMode: authorization,
            filesystemOrProjectRoot: root, recommendedModel: recommendedModel, reasoningLevel: reasoningLevel,
            mementoName: memento?.summary, mementoID: memento?.id,
            currentStateOrLastValidatedState: capturedState,
            naturalResumePointOrNextStep: capturedNext,
            requiredOutcome: completion, verification: verification, stoppingCondition: stop
        )
        let context = SessionContext(
            sessionIdentity: "Prepare \(brief.sessionMode.rawValue) session for \(subject.name) (\(subject.id)), a \(subject.kind) in \(subject.lifecycle) at \(subject.priority) priority. Recommended model: \(recommendedModel); reasoning: \(reasoningLevel); resolved root: \(root).",
            authorityAndScope: authority,
            mementoContinuity: continuity,
            canonicalObjectiveAndBoundaries: "Objective or question: \(objective)\nBoundaries and protected state:\n\(boundaries)\nRequired outcome: \(completion)",
            currentOrLastValidatedState: capturedState,
            dependenciesAndRelationships: relationships,
            planAndRelevantLocations: "Plan and steps:\n\(plan)\nRelevant locations:\n\(locations)",
            executionInstructions: "Begin at: \(capturedNext)\nRevalidate every item marked Captured before relying on it. Preserve unknown canonical content and remain within \(authorization.rawValue) authority.",
            verificationRequirements: verification,
            stoppingAndHandoffRequirements: "\(stop)\n\n\(administrativeHandoff)",
            canonicalSourceReferences: sourceReferences
        )
        return SessionPackage(schemaVersion: SessionPackage.currentSchemaVersion, preparedAt: now(), sourceSnapshot: snapshot, brief: brief, context: context)
    }

    private func sourceSnapshot(subject: Subject, memento: Memento?, configuration: ProductionsConfiguration) throws -> SessionSourceSnapshot {
        return SessionSourceSnapshot(
            registry: try snapshot(subject.registryPath, configuration: configuration),
            workspace: try snapshot(subject.recordPath, configuration: configuration),
            mementoLedger: try snapshot(ProductionsPath.mementos.rawValue, configuration: configuration),
            extendedPayload: try memento?.extendedPayloadPath.map { try snapshot($0, configuration: configuration) }
        )
    }

    private func snapshot(_ path: String, configuration: ProductionsConfiguration) throws -> SessionSourceFile {
        let root = configuration.rootURL.standardizedFileURL
        let url = root.appending(path: path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), manager.fileExists(atPath: url.path) else { throw SessionPreparationError.unresolved("Session source does not resolve safely: \(path)") }
        var component = root
        for name in url.pathComponents.dropFirst(root.pathComponents.count) {
            component.append(path: name)
            guard !isSymlink(component) else { throw SessionPreparationError.unresolved("Session source is symlinked: \(path)") }
        }
        let data = try Data(contentsOf: url)
        return SessionSourceFile(path: path, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func resolveRoot(subject: Subject, workspace: WorkspaceRecord, memento: Memento?, products: [ProductRecord], productionsRoot: URL, selectedRoot: String?) throws -> String {
        let tiers = [
            directoryCandidates(in: [memento?.currentState, memento?.naturalResumePoint, memento?.extendedPayloadContent].compactMap { $0 }),
            directoryCandidates(in: [workspace.field("Relevant locations")]),
            productCandidates(for: subject, products: products),
            [productionsRoot.standardizedFileURL.path]
        ]
        for tier in tiers {
            let validated = Array(Set(tier.compactMap(validateDirectory))).sorted()
            guard !validated.isEmpty else { continue }
            if let selectedRoot {
                let selected = URL(fileURLWithPath: selectedRoot, isDirectory: true).standardizedFileURL.path
                guard validated.contains(selected) else { throw SessionPreparationError.unresolved("The selected root is not a validated candidate.") }
                return selected
            }
            if validated.count == 1 { return validated[0] }
            throw SessionPreparationError.ambiguousRoots(validated)
        }
        throw SessionPreparationError.unresolved("No safe filesystem or project root resolves.")
    }

    private func productCandidates(for subject: Subject, products: [ProductRecord]) -> [String] {
        let ids = subject.product.matches(of: /PROD-[0-9]{4,}/).map { String($0.output) }
        let matches = products.filter { ids.contains($0.id) || (!subject.product.isEmpty && subject.product.localizedCaseInsensitiveContains($0.name)) }
        return matches.map(\.canonicalWorkspace)
    }

    private func directoryCandidates(in values: [String]) -> [String] {
        values.flatMap { value in
            var result: [String] = []
            let pattern = #"`(/[^`]+)`|\[.*?\]\((/[^)]+)\)|(?:(?<=^)|(?<=[;\n]))\s*(/[^;\n]+)"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            for match in regex.matches(in: value, range: range) {
                for index in 1..<match.numberOfRanges where match.range(at: index).location != NSNotFound {
                    if let swiftRange = Range(match.range(at: index), in: value) {
                        result.append(String(value[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines))
                        break
                    }
                }
            }
            return result
        }
    }

    private func validateDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue, !isSymlink(url) else { return nil }
        return url.path
    }

    private func isSymlink(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    private func value(_ value: String, fallback: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value == "—" ? fallback : value }
    private func firstNonempty(_ values: [String], fallback: String) -> String { values.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? fallback }
    private func list(_ values: [String]) -> String { values.isEmpty ? "—" : values.joined(separator: "; ") }
    private func markMutable(_ value: String) -> String {
        let mutable = #"(?i)\b(repository|repo|branch|worktree|process|pid|file|path|hash|sha(?:-?256)?|tests?|suite|commit|build)\b"#
        guard value.range(of: mutable, options: .regularExpression) != nil else { return value }
        return "[Captured; revalidate before reliance] \(value)"
    }
}

protocol SessionPasteboardWriting { func write(_ text: String) throws }
struct SystemSessionPasteboard: SessionPasteboardWriting {
    func write(_ text: String) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { throw SessionPreparationError.unresolved("The session package could not be written to the pasteboard.") }
    }
}

struct SessionPreparationService {
    let renderer: SessionPackageRenderer
    let pasteboard: any SessionPasteboardWriting

    init(renderer: SessionPackageRenderer = SessionPackageRenderer(), pasteboard: any SessionPasteboardWriting = SystemSessionPasteboard()) {
        self.renderer = renderer; self.pasteboard = pasteboard
    }

    func copy(_ package: SessionPackage, configuration: ProductionsConfiguration) throws {
        for source in package.sourceSnapshot.files {
            let root = configuration.rootURL.standardizedFileURL
            let url = root.appending(path: source.path).standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: url.path) else { throw SessionPreparationError.stalePreview("\(source.path) no longer resolves safely; regenerate before Copy.") }
            var component = root
            for name in url.pathComponents.dropFirst(root.pathComponents.count) {
                component.append(path: name)
                guard (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw SessionPreparationError.stalePreview("\(source.path) became symlinked; regenerate before Copy.") }
            }
            let data = try Data(contentsOf: url)
            let current = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard current == source.sha256 else { throw SessionPreparationError.stalePreview("\(source.path) changed after preview; regenerate before Copy.") }
        }
        try pasteboard.write(package.displayedText)
    }
}

enum SessionStartOutcome: Equatable {
    case prepared(CanvasWorkTransactionResult, SessionPackage)
    case canvasCommittedPackageFailed(String)
}

struct SessionPreparationCoordinator {
    let canvas: CanvasWorkTransactionService
    let renderer: SessionPackageRenderer
    let reader: any ProductionsReading

    func startWorkAndPrepare(configuration: ProductionsConfiguration, work: WorkItem, reason: String, context: String, authorization: SessionAuthorizationMode, recommendedModel: String, reasoningLevel: String, selectedRoot: String? = nil) throws -> SessionStartOutcome {
        let loader = ProductionsLoader(reader: reader)
        let result: CanvasWorkTransactionResult
        do {
            result = try canvas.perform(action: .start, configuration: configuration, work: work, reason: reason, context: context, reload: loader.load)
        } catch let error as CanvasWorkTransactionError {
            if case let .reloadFailed(message) = error { return .canvasCommittedPackageFailed(message) }
            throw error
        }
        let reloaded = loader.load(configuration: configuration)
        do {
            return .prepared(result, try renderer.prepare(state: reloaded, workID: work.id, authorization: authorization, recommendedModel: recommendedModel, reasoningLevel: reasoningLevel, selectedRoot: selectedRoot))
        } catch {
            return .canvasCommittedPackageFailed("Canvas committed; session package rendering failed and Canvas was not retried: \(error.localizedDescription)")
        }
    }
}
