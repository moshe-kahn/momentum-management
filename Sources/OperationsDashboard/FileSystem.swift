import Foundation

struct FileSystemEntry: Equatable, Sendable {
    let name: String
    let isRegularFile: Bool
    let isDirectory: Bool
}

protocol FileSystem {
    func exists(at url: URL) -> Bool
    func isDirectory(at url: URL) throws -> Bool
    func directoryEntries(at url: URL) throws -> [FileSystemEntry]
    func readData(at url: URL) throws -> Data
    func modificationDate(at url: URL) -> Date?
}

struct LocalFileSystem: FileSystem {
    private let manager = FileManager.default

    func exists(at url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    func isDirectory(at url: URL) throws -> Bool {
        try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
    }

    func directoryEntries(at url: URL) throws -> [FileSystemEntry] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey]
        return try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(keys), options: [])
            .map { child in
                let values = try child.resourceValues(forKeys: keys)
                return FileSystemEntry(
                    name: child.lastPathComponent,
                    isRegularFile: values.isRegularFile == true,
                    isDirectory: values.isDirectory == true
                )
            }
    }

    func readData(at url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    func modificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

struct InboxScanner {
    func countEntries(at url: URL, fileSystem: any FileSystem) throws -> Int {
        try fileSystem.directoryEntries(at: url).reduce(into: 0) { count, entry in
            guard !entry.name.hasPrefix(".") else { return }
            if entry.isRegularFile || entry.isDirectory { count += 1 }
        }
    }
}
