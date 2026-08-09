import SwiftUI

protocol IntakeEnumerating {
    func enumerate(configuration: CaptureConfiguration, fileSystem: any CaptureFileSystem) throws -> IntakeEnumerationResult
}

extension IntakeEnumerator: IntakeEnumerating {}

protocol CaptureMoving {
    func move(selected items: [IntakeItem], configuration: CaptureConfiguration) -> IntakeMoveBatchResult
}

extension InboxCaptureService: CaptureMoving {}

protocol PreparedItemsEnumerating {
    func enumerate(configuration: CaptureConfiguration, fileSystem: any CaptureFileSystem) throws -> PreparedItemsEnumerationResult
}

extension PreparedItemsEnumerator: PreparedItemsEnumerating {}

protocol PreparedItemsMoving {
    func move(selected items: [PreparedIntakeItem], configuration: CaptureConfiguration) -> PreparedItemMoveBatchResult
}

extension PreparedItemsCaptureService: PreparedItemsMoving {}

struct CaptureSessionResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let succeeded: Bool
    var isCurrent: Bool
}

struct CaptureSessionBatch: Identifiable, Equatable {
    let id = UUID()
    let completedAt: Date
    var results: [CaptureSessionResult]

    var summary: String {
        let passed = results.filter(\.succeeded).count
        let failed = results.count - passed
        return "\(passed) passed · \(failed) failed"
    }
}

@MainActor
final class EnterpriseInboxCaptureViewModel: ObservableObject {
    @Published private(set) var enumeration: IntakeEnumerationResult?
    @Published private(set) var preparedEnumeration: PreparedItemsEnumerationResult?
    @Published private(set) var configurationProblem: String?
    @Published private(set) var destinationProblem: String?
    @Published private(set) var selectedItemIDs: Set<String> = []
    @Published private(set) var moveResult: IntakeMoveBatchResult?
    @Published private(set) var preparedMoveResult: PreparedItemMoveBatchResult?
    @Published private(set) var isMoveInProgress = false
    @Published private(set) var isPreparedMoveInProgress = false
    @Published var isConfirmationPresented = false
    @Published var isPreparedConfirmationPresented = false
    @Published var quickCaptureText = ""
    @Published private(set) var quickCaptureResult: QuickCaptureResult?
    @Published private(set) var isQuickCaptureInProgress = false
    @Published private(set) var sessionBatches: [CaptureSessionBatch] = []

    private let configurationStore: CaptureConfigurationStore
    private let fileSystem: any CaptureFileSystem
    private let enumerator: any IntakeEnumerating
    private let preparedEnumerator: any PreparedItemsEnumerating
    private let mover: any CaptureMoving
    private let preparedMover: any PreparedItemsMoving
    private let quickCaptureWriter: any QuickCaptureWriting
    private let now: () -> Date
    private let dashboardRefresh: () -> Void
    private var configuration: CaptureConfiguration?

    static func live(dashboardRefresh: @escaping () -> Void = {}) -> EnterpriseInboxCaptureViewModel {
        EnterpriseInboxCaptureViewModel(
            configurationStore: CaptureConfigurationStore(),
            fileSystem: LocalCaptureFileSystem(),
            enumerator: IntakeEnumerator(),
            mover: InboxCaptureService(fileSystem: LocalCaptureMutationFileSystem()),
            preparedEnumerator: PreparedItemsEnumerator(),
            preparedMover: PreparedItemsCaptureService(fileSystem: LocalCaptureMutationFileSystem()),
            quickCaptureWriter: QuickCaptureWriter(),
            dashboardRefresh: dashboardRefresh
        )
    }

