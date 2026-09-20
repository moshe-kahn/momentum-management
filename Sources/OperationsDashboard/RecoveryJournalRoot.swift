import Foundation

enum RecoveryJournalRoot {
    static let environmentKey = "OPERATIONS_DASHBOARD_RECOVERY_ROOT"
    private static let state = RecoveryJournalRootState()

    static func withProductionsRoot<T>(_ productionsRootPath: String, _ body: () throws -> T) rethrows -> T {
        let previous = state.replace(productionsRootPath)
        defer {
            _ = state.replace(previous)
        }
        return try body()
    }

    static func directory(
        named name: String,
        manager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
                .appending(path: name, directoryHint: .isDirectory)
        }

        let productionsRootPath = state.productionsRootPath()
        if let productionsRootPath,
           !productionsRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: productionsRootPath, isDirectory: true)
                .appending(path: "Warehouse/Recovery/OperationsDashboard/\(name)", directoryHint: .isDirectory)
        }

        return manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/\(name)", directoryHint: .isDirectory)
    }
}

private final class RecoveryJournalRootState: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var scopedProductionsRootPath: String?

    func replace(_ value: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let previous = scopedProductionsRootPath
        scopedProductionsRootPath = value
        return previous
    }

    func productionsRootPath() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return scopedProductionsRootPath
    }
}
