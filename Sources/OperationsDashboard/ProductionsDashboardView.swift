import AppKit
import SwiftUI
import OSLog

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
    @Published private(set) var noticeSeverity: ProductionsNoticeSeverity = .information
    @Published private(set) var settingsIssues: [ProductionsIssue] = []
    @Published var selectedID: String?
    @Published private(set) var intakeResults: [InboxIntakeResult] = []
    @Published private(set) var intakeDiagnostics = IntakeDiagnostics()
    @Published private(set) var sessionPackage: SessionPackage?
    let captureMonitor: ProductionsAutomaticCaptureMonitor
    private let store: ProductionsConfigurationStore
    private let reader: any ProductionsReading
    private let opener: any SourceOpening
    private let registrationService: FlowRegistrationService
    private let canvasWorkService: CanvasWorkTransactionService
    private let sessionService: SessionPreparationService
    private let mementoService: MementoTransactionService
    private let automaticIntake: InboxAutomaticIntake
    private let scheduler: any InboxIntakeScheduling
    private let now: () -> Date
    private var intakeLifecycle: InboxAutomaticIntakeLifecycle?
    private var installedIntakeStarted = false
    private var isExecutingScheduledObservation = false
    private let instanceID = UUID().uuidString

    init(store: ProductionsConfigurationStore = ProductionsConfigurationStore(), reader: any ProductionsReading = LocalFileSystem(), opener: any SourceOpening = WorkspaceSourceOpener(), registrationService: FlowRegistrationService = FlowRegistrationService(), canvasWorkService: CanvasWorkTransactionService = CanvasWorkTransactionService(), sessionService: SessionPreparationService = SessionPreparationService(), mementoService: MementoTransactionService = MementoTransactionService(), automaticIntake: InboxAutomaticIntake? = nil, intakeScheduler: any InboxIntakeScheduling = DispatchInboxIntakeScheduler(), now: @escaping () -> Date = Date.init, initialConfiguration: ProductionsConfiguration? = nil) {
        self.store = store; self.reader = reader; self.opener = opener; self.registrationService = registrationService
        self.canvasWorkService = canvasWorkService
        self.sessionService = sessionService; self.mementoService = mementoService
        self.automaticIntake = automaticIntake ?? InboxAutomaticIntake(registration: registrationService)
        self.scheduler = intakeScheduler; self.now = now; self.captureMonitor = ProductionsAutomaticCaptureMonitor()
        IntakeLifecycleLog.event(instanceID, "ViewModel created")
        do {
            let configuration = try initialConfiguration.map { $0 } ?? store.load()
            if let configuration {
                rootPath = configuration.productionsRootPath
                readOnlyLoad(configuration)
                settingsIssues = state?.issues ?? []
            }
        } catch { setMessage(error.localizedDescription, severity: .failure) }
    }

    /// Called by the installed SwiftUI lifecycle, never from init. It is
    /// idempotent across repeated appearances and owns the only recheck timer.
    func startAutomaticCaptureMonitoring() { captureMonitor.start(productionsRootPath: rootPath) }

    func startAutomaticIntake() {
        IntakeLifecycleLog.event(instanceID, "startAutomaticIntake entry")
        guard !installedIntakeStarted, state?.issues.isEmpty == true else { IntakeLifecycleLog.event(instanceID, "startAutomaticIntake idempotence/config rejection"); return }
        installedIntakeStarted = true
        intakeLifecycle = InboxAutomaticIntakeLifecycle(scheduler: scheduler, delay: automaticIntake.quiescenceInterval, didFire: { [weak self] in
            guard let self else { return }
            self.intakeDiagnostics.callbackFired = true
            self.isExecutingScheduledObservation = true
            IntakeLifecycleLog.event(self.instanceID, "ViewModel received scheduled callback")
        }, scan: { [weak self] in self?.performAutomaticIntake() ?? [] })
        intakeResults = intakeLifecycle?.observe() ?? []
        if intakeResults.contains(where: { $0.outcome == .deferred }) {
            intakeDiagnostics.firstObservation = now()
            intakeDiagnostics.scheduledDeadline = now().addingTimeInterval(automaticIntake.quiescenceInterval)
            IntakeLifecycleLog.event(instanceID, "first observation; recheck scheduled")
        }
    }

    func chooseRoot() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Use Productions Folder"; guard panel.runModal() == .OK, let url = panel.url else { return }; rootPath = url.standardizedFileURL.path; preflightSelection() }
    func validate() { readOnlyLoad(ProductionsConfiguration(schemaVersion: 2, productionsRootPath: rootPath)); observeIntakeIfInstalled() }
    func saveAndLoad() { preflightSelection(); guard !hasBlockingSettingsIssues else { return }; let configuration = ProductionsConfiguration(schemaVersion: 2, productionsRootPath: rootPath); do { try store.save(configuration); readOnlyLoad(configuration); observeIntakeIfInstalled(); startAutomaticCaptureMonitoring() } catch { setMessage(error.localizedDescription, severity: .failure) } }
    func refresh() { validate() }
    func inboxFilesystemDidChange() { validate() }
    func retryRegistration(payload: FlowItem) { guard let configuration = state?.configuration else { return }; let result = automaticIntake.retry(configuration: configuration, payload: payload) { ProductionsLoader(reader: self.reader).load(configuration: $0) }; intakeResults = [result]; readOnlyLoad(configuration) }
    func retryProblem(for payload: FlowItem) -> String? { guard let result = intakeResults.first(where: { $0.payloadPath == payload.location }) else { return nil }; switch result.outcome { case .problem, .investigationRequired, .suspended: return result.reason; case .deferred, .registered: return nil } }
    func registrationPreview(payload: FlowItem, metadata: FlowRegistrationMetadata) throws -> FlowRegistrationPreview { guard let configuration = state?.configuration else { throw FlowRegistrationError.ineligible("Choose a valid Productions root before registering Inbox items.") }; return try registrationService.preview(configuration: configuration, payload: payload, metadata: metadata) }
    func register(payload: FlowItem, metadata: FlowRegistrationMetadata, preview: FlowRegistrationPreview) throws { guard let configuration = state?.configuration else { throw FlowRegistrationError.ineligible("Choose a valid Productions root before registering Inbox items.") }; try registrationService.commit(configuration: configuration, payload: payload, metadata: metadata, preview: preview, expectedPayloadState: preview.payloadState) { ProductionsLoader(reader: self.reader).load(configuration: $0) }; readOnlyLoad(configuration) }
    func performCanvasAction(_ action: CanvasWorkAction, work: WorkItem, reason: String, context: String) {
        guard let configuration = state?.configuration else { setMessage("Choose a valid Productions root before changing Canvas.", severity: .warning); return }
        do {
            if action == .start {
                let outcome = try SessionPreparationCoordinator(canvas: canvasWorkService, renderer: sessionService.renderer, reader: reader).startWorkAndPrepare(configuration: configuration, work: work, reason: reason, context: context, authorization: .readOnly, recommendedModel: "Codex", reasoningLevel: "high")
                readOnlyLoad(configuration)
                switch outcome {
                case let .prepared(result, package):
                    sessionPackage = package
                    setMessage("Start work recorded for \(work.title) (\(work.id)): \(result.appendedEvents.joined(separator: ", ")). Session package prepared.", severity: .success)
                case let .canvasCommittedPackageFailed(diagnostic):
                    setMessage(diagnostic, severity: .warning)
                }
            } else {
                let result = try canvasWorkService.perform(action: action, configuration: configuration, work: work, reason: reason, context: context) { ProductionsLoader(reader: self.reader).load(configuration: $0) }
                readOnlyLoad(configuration)
                setMessage("\(result.action.title) recorded for \(work.title) (\(work.id)): \(result.appendedEvents.joined(separator: ", ")).", severity: .success)
            }
        } catch { setMessage(error.localizedDescription, severity: .failure) }
    }
    func prepareSession(work: WorkItem, authorization: SessionAuthorizationMode = .readOnly, model: String = "Codex", reasoning: String = "high") {
        prepareSession(targetID: work.id, authorization: authorization, model: model, reasoning: reasoning)
    }
    func prepareSession(targetID: String, authorization: SessionAuthorizationMode = .readOnly, model: String = "Codex", reasoning: String = "high") {
        guard let state else { setMessage("Choose a valid Productions root before preparing a session.", severity: .warning); return }
        do { sessionPackage = try sessionService.renderer.prepare(state: state, workID: targetID, authorization: authorization, recommendedModel: model, reasoningLevel: reasoning); setMessage("Session package prepared without changing Productions.", severity: .success) }
        catch { sessionPackage = nil; setMessage(error.localizedDescription, severity: .failure) }
    }
    func copyPreparedSession() {
        guard let package = sessionPackage, let configuration = state?.configuration else { setMessage("Prepare a session package before Copy.", severity: .warning); return }
        do { try sessionService.copy(package, configuration: configuration); setMessage("The displayed session package was copied; Productions was unchanged.", severity: .success) }
        catch { sessionPackage = nil; setMessage(error.localizedDescription, severity: .failure) }
    }
    func mutateMemento(action: MementoTransactionAction, work: WorkItem, draft: MementoDraft? = nil) {
        mutateMemento(action: action, targetID: work.id, displayName: work.title, draft: draft)
    }
    func mutateMemento(action: MementoTransactionAction, targetID: String, displayName: String, draft: MementoDraft? = nil) {
        guard let configuration = state?.configuration else { setMessage("Choose a valid Productions root before changing a Memento.", severity: .warning); return }
        let reload = { ProductionsLoader(reader: self.reader).load(configuration: $0) }
        do {
            let result: MementoTransactionResult
            switch action {
            case .create, .supersede:
                guard let draft else { setMessage("A complete Memento draft is required.", severity: .warning); return }
                result = action == .create
                    ? try mementoService.create(configuration: configuration, targetID: targetID, draft: draft, reload: reload)
                    : try mementoService.supersede(configuration: configuration, targetID: targetID, draft: draft, reload: reload)
            case .resolve: result = try mementoService.resolve(configuration: configuration, targetID: targetID, reload: reload)
            }
            readOnlyLoad(configuration); sessionPackage = nil
            setMessage("\(result.action.rawValue.capitalized) Memento \(result.mementoID) for \(displayName) (\(targetID)). Open Crumbs were not automatically resolved.", severity: .success)
        } catch { setMessage(error.localizedDescription, severity: .failure) }
    }
    func open(_ relativePath: String, directory: Bool = false) { guard let state else { return }; let url = state.configuration.url(relativePath, directory: directory); guard reader.exists(at: url), reader.isReadable(at: url) else { setMessage("Source is unavailable: \(relativePath)", severity: .warning); return }; do { try opener.open(url) } catch { setMessage(error.localizedDescription, severity: .failure) } }
    var blockingSettingsIssues: [ProductionsIssue] { settingsIssues.filter { if case .missing = $0 { return true }; if case .unreadable = $0 { return true }; return false } }
    var hasBlockingSettingsIssues: Bool { !blockingSettingsIssues.isEmpty }
    func preflightSelection() { settingsIssues = ProductionsLoader(reader: reader).load(configuration: ProductionsConfiguration(schemaVersion: 2, productionsRootPath: rootPath)).issues }
    func select(targetID: String?) { selectedID = targetID }
    func reconcileSelection(for section: ProductionsNavigationSection, departmentFilter: ProductionsDepartmentFilter = .all, searchText: String = "", currentRowID: String? = nil) -> ProductionsSelection? {
        guard let state else { selectedID = nil; return nil }
        let selection = ProductionsDashboardPresentation.reconciledSelection(currentTargetID: selectedID, currentRowID: currentRowID, section: section, state: state, departmentFilter: departmentFilter, searchText: searchText)
        selectedID = selection?.targetID
        return selection
    }

    private func observeIntakeIfInstalled() { intakeResults = intakeLifecycle?.observe() ?? [] }
    private func performAutomaticIntake() -> [InboxIntakeResult] {
        guard let configuration = state?.configuration else { return [] }
        let before = state?.inbox ?? []
        let results = automaticIntake.scan(configuration: configuration, candidates: before) { ProductionsLoader(reader: self.reader).load(configuration: $0) }
        intakeResults = results
        readOnlyLoad(configuration)
        if isExecutingScheduledObservation {
            intakeDiagnostics.secondObservationOutcome = results.map { "\($0.payloadPath): \($0.reason)" }.joined(separator: " · ")
            intakeDiagnostics.scheduledDeadline = nil
            isExecutingScheduledObservation = false
            IntakeLifecycleLog.event(instanceID, "scheduled observation outcome recorded")
        } else {
            IntakeLifecycleLog.event(instanceID, "initial observation completed")
        }
        return results
    }
    private func readOnlyLoad(_ configuration: ProductionsConfiguration) {
        let next = ProductionsLoader(reader: reader).load(configuration: configuration)
        state = next
        if next.issues.isEmpty {
            setMessage(nil, severity: .information)
        } else {
            setMessage("\(next.issues.count) contract issue\(next.issues.count == 1 ? "" : "s")", severity: .warning)
        }
        if selectedID == nil {
            selectedID = next.inbox.first?.id ?? next.processing.first?.id ?? next.work.first?.id
        }
    }

    private func setMessage(_ value: String?, severity: ProductionsNoticeSeverity) {
        message = value
        noticeSeverity = severity
    }

    deinit { IntakeLifecycleLog.event(instanceID, "ViewModel destruction") }
}