    init(
        configurationStore: CaptureConfigurationStore,
        fileSystem: any CaptureFileSystem,
        enumerator: any IntakeEnumerating = IntakeEnumerator(),
        mover: any CaptureMoving,
        preparedEnumerator: any PreparedItemsEnumerating = PreparedItemsEnumerator(),
        preparedMover: any PreparedItemsMoving = PreparedItemsCaptureService(fileSystem: LocalCaptureMutationFileSystem()),
        quickCaptureWriter: any QuickCaptureWriting = QuickCaptureWriter(),
        now: @escaping () -> Date = Date.init,
        dashboardRefresh: @escaping () -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.fileSystem = fileSystem
        self.enumerator = enumerator
        self.mover = mover
        self.preparedEnumerator = preparedEnumerator
        self.preparedMover = preparedMover
        self.quickCaptureWriter = quickCaptureWriter
        self.now = now
        self.dashboardRefresh = dashboardRefresh
        refresh()
    }

    var items: [IntakeItem] { enumeration?.items ?? [] }
    var preparedItems: [PreparedIntakeItem] { preparedEnumeration?.items ?? [] }
    var selectedItems: [IntakeItem] { items.filter { selectedItemIDs.contains($0.id) } }
    var selectedCount: Int { selectedItems.count }
    var canMove: Bool { configuration != nil && destinationProblem == nil && selectedCount > 0 && !isMoveInProgress }
    var canMovePrepared: Bool { configuration != nil && destinationProblem == nil && !preparedItems.isEmpty && !isPreparedMoveInProgress }
    var canQuickCapture: Bool { configuration != nil && destinationProblem == nil && QuickCaptureWriter.isValid(text: quickCaptureText) && !isQuickCaptureInProgress }
    var sessionResults: [CaptureSessionResult] { sessionBatches.flatMap(\.results) }
    var successfulSessionResultCount: Int { sessionResults.filter(\.succeeded).count }
    var failedSessionResultCount: Int { sessionResults.count - successfulSessionResultCount }

    func refresh() {
        deemphasizeSessionResults()
        reload()
    }

    func deemphasizeSessionResults() {
        for batchIndex in sessionBatches.indices {
            for resultIndex in sessionBatches[batchIndex].results.indices {
                sessionBatches[batchIndex].results[resultIndex].isCurrent = false
            }
        }
    }

    func updateQuickCaptureText(_ text: String) {
        quickCaptureText = text
        deemphasizeSessionResults()
    }

    private func reload() {
        isConfirmationPresented = false
        isPreparedConfirmationPresented = false
        configurationProblem = nil
        destinationProblem = nil
        configuration = nil
        enumeration = nil
        preparedEnumeration = nil

        switch configurationStore.launchState() {
        case let .configured(configuration):
            self.configuration = configuration
            let validation = CaptureConfigurationValidator(fileSystem: fileSystem).validate(configuration)
            if validation.destinationState != .available {
                destinationProblem = "Enterprise Inbox destination is unavailable."
            }
            do {
                enumeration = try enumerator.enumerate(configuration: configuration, fileSystem: fileSystem)
                preparedEnumeration = try preparedEnumerator.enumerate(configuration: configuration, fileSystem: fileSystem)
                reconcileSelection()
            } catch {
                configurationProblem = error.localizedDescription
            }
        case .setupRequired:
            configurationProblem = "Capture setup is required before items can be listed."
            selectedItemIDs = []
        case let .malformed(message):
            configurationProblem = "Capture configuration is malformed: \(message)"
            selectedItemIDs = []
        }
    }

