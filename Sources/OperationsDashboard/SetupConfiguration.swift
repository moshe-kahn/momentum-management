import Foundation

struct SetupProductDraft: Identifiable, Equatable {
    let id: String
    let displayName: String
    var productRootPath: String

    static let inboxRelativePath = "Dashboard/Inbox"
    static let statusRecordRelativePath = "Reference/Product/Operations Dashboard Status.md"

    var derivedInboxURL: URL? {
        guard !productRootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: productRootPath, isDirectory: true)
            .appending(path: Self.inboxRelativePath, directoryHint: .isDirectory)
    }

    var derivedStatusRecordURL: URL? {
        guard !productRootPath.isEmpty else { return nil }
        return URL(fileURLWithPath: productRootPath, isDirectory: true)
            .appending(path: Self.statusRecordRelativePath, directoryHint: .notDirectory)
    }

    func asConfiguredProduct() -> ConfiguredProduct {
        ConfiguredProduct(
            id: id,
            displayName: displayName,
            productRootPath: productRootPath,
            inboxRelativePath: Self.inboxRelativePath,
            statusRecordRelativePath: Self.statusRecordRelativePath
        )
    }
}

struct SetupDraft: Equatable {
    var products: [SetupProductDraft]

    static func initial() -> SetupDraft {
        SetupDraft(products: [
            SetupProductDraft(id: "momentum-management", displayName: "Momentum Management", productRootPath: ""),
            SetupProductDraft(id: "momomovies", displayName: "MomoMovies", productRootPath: "")
        ])
    }

    static func from(configuration: DashboardConfiguration) -> SetupDraft {
        let byID = Dictionary(uniqueKeysWithValues: configuration.products.map { ($0.id, $0) })
        var draft = initial()
        for index in draft.products.indices {
            if let configured = byID[draft.products[index].id] {
                draft.products[index].productRootPath = configured.productRootPath
            }
        }
        return draft
    }

    func configuration() throws -> DashboardConfiguration {
        try DashboardConfiguration(schemaVersion: 1, products: products.map { $0.asConfiguredProduct() }).validated()
    }
}

enum SetupSourceState: Equatable {
    case notSelected
    case available
    case missing
    case unreadable(String)

    var message: String {
        switch self {
        case .notSelected: "Select a product root."
        case .available: "Available"
        case .missing: "Missing"
        case let .unreadable(message): "Unreadable: \(message)"
        }
    }
}

struct SetupProductAssessment: Equatable, Identifiable {
    let id: String
    let rootState: SetupSourceState
    let inboxState: SetupSourceState
    let statusRecordState: SetupSourceState
}

struct SetupValidationResult: Equatable {
    let errors: [String]
    let warnings: [String]
    let assessments: [SetupProductAssessment]

    var canSave: Bool { errors.isEmpty }
}

struct SetupValidator {
    let fileSystem: any FileSystem

    func validate(_ draft: SetupDraft) -> SetupValidationResult {
        var errors: [String] = []
        var warnings: [String] = []
        var assessments: [SetupProductAssessment] = []
        let ids = draft.products.map(\.id)
        if Set(ids).count != ids.count { errors.append("Configured product IDs must be distinct.") }

        let normalizedRoots = draft.products.compactMap { product -> String? in
            guard !product.productRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return URL(fileURLWithPath: product.productRootPath).standardizedFileURL.path
        }
        if Set(normalizedRoots).count != normalizedRoots.count { errors.append("Product roots must be distinct.") }

        for product in draft.products {
            let assessment = assess(product, errors: &errors, warnings: &warnings)
            assessments.append(assessment)
        }
        if draft.products.count != 2 { errors.append("Setup requires exactly two configured products.") }
        return SetupValidationResult(errors: errors, warnings: warnings, assessments: assessments)
    }

    private func assess(_ product: SetupProductDraft, errors: inout [String], warnings: inout [String]) -> SetupProductAssessment {
        let name = product.displayName
        guard !product.productRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errors.append("\(name) requires a product root.")
            return SetupProductAssessment(id: product.id, rootState: .notSelected, inboxState: .notSelected, statusRecordState: .notSelected)
        }

        let root = URL(fileURLWithPath: product.productRootPath, isDirectory: true)
        guard fileSystem.exists(at: root) else {
            errors.append("\(name) product root does not exist.")
            return SetupProductAssessment(id: product.id, rootState: .missing, inboxState: .notSelected, statusRecordState: .notSelected)
        }

        do {
            guard try fileSystem.isDirectory(at: root) else {
                errors.append("\(name) product root is not a directory.")
                return SetupProductAssessment(id: product.id, rootState: .unreadable("Not a directory"), inboxState: .notSelected, statusRecordState: .notSelected)
            }
            _ = try fileSystem.directoryEntries(at: root)
        } catch {
            errors.append("\(name) product root is inaccessible.")
            return SetupProductAssessment(id: product.id, rootState: .unreadable(error.localizedDescription), inboxState: .notSelected, statusRecordState: .notSelected)
        }

        let inboxState = sourceState(at: product.derivedInboxURL, label: "Inbox", productName: name, warnings: &warnings)
        let statusState = sourceState(at: product.derivedStatusRecordURL, label: "status record", productName: name, warnings: &warnings)
        return SetupProductAssessment(id: product.id, rootState: .available, inboxState: inboxState, statusRecordState: statusState)
    }

    private func sourceState(at url: URL?, label: String, productName: String, warnings: inout [String]) -> SetupSourceState {
        guard let url else { return .notSelected }
        guard fileSystem.exists(at: url) else {
            warnings.append("\(productName) \(label) is missing; no file or folder will be created.")
            return .missing
        }
        if label == "Inbox" {
            do {
                _ = try fileSystem.directoryEntries(at: url)
            } catch {
                warnings.append("\(productName) Inbox is unreadable.")
                return .unreadable(error.localizedDescription)
            }
        }
        return .available
    }
}

struct SetupCoordinator {
    let store: ConfigurationStore
    let validator: SetupValidator

    func initialDraft(for state: ConfigurationLaunchState) -> SetupDraft {
        if case let .configured(configuration) = state { return .from(configuration: configuration) }
        return .initial()
    }

    func save(_ draft: SetupDraft) throws -> SetupValidationResult {
        let result = validator.validate(draft)
        guard result.canSave else { return result }
        try store.saveResolvedConfiguration(draft.configuration())
        return result
    }
}