struct ProductionsDashboardView: View {
    @StateObject private var model = ProductionsDashboardViewModel()
    @State private var section: ProductionsNavigationSection? = .inbox
    @State private var departmentFilter: ProductionsDepartmentFilter = .all
    @State private var selectedRowID: String?
    @State private var searchText = ""
    @State private var isShowingSettings = false
    @State private var isShowingCapture = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dashboardHeader
            if model.state == nil {
                setup.padding()
            } else {
                if let message = model.message {
                    NoticeBanner(message: message, severity: model.noticeSeverity)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
                navigation
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $isShowingSettings) {
            ProductionsSettingsView(model: model, isPresented: $isShowingSettings)
        }
        .sheet(isPresented: $isShowingCapture) {
            ProductionsInboxCaptureSheet(rootPath: model.rootPath, monitor: model.captureMonitor)
        }
        .task {
            model.startAutomaticIntake()
            model.startAutomaticCaptureMonitoring()
            reconcileSelection()
        }
        .onChange(of: section) { _, newSection in
            guard newSection != nil else { section = .inbox; return }
            searchText = ""
            selectedRowID = nil
            reconcileSelection()
        }
        .onChange(of: departmentFilter) { _, _ in
            reconcileSelection()
        }
        .onChange(of: searchText) { _, _ in reconcileSelection() }
        .onChange(of: selectedRowID) { _, rowID in
            guard let state = model.state,
                  let rowID,
                  let item = ProductionsDashboardPresentation.filteredItems(for: currentSection, in: state, departmentFilter: departmentFilter, searchText: searchText).first(where: { $0.id == rowID }) else { return }
            model.select(targetID: item.targetID)
        }
        .onChange(of: model.state) { _, state in
            if let state, !ProductionsDashboardPresentation.departmentFilters(in: state).contains(departmentFilter) {
                departmentFilter = .all
            }
            reconcileSelection()
        }
    }

