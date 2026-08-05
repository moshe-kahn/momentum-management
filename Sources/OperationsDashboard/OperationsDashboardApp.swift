import AppKit
import SwiftUI

@main
struct OperationsDashboardApp: App {
    var body: some Scene {
        WindowGroup("Operations Dashboard") {
            DashboardView(viewModel: DashboardViewModel.live())
        }
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var products: [ProductDashboardState] = []
    @Published private(set) var configurationError: String?
    @Published var setupDraft: SetupDraft = .initial()
    @Published private(set) var setupResult = SetupValidationResult(errors: [], warnings: [], assessments: [])
    @Published private(set) var isShowingSetup = true
    @Published private(set) var setupSaveError: String?

    private let store: ConfigurationStore
    private let fileSystem: any FileSystem
    private var hasSavedConfiguration = false

    static func live() -> DashboardViewModel {
        DashboardViewModel(store: ConfigurationStore(), fileSystem: LocalFileSystem())
    }

    init(store: ConfigurationStore, fileSystem: any FileSystem) {
        self.store = store
        self.fileSystem = fileSystem
        reloadLaunchState()
    }

    func refresh() {
        guard !isShowingSetup else {
            validateSetup()
            return
        }
        loadDashboard()
    }

    func reopenSetup() {
        setupDraft = SetupCoordinator(store: store, validator: SetupValidator(fileSystem: fileSystem))
            .initialDraft(for: store.launchState())
        setupSaveError = nil
        validateSetup()
        isShowingSetup = true
    }

    func chooseRoot(for productID: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let index = setupDraft.products.firstIndex(where: { $0.id == productID }) else { return }
        setupDraft.products[index].productRootPath = url.standardizedFileURL.path
        setupSaveError = nil
        validateSetup()
    }

    func validateSetup() {
        setupResult = SetupValidator(fileSystem: fileSystem).validate(setupDraft)
    }

    func saveSetup() {
        setupSaveError = nil
        do {
            let coordinator = SetupCoordinator(store: store, validator: SetupValidator(fileSystem: fileSystem))
            setupResult = try coordinator.save(setupDraft)
            guard setupResult.canSave else { return }
            reloadLaunchState()
        } catch {
            setupSaveError = error.localizedDescription
        }
    }

    func cancelSetup() {
        guard hasSavedConfiguration else { return }
        isShowingSetup = false
        loadDashboard()
    }

    private func reloadLaunchState() {
        switch store.launchState() {
        case let .configured(configuration):
            hasSavedConfiguration = true
            setupDraft = .from(configuration: configuration)
            isShowingSetup = false
            configurationError = nil
            loadDashboard(configuration: configuration)
        case .setupRequired:
            hasSavedConfiguration = false
            setupDraft = .initial()
            isShowingSetup = true
            configurationError = "Setup is required before the dashboard can read any product folder."
            validateSetup()
        case let .malformed(message):
            hasSavedConfiguration = false
            setupDraft = .initial()
            isShowingSetup = true
            configurationError = "Saved configuration is malformed: \(message)"
            validateSetup()
        }
    }

    private func loadDashboard() {
        guard case let .configured(configuration) = store.launchState() else { return }
        loadDashboard(configuration: configuration)
    }

    private func loadDashboard(configuration: DashboardConfiguration) {
        do {
            products = try DashboardLoader(configurationLoader: store, fileSystem: fileSystem).load(configuration: configuration)
            configurationError = nil
        } catch {
            products = []
            configurationError = error.localizedDescription
        }
    }
}

struct DashboardView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Operations Dashboard")
                    .font(.title2)
                Spacer()
                Button("Refresh") { viewModel.refresh() }
                    .disabled(viewModel.isShowingSetup)
                if !viewModel.isShowingSetup {
                    Button("Configure Sources") { viewModel.reopenSetup() }
                }
            }
            if viewModel.isShowingSetup {
                SetupView(viewModel: viewModel)
            } else if let error = viewModel.configurationError {
                ContentUnavailableView("Configuration unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                List(viewModel.products) { product in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(product.product.displayName).font(.headline)
                        Text(product.inboxCount.map { "Inbox: \($0)" } ?? "Inbox unavailable")
                        Text(product.status?.currentStatus ?? "Status unavailable")
                        if !product.issues.isEmpty {
                            Text(product.issues.map(\.message).joined(separator: " · "))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 420)
    }
}

private struct SetupView: View {
    @ObservedObject var viewModel: DashboardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Up Sources").font(.headline)
            Text("Choose exactly the two approved product roots. Derived source paths are read-only and missing future status records are warnings, not files to create.")
                .foregroundStyle(.secondary)
            if let configurationError = viewModel.configurationError {
                Text(configurationError).foregroundStyle(.orange)
            }
            ForEach(viewModel.setupDraft.products) { product in
                VStack(alignment: .leading, spacing: 5) {
                    Text(product.displayName).font(.subheadline.bold())
                    Text(product.productRootPath.isEmpty ? "No root selected" : product.productRootPath)
                        .font(.caption).textSelection(.enabled)
                    Button("Choose Product Root") { viewModel.chooseRoot(for: product.id) }
                    derivedPath("Inbox", product.derivedInboxURL, assessment: assessment(for: product.id)?.inboxState)
                    derivedPath("Status record", product.derivedStatusRecordURL, assessment: assessment(for: product.id)?.statusRecordState)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
            messages(viewModel.setupResult.errors, color: .red)
            messages(viewModel.setupResult.warnings, color: .orange)
            if let saveError = viewModel.setupSaveError { Text(saveError).foregroundStyle(.red) }
            HStack {
                Button("Validate") { viewModel.validateSetup() }
                Spacer()
                Button("Cancel") { viewModel.cancelSetup() }
                    .disabled(!canCancel)
                Button("Save Configuration") { viewModel.saveSetup() }
                    .disabled(!viewModel.setupResult.canSave)
            }
        }
    }

    private var canCancel: Bool { !viewModel.products.isEmpty }

    private func assessment(for id: String) -> SetupProductAssessment? {
        viewModel.setupResult.assessments.first(where: { $0.id == id })
    }

    @ViewBuilder
    private func derivedPath(_ label: String, _ url: URL?, assessment: SetupSourceState?) -> some View {
        Text("\(label): \(url?.path ?? "Select a root first") — \(assessment?.message ?? "Not checked")")
            .font(.caption)
            .foregroundStyle(assessment == .missing ? .orange : .secondary)
    }

    @ViewBuilder
    private func messages(_ messages: [String], color: Color) -> some View {
        ForEach(messages, id: \.self) { Text($0).font(.caption).foregroundStyle(color) }
    }
}
