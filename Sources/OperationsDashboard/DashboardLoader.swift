import Foundation

protocol ConfigurationLoading {
    func loadConfiguration() throws -> DashboardConfiguration
}

protocol ConfigurationStorage {
    func loadData() throws -> Data?
    func saveData(_ data: Data) throws
}

struct ApplicationSupportConfigurationStorage: ConfigurationStorage {
    let fileManager: FileManager = .default

    var configurationURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "Operations Dashboard", directoryHint: .isDirectory)
            .appending(path: "dashboard-config.json", directoryHint: .notDirectory)
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

enum ConfigurationLaunchState: Equatable {
    case setupRequired
    case configured(DashboardConfiguration)
    case malformed(String)
}

struct ConfigurationStore: ConfigurationLoading {
    let storage: any ConfigurationStorage

    init(storage: any ConfigurationStorage = ApplicationSupportConfigurationStorage()) {
        self.storage = storage
    }

    func launchState() -> ConfigurationLaunchState {
        do {
            guard let data = try storage.loadData() else { return .setupRequired }
            return .configured(try decode(data: data))
        } catch {
            return .malformed(error.localizedDescription)
        }
    }

    func loadConfiguration() throws -> DashboardConfiguration {
        guard case let .configured(configuration) = launchState() else { throw ConfigurationError.absent }
        return configuration
    }

    func saveResolvedConfiguration(_ configuration: DashboardConfiguration) throws {
        let validated = try configuration.validated()
        let data = try JSONEncoder().encode(validated)
        try storage.saveData(data)
    }

    func decode(data: Data) throws -> DashboardConfiguration {
        do {
            return try JSONDecoder().decode(DashboardConfiguration.self, from: data).validated()
        } catch let error as ConfigurationError {
            throw error
        } catch {
            throw ConfigurationError.malformed(error.localizedDescription)
        }
    }
}

struct DashboardLoader {
    let configurationLoader: any ConfigurationLoading
    let fileSystem: any FileSystem
    private let scanner = InboxScanner()
    private let parser = StatusParser()

    init(configurationLoader: any ConfigurationLoading, fileSystem: any FileSystem) {
        self.configurationLoader = configurationLoader
        self.fileSystem = fileSystem
    }

    func load() throws -> [ProductDashboardState] {
        try load(configuration: configurationLoader.loadConfiguration())
    }

    func load(configuration: DashboardConfiguration) throws -> [ProductDashboardState] {
        try configuration.validated().products.map(loadProduct)
    }

    private func loadProduct(_ product: ConfiguredProduct) -> ProductDashboardState {
        let inboxURL = product.resolved(product.inboxRelativePath)
        let statusURL = product.resolved(product.statusRecordRelativePath)
        var issues: [SourceIssue] = []
        var inboxCount: Int?
        var status: OperatingStatus?

        if !fileSystem.exists(at: inboxURL) {
            issues.append(.missingInbox)
        } else {
            do { inboxCount = try scanner.countEntries(at: inboxURL, fileSystem: fileSystem) }
            catch { issues.append(.unreadableInbox(error.localizedDescription)) }
        }

        if !fileSystem.exists(at: statusURL) {
            issues.append(.missingStatusRecord)
        } else {
            do {
                status = try parser.parse(data: fileSystem.readData(at: statusURL), sourceModificationDate: fileSystem.modificationDate(at: statusURL))
            } catch let error as StatusParseError {
                issues.append(.malformedStatusRecord(error.localizedDescription))
            } catch {
                issues.append(.unreadableStatusRecord(error.localizedDescription))
            }
        }

        return ProductDashboardState(product: product, inboxCount: inboxCount, status: status, issues: issues)
    }
}