    private var currentSection: ProductionsNavigationSection { section ?? .inbox }

    private var dashboardHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Momentum Management").font(.title2.weight(.semibold))
                Text("Operations Dashboard").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.state == nil)
                .accessibilityHint("Reloads canonical sources and preserves a valid selection.")
            Button { isShowingCapture = true } label: { Label("Add to Inbox", systemImage: "tray.and.arrow.down") }
                .disabled(model.state == nil)
            Button { isShowingSettings = true } label: { Image(systemName: "gearshape") }
                .accessibilityLabel("Productions settings")
        }
        .padding()
    }

    private var navigation: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 165, ideal: 190, max: 230)
        } content: {
            itemList
                .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 430)
        } detail: {
            detail
        }
    }

    private var sidebar: some View {
        List(selection: $section) {
            if let state = model.state {
                Section("Department") {
                    Picker("Department", selection: $departmentFilter) {
                        ForEach(ProductionsDashboardPresentation.departmentFilters(in: state)) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Department filter")
                    .accessibilityValue(departmentFilter.title)
                }
                ForEach(ProductionsNavigationGroup.allCases) { group in
                    Section(group.rawValue) {
                        ForEach(ProductionsDashboardPresentation.sections(in: group)) { itemSection in
                            HStack {
                                Label(itemSection.title, systemImage: itemSection.systemImage)
                                Spacer()
                                Text(ProductionsDashboardPresentation.count(for: itemSection, in: state, departmentFilter: departmentFilter), format: .number)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .tag(itemSection)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(itemSection.title), \(ProductionsDashboardPresentation.count(for: itemSection, in: state, departmentFilter: departmentFilter)) items, \(departmentFilter.title)")
                        }
                    }
                }
            }
        }
        .navigationTitle("Browse")
    }

    @ViewBuilder private var itemList: some View {
        if let state = model.state {
            let allItems = ProductionsDashboardPresentation.items(for: currentSection, in: state, departmentFilter: departmentFilter)
            let visibleItems = ProductionsDashboardPresentation.filteredItems(for: currentSection, in: state, departmentFilter: departmentFilter, searchText: searchText)
            ProductionsItemList(
                title: currentSection.title,
                emptyTitle: currentSection.emptyTitle,
                systemImage: currentSection.systemImage,
                items: visibleItems,
                hasSearchQuery: !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                hasUnfilteredItems: !allItems.isEmpty,
                selectedRowID: $selectedRowID
            )
            .searchable(text: $searchText, prompt: "Search \(currentSection.title)")
        }
    }

    @ViewBuilder private var detail: some View {
        if let state = model.state {
            DetailView(
                state: state,
                selectedID: model.selectedID,
                sessionPackage: model.sessionPackage,
                open: model.open,
                retry: model.retryRegistration,
                problem: model.retryProblem,
                canvasAction: model.performCanvasAction,
                prepare: model.prepareSession,
                bundlePrepare: model.prepareSession,
                copy: model.copyPreparedSession,
                mementoAction: model.mutateMemento,
                bundleMementoAction: model.mutateMemento
            )
            .navigationTitle("Details")
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Configure Productions root").font(.headline)
            Text("Version 2 reads the shared Productions system. Existing version 1 configuration remains untouched for recovery.").foregroundStyle(.secondary)
            Text(model.rootPath.isEmpty ? "No root selected" : model.rootPath).font(.caption).textSelection(.enabled)
            HStack {
                Button("Choose Productions Folder") { model.chooseRoot() }
                Button("Save and Load") { model.saveAndLoad() }.disabled(model.rootPath.isEmpty)
            }
            if let message = model.message { NoticeBanner(message: message, severity: model.noticeSeverity) }
        }
    }

    private func reconcileSelection() {
        let selection = model.reconcileSelection(for: currentSection, departmentFilter: departmentFilter, searchText: searchText, currentRowID: selectedRowID)
        selectedRowID = selection?.rowID
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
            Text("Choosing and saving the root changes only this app’s local configuration. Productions mutations use separately authorized transaction paths; Canvas writes require a visible action.")
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

private struct NoticeBanner: View {
    let message: String
    let severity: ProductionsNoticeSeverity

    var body: some View {
        Label(message, systemImage: severity.systemImage)
            .font(.callout)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.25)) }
            .textSelection(.enabled)
            .accessibilityLabel(ProductionsPresentationAccessibility.noticeLabel(message: message, severity: severity))
    }

    private var color: Color {
        switch severity {
        case .information: .blue
        case .success: .green
        case .warning: .orange
        case .failure: .red
        }
    }
}

