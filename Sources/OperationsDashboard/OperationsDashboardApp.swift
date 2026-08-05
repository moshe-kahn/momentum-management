import SwiftUI

@main
struct OperationsDashboardApp: App {
    var body: some Scene {
        WindowGroup("Operations Dashboard") {
            DashboardView(viewModel: DashboardViewModel(
                loader: DashboardLoader(configurationLoader: ConfigurationStore(), fileSystem: LocalFileSystem())
            ))
        }
    }
}

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published private(set) var products: [ProductDashboardState] = []
    @Published private(set) var configurationError: String?

    private let loader: DashboardLoader

    init(loader: DashboardLoader) {
        self.loader = loader
        refresh()
    }

    func refresh() {
        do {
            products = try loader.load()
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
            }
            if let error = viewModel.configurationError {
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
        .frame(minWidth: 580, minHeight: 360)
    }
}
