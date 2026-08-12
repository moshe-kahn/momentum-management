import AppKit
import Foundation
import SwiftUI

/// TASK-0043 capture boundary. These operations only create or transfer one
/// immediate Inbox payload; they intentionally have no Flow or ledger access.
enum ProductionsInboxCaptureOutcome: Equatable {
    case captured(URL)
    case deferred(String)
    case rejected(String)
}

struct ProductionsInboxCaptureService {
    private let manager: FileManager
    private let now: () -> Date
    private var observations: [String: Observation] = [:]

    init(manager: FileManager = .default, now: @escaping () -> Date = Date.init) { self.manager = manager; self.now = now }

    mutating func copyManual(source: URL, productionsRoot: URL) -> ProductionsInboxCaptureOutcome {
        guard let kind = eligibleKind(source) else { return .rejected("Select a readable, non-hidden file or folder; symbolic links and unsupported items cannot be captured.") }
        let inbox = productionsRoot.appending(path: "Office/Inbox", directoryHint: .isDirectory)
        guard validInbox(inbox) else { return .rejected("Office/Inbox is unavailable.") }
        let destination = inbox.appending(path: source.lastPathComponent, directoryHint: kind == .directory ? .isDirectory : .notDirectory)
        guard !manager.fileExists(atPath: destination.path) else { return .rejected("Inbox already contains an item named \(source.lastPathComponent).") }
        let temporary = inbox.appending(path: ".capture-\(UUID().uuidString)", directoryHint: kind == .directory ? .isDirectory : .notDirectory)
        do {
            try manager.copyItem(at: source, to: temporary)
            try manager.moveItem(at: temporary, to: destination)
            return .captured(destination)
        } catch {
            try? manager.removeItem(at: temporary)
            return .rejected("Manual capture failed: \(error.localizedDescription)")
        }
    }

    mutating func createTypedNote(text: String, productionsRoot: URL, now: Date = Date()) -> ProductionsInboxCaptureOutcome {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .rejected("Enter a nonblank note.") }
        let inbox = productionsRoot.appending(path: "Office/Inbox", directoryHint: .isDirectory)
        guard validInbox(inbox) else { return .rejected("Office/Inbox is unavailable.") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let stamp = formatter.string(from: now).replacingOccurrences(of: ":", with: "-")
        let destination = inbox.appending(path: "Quick Capture \(stamp).md")
        guard !manager.fileExists(atPath: destination.path) else { return .rejected("Inbox already contains \(destination.lastPathComponent).") }
        let contents = "# Quick Capture\n\nCreated: \(formatter.string(from: now))\nSource: Operations Dashboard\n\n\(text.hasSuffix("\\n") ? text : text + "\\n")"
        do { try Data(contents.utf8).write(to: destination, options: .withoutOverwriting); return .captured(destination) }
        catch { return .rejected("Quick Capture failed: \(error.localizedDescription)") }
    }

    mutating func observeAutomatic(sourceFolder: URL, productionsRoot: URL) -> [ProductionsInboxCaptureOutcome] {
        guard validFolder(sourceFolder) else { return [.rejected("Configured automatic source is not a readable non-symbolic-link folder.")] }
        let inbox = productionsRoot.appending(path: "Office/Inbox", directoryHint: .isDirectory)
        guard validInbox(inbox) else { return [.rejected("Office/Inbox is unavailable.")] }
        let entries: [URL]
        do { entries = try manager.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted { $0.path < $1.path } }
        catch { return [.rejected("Cannot enumerate automatic source: \(error.localizedDescription)")] }
        var results: [ProductionsInboxCaptureOutcome] = []
        for item in entries {
            guard let kind = eligibleKind(item), let current = fingerprint(item, kind: kind) else { results.append(.rejected("\(item.lastPathComponent) is hidden, symbolic, unreadable, or unsupported.")); continue }
            let key = item.standardizedFileURL.path
            guard let previous = observations[key], previous.fingerprint == current else { observations[key] = Observation(fingerprint: current, firstObserved: now()); results.append(.deferred("\(item.lastPathComponent) is waiting to remain unchanged for 2 seconds.")); continue }
            guard now().timeIntervalSince(previous.firstObserved) >= 2 else { results.append(.deferred("\(item.lastPathComponent) is waiting to remain unchanged for 2 seconds.")); continue }
            let destination = inbox.appending(path: item.lastPathComponent, directoryHint: kind == .directory ? .isDirectory : .notDirectory)
            guard !manager.fileExists(atPath: destination.path) else { results.append(.rejected("Inbox already contains an item named \(item.lastPathComponent).")); break }
            do { try manager.moveItem(at: item, to: destination); observations.removeValue(forKey: key); results.append(.captured(destination)) }
            catch { results.append(.rejected("Automatic capture failed for \(item.lastPathComponent): \(error.localizedDescription)")); break }
        }
        return results
    }

    private enum Kind { case file, directory }
    private struct CaptureFingerprint: Equatable { let kind: Kind; let size: Int; let modified: Date }
    private struct Observation { let fingerprint: CaptureFingerprint; let firstObserved: Date }
    private func validInbox(_ url: URL) -> Bool { validFolder(url) }
    private func validFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && manager.isReadableFile(atPath: url.path) && manager.isWritableFile(atPath: url.path) }
    private func eligibleKind(_ url: URL) -> Kind? {
        guard !url.lastPathComponent.hasPrefix("."), manager.isReadableFile(atPath: url.path) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
        if values.isRegularFile == true { return .file }; if values.isDirectory == true { return .directory }; return nil
    }
    private func fingerprint(_ url: URL, kind: Kind) -> CaptureFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return CaptureFingerprint(kind: kind, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
    }
}


