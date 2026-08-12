import AppKit
import SwiftUI

@MainActor
final class ProductionsDashboardViewModel: ObservableObject {
    struct IntakeDiagnostics: Equatable {
        var firstObservation: Date?
        var scheduledDeadline: Date?
        var callbackFired = false
        var secondObservationOutcome: String?
    }

    @Published private(set) var state: ProductionsState?
    @Published var rootPath = ""
    @Published private(set) var message: String?
    @Published private(set) var settingsIssues: [ProductionsIssue] = []
    @Published var selectedID: String?
    @Published private(set) var intakeResults: [InboxIntakeResult] = []
    @Published private(set) var intakeDiagnostics = IntakeDiagnostics()
    private let store: ProductionsConfigurationStore
    private let reader: any ProductionsReading
    private let opener: any SourceOpening
    private let registrationService: FlowRegistrationService
    private let automaticIntake: InboxAutomaticIntake
    private let scheduler: any InboxIntakeScheduling
    private let now: () -> Date
    private var intakeLifecycle: InboxAutomaticIntakeLifecycle?
    private var installedIntakeStarted = false

    init(store: ProductionsConfigurationStore = ProductionsConfigurationStore(), reader: any ProductionsReading = LocalFileSystem(), opener: any SourceOpening = WorkspaceSourceOpener(), registrationService: FlowRegistrationService = FlowRegistrationService(), automaticIntake: InboxAutomaticIntake? = nil, intakeScheduler: any InboxIntakeScheduling = DispatchInboxIntakeScheduler(), now: @escaping () -> Date = Date.init, initialConfiguration: ProductionsConfiguration? = nil) {
        self.store = store; self.reader = reader; self.opener = opener; self.registrationService = registrationService
        self.automaticIntake = automaticIntake ?? InboxAutomaticIntake(registration: registrationService)
        self.scheduler = intakeScheduler; self.now = now
        do {
            let configuration = try initialConfiguration.map { $0 } ?? store.load()
            if let configuration {
                rootPath = configuration.productionsRootPath
                readOnlyLoad(configuration)
                settingsIssues = state?.issues ?? []
            }
        } catch { message = error.localizedDescription }
    }

    /// Called by the installed SwiftUI lifecycle, never from init. It is
    /// idempotent across repeated appearances and owns the only recheck timer.
    func startAutomaticIntake() {
        guard !installedIntakeStarted, state?.issues.isEmpty == true else { return }
        installedIntakeStarted = true
        intakeLifecycle = InboxAutomaticIntakeLifecycle(scheduler: scheduler, delay: automaticIntake.quiescenceInterval, didFire: { [weak self] in
            guard let self else { return }
            self.intakeDiagnostics.callbackFired = true
            print("Operations Dashboard intake diagnostic: scheduled callback fired")
        }, scan: { [weak self] in self?.performAutomaticIntake() ?? [] })
        intakeResults = intakeLifecycle?.observe() ?? []
        if intakeResults.contains(where: { $0.outcome == .deferred }) {
            intakeDiagnostics.firstObservation = now()
            intakeDiagnostics.scheduledDeadline = now().addingTimeInterval(automaticIntake.quiescenceInterval)
            print("Operations Dashboard intake diagnostic: first observation; recheck scheduled")
        }
    }

