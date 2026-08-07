import Foundation

struct CaptureConfiguration: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    static let expectedSources = [
        (id: "icloud-downloads", displayName: "iCloud Drive Downloads"),
        (id: "kahntra-downloads", displayName: "Kahntra Downloads")
    ]

    let schemaVersion: Int
    let intakeSources: [IntakeSource]
    let enterpriseInboxPath: String

    func validated() throws -> CaptureConfiguration {
        guard schemaVersion == Self.schemaVersion else {
            throw CaptureConfigurationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard intakeSources.count == Self.expectedSources.count else {
            throw CaptureConfigurationError.requiresExactlyTwoSources
        }
        guard !enterpriseInboxPath.isEmpty, URL(fileURLWithPath: enterpriseInboxPath).path == enterpriseInboxPath else {
            throw CaptureConfigurationError.invalidEnterpriseInboxPath
        }
        let destinationComponents = URL(fileURLWithPath: enterpriseInboxPath).standardizedFileURL.pathComponents
        guard destinationComponents.suffix(2) == ["Dashboard", "Inbox"] else {
            throw CaptureConfigurationError.invalidEnterpriseInboxPath
        }

        for (source, expected) in zip(intakeSources, Self.expectedSources) {
            guard source.id == expected.id, source.displayName == expected.displayName else {
                throw CaptureConfigurationError.invalidSourceDefinition
            }
            try source.validated()
        }

        let normalizedSources = intakeSources.map { URL(fileURLWithPath: $0.rootPath).standardizedFileURL.path }
        guard Set(normalizedSources).count == normalizedSources.count else {
            throw CaptureConfigurationError.duplicateSourcePath
        }
        let destination = URL(fileURLWithPath: enterpriseInboxPath).standardizedFileURL.path
        guard !normalizedSources.contains(destination) else {
            throw CaptureConfigurationError.destinationMatchesSource
        }
        return self
    }

    var enterpriseInboxURL: URL {
        URL(fileURLWithPath: enterpriseInboxPath, isDirectory: true)
    }
}

struct IntakeSource: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let rootPath: String

    func validated() throws {
        guard !id.isEmpty, !displayName.isEmpty, !rootPath.isEmpty,
              URL(fileURLWithPath: rootPath).path == rootPath else {
            throw CaptureConfigurationError.invalidSourcePath
        }
    }

    var rootURL: URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
    }
}

enum CaptureConfigurationError: LocalizedError, Equatable {
    case absent
    case malformed(String)
    case unsupportedSchemaVersion(Int)
    case requiresExactlyTwoSources
    case invalidSourceDefinition
    case invalidSourcePath
    case invalidEnterpriseInboxPath
    case duplicateSourcePath
    case destinationMatchesSource

    var errorDescription: String? {
        switch self {
        case .absent: "Capture configuration is absent."
        case let .malformed(message): "Capture configuration is malformed: \(message)"
        case let .unsupportedSchemaVersion(version): "Unsupported capture configuration schema version \(version)."
        case .requiresExactlyTwoSources: "Capture configuration must contain exactly two intake sources."
        case .invalidSourceDefinition: "Capture configuration source IDs or labels are invalid."
        case .invalidSourcePath: "Capture configuration contains an invalid intake source path."
        case .invalidEnterpriseInboxPath: "Capture configuration contains an invalid Enterprise Inbox path."
        case .duplicateSourcePath: "Capture configuration intake source paths must be distinct."
        case .destinationMatchesSource: "Enterprise Inbox cannot also be an intake source."
        }
    }
}

protocol CaptureConfigurationStorage {
    func loadData() throws -> Data?
    func saveData(_ data: Data) throws
}

struct ApplicationSupportCaptureConfigurationStorage: CaptureConfigurationStorage {
    let fileManager: FileManager = .default

    var configurationURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "Operations Dashboard", directoryHint: .isDirectory)
            .appending(path: "enterprise-inbox-capture-config.json", directoryHint: .notDirectory)
    }

    func loadData() throws -> Data? {
        guard fileManager.fileExists(atPath: configurationURL.path) else { return nil }
        return try Data(contentsOf: configurationURL)
    }

    func saveData(_ data: Data) throws {
        try fileManager.createDirectory(at: configurationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: configurationURL, options: .atomic)
    }
}

enum CaptureConfigurationLaunchState: Equatable {
    case setupRequired
    case configured(CaptureConfiguration)
    case malformed(String)
}