private struct ProductionsItemList: View {
    let title: String
    let emptyTitle: String
    let systemImage: String
    let items: [ProductionsNavigationItem]
    let hasSearchQuery: Bool
    let hasUnfilteredItems: Bool
    @Binding var selectedRowID: String?

    var body: some View {
        List(selection: $selectedRowID) {
            ForEach(items) { item in
                ProductionsItemRow(item: item, isSelected: selectedRowID == item.id)
                    .tag(item.id)
            }
        }
        .navigationTitle(title)
        .overlay {
            if items.isEmpty {
                if hasSearchQuery && hasUnfilteredItems {
                    ContentUnavailableView("No matches", systemImage: "magnifyingglass", description: Text("Try another ID, title, summary, or status."))
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: systemImage)
                }
            }
        }
    }
}

private struct ProductionsItemRow: View {
    let item: ProductionsNavigationItem
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(item.title).font(.headline).lineLimit(2)
            if !item.subtitle.isEmpty {
                Text(item.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
            if !item.metadata.isEmpty {
                Text(item.metadata.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ProductionsPresentationAccessibility.rowLabel(item))
        .accessibilityHint(ProductionsPresentationAccessibility.selectionHint)
        .accessibilityValue(ProductionsPresentationAccessibility.selectionValue(isSelected: isSelected))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
private struct DetailView: View {
    let state: ProductionsState
    let selectedID: String?
    let sessionPackage: SessionPackage?
    let open: (String, Bool) -> Void
    let retry: (FlowItem) -> Void
    let problem: (FlowItem) -> String?
    let canvasAction: (CanvasWorkAction, WorkItem, String, String) -> Void
    let prepare: (WorkItem, SessionAuthorizationMode, String, String) -> Void
    let bundlePrepare: (String, SessionAuthorizationMode, String, String) -> Void
    let copy: () -> Void
    let mementoAction: (MementoTransactionAction, WorkItem, MementoDraft?) -> Void
    let bundleMementoAction: (MementoTransactionAction, String, String, MementoDraft?) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let work = state.work.first(where: { $0.id == selectedID }) {
                    WorkDetailView(work: work, isOnCanvas: state.canvasCurrentIDs.contains(work.id), currentMemento: state.mementos.first(where: { $0.target == work.id }), sessionPackage: sessionPackage?.brief.workID == work.id ? sessionPackage : nil, open: open, perform: canvasAction, prepare: prepare, copy: copy, mementoAction: mementoAction)
                } else if let product = state.products.first(where: { $0.id == selectedID }) {
                    ProductDetailView(product: product)
                } else if let flow = (state.inbox + state.processing).first(where: { $0.id == selectedID }) {
                    if flow.stage == "Processing", let id = flow.flowID {
                        BundleDetailView(bundle: flow, currentMemento: state.mementos.first(where: { $0.target == id }), sessionPackage: sessionPackage?.brief.workID == id ? sessionPackage : nil, open: open, prepare: bundlePrepare, copy: copy, mementoAction: bundleMementoAction)
                    } else {
                        InboxDetailView(flow: flow, open: open, retry: retry, problem: problem)
                    }
                } else { ContentUnavailableView("Select an item", systemImage: "doc.text") }
                if !state.issues.isEmpty {
                    GroupBox("Contract issues") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(state.issues) {
                                Label($0.message, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }
}

private struct ProductDetailView: View {
    let product: ProductRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(product.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(product.name).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    StatusPill(text: "Product", systemImage: "cube", tint: .blue)
                    StatusPill(text: product.lifecycle, systemImage: "circle.fill", tint: .secondary)
                    StatusPill(text: "Department not provided", systemImage: "building.2", tint: .secondary)
                }
            }
            GroupBox("Canonical product metadata") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Current lead", value: product.lead)
                    LabeledContent("Canonical workspace") {
                        Text(product.canonicalWorkspace).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    LabeledContent("Related records", value: product.related.isEmpty ? "None" : product.related.joined(separator: "; "))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Label("The canonical Products registry does not provide a Department field. No department is inferred.", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct InboxDetailView: View {
    let flow: FlowItem
    let open: (String, Bool) -> Void
    let retry: (FlowItem) -> Void
    let problem: (FlowItem) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(flow.flowID ?? "Unregistered").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(flow.label).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    StatusPill(text: "Inbox", systemImage: "tray", tint: .blue)
                    StatusPill(text: flow.isUnregistered ? "Unregistered" : flow.priority, systemImage: flow.isUnregistered ? "exclamationmark.triangle" : "flag", tint: flow.isUnregistered ? .orange : .secondary)
                    StatusPill(text: flow.department.map { "Department: \($0)" } ?? "Unknown department", systemImage: "building.2", tint: .secondary)
                }
            }
            Text(flow.summary).font(.body)
            GroupBox("Source") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(flow.location).font(.caption.monospaced()).textSelection(.enabled)
                    AdaptiveActionRow {
                        Button("Open payload") { open(flow.location, false) }
                        Button("Open Inbox folder") { open("Office/Inbox", true) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if flow.isUnregistered, let reason = problem(flow) {
                GroupBox("Registration requires attention") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Button("Retry registration…") { retry(flow) }
                            .accessibilityHint("Starts a new explicit registration transaction after the problem has been resolved.")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct WorkDetailView: View {
    let work: WorkItem
    let isOnCanvas: Bool
    let currentMemento: Memento?
    let sessionPackage: SessionPackage?
    let open: (String, Bool) -> Void
    let perform: (CanvasWorkAction, WorkItem, String, String) -> Void
    let prepare: (WorkItem, SessionAuthorizationMode, String, String) -> Void
    let copy: () -> Void
    let mementoAction: (MementoTransactionAction, WorkItem, MementoDraft?) -> Void
    @State private var pendingAction: CanvasWorkAction?
    @State private var showingPrepare = false
    @State private var showingMemento = false
    @State private var confirmingResolution = false

    private var availability: ProductionsWorkActionAvailability {
        ProductionsWorkActionAvailability(work: work, isOnCanvas: isOnCanvas, currentMemento: currentMemento)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(work.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(work.title).font(.title2.weight(.semibold))
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { statusPills }
                    VStack(alignment: .leading, spacing: 6) { statusPills }
                }
                if !work.registryDescription.isEmpty {
                    Text(work.registryDescription).font(.body).foregroundStyle(.secondary)
                }
            }

            GroupBox("Session and continuity") {
                VStack(alignment: .leading, spacing: 12) {
                    MementoSummaryView(memento: currentMemento)
                    Divider()
                    Text("Prepare is read-only. Start records Canvas attention and then prepares the same package. Stop clears Canvas attention only.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    AdaptiveActionRow {
                        Button("Prepare session…") { showingPrepare = true }
                            .accessibilityHint("Prepares a read-only start or resume package without changing Productions.")
                        Button("Start work…") { pendingAction = .start }
                            .disabled(!availability.canStart)
                            .accessibilityHint("Confirms an explicit Canvas transaction, then prepares a session package.")
                        Button("Stop work…") { pendingAction = .stop }
                            .disabled(!availability.canStop)
                            .accessibilityHint("Confirms a Canvas Cleared event without changing lifecycle or priority.")
                    }
                    AdaptiveActionRow {
                        Button(availability.mementoActionTitle) { showingMemento = true }
                        if availability.canResolveMemento {
                            Button("Resolve Memento…", role: .destructive) { confirmingResolution = true }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let package = sessionPackage {
                PreparedSessionView(
                    package: package,
                    regenerate: { prepare(work, package.brief.authorizationMode, package.brief.recommendedModel, package.brief.reasoningLevel) },
                    copy: copy
                )
            }

            GroupBox("Sources") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(work.workspacePath).font(.caption.monospaced()).textSelection(.enabled)
                    AdaptiveActionRow {
                        Button("Open record") { open(work.workspacePath, false) }
                        Button("Open containing folder") { open("Workspace/\(work.id)", true) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            CanonicalRecordDisclosure(content: work.content)
        }
        .sheet(item: $pendingAction) { action in
            CanvasWorkActionSheet(action: action, work: work, isOnCanvas: isOnCanvas) { reason, context in
                perform(action, work, reason, context)
                pendingAction = nil
            } cancel: {
                pendingAction = nil
            }
        }
        .sheet(isPresented: $showingPrepare) {
            PrepareSessionSheet(title: work.title, workID: work.id) { authorization, model, reasoning in
                prepare(work, authorization, model, reasoning); showingPrepare = false
            } cancel: { showingPrepare = false }
        }
        .sheet(isPresented: $showingMemento) {
            MementoActionSheet(title: work.title, targetID: work.id, action: currentMemento == nil ? .create : .supersede) { draft in
                mementoAction(currentMemento == nil ? .create : .supersede, work, draft); showingMemento = false
            } cancel: { showingMemento = false }
        }
        .confirmationDialog("Resolve \(currentMemento?.summary ?? "current Memento")?", isPresented: $confirmingResolution) {
            Button("Resolve and retain payload", role: .destructive) { mementoAction(.resolve, work, nil) }
        } message: { Text("The live row and Current Memento section will be removed. Any extended payload and all Open Crumbs remain unchanged.") }
    }

    @ViewBuilder private var statusPills: some View {
        StatusPill(text: work.kind.rawValue, systemImage: "doc.text", tint: .secondary)
        StatusPill(text: work.lifecycle, systemImage: "circle.fill", tint: work.lifecycle.hasPrefix("Done") ? .secondary : .blue)
        StatusPill(text: work.priority, systemImage: "flag", tint: .secondary)
        StatusPill(text: work.department.isEmpty ? "Unknown department" : "Department: \(work.department)", systemImage: "building.2", tint: .secondary)
        StatusPill(text: isOnCanvas ? "On Canvas" : "Off Canvas", systemImage: isOnCanvas ? "rectangle.on.rectangle" : "rectangle", tint: isOnCanvas ? .green : .secondary)
        StatusPill(text: currentMemento == nil ? "No Memento" : "Current Memento", systemImage: currentMemento == nil ? "bookmark.slash" : "bookmark.fill", tint: currentMemento == nil ? .secondary : .purple)
    }
}

private struct BundleDetailView: View {
    let bundle: FlowItem
    let currentMemento: Memento?
    let sessionPackage: SessionPackage?
    let open: (String, Bool) -> Void
    let prepare: (String, SessionAuthorizationMode, String, String) -> Void
    let copy: () -> Void
    let mementoAction: (MementoTransactionAction, String, String, MementoDraft?) -> Void
    @State private var showingPrepare = false
    @State private var showingMemento = false
    @State private var confirmingResolution = false

    private var availability: ProductionsBundleActionAvailability {
        ProductionsBundleActionAvailability(currentMemento: currentMemento)
    }

    var body: some View {
        let id = bundle.flowID ?? ""
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(id).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(bundle.label).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    StatusPill(text: "Processing bundle", systemImage: "shippingbox", tint: .blue)
                    StatusPill(text: bundle.priority, systemImage: "flag", tint: .secondary)
                    StatusPill(text: bundle.department.map { "Department: \($0)" } ?? "Unknown department", systemImage: "building.2", tint: .secondary)
                    StatusPill(text: currentMemento == nil ? "No Memento" : "Current Memento", systemImage: currentMemento == nil ? "bookmark.slash" : "bookmark.fill", tint: currentMemento == nil ? .secondary : .purple)
                }
                Text(bundle.summary).font(.body).foregroundStyle(.secondary)
            }

            GroupBox("Session and continuity") {
                VStack(alignment: .leading, spacing: 12) {
                    MementoSummaryView(memento: currentMemento)
                    Divider()
                    Label("Processing bundles can prepare only a validated Memento-backed resume package and never receive Canvas Start work.", systemImage: "lock.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    AdaptiveActionRow {
                        Button("Prepare session…") { showingPrepare = true }.disabled(!availability.canPrepare)
                        Button(availability.mementoActionTitle) { showingMemento = true }
                        if availability.canResolveMemento {
                            Button("Resolve Memento…", role: .destructive) { confirmingResolution = true }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let package = sessionPackage {
                PreparedSessionView(
                    package: package,
                    regenerate: { prepare(id, package.brief.authorizationMode, package.brief.recommendedModel, package.brief.reasoningLevel) },
                    copy: copy
                )
            }

            GroupBox("Sources") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(bundle.location).font(.caption.monospaced()).textSelection(.enabled)
                    AdaptiveActionRow {
                        Button("Open bundle") { open(bundle.location, true) }
                        Button("Open Processing folder") { open("Office/Processing", true) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            CanonicalRecordDisclosure(content: bundle.bundleContent)
        }
        .sheet(isPresented: $showingPrepare) {
            PrepareSessionSheet(title: bundle.label, workID: id) { authorization, model, reasoning in
                prepare(id, authorization, model, reasoning); showingPrepare = false
            } cancel: { showingPrepare = false }
        }
        .sheet(isPresented: $showingMemento) {
            MementoActionSheet(title: bundle.label, targetID: id, action: currentMemento == nil ? .create : .supersede) { draft in
                mementoAction(currentMemento == nil ? .create : .supersede, id, bundle.label, draft); showingMemento = false
            } cancel: { showingMemento = false }
        }
        .confirmationDialog("Resolve \(currentMemento?.summary ?? "current Memento")?", isPresented: $confirmingResolution) {
            Button("Resolve and retain payload", role: .destructive) { mementoAction(.resolve, id, bundle.label, nil) }
        } message: { Text("The live row and Current Memento section will be removed. Any extended payload and all Open Crumbs remain unchanged.") }
    }
}

private struct StatusPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.10), in: Capsule())
            .overlay { Capsule().stroke(tint.opacity(0.22)) }
            .accessibilityElement(children: .combine)
    }
}

private struct AdaptiveActionRow<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }
}

private struct MementoSummaryView: View {
    let memento: Memento?

    var body: some View {
        if let memento {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Current Memento", systemImage: "bookmark.fill").font(.headline)
                    Spacer()
                    Text(memento.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(memento.summary).font(.subheadline.weight(.semibold))
                LabeledContent("Current state") { Text(memento.currentState).multilineTextAlignment(.trailing).textSelection(.enabled) }
                LabeledContent("Resume point") { Text(memento.naturalResumePoint).multilineTextAlignment(.trailing).textSelection(.enabled) }
                if !memento.openCrumbs.isEmpty {
                    LabeledContent("Open Crumbs") { Text(memento.openCrumbs.joined(separator: "; ")).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }
            .accessibilityElement(children: .contain)
        } else {
            Label("No current Memento. Prepare will use canonical-record start mode.", systemImage: "bookmark.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PreparedSessionView: View {
    let package: SessionPackage
    let regenerate: () -> Void
    let copy: () -> Void

    var body: some View {
        GroupBox("Prepared session") {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { metadata }
                    VStack(alignment: .leading, spacing: 6) { metadata }
                }
                Text("The preview below is the complete package. Copy revalidates every canonical source hash before writing these exact bytes to the pasteboard.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView([.vertical, .horizontal]) {
                    Text(package.displayedText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 180, maxHeight: 320)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).stroke(.separator) }
                AdaptiveActionRow {
                    Button("Regenerate package") { regenerate() }
                        .accessibilityHint("Rebuilds the read-only package from current canonical sources.")
                    Button("Copy package") { copy() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Revalidates source hashes and copies the exact displayed package. Productions is not changed.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var metadata: some View {
        StatusPill(text: package.brief.sessionMode == .resume ? "Resume" : "Start", systemImage: package.brief.sessionMode == .resume ? "bookmark.fill" : "play", tint: package.brief.sessionMode == .resume ? .purple : .blue)
        StatusPill(text: package.brief.authorizationMode.rawValue, systemImage: "lock.shield", tint: .secondary)
        StatusPill(text: package.brief.recommendedModel, systemImage: "cpu", tint: .secondary)
        if let mementoID = package.brief.mementoID {
            StatusPill(text: mementoID, systemImage: "number", tint: .secondary)
        }
    }
}

private struct CanonicalRecordDisclosure: View {
    let content: String?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Canonical record", isExpanded: $isExpanded) {
            ScrollView([.vertical, .horizontal]) {
                Text(content ?? "Record unavailable")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
            .frame(minHeight: 140, maxHeight: 320)
        }
        .font(.headline)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityHint("Expands a bounded, selectable view of the complete canonical Markdown record.")
    }
}

private struct PrepareSessionSheet: View {
    let title: String
    let workID: String
    let confirm: (SessionAuthorizationMode, String, String) -> Void
    let cancel: () -> Void
    @State private var authorization: SessionAuthorizationMode = .readOnly
    @State private var model = "Codex"
    @State private var reasoning = "high"
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Prepare session", systemImage: "doc.text.magnifyingglass").font(.title3.weight(.semibold))
            Text("\(title) (\(workID))").font(.headline)
            Label("Session mode is derived from validated Memento presence; it is never inferred from Canvas membership.", systemImage: "bookmark")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Preview, regeneration, and Copy are passive. Authorization and model inputs are ephemeral and cannot broaden canonical boundaries.")
                .font(.callout)
                .foregroundStyle(.secondary)
            GroupBox("Ephemeral session inputs") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Authorization", selection: $authorization) {
                        ForEach(SessionAuthorizationMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    LabeledContent("Recommended model") { TextField("Model", text: $model).frame(minWidth: 250) }
                    LabeledContent("Reasoning level") { TextField("Reasoning", text: $reasoning).frame(minWidth: 250) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                Button("Prepare package") { confirm(authorization, model, reasoning) }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityHint("Builds a read-only preview without changing Productions or Canvas.")
            }
        }
        .padding()
        .frame(minWidth: 560)
    }
}

private struct MementoActionSheet: View {
    let title: String
    let targetID: String
    let action: MementoTransactionAction
    let confirm: (MementoDraft) -> Void
    let cancel: () -> Void
    @State private var summary = ""
    @State private var currentState = ""
    @State private var resumePoint = ""
    @State private var openCrumbs = ""
    @State private var extendedPayload = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(action == .create ? "Leave Memento" : "Supersede Memento", systemImage: "bookmark.fill").font(.title3.weight(.semibold))
            Text("\(title) (\(targetID))").font(.headline)
            Label("This is an explicit recoverable Productions transaction. Open Crumbs are referenced only and will not be resolved.", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("Memento name · Required") { TextField("Concise checkpoint name", text: $summary).frame(minWidth: 340) }
            VStack(alignment: .leading, spacing: 5) {
                Text("Current validated state · Required").font(.subheadline.weight(.semibold))
                TextEditor(text: $currentState)
                    .frame(height: 90)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                    .accessibilityLabel("Current validated state, required")
            }
            LabeledContent("Natural resume point · Required") { TextField("Exact next action", text: $resumePoint).frame(minWidth: 340) }
            LabeledContent("Open Crumb IDs · Optional") { TextField("Semicolon-separated IDs", text: $openCrumbs).frame(minWidth: 340) }
            VStack(alignment: .leading, spacing: 5) {
                Text("Extended payload · Optional").font(.subheadline.weight(.semibold))
                Text("Supplementary context only; it cannot override the target record.").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $extendedPayload)
                    .frame(height: 70)
                    .padding(4)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.secondary.opacity(0.3)))
                    .accessibilityLabel("Extended payload, optional")
            }
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { cancel() }
                Button(action == .create ? "Create Memento" : "Supersede Memento") {
                    let crumbs = openCrumbs.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    confirm(MementoDraft(summary: summary, currentState: currentState, naturalResumePoint: resumePoint, openCrumbs: crumbs, extendedPayload: extendedPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : extendedPayload))
                }
                .buttonStyle(.borderedProminent)
                .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currentState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || resumePoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 620)
    }
}

private struct CanvasWorkActionSheet: View {
    let action: CanvasWorkAction
    let work: WorkItem
    let isOnCanvas: Bool
    let confirm: (String, String) -> Void
    let cancel: () -> Void
    @State private var reason: String
    @State private var context: String

    init(action: CanvasWorkAction, work: WorkItem, isOnCanvas: Bool, confirm: @escaping (String, String) -> Void, cancel: @escaping () -> Void) {
        self.action = action
        self.work = work
        self.isOnCanvas = isOnCanvas
        self.confirm = confirm
        self.cancel = cancel
        _reason = State(initialValue: action == .start ? "Intentional work started." : "Deferral.")
        _context = State(initialValue: action == .start ? "Work explicitly selected in Momentum Management." : "Work intentionally cleared from current attention.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(action.title, systemImage: action == .start ? "play.circle" : "stop.circle").font(.title3.weight(.semibold))
            Text("\(work.title) (\(work.id))").font(.headline)
            GroupBox("Transaction boundary") {
                VStack(alignment: .leading, spacing: 6) {
                    if action == .start {
                        Label(isOnCanvas ? "Canvas change: append Engaged." : "Canvas change: append Placed, then Engaged.", systemImage: "rectangle.on.rectangle")
                        Text("After Canvas commits, the same renderer prepares a read-only session package. A committed Canvas transaction is never retried if package generation then fails.")
                    } else {
                        Label("Canvas change: append Cleared.", systemImage: "rectangle.slash")
                        Text("Stop does not change Registry lifecycle or priority and does not create or resolve a Memento.")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            LabeledContent("Reason · Required") { TextField("Reason", text: $reason).frame(minWidth: 320) }
            LabeledContent("Context · Required") { TextField("Context", text: $context).frame(minWidth: 320) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                Button(action.title) { confirm(reason, context) }
                    .buttonStyle(.borderedProminent)
                    .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(minWidth: 560)
    }
}