    func chooseRoot() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Use Productions Folder"; guard panel.runModal() == .OK, let url = panel.url else { return }; rootPath = url.standardizedFileURL.path; preflightSelection() }
    func validate() { readOnlyLoad(ProductionsConfiguration(schemaVersion: 2, productionsRootPath: rootPath)); observeIntakeIfInstalled() }
    func saveAndLoad() { preflightSelection(); guard !hasBlockingSettingsIssues else { return }; let configuration = ProductionsConfiguration(schemaVersion: 2, productionsRootPath: rootPath); do { try store.save(configuration); readOnlyLoad(configuration); observeIntakeIfInstalled() } catch { message = error.localizedDescription } }
    func refresh() { validate() }
    func inboxFilesystemDidChange() { validate() }
    func retryRegistration(payload: FlowItem) { guard let configuration = state?.configuration else { return }; let result = automaticIntake.retry(configuration: configuration, payload: payload) { ProductionsLoader(reader: self.reader).load(configuration: $0) }; intakeResults = [result]; readOnlyLoad(configuration) }
    func retryProblem(for payload: FlowItem) -> String? { guard let result = intakeResults.first(where: { $0.payloadPath == payload.location }) else { return nil }; switch result.outcome { case .problem, .investigationRequired, .suspended: return result.reason; case .deferred, .registered: return nil } }
    func registrationPreview(payload: FlowItem, metadata: FlowRegistrationMetadata) throws -> FlowRegistrationPreview { guard let configuration = state?.configuration else { throw FlowRegistrationError.ineligible("Choose a valid Productions root before registering Inbox items.") }; return try registrationService.preview(configuration: configuration, payload: payload, metadata: metadata) }
    func register(payload: FlowItem, metadata: FlowRegistrationMetadata, preview: FlowRegistrationPreview) throws { guard let configuration = state?.configuration else { throw FlowRegistrationError.ineligible("Choose a valid Productions root before registering Inbox items.") }; try registrationService.commit(configuration: configuration, payload: payload, metadata: metadata, preview: preview) { ProductionsLoader(reader: self.reader).load(configuration: $0) }; readOnlyLoad(configuration) }
    func open(_ relativePath: String, directory: Bool = false) { guard let state else { return }; let url = state.configuration.url(relativePath, directory: directory); guard reader.exists(at: url), reader.isReadable(at: url) else { message = "Source is unavailable: \(relativePath)"; return }; do { try opener.open(url) } catch { message = error.localizedDescription } }
    var blockingSettingsIssues: [ProductionsIssue] { settingsIssues.filter { if case .missing = $0 { return true }; if case .unreadable = $0 { return true }; return false } }
    var hasBlockingSettingsIssues: Bool { !blockingSettingsIssues.isEmpty }
    func preflightSelection() { settingsIssues = ProductionsLoader(reader: reader).load(configuration: ProductionsConfiguration(schemaVersion: 2, productionsRootPath: rootPath)).issues }

    private func observeIntakeIfInstalled() { intakeResults = intakeLifecycle?.observe() ?? [] }
    private func performAutomaticIntake() -> [InboxIntakeResult] {
        guard let configuration = state?.configuration else { return [] }
        let before = state?.inbox ?? []
        let results = automaticIntake.scan(configuration: configuration, candidates: before) { ProductionsLoader(reader: self.reader).load(configuration: $0) }
        intakeResults = results
        readOnlyLoad(configuration)
        intakeDiagnostics.secondObservationOutcome = results.map { "\($0.payloadPath): \($0.reason)" }.joined(separator: " · ")
        intakeDiagnostics.scheduledDeadline = nil
        print("Operations Dashboard intake diagnostic: second observation outcome: \(intakeDiagnostics.secondObservationOutcome ?? "none")")
        return results
    }
    private func readOnlyLoad(_ configuration: ProductionsConfiguration) { let next = ProductionsLoader(reader: reader).load(configuration: configuration); state = next; message = next.issues.isEmpty ? nil : "\(next.issues.count) contract issue\(next.issues.count == 1 ? "" : "s")"; if selectedID == nil { selectedID = next.work.first?.id ?? next.processing.first?.id ?? next.inbox.first?.id } }
}