struct CaptureConfigurationStore {
    let storage: any CaptureConfigurationStorage

    init(storage: any CaptureConfigurationStorage = ApplicationSupportCaptureConfigurationStorage()) {
        self.storage = storage
    }

    func launchState() -> CaptureConfigurationLaunchState {
        do {
            guard let data = try storage.loadData() else { return .setupRequired }
            return .configured(try decode(data: data))
        } catch {
            return .malformed(error.localizedDescription)
        }
    }

    func loadConfiguration() throws -> CaptureConfiguration {
        guard case let .configured(configuration) = launchState() else { throw CaptureConfigurationError.absent }
        return configuration
    }

    func saveResolvedConfiguration(_ configuration: CaptureConfiguration) throws {
        let data = try JSONEncoder().encode(configuration.validated())
        try storage.saveData(data)
    }

    func decode(data: Data) throws -> CaptureConfiguration {
        do {
            return try JSONDecoder().decode(CaptureConfiguration.self, from: data).validated()
        } catch let error as CaptureConfigurationError {
            throw error
        } catch {
            throw CaptureConfigurationError.malformed(error.localizedDescription)
        }
    }
}

struct CaptureDirectoryEntry: Equatable, Sendable {
    let url: URL
    let name: String
    let isRegularFile: Bool
    let isDirectory: Bool
    let isPackage: Bool
    let isSymbolicLink: Bool
    let resourceIdentifier: String?
}

protocol CaptureFileSystem {
    func exists(at url: URL) -> Bool
    func isReadable(at url: URL) -> Bool
    func isWritable(at url: URL) -> Bool
    func isDirectory(at url: URL) throws -> Bool
    func isSymbolicLink(at url: URL) throws -> Bool
    func directoryEntries(at url: URL) throws -> [CaptureDirectoryEntry]
}

struct LocalCaptureFileSystem: CaptureFileSystem {
    private let manager = FileManager.default

    func exists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    func isReadable(at url: URL) -> Bool {
        manager.isReadableFile(atPath: url.path)
    }

    func isWritable(at url: URL) -> Bool {
        manager.isWritableFile(atPath: url.path)
    }

    func isDirectory(at url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    func isSymbolicLink(at url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
    }

    func directoryEntries(at url: URL) throws -> [CaptureDirectoryEntry] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isPackageKey,
            .isSymbolicLinkKey,
            .fileResourceIdentifierKey
        ]
        return try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: []).map { child in
            let values = try child.resourceValues(forKeys: keys)
            return CaptureDirectoryEntry(
                url: child.standardizedFileURL,
                name: child.lastPathComponent,
                isRegularFile: values.isRegularFile == true,
                isDirectory: values.isDirectory == true,
                isPackage: values.isPackage == true,
                isSymbolicLink: values.isSymbolicLink == true,
                resourceIdentifier: values.fileResourceIdentifier.map { String(describing: $0) }
            )
        }
    }
}

enum IntakeItemKind: String, Equatable, Sendable {
    case file
    case directory
    case package
}

struct IntakeItem: Identifiable, Equatable, Sendable {
    let sourceID: String
    let sourceDisplayName: String
    let sourceRootURL: URL
    let itemURL: URL
    let displayName: String
    let kind: IntakeItemKind
    let resourceIdentifier: String?

    var id: String {
        "\(sourceID)|\(resourceIdentifier ?? itemURL.standardizedFileURL.path)"
    }
}

enum IntakeSourceAvailability: Equatable, Sendable {
    case available
    case empty
    case missing
    case unreadable(String)
}

struct IntakeSourceEnumeration: Equatable, Sendable {
    let source: IntakeSource
    let availability: IntakeSourceAvailability
    let items: [IntakeItem]
}

struct IntakeEnumerationResult: Equatable, Sendable {
    let sources: [IntakeSourceEnumeration]
    let items: [IntakeItem]
}

struct IntakeEnumerator {
    func enumerate(configuration: CaptureConfiguration, fileSystem: any CaptureFileSystem) throws -> IntakeEnumerationResult {
        let validated = try configuration.validated()
        let sources = validated.intakeSources.map { enumerate(source: $0, fileSystem: fileSystem) }
        let items = sources.flatMap(\.items).sorted(by: sort)
        return IntakeEnumerationResult(sources: sources, items: items)
    }