    func toggleSelection(of item: IntakeItem) {
        guard items.contains(item) else { return }
        deemphasizeSessionResults()
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func selectAll() {
        deemphasizeSessionResults()
        selectedItemIDs = Set(items.map(\.id))
    }

    func clearSelection() {
        deemphasizeSessionResults()
        selectedItemIDs = []
    }

    func requestMoveConfirmation() {
        guard canMove else { return }
        isConfirmationPresented = true
    }

    func cancelMoveConfirmation() {
        isConfirmationPresented = false
    }

    func requestPreparedMoveConfirmation() {
        guard canMovePrepared else { return }
        deemphasizeSessionResults()
        isPreparedConfirmationPresented = true
    }

    func cancelPreparedMoveConfirmation() {
        isPreparedConfirmationPresented = false
    }

    func confirmMove() {
        guard !isMoveInProgress, isConfirmationPresented, let configuration, !selectedItems.isEmpty else { return }
        let submittedItems = selectedItems
        isMoveInProgress = true
        isConfirmationPresented = false
        let result = mover.move(selected: submittedItems, configuration: configuration)
        moveResult = result
        appendMoveResults(result)
        isMoveInProgress = false
        reload()
        dashboardRefresh()
    }

    func confirmPreparedMove() {
        guard !isPreparedMoveInProgress, isPreparedConfirmationPresented, let configuration, !preparedItems.isEmpty else { return }
        let submittedItems = preparedItems
        isPreparedMoveInProgress = true
        isPreparedConfirmationPresented = false
        let result = preparedMover.move(selected: submittedItems, configuration: configuration)
        preparedMoveResult = result
        appendPreparedMoveResults(result)
        isPreparedMoveInProgress = false
        reload()
        dashboardRefresh()
    }

    func submitQuickCapture() {
        guard !isQuickCaptureInProgress, let configuration, canQuickCapture else { return }
        isQuickCaptureInProgress = true
        let result = quickCaptureWriter.create(text: quickCaptureText, configuration: configuration, now: now())
        quickCaptureResult = result
        appendQuickCaptureResult(result)
        if case .success = result {
            quickCaptureText = ""
            reload()
            dashboardRefresh()
        }
        isQuickCaptureInProgress = false
    }

    private func reconcileSelection() {
        selectedItemIDs.formIntersection(Set(items.map(\.id)))
    }

    private func appendMoveResults(_ batch: IntakeMoveBatchResult) {
        appendSessionResults(batch.results.map { result in
            switch result.outcome {
            case let .moved(destination):
                let renamed = destination.lastPathComponent != result.item.displayName
                let title = renamed
                    ? "Moved \(result.item.displayName), renamed to \(destination.lastPathComponent)"
                    : "Moved \(result.item.displayName)"
                return CaptureSessionResult(title: title, succeeded: true, isCurrent: true)
            case let .failed(_, diagnostic, _):
                return CaptureSessionResult(title: "Did not move \(result.item.displayName): \(diagnostic)", succeeded: false, isCurrent: true)
            }
        })
    }

    private func appendQuickCaptureResult(_ result: QuickCaptureResult) {
        let sessionResult: CaptureSessionResult
        switch result {
        case let .success(path):
            sessionResult = CaptureSessionResult(title: "Added \(path.lastPathComponent)", succeeded: true, isCurrent: true)
        case let .failure(_, diagnostic):
            sessionResult = CaptureSessionResult(title: "Quick Capture failed: \(diagnostic)", succeeded: false, isCurrent: true)
        }
        appendSessionResults([sessionResult])
    }

    private func appendPreparedMoveResults(_ batch: PreparedItemMoveBatchResult) {
        appendSessionResults(batch.results.map { result in
            switch result.outcome {
            case let .moved(destination):
                let renamed = destination.lastPathComponent != result.item.displayName
                let title = renamed
                    ? "Moved \(result.item.displayName) from \(result.item.sourceDisplayName), renamed to \(destination.lastPathComponent)"
                    : "Moved \(result.item.displayName) from \(result.item.sourceDisplayName)"
                return CaptureSessionResult(title: title, succeeded: true, isCurrent: true)
            case let .failed(_, diagnostic, _):
                return CaptureSessionResult(title: "Did not move \(result.item.displayName) from \(result.item.sourceDisplayName): \(diagnostic)", succeeded: false, isCurrent: true)
            }
        })
    }

    private func appendSessionResults(_ results: [CaptureSessionResult]) {
        deemphasizeSessionResults()
        sessionBatches.insert(CaptureSessionBatch(completedAt: now(), results: results), at: 0)
    }
}

struct EnterpriseInboxCaptureSheet: View {
    @StateObject private var viewModel: EnterpriseInboxCaptureViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var workspace: CaptureWorkspace = .addItems