struct ProductionsDashboardView: View {
    @StateObject private var model = ProductionsDashboardViewModel()
    @State private var section = "Inbox"
    @State private var isShowingSettings = false
    private let sections = ["Inbox", "Processing", "Canvas", "Work", "Threads", "Detail"]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Operations Dashboard").font(.title2)
                Spacer()
                Button("Refresh") { model.refresh() }
                Button { isShowingSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("Productions settings")
            }
            if model.state == nil {
                setup
            } else {
                Picker("View", selection: $section) { ForEach(sections, id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
                content
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
                IntakeDiagnosticsView(diagnostics: model.intakeDiagnostics)
            }
        }
        .padding()
        .frame(minWidth: 780, minHeight: 540)
        .sheet(isPresented: $isShowingSettings) {
            ProductionsSettingsView(model: model, isPresented: $isShowingSettings)
        }
        .task { model.startAutomaticIntake() }
    }
    private var setup: some View { VStack(alignment: .leading, spacing: 10) { Text("Configure Productions root").font(.headline); Text("Version 2 reads the shared Productions system. Existing version 1 configuration remains untouched for recovery.").foregroundStyle(.secondary); Text(model.rootPath.isEmpty ? "No root selected" : model.rootPath).font(.caption).textSelection(.enabled); HStack { Button("Choose Productions Folder") { model.chooseRoot() }; Button("Save and Load") { model.saveAndLoad() }.disabled(model.rootPath.isEmpty) }; if let message = model.message { Text(message).foregroundStyle(.orange) } } }
    @ViewBuilder private var content: some View {
        if let state = model.state {
            switch section {
            case "Inbox": FlowList(title: "Inbox", items: state.inbox, select: { model.selectedID = $0 })
            case "Processing": FlowList(title: "Processing", items: state.processing, select: { model.selectedID = $0 })
            case "Canvas": CanvasList(state: state, select: { model.selectedID = $0 })
            case "Work": WorkList(items: state.work, canvas: state.canvasCurrentIDs, select: { model.selectedID = $0 })
            case "Threads": ThreadsList(crumbs: state.crumbs, mementos: state.mementos, select: { model.selectedID = $0 })
            default: DetailView(state: state, selectedID: model.selectedID, open: model.open, retry: model.retryRegistration, problem: model.retryProblem)
            }
        }
    }
}

private struct IntakeDiagnosticsView: View {
    let diagnostics: ProductionsDashboardViewModel.IntakeDiagnostics
    var body: some View {
        if diagnostics.firstObservation != nil || diagnostics.callbackFired {
            HStack(spacing: 10) {
                Text("Intake diagnostics").font(.caption.weight(.semibold))
                if let first = diagnostics.firstObservation { Text("first: \(first.formatted(date: .omitted, time: .standard))").font(.caption) }
                if let deadline = diagnostics.scheduledDeadline { Text("scheduled: \(deadline.formatted(date: .omitted, time: .standard))").font(.caption) }
                Text(diagnostics.callbackFired ? "callback fired" : "awaiting callback").font(.caption)
                if let outcome = diagnostics.secondObservationOutcome { Text(outcome).font(.caption).lineLimit(1) }
            }
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }
}

private struct ProductionsSettingsView: View {
    @ObservedObject var model: ProductionsDashboardViewModel
    @Binding var isPresented: Bool
    @State private var originalRootPath: String

    init(model: ProductionsDashboardViewModel, isPresented: Binding<Bool>) {
        self.model = model
        _isPresented = isPresented
        _originalRootPath = State(initialValue: model.rootPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Productions Settings").font(.title3)
            Text("The saved root is only this app’s local v2 configuration. It does not write to Productions.")
                .foregroundStyle(.secondary)
            Text(model.rootPath.isEmpty ? "No root selected" : model.rootPath)
                .font(.caption)
                .textSelection(.enabled)
            Button("Choose Root Folder") { model.chooseRoot() }
            if !model.blockingSettingsIssues.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top, spacing: 16) {
                        Text("Cannot save: \(model.blockingSettingsIssues.count) required contract path\(model.blockingSettingsIssues.count == 1 ? " is" : "s are") missing or unavailable.")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.red)
                            .frame(width: 245, alignment: .leading)
                        ScrollView {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(model.blockingSettingsIssues) { issue in
                                    Text(issue.message).font(.caption).foregroundStyle(.red)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 112)
                    }
                    Text("Creating missing contract paths is not available in the read-only phase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.28)) }
            } else if !model.rootPath.isEmpty {
                Text("Required paths are available. Save will remember this root locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.rootPath = originalRootPath
                    isPresented = false
                }
                Button("Save") {
                    model.saveAndLoad()
                    isPresented = false
                }
                .disabled(model.rootPath.isEmpty || model.hasBlockingSettingsIssues)
            }
        }
        .padding()
        .frame(minWidth: 500)
    }
}

