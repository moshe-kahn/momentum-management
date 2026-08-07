import SwiftUI

protocol IntakeEnumerating {
    func enumerate(configuration: CaptureConfiguration, fileSystem: any CaptureFileSystem) throws -> IntakeEnumerationResult
}

extension IntakeEnumerator: IntakeEnumerating {}

protocol CaptureMoving {
    func move(selected items: [IntakeItem], configuration: CaptureConfiguration) -> IntakeMoveBatchResult
}

extension InboxCaptureService: CaptureMoving {}

@MainActor
final class EnterpriseInboxCaptureViewModel: ObservableObject {
    @Published private(set) var enumeration: IntakeEnumerationResult?
    @Published private(set) var configurationProblem: String?
    @Published private(set) var destinationProblem: String?
    @Published private(set) var selectedItemIDs: Set<String> = []
    @Published private(set) var moveResult: IntakeMoveBatchResult?
    @Published private(set) var isMoveInProgress = false
    @Published var isConfirmationPresented = false

    private let configurationStore: CaptureConfigurationStore
    private let fileSystem: any CaptureFileSystem
    private let enumerator: any IntakeEnumerating
    private let mover: any CaptureMoving
    private let dashboardRefresh: () -> Void
    private var configuration: CaptureConfiguration?

    static func live(dashboardRefresh: @escaping () -> Void = {}) -> EnterpriseInboxCaptureViewModel {
        EnterpriseInboxCaptureViewModel(
            configurationStore: CaptureConfigurationStore(),
            fileSystem: LocalCaptureFileSystem(),
            enumerator: IntakeEnumerator(),
            mover: InboxCaptureService(fileSystem: LocalCaptureMutationFileSystem()),
            dashboardRefresh: dashboardRefresh
        )
    }

    init(
        configurationStore: CaptureConfigurationStore,
        fileSystem: any CaptureFileSystem,
        enumerator: any IntakeEnumerating = IntakeEnumerator(),
        mover: any CaptureMoving,
        dashboardRefresh: @escaping () -> Void = {}
    ) {
        self.configurationStore = configurationStore
        self.fileSystem = fileSystem
        self.enumerator = enumerator
        self.mover = mover
        self.dashboardRefresh = dashboardRefresh
        refresh()
    }

    var items: [IntakeItem] { enumeration?.items ?? [] }
    var selectedItems: [IntakeItem] { items.filter { selectedItemIDs.contains($0.id) } }
    var selectedCount: Int { selectedItems.count }
    var canMove: Bool { configuration != nil && destinationProblem == nil && selectedCount > 0 && !isMoveInProgress }

    func refresh() {
        isConfirmationPresented = false
        configurationProblem = nil
        destinationProblem = nil
        configuration = nil
        enumeration = nil

        switch configurationStore.launchState() {
        case let .configured(configuration):
            self.configuration = configuration
            let validation = CaptureConfigurationValidator(fileSystem: fileSystem).validate(configuration)
            if validation.destinationState != .available {
                destinationProblem = "Enterprise Inbox destination is unavailable."
            }
            do {
                enumeration = try enumerator.enumerate(configuration: configuration, fileSystem: fileSystem)
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
        if selectedItemIDs.contains(item.id) {
            selectedItemIDs.remove(item.id)
        } else {
            selectedItemIDs.insert(item.id)
        }
    }

    func selectAll() {
        selectedItemIDs = Set(items.map(\.id))
    }

    func clearSelection() {
        selectedItemIDs = []
    }

    func requestMoveConfirmation() {
        guard canMove else { return }
        isConfirmationPresented = true
    }

    func cancelMoveConfirmation() {
        isConfirmationPresented = false
    }

    func confirmMove() {
        guard !isMoveInProgress, isConfirmationPresented, let configuration, !selectedItems.isEmpty else { return }
        let submittedItems = selectedItems
        isMoveInProgress = true
        isConfirmationPresented = false
        let result = mover.move(selected: submittedItems, configuration: configuration)
        moveResult = result
        isMoveInProgress = false
        refresh()
        dashboardRefresh()
    }

    private func reconcileSelection() {
        selectedItemIDs.formIntersection(Set(items.map(\.id)))
    }
}

struct EnterpriseInboxCaptureSheet: View {
    @ObservedObject var viewModel: EnterpriseInboxCaptureViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Items").font(.title2)
                    Text("Select items to move into Enterprise Inbox.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh") { viewModel.refresh() }
                    .disabled(viewModel.isMoveInProgress)
                    .accessibilityLabel("Refresh intake items")
            }

            if let problem = viewModel.configurationProblem {
                ContentUnavailableView("Capture configuration unavailable", systemImage: "exclamationmark.triangle", description: Text(problem))
            } else {
                sourceAvailability
                if let destinationProblem = viewModel.destinationProblem {
                    Text(destinationProblem).foregroundStyle(.orange)
                }
                resultSummary
                intakeContent
                controls
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 440)
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
    }

    private var sourceAvailability: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Intake sources").font(.headline)
            ForEach(viewModel.enumeration?.sources ?? [], id: \.source.id) { source in
                Text("\(source.source.displayName): \(availabilityText(source.availability))")
                    .accessibilityLabel("\(source.source.displayName), \(availabilityText(source.availability))")
                    .foregroundStyle(isUnavailable(source.availability) ? .orange : .secondary)
            }
        }
    }

    @ViewBuilder
    private var resultSummary: some View {
        if let result = viewModel.moveResult {
            let moved = result.results.filter { if case .moved = $0.outcome { return true }; return false }.count
            let failures = result.results.compactMap { item -> String? in
                guard case let .failed(_, diagnostic, _) = item.outcome else { return nil }
                return "\(item.item.displayName): \(diagnostic)"
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Move result: \(moved) moved, \(failures.count) failed.")
                    .font(.subheadline.weight(.semibold))
                ForEach(failures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
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
