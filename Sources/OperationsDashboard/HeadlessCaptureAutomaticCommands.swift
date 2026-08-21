import CryptoKit
import Darwin
import Foundation

enum AutomaticCaptureDisposition: String, Codable, Equatable {
    case deferred, ineligible, planned, collision, notAttempted
}

struct AutomaticCaptureItemState: Codable, Equatable {
    let filesystemKind: UInt32
    let device: UInt64
    let inode: UInt64
    let byteSize: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    var isRegularFile: Bool { filesystemKind == UInt32(S_IFREG) }
    var isDirectory: Bool { filesystemKind == UInt32(S_IFDIR) }
    func hasSameIdentity(as other: Self) -> Bool { filesystemKind == other.filesystemKind && device == other.device && inode == other.inode }
}

struct AutomaticCaptureObservationItem: Codable, Equatable {
    let basename: String
    let state: AutomaticCaptureItemState
    let eligible: Bool
    let diagnostic: String
}

struct AutomaticCaptureObservation: Codable, Equatable {
    static let schemaVersion = 1
    static let action = "capture-automatic-observe"
    let schema: Int
    let actionDiscriminator: String
    let receiptID: String
    let bootSessionID: String
    let continuousNanoseconds: UInt64
    let observedAt: String
    let productionsRoot: String
    let sourcePath: String
    let officePath: String
    let inboxPath: String
    let rootState: AutomaticCaptureItemState
    let sourceState: AutomaticCaptureItemState
    let officeState: AutomaticCaptureItemState
    let inboxState: AutomaticCaptureItemState
    let items: [AutomaticCaptureObservationItem]
}

struct AutomaticCaptureMoveItem: Codable, Equatable {
    let basename: String
    let sourcePath: String
    let destinationPath: String
    let state: AutomaticCaptureItemState
    let disposition: AutomaticCaptureDisposition
    let diagnostic: String
}

struct AutomaticCaptureMovePreview: Codable, Equatable {
    static let schemaVersion = 1
    static let action = "capture-automatic-move"
    let schema: Int
    let actionDiscriminator: String
    let observation: AutomaticCaptureObservation
    let productionsRoot: String
    let sourcePath: String
    let officePath: String
    let inboxPath: String
    let rootState: AutomaticCaptureItemState
    let sourceState: AutomaticCaptureItemState
    let officeState: AutomaticCaptureItemState
    let inboxState: AutomaticCaptureItemState
    let items: [AutomaticCaptureMoveItem]
}

struct AutomaticCaptureCommitItem: Codable, Equatable {
    enum State: String, Codable { case pending, renaming, publishedUnverified, captured, failed, notAttempted }
    let basename: String
    var state: State
    var diagnostic: String
}

struct AutomaticCaptureBatchJournal: Codable, Equatable, @unchecked Sendable {
    enum State: String, Codable { case claimed, executing, completed, definiteFailure, partial, uncertain }
    let receiptID: String
    let preview: AutomaticCaptureMovePreview
    var state: State
    var items: [AutomaticCaptureCommitItem]
    var diagnostic: String
    var updatedAt: String
}

struct AutomaticCaptureCommitReport: Codable, Equatable {
    let receiptID: String
    let state: String
    let items: [AutomaticCaptureCommitItem]
    let diagnostic: String
}

enum AutomaticCaptureCommitOutcome {
    case completed(AutomaticCaptureCommitReport)
    case definiteFailure(AutomaticCaptureCommitReport)
    case uncertain(AutomaticCaptureCommitReport)
}

enum AutomaticCaptureError: LocalizedError, Equatable {
    case rejected(String)
    case confirmationRequired
    case uncertain(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(message), let .uncertain(message): message
        case .confirmationRequired: "The command does not match authoritative automatic-capture state. Observe and preview again."
        }
    }
}

private protocol AutomaticCanonicalJSON: Codable {}
extension AutomaticCaptureObservation: AutomaticCanonicalJSON {}
extension AutomaticCaptureMovePreview: AutomaticCanonicalJSON {}

private extension AutomaticCanonicalJSON {
    func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    func canonicalEnvelope() throws -> String { try canonicalJSON().base64EncodedString() }
}

extension AutomaticCaptureObservation {
    func observationToken() throws -> String { "observe:capture-automatic:v1:\(Self.digest(try canonicalJSON()))" }
    static func decodeEnvelope(_ envelope: String, token: String) throws -> Self {
        guard let data = Data(base64Encoded: envelope), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schema == schemaVersion, value.actionDiscriminator == action,
              try value.canonicalJSON() == data, try value.observationToken() == token else { throw AutomaticCaptureError.confirmationRequired }
        return value
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

extension AutomaticCaptureMovePreview {
    func confirmationToken() throws -> String {
        let digest = SHA256.hash(data: try canonicalJSON()).map { String(format: "%02x", $0) }.joined()
        return "confirm:capture-automatic-move:v1:\(digest)"
    }
    static func decodeEnvelope(_ envelope: String, token: String) throws -> Self {
        guard let data = Data(base64Encoded: envelope), let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schema == schemaVersion, value.actionDiscriminator == action,
              try value.canonicalJSON() == data, try value.confirmationToken() == token else { throw AutomaticCaptureError.confirmationRequired }
        return value
    }
}

struct AutomaticCaptureRuntime {
    let now: () -> Date
    let continuousNanoseconds: () -> UInt64
    let bootSessionID: () -> String
    let sameFileSystem: (AutomaticCaptureItemState, AutomaticCaptureItemState) -> Bool
    let renameExclusive: (Int32, String, Int32, String) -> Int32
    let beforeEntryInspection: (String) throws -> Void
    let beforeNamespaceRevalidation: () throws -> Void

    static var live: AutomaticCaptureRuntime { AutomaticCaptureRuntime(
        now: Date.init,
        continuousNanoseconds: {
            var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
            return mach_continuous_time() * UInt64(info.numer) / UInt64(info.denom)
        },
        bootSessionID: {
            var size = 0
            guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return "unavailable" }
            var bytes = [CChar](repeating: 0, count: size)
            guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "unavailable" }
            return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        },
        sameFileSystem: { $0.device == $1.device },
        renameExclusive: { sourceFD, sourceName, inboxFD, destinationName in
            let result = sourceName.withCString { sourcePointer in
                destinationName.withCString { destinationPointer in
                    renameatx_np(sourceFD, sourcePointer, inboxFD, destinationPointer, UInt32(RENAME_EXCL))
                }
            }
            return result == 0 ? 0 : errno
        },
        beforeEntryInspection: { _ in },
        beforeNamespaceRevalidation: {}
    ) }
}