private struct FlowList: View { let title: String; let items: [FlowItem]; let select: (String) -> Void; var body: some View { List(items) { item in Button { select(item.id) } label: { VStack(alignment: .leading) { Text("\(item.flowID ?? "Unregistered") · \(item.label)").font(.headline); Text(item.isUnregistered ? item.summary : "\(item.priority) · \(item.summary)").font(.caption).foregroundStyle(item.isUnregistered ? .orange : .secondary) } }.buttonStyle(.plain) }.overlay { if items.isEmpty { ContentUnavailableView("No \(title) items", systemImage: "tray") } } } }
private struct WorkList: View { let items: [WorkItem]; let canvas: Set<String>; let select: (String) -> Void; var body: some View { List(items) { item in Button { select(item.id) } label: { VStack(alignment: .leading) { Text("\(item.id) · \(item.title)").font(.headline); Text("\(item.kind.rawValue) · \(item.lifecycle) · \(item.priority)\(canvas.contains(item.id) ? " · On Canvas" : "")").font(.caption).foregroundStyle(.secondary) } }.buttonStyle(.plain) } } }
private struct CanvasList: View { let state: ProductionsState; let select: (String) -> Void; var body: some View { List(state.work.filter { state.canvasCurrentIDs.contains($0.id) }) { item in Button("\(item.id) · \(item.title)") { select(item.id) } }.overlay { if state.canvasCurrentIDs.isEmpty { ContentUnavailableView("Canvas is empty", systemImage: "rectangle.on.rectangle") } } } }
private struct ThreadsList: View {
    let crumbs: [Crumb]; let mementos: [Memento]; let select: (String) -> Void
    var body: some View {
        List {
            Section("Crumbs") { ForEach(crumbs) { crumb in Button("\(crumb.priority) · \(crumb.summary)") { select(crumb.target) } } }
            Section("Mementos") { ForEach(mementos) { memento in Button("\(memento.target) · \(memento.resumePoint)") { select(memento.target) } } }
        }
    }
}
private struct DetailView: View {
    let state: ProductionsState
    let selectedID: String?
    let open: (String, Bool) -> Void
    let retry: (FlowItem) -> Void
    let problem: (FlowItem) -> String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let work = state.work.first(where: { $0.id == selectedID }) {
                    Text("\(work.id) · \(work.title)").font(.title3)
                    Text("\(work.kind.rawValue) · \(work.lifecycle) · \(work.priority)")
                    Text(work.content ?? "Record unavailable").font(.caption).textSelection(.enabled)
                    HStack { Button("Open") { open(work.workspacePath, false) }; Button("Open Containing Folder") { open("Workspace/\(work.id)", true) } }
                } else if let flow = (state.inbox + state.processing).first(where: { $0.id == selectedID }) {
                    Text("\(flow.flowID ?? "Unregistered") · \(flow.label)").font(.title3)
                    Text(flow.summary)
                    Text(flow.bundleContent ?? "Inbox payload: \(flow.location)").font(.caption).textSelection(.enabled)
                    HStack {
                        Button("Open") { open(flow.location, flow.stage == "Processing") }
                        Button("Open Containing Folder") { open(flow.stage == "Inbox" ? "Office/Inbox" : "Office/Processing", true) }
                        if flow.isUnregistered, let reason = problem(flow) {
                            Text(reason).font(.caption).foregroundStyle(.orange)
                            Button("Retry registration") { retry(flow) }
                        }
                    }
                } else { ContentUnavailableView("Select an item", systemImage: "doc.text") }
                if !state.issues.isEmpty {
                    Divider(); Text("Contract issues").font(.headline)
                    ForEach(state.issues) { Text($0.message).font(.caption).foregroundStyle(.orange) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