    init(dashboardRefresh: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: EnterpriseInboxCaptureViewModel.live(dashboardRefresh: dashboardRefresh))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enterprise Inbox").font(.title2)
                    Text("Move selected intake items or create a Quick Capture note.").foregroundStyle(.secondary)
                }
            }

            if let problem = viewModel.configurationProblem {
                ContentUnavailableView("Capture configuration unavailable", systemImage: "exclamationmark.triangle", description: Text(problem))
            } else {
                preparedItemsSection

                Picker("Capture mode", selection: $workspace) {
                    ForEach(CaptureWorkspace.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Capture mode")
                .onChange(of: workspace) { _, _ in viewModel.deemphasizeSessionResults() }

                if let destinationProblem = viewModel.destinationProblem {
                    Text(destinationProblem).foregroundStyle(.orange)
                }

                workspaceContent
                    .frame(height: 330, alignment: .top)
                Divider()
                results
                    .frame(height: 150, alignment: .top)
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .disabled(viewModel.isMoveInProgress || viewModel.isPreparedMoveInProgress || viewModel.isQuickCaptureInProgress)
                        .accessibilityLabel("Close Enterprise Inbox")
                }
            }
        }
        .padding()
        .frame(minWidth: 680, minHeight: 650)
        .confirmationDialog(
            "Move \(viewModel.selectedCount) item\(viewModel.selectedCount == 1 ? "" : "s") to Enterprise Inbox?",
            isPresented: $viewModel.isConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Move Items", role: .destructive) { viewModel.confirmMove() }
            Button("Cancel", role: .cancel) { viewModel.cancelMoveConfirmation() }
        } message: {
            Text("Selected items will be moved out of their Downloads locations into Enterprise Inbox.")
        }
        .confirmationDialog(
            "Capture \(viewModel.preparedItems.count) prepared item\(viewModel.preparedItems.count == 1 ? "" : "s") to Enterprise Inbox?",
            isPresented: $viewModel.isPreparedConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Capture Items", role: .destructive) { viewModel.confirmPreparedMove() }
            Button("Cancel", role: .cancel) { viewModel.cancelPreparedMoveConfirmation() }
        } message: {
            Text("Only the current immediate items in the two Kahntra Enterprise folders will be moved into Enterprise Inbox.")
        }
    }

    @ViewBuilder
    private var workspaceContent: some View {
        switch workspace {
        case .addItems:
            addItemsWorkspace
        case .quickCapture:
            quickCaptureWorkspace
        }
    }

    private var addItemsWorkspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            sourceAvailability
            intakeContent
                .frame(maxHeight: .infinity)
            controls
        }
    }

    private var preparedItemsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Kahntra Enterprise").font(.headline)
                    Text("\(viewModel.preparedItems.count) item\(viewModel.preparedItems.count == 1 ? "" : "s") ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Capture Kahntra Enterprise Items") { viewModel.requestPreparedMoveConfirmation() }
                    .disabled(!viewModel.canMovePrepared)
                    .accessibilityLabel("Capture prepared Kahntra Enterprise items")
            }
            ForEach(viewModel.preparedEnumeration?.folders ?? [], id: \.folder.source.id) { folder in
                Text("\(folder.folder.source.displayName): \(availabilityText(folder.availability))")
                    .font(.caption)
                    .foregroundStyle(isUnavailable(folder.availability) ? .orange : .secondary)
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .contain)
    }

    private var sourceAvailability: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Intake sources").font(.headline)
                Spacer()
                Button("Refresh") { viewModel.refresh() }
                    .disabled(viewModel.isMoveInProgress)
                    .accessibilityLabel("Refresh intake items")
            }
            ForEach(viewModel.enumeration?.sources ?? [], id: \.source.id) { source in
                Text("\(source.source.displayName): \(availabilityText(source.availability))")
                    .accessibilityLabel("\(source.source.displayName), \(availabilityText(source.availability))")
                    .foregroundStyle(isUnavailable(source.availability) ? .orange : .secondary)
            }
        }
    }

    @ViewBuilder
    private var intakeContent: some View {
        if viewModel.items.isEmpty {
            ContentUnavailableView("No intake items", systemImage: "tray", description: Text("Available sources currently have no visible items to add."))
        } else {
            List(viewModel.items) { item in
                Toggle(isOn: Binding(
                    get: { viewModel.selectedItemIDs.contains(item.id) },
                    set: { _ in viewModel.toggleSelection(of: item) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayName)
                        Text("\(item.sourceDisplayName) · \(item.kind.rawValue.capitalized)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(viewModel.isMoveInProgress)
                .accessibilityLabel("\(item.displayName), from \(item.sourceDisplayName)")
            }
        }
    }

    private var controls: some View {
        HStack {
            Text("\(viewModel.selectedCount) selected")
                .accessibilityLabel("\(viewModel.selectedCount) items selected")
            Spacer()
            Button("Select All") { viewModel.selectAll() }
                .disabled(viewModel.items.isEmpty || viewModel.isMoveInProgress)
                .accessibilityLabel("Select all intake items")
            Button("Clear") { viewModel.clearSelection() }
                .disabled(viewModel.selectedCount == 0 || viewModel.isMoveInProgress)
                .accessibilityLabel("Clear intake selection")
            Button("Move to Enterprise Inbox") { viewModel.requestMoveConfirmation() }
                .disabled(!viewModel.canMove)
                .accessibilityLabel("Move selected items to Enterprise Inbox")
        }
    }

    private var quickCaptureWorkspace: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick Capture").font(.headline)
            Text("Create one new Markdown item in Enterprise Inbox.").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(
                get: { viewModel.quickCaptureText },
                set: { viewModel.updateQuickCaptureText($0) }
            ))
                .frame(maxHeight: .infinity)
                .padding(8)
                .overlay { Rectangle().stroke(.separator) }
                .disabled(viewModel.isQuickCaptureInProgress)
                .accessibilityLabel("Quick Capture text")
            if !viewModel.quickCaptureText.isEmpty && !QuickCaptureWriter.isValid(text: viewModel.quickCaptureText) {
                Text("Enter non-whitespace text to add an item.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Add to Inbox") { viewModel.submitQuickCapture() }
                    .disabled(!viewModel.canQuickCapture)
                    .accessibilityLabel("Add Quick Capture text to Enterprise Inbox")
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Results").font(.headline)
                Spacer()
                Text("\(viewModel.successfulSessionResultCount) passed · \(viewModel.failedSessionResultCount) failed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if viewModel.sessionResults.isEmpty {
                Text("No actions this session.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.sessionBatches) { batch in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(batch.completedAt, format: .dateTime.hour().minute().second())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Divider()
                                    Text(batch.summary)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(batch.results) { result in
                                    Text(result.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(resultColor(result))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .accessibilityLabel("Session results")
            }
        }
    }

    private func resultColor(_ result: CaptureSessionResult) -> Color {
        guard result.isCurrent else { return .secondary }
        return result.succeeded ? .green : .red
    }

    private func availabilityText(_ availability: IntakeSourceAvailability) -> String {
        switch availability {
        case .available: "Available"
        case .empty: "Empty"
        case .missing: "Unavailable"
        case let .unreadable(message): "Unavailable — \(message)"
        }
    }

    private func isUnavailable(_ availability: IntakeSourceAvailability) -> Bool {
        switch availability {
        case .missing, .unreadable: true
        case .available, .empty: false
        }
    }
}

private enum CaptureWorkspace: String, CaseIterable, Identifiable {
    case addItems
    case quickCapture

    var id: Self { self }
    var title: String {
        switch self {
        case .addItems: "Add Items"
        case .quickCapture: "Quick Capture"
        }
    }
}