final class AutomaticCaptureReceiptStore: @unchecked Sendable {
    private let root: URL
    private let now: () -> Date
    private let expiration: TimeInterval
    private let maximumRecords: Int
    private let failOperation: (String) -> Bool

    static func live() -> AutomaticCaptureReceiptStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AutomaticCaptureReceiptStore(root: support.appending(path: "com.kahntra.operations-dashboard/AutomaticCaptureReceipts", directoryHint: .isDirectory))
    }

    init(root: URL, now: @escaping () -> Date = Date.init, expiration: TimeInterval = 7 * 24 * 60 * 60, maximumRecords: Int = 128, failOperation: @escaping (String) -> Bool = { _ in false }) {
        self.root = root; self.now = now; self.expiration = expiration; self.maximumRecords = max(1, maximumRecords); self.failOperation = failOperation
    }

    func create(_ observation: AutomaticCaptureObservation) throws {
        guard !failOperation("create") else { throw AutomaticCaptureError.rejected("Automatic-capture receipt creation failed.") }
        try withLockedRoot(create: true) { directory, identity in
            try cleanupAndReserve(directory, identity: identity)
            try writeExclusive(try observation.canonicalJSON(), named: observationName(observation.receiptID), directory: directory, identity: identity)
        }
    }

    func loadObservation(_ id: String) throws -> AutomaticCaptureObservation {
        try withLockedRoot(create: false) { directory, identity in
            let data = try read(named: observationName(id), directory: directory, identity: identity)
            guard let observation = try? JSONDecoder().decode(AutomaticCaptureObservation.self, from: data), try observation.canonicalJSON() == data else { throw AutomaticCaptureError.rejected("The automatic-capture observation receipt is invalid or unavailable.") }
            return observation
        }
    }

    func claim(_ journal: AutomaticCaptureBatchJournal) throws {
        do {
            guard !failOperation("claim") else { throw AutomaticCaptureError.rejected("Injected receipt claim failure.") }
            try withLockedRoot(create: false) { directory, identity in
                try writeExclusive(try encode(journal), named: claimName(journal.receiptID), directory: directory, identity: identity)
            }
        }
        catch { throw AutomaticCaptureError.uncertain("The observation receipt is already claimed or could not be claimed durably; do not retry automatically.") }
    }

    func loadClaim(_ id: String) -> AutomaticCaptureBatchJournal? {
        try? withLockedRoot(create: false) { directory, identity in
            guard let data = try? read(named: claimName(id), directory: directory, identity: identity) else { return nil }
            return try? JSONDecoder().decode(AutomaticCaptureBatchJournal.self, from: data)
        }
    }

    func update(_ journal: AutomaticCaptureBatchJournal) throws {
        guard !failOperation("update") else { throw AutomaticCaptureError.uncertain("The automatic-capture journal could not be updated durably.") }
        try withLockedRoot(create: false) { directory, identity in
            let temporary = ".\(journal.receiptID).\(UUID().uuidString).tmp"
            try writeExclusive(try encode(journal), named: temporary, directory: directory, identity: identity)
            try validateRoot(directory, identity: identity)
            let result = temporary.withCString { temporaryPointer in claimName(journal.receiptID).withCString { claimPointer in renameat(directory, temporaryPointer, directory, claimPointer) } }
            guard result == 0, fsync(directory) == 0 else { throw AutomaticCaptureError.uncertain("The automatic-capture journal could not be updated durably.") }
            try validateRoot(directory, identity: identity)
        }
    }

    private func encode(_ journal: AutomaticCaptureBatchJournal) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(journal)
    }

    private struct DirectoryIdentity {
        let device: dev_t
        let inode: ino_t
    }

    private func openDirectory(create: Bool) throws -> (Int32, DirectoryIdentity) {
        guard root.path.hasPrefix("/"), root.path != "/" else { throw AutomaticCaptureError.rejected("Automatic-capture receipt storage requires a bounded absolute path.") }
        var directory = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw AutomaticCaptureError.rejected("Automatic-capture receipt storage is unavailable.") }
        do {
            var logicalPath = ""
            for component in root.path.split(separator: "/").map(String.init) {
                logicalPath += "/\(component)"
                var child = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                if child < 0, errno == ENOENT, create {
                    let made = component.withCString { mkdirat(directory, $0, 0o700) }
                    guard made == 0 || errno == EEXIST else { throw AutomaticCaptureError.rejected("Automatic-capture receipt storage could not be created safely.") }
                    child = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
                }
                // APFS firmlink components report ENOTDIR with O_NOFOLLOW. A fallback open is
                // accepted only when the descriptor retains the exact logical path and the
                // before/after no-follow namespace identities agree; ordinary symlinks fail it.
                if child < 0, errno == ENOTDIR {
                    var before = stat()
                    let inspected = component.withCString { fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW) }
                    let isDirectory = before.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR)
                    let isFirmlinkCandidate = before.st_mode & UInt16(S_IFMT) == UInt16(S_IFLNK)
                    guard inspected == 0, isDirectory || isFirmlinkCandidate else { throw AutomaticCaptureError.rejected("Automatic-capture receipt storage is unavailable or contains a symbolic link component.") }
                    child = component.withCString { openat(directory, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
                    var opened = stat(), after = stat()
                    guard child >= 0, fstat(child, &opened) == 0,
                          component.withCString({ fstatat(directory, $0, &after, AT_SYMLINK_NOFOLLOW) }) == 0,
                          opened.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR),
                          before.st_dev == after.st_dev, before.st_ino == after.st_ino,
                          (isFirmlinkCandidate && descriptorPath(child) == logicalPath) ||
                            (after.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) && before.st_dev == opened.st_dev && before.st_ino == opened.st_ino) else {
                        if child >= 0 { close(child) }
                        throw AutomaticCaptureError.rejected("Automatic-capture receipt storage component changed or was a symbolic link.")
                    }
                }
                guard child >= 0 else { throw AutomaticCaptureError.rejected("Automatic-capture receipt storage is unavailable or contains a symbolic link component.") }
                close(directory); directory = child
            }
            var state = stat()
            guard fstat(directory, &state) == 0, state.st_uid == geteuid(), state.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR), fchmod(directory, 0o700) == 0 else {
                throw AutomaticCaptureError.rejected("Automatic-capture receipt storage is not a safe owner directory.")
            }
            guard fstat(directory, &state) == 0, state.st_mode & 0o077 == 0 else { throw AutomaticCaptureError.rejected("Automatic-capture receipt storage is not owner-only.") }
            return (directory, .init(device: state.st_dev, inode: state.st_ino))
        } catch { close(directory); throw error }
    }

    private func descriptorPath(_ descriptor: Int32) -> String? {
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard fcntl(descriptor, F_GETPATH, &bytes) == 0 else { return nil }
        let prefix = bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: prefix, as: UTF8.self)
    }

    private func withLockedRoot<T>(create: Bool, _ operation: (Int32, DirectoryIdentity) throws -> T) throws -> T {
        let (directory, identity) = try openDirectory(create: create)
        defer { close(directory) }
        if failOperation("afterRootOpen") { throw AutomaticCaptureError.rejected("Automatic-capture receipt root changed during access.") }
        try validateRoot(directory, identity: identity)
        let lockName = ".receipt-root.lock"
        let lock = lockName.withCString { openat(directory, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard lock >= 0 else { throw AutomaticCaptureError.rejected("Automatic-capture receipt storage could not be locked.") }
        defer { close(lock) }
        var lockState = stat()
        guard fstat(lock, &lockState) == 0, lockState.st_uid == geteuid(), lockState.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), fchmod(lock, 0o600) == 0, flock(lock, LOCK_EX) == 0 else {
            throw AutomaticCaptureError.rejected("Automatic-capture receipt storage lock is unsafe.")
        }
        defer { _ = flock(lock, LOCK_UN) }
        try validateRoot(directory, identity: identity)
        let value = try operation(directory, identity)
        try validateRoot(directory, identity: identity)
        return value
    }

    private func validateRoot(_ directory: Int32, identity: DirectoryIdentity) throws {
        var retained = stat()
        guard fstat(directory, &retained) == 0, retained.st_dev == identity.device, retained.st_ino == identity.inode,
              retained.st_uid == geteuid(), retained.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR), retained.st_mode & 0o077 == 0 else {
            throw AutomaticCaptureError.rejected("Automatic-capture receipt root identity changed during mutation.")
        }
        let (reopened, reopenedIdentity) = try openDirectory(create: false)
        close(reopened)
        guard reopenedIdentity.device == identity.device, reopenedIdentity.inode == identity.inode else {
            throw AutomaticCaptureError.rejected("Automatic-capture receipt root namespace was replaced during mutation.")
        }
    }

    private func writeExclusive(_ data: Data, named name: String, directory: Int32, identity: DirectoryIdentity) throws {
        guard validName(name) else { throw AutomaticCaptureError.rejected("Invalid automatic-capture receipt identifier.") }
        guard data.count <= 8 * 1024 * 1024 else { throw AutomaticCaptureError.rejected("Automatic-capture receipt is oversized.") }
        let descriptor = name.withCString { openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else { throw AutomaticCaptureError.rejected("Automatic-capture receipt already exists or is unavailable.") }
        var complete = false
        defer { close(descriptor); if !complete, (try? validateRoot(directory, identity: identity)) != nil { name.withCString { _ = unlinkat(directory, $0, 0) } } }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw AutomaticCaptureError.rejected("Automatic-capture receipt could not be written.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, fsync(directory) == 0 else { throw AutomaticCaptureError.rejected("Automatic-capture receipt could not be persisted.") }
        try validateRoot(directory, identity: identity)
        complete = true
    }

    private func read(named name: String, directory: Int32, identity: DirectoryIdentity) throws -> Data {
        try validateRoot(directory, identity: identity)
        guard validName(name) else { throw AutomaticCaptureError.rejected("Invalid automatic-capture receipt identifier.") }
        let descriptor = name.withCString { openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw AutomaticCaptureError.rejected("The automatic-capture observation receipt is invalid or unavailable.") }
        defer { close(descriptor) }
        var state = stat()
        guard fstat(descriptor, &state) == 0, state.st_uid == geteuid(), state.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG), state.st_mode & 0o077 == 0, state.st_size <= 8 * 1024 * 1024 else { throw AutomaticCaptureError.rejected("The automatic-capture receipt is unsafe or oversized.") }
        var data = Data(count: Int(state.st_size))
        var offset = 0
        try data.withUnsafeMutableBytes { buffer in
            while offset < buffer.count {
                let count = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard count > 0 else { throw AutomaticCaptureError.rejected("The automatic-capture receipt could not be read completely.") }
                offset += count
            }
        }
        try validateRoot(directory, identity: identity)
        return data
    }

    private func cleanupAndReserve(_ directory: Int32, identity: DirectoryIdentity) throws {
        try validateRoot(directory, identity: identity)
        let names = try descriptorNames(directory)
        if failOperation("afterEnumeration") { throw AutomaticCaptureError.rejected("Automatic-capture receipt namespace changed during enumeration.") }
        try validateRoot(directory, identity: identity)
        let candidates = names.filter { $0.hasSuffix(".observation.json") || $0.hasSuffix(".claim.json") || $0.hasSuffix(".tmp") }
        var records: [(String, Date)] = []
        for name in candidates where validName(name) {
            var state = stat()
            guard name.withCString({ fstatat(directory, $0, &state, AT_SYMLINK_NOFOLLOW) }) == 0,
                  state.st_uid == geteuid(), state.st_mode & UInt16(S_IFMT) == UInt16(S_IFREG) else { continue }
            if name.hasSuffix(".tmp") {
                guard name.withCString({ unlinkat(directory, $0, 0) }) == 0 else { throw AutomaticCaptureError.rejected("An abandoned automatic-capture temporary record could not be cleaned safely.") }
            } else {
                guard state.st_mode & 0o077 == 0 else { continue }
                records.append((name, Date(timeIntervalSince1970: TimeInterval(state.st_mtimespec.tv_sec))))
            }
        }
        let ordered = records.sorted { $0.1 < $1.1 }
        var retained = ordered
        for record in ordered where now().timeIntervalSince(record.1) > expiration {
            guard record.0.withCString({ unlinkat(directory, $0, 0) }) == 0 else { throw AutomaticCaptureError.rejected("An expired automatic-capture record could not be removed safely.") }
            retained.removeAll { $0.0 == record.0 }
        }
        while retained.filter({ $0.0.hasSuffix(".observation.json") }).count >= maximumRecords,
              let observation = retained.first(where: { candidate in
                  candidate.0.hasSuffix(".observation.json") && !retained.contains(where: { $0.0 == claimName(forObservationName: candidate.0) })
              }) {
            guard observation.0.withCString({ unlinkat(directory, $0, 0) }) == 0 else { throw AutomaticCaptureError.rejected("An old automatic-capture observation could not be evicted safely.") }
            retained.removeAll { $0.0 == observation.0 }
        }
        guard retained.filter({ $0.0.hasSuffix(".observation.json") }).count < maximumRecords else { throw AutomaticCaptureError.rejected("Automatic-capture receipt storage is full of active claims requiring recovery.") }
        guard fsync(directory) == 0 else { throw AutomaticCaptureError.rejected("Automatic-capture receipt cleanup could not be persisted.") }
        try validateRoot(directory, identity: identity)
    }

    private func descriptorNames(_ directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else { if duplicate >= 0 { close(duplicate) }; throw AutomaticCaptureError.rejected("Automatic-capture receipt storage could not be enumerated.") }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    private func claimName(forObservationName name: String) -> String {
        String(name.dropLast(".observation.json".count)) + ".claim.json"
    }

    private func observationName(_ id: String) -> String { "\(id).observation.json" }
    private func claimName(_ id: String) -> String { "\(id).claim.json" }
    private func validName(_ name: String) -> Bool { !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") }
}

struct AutomaticCaptureContext {
    static let preferencesSuiteName = "com.kahntra.operations-dashboard"
    static let preferencesSourceKey = "operations-dashboard.capture.automatic-source"
    let configuredSource: () -> String?
    let receipts: AutomaticCaptureReceiptStore
    let runtime: AutomaticCaptureRuntime
    let manager: FileManager

    static var live: AutomaticCaptureContext {
        let preferences = UserDefaults(suiteName: preferencesSuiteName)
        return .init(configuredSource: { preferences?.string(forKey: preferencesSourceKey) }, receipts: .live(), runtime: .live, manager: .default)
    }
}

private struct AutomaticCaptureNamespace {
    let rootURL: URL
    let sourceURL: URL
    let officeURL: URL
    let inboxURL: URL
    let rootFD: Int32
    let sourceFD: Int32
    let officeFD: Int32
    let inboxFD: Int32
    let rootState: AutomaticCaptureItemState
    let sourceState: AutomaticCaptureItemState
    let officeState: AutomaticCaptureItemState
    let inboxState: AutomaticCaptureItemState
    func closeAll() { close(inboxFD); close(officeFD); close(sourceFD); close(rootFD) }
}

extension ProductionsInboxCaptureService {
    func recordAutomaticObservation(productionsRoot: URL) throws -> AutomaticCaptureObservation {
        let context = automaticCaptureContext
        let namespace = try automaticNamespace(productionsRoot: productionsRoot, context: context)
        defer { namespace.closeAll() }
        let observation = AutomaticCaptureObservation(
            schema: AutomaticCaptureObservation.schemaVersion,
            actionDiscriminator: AutomaticCaptureObservation.action,
            receiptID: UUID().uuidString,
            bootSessionID: context.runtime.bootSessionID(),
            continuousNanoseconds: context.runtime.continuousNanoseconds(),
            observedAt: ISO8601DateFormatter().string(from: context.runtime.now()),
            productionsRoot: namespace.rootURL.path,
            sourcePath: namespace.sourceURL.path,
            officePath: namespace.officeURL.path,
            inboxPath: namespace.inboxURL.path,
            rootState: namespace.rootState,
            sourceState: namespace.sourceState,
            officeState: namespace.officeState,
            inboxState: namespace.inboxState,
            items: try automaticItems(namespace: namespace, context: context)
        )
        try context.receipts.create(observation)
        return observation
    }

    func previewAutomaticMove(productionsRoot: URL, observation: AutomaticCaptureObservation) throws -> AutomaticCaptureMovePreview {
        let context = automaticCaptureContext
        guard observation.schema == AutomaticCaptureObservation.schemaVersion, observation.actionDiscriminator == AutomaticCaptureObservation.action else { throw AutomaticCaptureError.confirmationRequired }
        guard context.receipts.loadClaim(observation.receiptID) == nil else { throw AutomaticCaptureError.uncertain("This observation receipt is already claimed; do not retry automatically.") }
        let stored = try context.receipts.loadObservation(observation.receiptID)
        guard stored == observation, observation.bootSessionID == context.runtime.bootSessionID() else { throw AutomaticCaptureError.rejected("The observation receipt is stale, forged, or belongs to another boot session. Observe again.") }
        let now = context.runtime.continuousNanoseconds()
        guard now >= observation.continuousNanoseconds, now - observation.continuousNanoseconds >= 2_000_000_000 else { throw AutomaticCaptureError.rejected("A second matching observation must occur at least two seconds after the first.") }
        let namespace = try automaticNamespace(productionsRoot: productionsRoot, context: context)
        defer { namespace.closeAll() }
        guard observation.productionsRoot == namespace.rootURL.path, observation.sourcePath == namespace.sourceURL.path,
              observation.officePath == namespace.officeURL.path, observation.inboxPath == namespace.inboxURL.path,
              observation.rootState.hasSameIdentity(as: namespace.rootState), observation.sourceState.hasSameIdentity(as: namespace.sourceState),
              observation.officeState.hasSameIdentity(as: namespace.officeState), observation.inboxState.hasSameIdentity(as: namespace.inboxState) else { throw AutomaticCaptureError.confirmationRequired }
        let current = try automaticItems(namespace: namespace, context: context)
        let prior = Dictionary(uniqueKeysWithValues: observation.items.map { ($0.basename, $0) })
        var stopped = false
        let plans = try current.map { item -> AutomaticCaptureMoveItem in
            let sourcePath = namespace.sourceURL.appending(path: item.basename).path
            let destinationPath = namespace.inboxURL.appending(path: item.basename).path
            if stopped { return .init(basename: item.basename, sourcePath: sourcePath, destinationPath: destinationPath, state: item.state, disposition: .notAttempted, diagnostic: "Not attempted because an earlier collision stops automatic capture.") }
            guard item.eligible else { return .init(basename: item.basename, sourcePath: sourcePath, destinationPath: destinationPath, state: item.state, disposition: .ineligible, diagnostic: item.diagnostic) }
            guard let previous = prior[item.basename], previous.eligible, previous.state == item.state else {
                return .init(basename: item.basename, sourcePath: sourcePath, destinationPath: destinationPath, state: item.state, disposition: .deferred, diagnostic: "\(item.basename) must remain unchanged for two matching observations at least two seconds apart.")
            }
            guard context.runtime.sameFileSystem(item.state, namespace.inboxState) else {
                return .init(basename: item.basename, sourcePath: sourcePath, destinationPath: destinationPath, state: item.state, disposition: .ineligible, diagnostic: "\(item.basename) is on a different filesystem; headless automatic capture is same-filesystem only.")
            }
            if try automaticEntryState(parent: namespace.inboxFD, name: item.basename) != nil {
                stopped = true
                return .init(basename: item.basename, sourcePath: sourcePath, destinationPath: destinationPath, state: item.state, disposition: .collision, diagnostic: "Office/Inbox already contains an item named \(item.basename).")
            }
            return .init(basename: item.basename, sourcePath: sourcePath, destinationPath: destinationPath, state: item.state, disposition: .planned, diagnostic: "Stable and eligible for an exclusive same-filesystem move.")
        }
        return .init(schema: AutomaticCaptureMovePreview.schemaVersion, actionDiscriminator: AutomaticCaptureMovePreview.action, observation: observation, productionsRoot: namespace.rootURL.path, sourcePath: namespace.sourceURL.path, officePath: namespace.officeURL.path, inboxPath: namespace.inboxURL.path, rootState: namespace.rootState, sourceState: namespace.sourceState, officeState: namespace.officeState, inboxState: namespace.inboxState, items: plans)
    }

    func commitAutomaticMove(productionsRoot: URL, confirmedPreview: AutomaticCaptureMovePreview) throws -> AutomaticCaptureCommitOutcome {
        let context = automaticCaptureContext
        if let existing = context.receipts.loadClaim(confirmedPreview.observation.receiptID) {
            return .uncertain(report(existing, diagnostic: "This automatic-capture receipt was already claimed; manual recovery is required."))
        }
        let currentPreview = try previewAutomaticMove(productionsRoot: productionsRoot, observation: confirmedPreview.observation)
        guard currentPreview == confirmedPreview else { throw AutomaticCaptureError.confirmationRequired }
        let namespace = try automaticNamespace(productionsRoot: productionsRoot, context: context)
        defer { namespace.closeAll() }
        guard confirmedPreview.productionsRoot == namespace.rootURL.path,
              confirmedPreview.sourcePath == namespace.sourceURL.path,
              confirmedPreview.officePath == namespace.officeURL.path,
              confirmedPreview.inboxPath == namespace.inboxURL.path,
              confirmedPreview.rootState == namespace.rootState,
              confirmedPreview.sourceState == namespace.sourceState,
              confirmedPreview.officeState == namespace.officeState,
              confirmedPreview.inboxState == namespace.inboxState else { throw AutomaticCaptureError.confirmationRequired }
        for plan in confirmedPreview.items where plan.disposition == .planned {
            guard try automaticEntryState(parent: namespace.sourceFD, name: plan.basename, runtime: context.runtime) == plan.state,
                  try automaticEntryState(parent: namespace.inboxFD, name: plan.basename, runtime: context.runtime) == nil else { throw AutomaticCaptureError.confirmationRequired }
        }
        guard try automaticRetainedNamespaceMatches(namespace, productionsRoot: productionsRoot, context: context) else { throw AutomaticCaptureError.confirmationRequired }
        var journal = AutomaticCaptureBatchJournal(receiptID: confirmedPreview.observation.receiptID, preview: confirmedPreview, state: .claimed, items: confirmedPreview.items.map { .init(basename: $0.basename, state: $0.disposition == .planned ? .pending : .notAttempted, diagnostic: $0.diagnostic) }, diagnostic: "Receipt claimed before the first rename.", updatedAt: ISO8601DateFormatter().string(from: context.runtime.now()))
        try context.receipts.claim(journal)
        var published = false
        var activeIndex: Int?
        do {
            for index in confirmedPreview.items.indices where confirmedPreview.items[index].disposition == .planned {
                activeIndex = index
                let plan = confirmedPreview.items[index]
                guard try automaticRetainedNamespaceMatches(namespace, productionsRoot: productionsRoot, context: context),
                      try automaticEntryState(parent: namespace.sourceFD, name: plan.basename, runtime: context.runtime) == plan.state,
                      try automaticEntryState(parent: namespace.inboxFD, name: plan.basename, runtime: context.runtime) == nil else {
                    journal.state = published ? .partial : .definiteFailure
                    journal.items[index].state = .failed
                    journal.items[index].diagnostic = "The source or destination changed after confirmation."
                    automaticStopRemaining(&journal, after: index)
                    journal.diagnostic = published ? "The batch partially committed; manual recovery is required." : "No item was moved; observe and preview again."
                    try context.receipts.update(journal)
                    let value = report(journal, diagnostic: journal.diagnostic)
                    return published ? .uncertain(value) : .definiteFailure(value)
                }
                journal.state = .executing; journal.items[index].state = .renaming; journal.items[index].diagnostic = "Exclusive rename in progress; a crash from this state is uncertain."
                journal.updatedAt = ISO8601DateFormatter().string(from: context.runtime.now())
                try context.receipts.update(journal)
                let moveError = context.runtime.renameExclusive(namespace.sourceFD, plan.basename, namespace.inboxFD, plan.basename)
                if moveError != 0 {
                    let sourceUnchanged = (try? automaticEntryState(parent: namespace.sourceFD, name: plan.basename, runtime: context.runtime)) == plan.state
                    let destinationAbsent = (try? automaticEntryState(parent: namespace.inboxFD, name: plan.basename, runtime: context.runtime)) == nil
                    journal.items[index].state = .failed
                    journal.items[index].diagnostic = "Exclusive automatic move failed (errno \(moveError))."
                    automaticStopRemaining(&journal, after: index)
                    if sourceUnchanged && destinationAbsent {
                        journal.state = published ? .partial : .definiteFailure
                        journal.diagnostic = published ? "The batch partially committed; manual recovery is required." : "Automatic capture failed before any item was moved."
                    } else {
                        journal.state = .uncertain
                        journal.diagnostic = "The move outcome is uncertain; manual recovery is required."
                    }
                    try context.receipts.update(journal)
                    let value = report(journal, diagnostic: journal.diagnostic)
                    return journal.state == .definiteFailure ? .definiteFailure(value) : .uncertain(value)
                }

                // This is the permanent publication boundary. Nothing below this point may throw out of this scope.
                published = true
                journal.items[index].state = .publishedUnverified; journal.items[index].diagnostic = "Rename published; verification pending."
                try context.receipts.update(journal)
                guard try automaticRetainedNamespaceMatches(namespace, productionsRoot: productionsRoot, context: context) else {
                    throw AutomaticCaptureError.uncertain("A retained automatic-capture namespace was replaced after publication.")
                }
                let destination = try automaticEntryState(parent: namespace.inboxFD, name: plan.basename, runtime: context.runtime)
                let source = try automaticEntryState(parent: namespace.sourceFD, name: plan.basename, runtime: context.runtime)
                guard destination == plan.state, source == nil else {
                    throw AutomaticCaptureError.uncertain("Post-move namespace verification failed.")
                }
                journal.items[index].state = .captured; journal.items[index].diagnostic = "Moved to Office/Inbox and verified by complete identity."
                try context.receipts.update(journal)
            }
            activeIndex = nil
            journal.state = .completed; journal.diagnostic = "Automatic capture completed."
            journal.updatedAt = ISO8601DateFormatter().string(from: context.runtime.now())
            try context.receipts.update(journal)
            return .completed(report(journal, diagnostic: journal.diagnostic))
        } catch {
            let failureDetail = error.localizedDescription
            if let index = activeIndex {
                if journal.items[index].state != .captured { journal.items[index].state = .failed }
                journal.items[index].diagnostic = failureDetail
                automaticStopRemaining(&journal, after: index)
            }
            journal.state = published ? .uncertain : .definiteFailure
            journal.diagnostic = published ? "\(failureDetail) The batch is partially committed or its final state is uncertain; manual recovery is required." : "\(failureDetail) No item was published; observe and preview again."
            journal.updatedAt = ISO8601DateFormatter().string(from: context.runtime.now())
            try? context.receipts.update(journal)
            let value = report(journal, diagnostic: journal.diagnostic)
            return published ? .uncertain(value) : .definiteFailure(value)
        }
    }

    private func report(_ journal: AutomaticCaptureBatchJournal, diagnostic: String) -> AutomaticCaptureCommitReport {
        .init(receiptID: journal.receiptID, state: journal.state.rawValue, items: journal.items, diagnostic: diagnostic)
    }

    private func automaticStopRemaining(_ journal: inout AutomaticCaptureBatchJournal, after index: Int) {
        guard index + 1 < journal.items.count else { return }
        for remaining in (index + 1)..<journal.items.count where journal.items[remaining].state == .pending {
            journal.items[remaining].state = .notAttempted
            journal.items[remaining].diagnostic = "Not attempted because an earlier move stopped the batch."
        }
    }

    private func automaticRetainedNamespaceMatches(_ retained: AutomaticCaptureNamespace, productionsRoot: URL, context: AutomaticCaptureContext) throws -> Bool {
        try context.runtime.beforeNamespaceRevalidation()
        let reopened = try automaticNamespace(productionsRoot: productionsRoot, context: context)
        defer { reopened.closeAll() }
        return reopened.rootURL.path == retained.rootURL.path && reopened.sourceURL.path == retained.sourceURL.path &&
            reopened.officeURL.path == retained.officeURL.path && reopened.inboxURL.path == retained.inboxURL.path &&
            reopened.rootState.hasSameIdentity(as: retained.rootState) && reopened.sourceState.hasSameIdentity(as: retained.sourceState) &&
            reopened.officeState.hasSameIdentity(as: retained.officeState) && reopened.inboxState.hasSameIdentity(as: retained.inboxState)
    }

    private func automaticNamespace(productionsRoot: URL, context: AutomaticCaptureContext) throws -> AutomaticCaptureNamespace {
        guard let configured = context.configuredSource(), !configured.isEmpty else { throw AutomaticCaptureError.rejected("No automatic capture source is configured in the Operations Dashboard preferences suite.") }
        var configuredState = stat()
        guard lstat(configured, &configuredState) == 0, configuredState.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else {
            throw AutomaticCaptureError.rejected("Configured automatic source is unavailable or symbolic.")
        }
        let rootURL = try automaticCanonicalURL(productionsRoot)
        let sourceURL = try automaticCanonicalURL(URL(fileURLWithPath: configured, isDirectory: true))
        let officeURL = rootURL.appending(path: "Office", directoryHint: .isDirectory)
        let inboxURL = officeURL.appending(path: "Inbox", directoryHint: .isDirectory)
        for protected in [rootURL, officeURL, inboxURL] where automaticPathsOverlap(sourceURL.path, protected.path) {
            throw AutomaticCaptureError.rejected("The configured automatic source must not equal, contain, or be contained by Productions, Office, or Office/Inbox.")
        }
        let rootFD = open(rootURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard rootFD >= 0 else { throw AutomaticCaptureError.rejected("Productions root is unavailable or contains a symbolic-link component.") }
        let officeFD = "Office".withCString { openat(rootFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard officeFD >= 0 else { close(rootFD); throw AutomaticCaptureError.rejected("The canonical Office directory is unavailable.") }
        let inboxFD = "Inbox".withCString { openat(officeFD, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard inboxFD >= 0 else { close(officeFD); close(rootFD); throw AutomaticCaptureError.rejected("Office/Inbox is unavailable.") }
        let sourceFD = open(sourceURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard sourceFD >= 0 else { close(inboxFD); close(officeFD); close(rootFD); throw AutomaticCaptureError.rejected("Configured automatic source is unavailable or contains a symbolic-link component.") }
        do {
            return .init(rootURL: rootURL, sourceURL: sourceURL, officeURL: officeURL, inboxURL: inboxURL, rootFD: rootFD, sourceFD: sourceFD, officeFD: officeFD, inboxFD: inboxFD, rootState: try automaticState(rootFD), sourceState: try automaticState(sourceFD), officeState: try automaticState(officeFD), inboxState: try automaticState(inboxFD))
        } catch { close(sourceFD); close(inboxFD); close(officeFD); close(rootFD); throw error }
    }

    private func automaticItems(namespace: AutomaticCaptureNamespace, context: AutomaticCaptureContext) throws -> [AutomaticCaptureObservationItem] {
        let entries = try context.manager.contentsOfDirectory(at: namespace.sourceURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted { $0.path < $1.path }
        return try entries.map { item in
            guard !item.lastPathComponent.contains("/") else { throw AutomaticCaptureError.rejected("Automatic source contains an invalid immediate-child name.") }
            var value = stat()
            guard item.lastPathComponent.withCString({ fstatat(namespace.sourceFD, $0, &value, AT_SYMLINK_NOFOLLOW) }) == 0 else { throw AutomaticCaptureError.rejected("Cannot inspect automatic source item \(item.lastPathComponent).") }
            let state = automaticState(value)
            let readable = context.manager.isReadableFile(atPath: item.path)
            let eligible = readable && (state.isRegularFile || state.isDirectory)
            let diagnostic = eligible ? "Eligible opaque immediate item." : "\(item.lastPathComponent) is symbolic, unreadable, or unsupported."
            return .init(basename: item.lastPathComponent, state: state, eligible: eligible, diagnostic: diagnostic)
        }
    }

    private func automaticEntryState(parent: Int32, name: String, runtime: AutomaticCaptureRuntime? = nil) throws -> AutomaticCaptureItemState? {
        try runtime?.beforeEntryInspection(name)
        var value = stat()
        let result = name.withCString { fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }
        if result != 0 { if errno == ENOENT { return nil }; throw AutomaticCaptureError.rejected("Automatic-capture namespace could not be inspected.") }
        return automaticState(value)
    }

    private func automaticState(_ descriptor: Int32) throws -> AutomaticCaptureItemState {
        var value = stat(); guard fstat(descriptor, &value) == 0 else { throw AutomaticCaptureError.rejected("Automatic-capture filesystem identity is unavailable.") }
        return automaticState(value)
    }

    private func automaticState(_ value: stat) -> AutomaticCaptureItemState {
        .init(filesystemKind: UInt32(value.st_mode) & UInt32(S_IFMT), device: UInt64(value.st_dev), inode: UInt64(value.st_ino), byteSize: Int64(value.st_size), modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }

    private func automaticCanonicalURL(_ url: URL) throws -> URL {
        guard let pointer = realpath(url.path, nil) else { throw AutomaticCaptureError.rejected("Automatic-capture path is unavailable.") }
        defer { free(pointer) }
        return URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
    }

    private func automaticPathsOverlap(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }
}

private struct AutomaticObservationOutput: Codable { let observation: AutomaticCaptureObservation; let observationEnvelope: String; let observationToken: String }
private struct AutomaticPreviewOutput: Codable { let preview: AutomaticCaptureMovePreview; let confirmedPreview: String; let confirmationToken: String }

struct HeadlessCaptureAutomaticAdapter {
    let makeService: () -> ProductionsInboxCaptureService
    init(makeService: @escaping () -> ProductionsInboxCaptureService = { ProductionsInboxCaptureService() }) { self.makeService = makeService }
    func observe(root: URL) throws -> AutomaticCaptureObservation { try makeService().recordAutomaticObservation(productionsRoot: root) }
    func preview(root: URL, envelope: String, token: String) throws -> AutomaticCaptureMovePreview {
        try makeService().previewAutomaticMove(productionsRoot: root, observation: AutomaticCaptureObservation.decodeEnvelope(envelope, token: token))
    }
    func execute(root: URL, envelope: String, token: String) throws -> AutomaticCaptureCommitOutcome {
        try makeService().commitAutomaticMove(productionsRoot: root, confirmedPreview: AutomaticCaptureMovePreview.decodeEnvelope(envelope, token: token))
    }
}

enum HeadlessCaptureAutomaticCommandLine {
    static let usage = "Usage: OperationsDashboard capture automatic observe --productions-root <path>\n       OperationsDashboard capture automatic preview --productions-root <path> --observation <base64> --observe-token <token>\n       OperationsDashboard capture automatic execute --productions-root <path> --confirmed-preview <base64> --confirm <token>"

    static func runIfRequested(arguments: [String] = CommandLine.arguments, adapter: HeadlessCaptureAutomaticAdapter = .init(), write: (String) -> Void = { print($0) }) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard values.first == "capture", values.dropFirst().first == "automatic" else { return nil }
        do {
            let parsed = try parse(values)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            switch parsed.action {
            case "observe":
                let observation = try adapter.observe(root: parsed.root)
                write(String(decoding: try encoder.encode(AutomaticObservationOutput(observation: observation, observationEnvelope: try observation.canonicalEnvelope(), observationToken: try observation.observationToken())), as: UTF8.self))
            case "preview":
                let preview = try adapter.preview(root: parsed.root, envelope: parsed.options["--observation"]!, token: parsed.options["--observe-token"]!)
                write(String(decoding: try encoder.encode(AutomaticPreviewOutput(preview: preview, confirmedPreview: try preview.canonicalEnvelope(), confirmationToken: try preview.confirmationToken())), as: UTF8.self))
            default:
                let outcome = try adapter.execute(root: parsed.root, envelope: parsed.options["--confirmed-preview"]!, token: parsed.options["--confirm"]!)
                switch outcome {
                case let .completed(report): write(String(decoding: try encoder.encode(report), as: UTF8.self)); return 0
                case let .definiteFailure(report): write(String(decoding: try encoder.encode(report), as: UTF8.self)); return 2
                case let .uncertain(report): write("Automatic capture committed, partially committed, or is uncertain; do not retry automatically. " + String(decoding: try encoder.encode(report), as: UTF8.self)); return 3
                }
            }
            return 0
        } catch let error as AutomaticCaptureError {
            if case let .uncertain(message) = error { write(message); return 3 }
            write(error.localizedDescription); return 2
        } catch { write(error.localizedDescription); return 2 }
    }

    private static func parse(_ values: [String]) throws -> (action: String, root: URL, options: [String: String]) {
        guard values.count >= 3, ["observe", "preview", "execute"].contains(values[2]) else { throw AutomaticCaptureError.rejected(usage) }
        let action = values[2]
        let allowed: Set<String> = action == "observe" ? ["--productions-root"] : action == "preview" ? ["--productions-root", "--observation", "--observe-token"] : ["--productions-root", "--confirmed-preview", "--confirm"]
        var options: [String: String] = [:]; var index = 3
        while index < values.count {
            let key = values[index]
            guard allowed.contains(key), index + 1 < values.count, options[key] == nil else { throw AutomaticCaptureError.rejected(usage) }
            options[key] = values[index + 1]; index += 2
        }
        guard let root = options["--productions-root"], !root.isEmpty, options.count == allowed.count else { throw AutomaticCaptureError.rejected(usage) }
        return (action, URL(fileURLWithPath: root, isDirectory: true), options)
    }
}