    private func enumerate(source: IntakeSource, fileSystem: any CaptureFileSystem) -> IntakeSourceEnumeration {
        let root = source.rootURL
        guard fileSystem.exists(at: root) else {
            return IntakeSourceEnumeration(source: source, availability: .missing, items: [])
        }
        do {
            guard try fileSystem.isDirectory(at: root), !(try fileSystem.isSymbolicLink(at: root)), fileSystem.isReadable(at: root) else {
                return IntakeSourceEnumeration(source: source, availability: .unreadable("Source is not a readable non-symbolic-link directory."), items: [])
            }
            let items = try fileSystem.directoryEntries(at: root).compactMap { entry -> IntakeItem? in
                guard !entry.name.hasPrefix("."), !entry.isSymbolicLink else { return nil }
                let kind: IntakeItemKind?
                if entry.isPackage && entry.isDirectory {
                    kind = .package
                } else if entry.isDirectory {
                    kind = .directory
                } else if entry.isRegularFile {
                    kind = .file
                } else {
                    kind = nil
                }
                guard let kind else { return nil }
                return IntakeItem(
                    sourceID: source.id,
                    sourceDisplayName: source.displayName,
                    sourceRootURL: root.standardizedFileURL,
                    itemURL: entry.url.standardizedFileURL,
                    displayName: entry.name,
                    kind: kind,
                    resourceIdentifier: entry.resourceIdentifier
                )
            }
            return IntakeSourceEnumeration(source: source, availability: items.isEmpty ? .empty : .available, items: items)
        } catch {
            return IntakeSourceEnumeration(source: source, availability: .unreadable(error.localizedDescription), items: [])
        }
    }

    private func sort(lhs: IntakeItem, rhs: IntakeItem) -> Bool {
        let nameOrder = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        let leftSource = CaptureConfiguration.expectedSources.firstIndex { $0.id == lhs.sourceID } ?? .max
        let rightSource = CaptureConfiguration.expectedSources.firstIndex { $0.id == rhs.sourceID } ?? .max
        if leftSource != rightSource { return leftSource < rightSource }
        return lhs.itemURL.standardizedFileURL.path < rhs.itemURL.standardizedFileURL.path
    }
}

enum CaptureConfigurationPathState: Equatable, Sendable {
    case available
    case missing
    case unreadable
    case symbolicLink
}

struct CaptureConfigurationValidationResult: Equatable, Sendable {
    let sourceStates: [String: CaptureConfigurationPathState]
    let destinationState: CaptureConfigurationPathState
    let errors: [String]

    var canSave: Bool { errors.isEmpty }
}

struct CaptureConfigurationValidator {
    let fileSystem: any CaptureFileSystem

    func validate(_ configuration: CaptureConfiguration) -> CaptureConfigurationValidationResult {
        do {
            let validated = try configuration.validated()
            var errors: [String] = []
            var sourceStates: [String: CaptureConfigurationPathState] = [:]
            let destination = validated.enterpriseInboxURL.standardizedFileURL
            let destinationState = pathState(at: destination, requiresWritable: true)

            if destinationState != .available {
                errors.append("Enterprise Inbox destination is unavailable.")
            }

            for source in validated.intakeSources {
                let root = source.rootURL.standardizedFileURL
                let state = pathState(at: root, requiresWritable: false)
                sourceStates[source.id] = state
                if state != .available {
                    errors.append("\(source.displayName) is unavailable.")
                }
                if contains(root, destination) || contains(destination, root) {
                    errors.append("\(source.displayName) cannot contain or be contained by Enterprise Inbox.")
                }
            }

            return CaptureConfigurationValidationResult(
                sourceStates: sourceStates,
                destinationState: destinationState,
                errors: errors
            )
        } catch {
            return CaptureConfigurationValidationResult(
                sourceStates: [:],
                destinationState: .missing,
                errors: [error.localizedDescription]
            )
        }
    }

    private func pathState(at url: URL, requiresWritable: Bool) -> CaptureConfigurationPathState {
        guard fileSystem.exists(at: url) else { return .missing }
        do {
            guard !(try fileSystem.isSymbolicLink(at: url)) else { return .symbolicLink }
            guard try fileSystem.isDirectory(at: url), fileSystem.isReadable(at: url), !requiresWritable || fileSystem.isWritable(at: url) else {
                return .unreadable
            }
            return .available
        } catch {
            return .unreadable
        }
    }

    private func contains(_ parent: URL, _ child: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        guard childComponents.count > parentComponents.count else { return false }
        return zip(parentComponents, childComponents).allSatisfy(==)
    }
}