/// App/ViewModel-owned lifecycle for the configured automatic source. It
/// continues after the capture sheet closes and owns exactly one polling task.
@MainActor
final class ProductionsAutomaticCaptureMonitor: ObservableObject {
    @Published private(set) var sourcePath: String
    @Published private(set) var latestOutcome: ProductionsInboxCaptureOutcome?
    private var service: ProductionsInboxCaptureService
    private var pollingTask: Task<Void, Never>?
    private var rootPath = ""
    private let storage: UserDefaults
    private let pollInterval: Duration
    static let sourceKey = "operations-dashboard.capture.automatic-source"

    init(storage: UserDefaults = .standard, pollInterval: Duration = .seconds(2), service: ProductionsInboxCaptureService = ProductionsInboxCaptureService()) {
        self.storage = storage; self.pollInterval = pollInterval; self.service = service
        sourcePath = storage.string(forKey: Self.sourceKey) ?? ""
    }
    var isMonitoring: Bool { pollingTask != nil }
    func start(productionsRootPath: String) {
        rootPath = productionsRootPath
        guard !sourcePath.isEmpty, !rootPath.isEmpty, pollingTask == nil else { return }
        let interval = pollInterval
        pollingTask = Task { [weak self, interval] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.observeNow()
                try? await Task.sleep(for: interval)
            }
        }
    }
    func configure(source: URL, productionsRootPath: String) {
        stop(); rootPath = productionsRootPath; sourcePath = source.standardizedFileURL.path
        storage.set(sourcePath, forKey: Self.sourceKey)
        latestOutcome = nil
        start(productionsRootPath: productionsRootPath)
    }
    func observeNow() {
        guard !sourcePath.isEmpty, !rootPath.isEmpty else { return }
        let outcomes = service.observeAutomatic(sourceFolder: URL(fileURLWithPath: sourcePath, isDirectory: true), productionsRoot: URL(fileURLWithPath: rootPath, isDirectory: true))
        latestOutcome = outcomes.last
    }
    func stop() { pollingTask?.cancel(); pollingTask = nil }
    deinit { pollingTask?.cancel() }
}

/// Thin TASK-0043 UI: all copying, typed-note creation, and stability checks
/// live in ProductionsInboxCaptureService and never call Flow registration.
struct ProductionsInboxCaptureSheet: View {
    let rootPath: String
    @ObservedObject var monitor: ProductionsAutomaticCaptureMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var service = ProductionsInboxCaptureService()
    @State private var note = ""
    @State private var message = ""

    private var root: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Inbox").font(.title2)
            Text("Capture creates an Inbox payload only. Flow registration happens separately after it arrives.").foregroundStyle(.secondary)
            GroupBox("File or folder") {
                HStack { Button("Choose and Copy…", action: copyManual); Spacer() }
            }
            GroupBox("Quick Capture") {
                TextEditor(text: $note).frame(minHeight: 100)
                HStack { Spacer(); Button("Save Note") { report(service.createTypedNote(text: note, productionsRoot: root)) }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            GroupBox("Automatic capture folder") {
                Text(monitor.sourcePath.isEmpty ? "No folder configured." : monitor.sourcePath).font(.caption).textSelection(.enabled)
                HStack {
                    Button("Choose Folder…", action: chooseAutomaticFolder)
                    Button("Check Now", action: monitor.observeNow).disabled(monitor.sourcePath.isEmpty)
                }
                Text(monitor.isMonitoring ? "Monitoring continues while the dashboard is open." : "Monitoring starts when a folder is configured and the dashboard is open.").font(.caption).foregroundStyle(.secondary)
                Text("Eligible immediate items are moved only after two unchanged observations. Conflicts remain in the source folder.").font(.caption).foregroundStyle(.secondary)
            }
            if let outcome = monitor.latestOutcome { outcomeText(outcome) }
            if !message.isEmpty { Text(message).foregroundStyle(message.hasPrefix("Captured") ? .green : .orange).textSelection(.enabled) }
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding().frame(minWidth: 620, minHeight: 460)
    }
    private func copyManual() { let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Copy to Inbox"; guard panel.runModal() == .OK, let source = panel.url else { return }; report(service.copyManual(source: source, productionsRoot: root)) }
    private func chooseAutomaticFolder() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Use Capture Folder"; guard panel.runModal() == .OK, let source = panel.url else { return }; monitor.configure(source: source, productionsRootPath: rootPath) }
    @ViewBuilder private func outcomeText(_ outcome: ProductionsInboxCaptureOutcome) -> some View { switch outcome { case let .captured(url): Text("Captured \(url.lastPathComponent). ").foregroundStyle(.green); case let .deferred(reason), let .rejected(reason): Text(reason).foregroundStyle(.orange) } }
    private func report(_ outcome: ProductionsInboxCaptureOutcome) { switch outcome { case let .captured(url): message = "Captured \(url.lastPathComponent)."; note = ""; case let .deferred(reason), let .rejected(reason): message = reason } }
}
