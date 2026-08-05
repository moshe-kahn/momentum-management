import Foundation

struct DashboardConfiguration: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let products: [ConfiguredProduct]

    func validated() throws -> DashboardConfiguration {
        guard schemaVersion == 1 else { throw ConfigurationError.unsupportedSchemaVersion(schemaVersion) }
        guard products.count == 2 else { throw ConfigurationError.requiresExactlyTwoProducts }
        let ids = Set(products.map(\.id))
        guard ids.count == products.count else { throw ConfigurationError.duplicateProductID }
        try products.forEach { try $0.validated() }
        return self
    }
}

struct ConfiguredProduct: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let productRootPath: String
    let inboxRelativePath: String
    let statusRecordRelativePath: String

    func validated() throws {
        guard !id.isEmpty, !displayName.isEmpty, !productRootPath.isEmpty,
              !inboxRelativePath.isEmpty, !statusRecordRelativePath.isEmpty else {
            throw ConfigurationError.emptyRequiredField
        }
        guard Self.isSafeRelativePath(inboxRelativePath),
              Self.isSafeRelativePath(statusRecordRelativePath) else {
            throw ConfigurationError.unsafeRelativePath
        }
    }

    func resolved(_ relativePath: String) -> URL {
        URL(fileURLWithPath: productRootPath, isDirectory: true)
            .appending(path: relativePath, directoryHint: .notDirectory)
    }

    private static func isSafeRelativePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.split(separator: "/").contains("..")
    }
}

enum ConfigurationError: LocalizedError, Equatable {
    case absent
    case malformed(String)
    case unsupportedSchemaVersion(Int)
    case requiresExactlyTwoProducts
    case duplicateProductID
    case emptyRequiredField
    case unsafeRelativePath

    var errorDescription: String? {
        switch self {
        case .absent: "Configuration is absent."
        case let .malformed(message): "Configuration is malformed: \(message)"
        case let .unsupportedSchemaVersion(version): "Unsupported configuration schema version \(version)."
        case .requiresExactlyTwoProducts: "Configuration must contain exactly two products."
        case .duplicateProductID: "Configuration product IDs must be unique."
        case .emptyRequiredField: "Configuration contains an empty required field."
        case .unsafeRelativePath: "Configuration contains a path outside its product root."
        }
    }
}

struct OperatingStatus: Equatable, Sendable {
    let currentStatus: String
    let nextActions: [String]
    let blockers: [String]
    let lastUpdated: Date
    let sourceModificationDate: Date?
}

enum SourceIssue: Equatable, Sendable {
    case missingInbox
    case missingStatusRecord
    case unreadableInbox(String)
    case unreadableStatusRecord(String)
    case malformedStatusRecord(String)

    var message: String {
        switch self {
        case .missingInbox: "Missing Inbox"
        case .missingStatusRecord: "Missing status record"
        case let .unreadableInbox(message): "Unreadable Inbox: \(message)"
        case let .unreadableStatusRecord(message): "Unreadable status record: \(message)"
        case let .malformedStatusRecord(message): "Malformed status record: \(message)"
        }
    }
}

struct ProductDashboardState: Identifiable, Equatable, Sendable {
    let product: ConfiguredProduct
    let inboxCount: Int?
    let status: OperatingStatus?
    let issues: [SourceIssue]

    var id: String { product.id }
    var isAvailable: Bool { issues.isEmpty }
}
