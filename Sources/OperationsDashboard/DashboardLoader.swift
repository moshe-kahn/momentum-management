import Foundation

protocol ConfigurationLoading {
    func loadConfiguration() throws -> DashboardConfiguration
}

struct ConfigurationStore: ConfigurationLoading {
    let fileManager: FileManager = .default
    let bundle: Bundle = .module

    var applicationSupportURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: "Operations Dashboard", directoryHint: .isDirectory)
            .appending(path: "dashboard-config.json", directoryHint: .notDirectory)
    }

    func loadConfiguration() throws -> DashboardConfiguration {
        if fileManager.fileExists(atPath: applicationSupportURL.path) {
            return try decode(data: Data(contentsOf: applicationSupportURL))
        }
        guard let sampleURL = bundle.url(forResource: "dashboard-config.sample", withExtension: "json") else {
            throw ConfigurationError.absent
        }
        return try decode(data: Data(contentsOf: sampleURL))
    }

    func saveResolvedConfiguration(_ configuration: DashboardConfiguration) throws {
        let validated = try configuration.validated()
        try fileManager.createDirectory(at: applicationSupportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(validated)
        try data.write(to: applicationSupportURL, options: .atomic)
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
        try configurationLoader.loadConfiguration().products.map(loadProduct)
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
