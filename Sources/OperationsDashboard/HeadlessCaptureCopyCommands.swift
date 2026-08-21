import CryptoKit
import Darwin
import Foundation

/// Phase 3D headless capture deliberately supports regular files only. It
/// does not provide file/folder/package parity; directory and package capture
/// remain on the existing GUI path.
struct CaptureFileCloneRuntime {
    let supportsClone: (URL) -> Bool
    let sameFileSystem: (CaptureCopyFileState, CaptureCopyFileState) -> Bool
    let clone: (Int32, Int32, String) -> Int32
    let beforePublication: () -> Void
    let afterDestinationOpen: (Int32) -> Void
    let afterPublication: () -> Void

    static var live: Self {
        CaptureFileCloneRuntime(
            supportsClone: CaptureFileCloneTransaction.volumeSupportsClone,
            sameFileSystem: { $0.device == $1.device },
            clone: { sourceFD, inboxFD, name in
                let result = name.withCString {
                    fclonefileat(sourceFD, inboxFD, $0, UInt32(CLONE_ACL | CLONE_NOFOLLOW_ANY | CLONE_RESOLVE_BENEATH))
                }
                return result == 0 ? 0 : errno
            },
            beforePublication: {},
            afterDestinationOpen: { _ in },
            afterPublication: {}
        )
    }
}

struct CaptureCopyFileState: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let linkCount: UInt64
    let userID: UInt32
    let groupID: UInt32
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    var isRegularFile: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFREG) }
    var isDirectory: Bool { mode & UInt32(S_IFMT) == UInt32(S_IFDIR) }
    func hasSameIdentity(as other: Self) -> Bool { device == other.device && inode == other.inode && mode == other.mode }
}

struct CaptureCopyPreview: Codable, Equatable {
    static let schemaVersion = 2
    static let action = "capture-copy"
    let schema: Int
    let actionDiscriminator: String
    let supportPolicy: String
    let productionsRoot: String
    let productionsRootResolvedPath: String
    let officePath: String
    let inboxPath: String
    let sourcePath: String
    let sourceResolvedPath: String
    let sourceBasename: String
    let destinationPath: String
    let sourceSHA256: String
    let productionsSHA256: String
    let inboxSHA256: String
    let postPublicationProductionsBaselineSHA256: String
    let postPublicationInboxBaselineSHA256: String
    let rootState: CaptureCopyFileState
    let officeState: CaptureCopyFileState
    let inboxState: CaptureCopyFileState
    let sourceParentState: CaptureCopyFileState
    let sourceState: CaptureCopyFileState
    let destinationAbsent: Bool
}

enum CaptureCopyError: LocalizedError, Equatable {
    case confirmationRequired
    case rejected(String)
    case sourceChanged
    case sourceKindChanged
    case inboxChanged
    case productionsChanged
    case destinationChanged
    case collision(String)
    case cloneFailed(String)
    case uncertain(String)

    var errorDescription: String? {
        switch self {
        case .confirmationRequired: return "The command does not match its confirmed capture-copy preview. Re-run capture copy preview."
        case let .rejected(message), let .cloneFailed(message), let .uncertain(message): return message
        case .sourceChanged: return "The capture source changed after preview. Re-run capture copy preview."
        case .sourceKindChanged: return "The capture source is no longer a supported regular file. Phase 3D headless copy does not support directories or packages."
        case .inboxChanged: return "Office/Inbox changed after preview. Re-run capture copy preview."
        case .productionsChanged: return "The Productions state changed after preview. Re-run capture copy preview."
        case .destinationChanged: return "The capture destination state changed after preview. Re-run capture copy preview."
        case let .collision(name): return "Office/Inbox already contains an item named \(name)."
        }
    }
}

private struct CanonicalFrameEncoder {
    private(set) var data = Data()
    mutating func append(_ fields: [Data]) {
        appendLength(fields.count)
        for field in fields { appendLength(field.count); data.append(field) }
    }
    mutating func append(_ fields: [String]) { append(fields.map { Data($0.utf8) }) }
    private mutating func appendLength(_ value: Int) {
        var encoded = UInt64(value).bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }
}

private struct CaptureFileCloneDescriptors {
    let root: Int32
    let office: Int32
    let inbox: Int32
    let sourceParent: Int32
    let source: Int32
    func closeAll() {
        close(source); close(sourceParent); close(inbox); close(office); close(root)
    }
}

private struct CaptureFileCloneTransaction {
    let runtime: CaptureFileCloneRuntime

    func preview(source: URL, root: URL) throws -> CaptureCopyPreview {
        try validateSourcePathHasNoSymlinkComponents(source)
        let normalizedRoot = root.standardizedFileURL
        let normalizedSource = source.standardizedFileURL
        try validateBasename(normalizedSource.lastPathComponent)
        try validateProductionsLoader(root: normalizedRoot)
        let descriptors = try openDescriptors(source: normalizedSource, root: normalizedRoot)
        defer { descriptors.closeAll() }
        let states = try states(for: descriptors)
        guard states.source.isRegularFile else { throw unsupportedKind(state: states.source) }
        guard runtime.sameFileSystem(states.source, states.inbox) else {
            throw CaptureCopyError.rejected("Headless capture copy requires the source and Office/Inbox to be on the same filesystem.")
        }
        guard runtime.supportsClone(URL(fileURLWithPath: resolvedPath(normalizedRoot.appending(path: "Office/Inbox", directoryHint: .isDirectory)), isDirectory: true)) else {
            throw CaptureCopyError.rejected("Office/Inbox is on a filesystem that does not support atomic file cloning; no mutation was attempted.")
        }
        guard !sameDirectory(descriptors.sourceParent, descriptors.inbox) else {
            throw CaptureCopyError.rejected("A file already inside Office/Inbox cannot be captured again.")
        }
        let destinationAbsent = try entryState(parent: descriptors.inbox, name: normalizedSource.lastPathComponent) == nil
        let sourceHash = try stableFileHash(descriptors.source, confirmed: states.source)
        let inboxHash = try treeHash(descriptors.inbox)
        let productionsHash = try treeHash(descriptors.root)
        let postPublicationInboxBaseline = try treeHash(descriptors.inbox, includeTimestamps: false)
        let postPublicationProductionsBaseline = try treeHash(descriptors.root, includeTimestamps: false)
        let office = normalizedRoot.appending(path: "Office", directoryHint: .isDirectory)
        let inbox = office.appending(path: "Inbox", directoryHint: .isDirectory)
        return .init(
            schema: CaptureCopyPreview.schemaVersion,
            actionDiscriminator: CaptureCopyPreview.action,
            supportPolicy: "regular files only; same clone-capable filesystem; directories and packages remain GUI-only",
            productionsRoot: normalizedRoot.path,
            productionsRootResolvedPath: resolvedPath(normalizedRoot),
            officePath: office.path,
            inboxPath: inbox.path,
            sourcePath: normalizedSource.path,
            sourceResolvedPath: resolvedPath(normalizedSource),
            sourceBasename: normalizedSource.lastPathComponent,
            destinationPath: inbox.appending(path: normalizedSource.lastPathComponent, directoryHint: .notDirectory).path,
            sourceSHA256: sourceHash,
            productionsSHA256: productionsHash,
            inboxSHA256: inboxHash,
            postPublicationProductionsBaselineSHA256: postPublicationProductionsBaseline,
            postPublicationInboxBaselineSHA256: postPublicationInboxBaseline,
            rootState: states.root,
            officeState: states.office,
            inboxState: states.inbox,
            sourceParentState: states.sourceParent,
            sourceState: states.source,
            destinationAbsent: destinationAbsent
        )
    }

    func commit(source: URL, root: URL, confirmed: CaptureCopyPreview) throws -> URL {
        try validateSourcePathHasNoSymlinkComponents(source)
        let normalizedRoot = root.standardizedFileURL
        let normalizedSource = source.standardizedFileURL
        let inboxURL = normalizedRoot.appending(path: "Office/Inbox", directoryHint: .isDirectory)
        let destination = inboxURL.appending(path: normalizedSource.lastPathComponent, directoryHint: .notDirectory)
        guard confirmed.schema == CaptureCopyPreview.schemaVersion,
              confirmed.actionDiscriminator == CaptureCopyPreview.action,
              confirmed.productionsRoot == normalizedRoot.path,
              confirmed.productionsRootResolvedPath == resolvedPath(normalizedRoot),
              confirmed.officePath == normalizedRoot.appending(path: "Office", directoryHint: .isDirectory).path,
              confirmed.inboxPath == inboxURL.path,
              confirmed.sourcePath == normalizedSource.path,
              confirmed.sourceBasename == normalizedSource.lastPathComponent,
              confirmed.destinationPath == destination.path else { throw CaptureCopyError.confirmationRequired }
        try validateProductionsLoader(root: normalizedRoot)
        let descriptors = try openDescriptors(source: normalizedSource, root: normalizedRoot)
        defer { descriptors.closeAll() }
        try validateBeforePublication(descriptors, source: normalizedSource, root: normalizedRoot, confirmed: confirmed)
        runtime.beforePublication()
        try validateBeforePublication(descriptors, source: normalizedSource, root: normalizedRoot, confirmed: confirmed)

        let cloneError = runtime.clone(descriptors.source, descriptors.inbox, confirmed.sourceBasename)
        if cloneError != 0 {
            switch cloneError {
            case EEXIST: throw CaptureCopyError.collision(confirmed.sourceBasename)
            case EXDEV: throw CaptureCopyError.rejected("Headless capture copy requires the source and Office/Inbox to be on the same filesystem.")
            case ENOTSUP: throw CaptureCopyError.rejected("Office/Inbox does not support atomic file cloning; no destination was published.")
            default: throw CaptureCopyError.cloneFailed("Atomic capture clone failed before publication (errno \(cloneError)); no destination was published.")
            }
        }

        do {
            let destinationFD = confirmed.sourceBasename.withCString { openat(descriptors.inbox, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
            guard destinationFD >= 0 else { throw CocoaError(.fileReadUnknown) }
            defer { close(destinationFD) }
            runtime.afterDestinationOpen(destinationFD)
            let publishedState = try fileState(destinationFD)
            runtime.afterPublication()
            try verifyAfterPublication(descriptors, destinationFD: destinationFD, publishedState: publishedState, source: normalizedSource, root: normalizedRoot, confirmed: confirmed)
            return destination
        } catch {
            throw CaptureCopyError.uncertain("Post-publication verification failed for \(destination.path).")
        }
    }

    private func validateBeforePublication(_ descriptors: CaptureFileCloneDescriptors, source: URL, root: URL, confirmed: CaptureCopyPreview) throws {
        try validateRetainedNamespace(descriptors, source: source, root: root)
        let current = try states(for: descriptors)
        guard current.root == confirmed.rootState, current.office == confirmed.officeState else { throw CaptureCopyError.productionsChanged }
        guard current.inbox == confirmed.inboxState else { throw CaptureCopyError.inboxChanged }
        guard current.source.isRegularFile else { throw CaptureCopyError.sourceKindChanged }
        guard current.sourceParent == confirmed.sourceParentState,
              current.source == confirmed.sourceState,
              resolvedPath(source) == confirmed.sourceResolvedPath,
              try namedEntryMatches(parent: descriptors.sourceParent, name: confirmed.sourceBasename, state: current.source),
              try stableFileHash(descriptors.source, confirmed: current.source) == confirmed.sourceSHA256 else { throw CaptureCopyError.sourceChanged }
        guard runtime.sameFileSystem(current.source, current.inbox) else { throw CaptureCopyError.rejected("Headless capture copy requires the source and Office/Inbox to be on the same filesystem.") }
        guard runtime.supportsClone(URL(fileURLWithPath: resolvedPath(root.appending(path: "Office/Inbox", directoryHint: .isDirectory)), isDirectory: true)) else { throw CaptureCopyError.rejected("Office/Inbox is on a filesystem that does not support atomic file cloning; no mutation was attempted.") }
        guard try treeHash(descriptors.inbox) == confirmed.inboxSHA256 else { throw CaptureCopyError.inboxChanged }
        guard try treeHash(descriptors.root) == confirmed.productionsSHA256 else { throw CaptureCopyError.productionsChanged }
        let destination = try entryState(parent: descriptors.inbox, name: confirmed.sourceBasename)
        guard (destination == nil) == confirmed.destinationAbsent else { throw CaptureCopyError.destinationChanged }
        guard confirmed.destinationAbsent else { throw CaptureCopyError.collision(confirmed.sourceBasename) }
        try validateProductionsLoader(root: root)
    }

    private func verifyAfterPublication(_ descriptors: CaptureFileCloneDescriptors, destinationFD: Int32, publishedState: CaptureCopyFileState, source: URL, root: URL, confirmed: CaptureCopyPreview) throws {
        try validateRetainedNamespace(descriptors, source: source, root: root)
        let sourceParentState = try fileState(descriptors.sourceParent)
        let sourceState = try fileState(descriptors.source)
        guard sourceParentState == confirmed.sourceParentState,
              sourceState == confirmed.sourceState,
              resolvedPath(source) == confirmed.sourceResolvedPath,
              try namedEntryMatches(parent: descriptors.sourceParent, name: confirmed.sourceBasename, state: sourceState),
              try stableFileHash(descriptors.source, confirmed: sourceState) == confirmed.sourceSHA256 else { throw CaptureCopyError.sourceChanged }
        let destinationState = try fileState(destinationFD)
        guard destinationState == publishedState,
              destinationState.isRegularFile,
              destinationState.inode != sourceState.inode,
              try namedEntryMatches(parent: descriptors.inbox, name: confirmed.sourceBasename, state: destinationState),
              try stableFileHash(destinationFD, confirmed: destinationState) == confirmed.sourceSHA256 else { throw CaptureCopyError.destinationChanged }
        guard fsync(destinationFD) == 0, fsync(descriptors.inbox) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let rootState = try fileState(descriptors.root)
        let officeState = try fileState(descriptors.office)
        let inboxState = try fileState(descriptors.inbox)
        guard rootState == confirmed.rootState, officeState == confirmed.officeState else { throw CaptureCopyError.productionsChanged }
        guard inboxState.hasSameIdentity(as: confirmed.inboxState) else { throw CaptureCopyError.inboxChanged }
        guard try treeHash(descriptors.inbox, excluding: Set([confirmed.sourceBasename]), includeTimestamps: false) == confirmed.postPublicationInboxBaselineSHA256 else { throw CaptureCopyError.inboxChanged }
        guard try treeHash(descriptors.root, excluding: Set(["Office/Inbox/\(confirmed.sourceBasename)"]), includeTimestamps: false) == confirmed.postPublicationProductionsBaselineSHA256 else { throw CaptureCopyError.productionsChanged }
        try validateProductionsLoader(root: root)
        try validateRetainedNamespace(descriptors, source: source, root: root)
    }

    private func openDescriptors(source: URL, root: URL) throws -> CaptureFileCloneDescriptors {
        let rootFD = open(resolvedPath(root), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard rootFD >= 0 else { throw CaptureCopyError.rejected("Productions root is unavailable or contains a symbolic-link path component.") }
        let officeFD = openDirectory(parent: rootFD, name: "Office")
        guard officeFD >= 0 else { close(rootFD); throw CaptureCopyError.rejected("The canonical Office directory is unavailable.") }
        let inboxFD = openDirectory(parent: officeFD, name: "Inbox")
        guard inboxFD >= 0 else { close(officeFD); close(rootFD); throw CaptureCopyError.rejected("Office/Inbox is unavailable.") }
        let parentURL = URL(fileURLWithPath: resolvedPath(source.deletingLastPathComponent()), isDirectory: true)
        let sourceParentFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard sourceParentFD >= 0 else { close(inboxFD); close(officeFD); close(rootFD); throw CaptureCopyError.sourceChanged }
        guard let preliminary = try? entryState(parent: sourceParentFD, name: source.lastPathComponent) else {
            close(sourceParentFD); close(inboxFD); close(officeFD); close(rootFD)
            throw CaptureCopyError.sourceChanged
        }
        guard preliminary.isRegularFile else {
            close(sourceParentFD); close(inboxFD); close(officeFD); close(rootFD)
            throw unsupportedKind(state: preliminary)
        }
        let sourceFD = source.lastPathComponent.withCString { openat(sourceParentFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard sourceFD >= 0 else {
            let existing = try? entryState(parent: sourceParentFD, name: source.lastPathComponent)
            close(sourceParentFD); close(inboxFD); close(officeFD); close(rootFD)
            if let existing { throw unsupportedKind(state: existing) }
            throw CaptureCopyError.sourceChanged
        }
        return .init(root: rootFD, office: officeFD, inbox: inboxFD, sourceParent: sourceParentFD, source: sourceFD)
    }

    private func validateRetainedNamespace(_ descriptors: CaptureFileCloneDescriptors, source: URL, root: URL) throws {
        let reopenedRoot = open(resolvedPath(root), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard reopenedRoot >= 0 else { throw CaptureCopyError.productionsChanged }
        defer { close(reopenedRoot) }
        guard try fileState(reopenedRoot).hasSameIdentity(as: fileState(descriptors.root)) else { throw CaptureCopyError.productionsChanged }
        let reopenedOffice = openDirectory(parent: reopenedRoot, name: "Office")
        guard reopenedOffice >= 0 else { throw CaptureCopyError.productionsChanged }
        defer { close(reopenedOffice) }
        guard try fileState(reopenedOffice).hasSameIdentity(as: fileState(descriptors.office)) else { throw CaptureCopyError.productionsChanged }
        let reopenedInbox = openDirectory(parent: reopenedOffice, name: "Inbox")
        guard reopenedInbox >= 0 else { throw CaptureCopyError.inboxChanged }
        defer { close(reopenedInbox) }
        guard try fileState(reopenedInbox).hasSameIdentity(as: fileState(descriptors.inbox)) else { throw CaptureCopyError.inboxChanged }
        let reopenedSourceParent = open(resolvedPath(source.deletingLastPathComponent()), O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard reopenedSourceParent >= 0 else { throw CaptureCopyError.sourceChanged }
        defer { close(reopenedSourceParent) }
        guard try fileState(reopenedSourceParent).hasSameIdentity(as: fileState(descriptors.sourceParent)) else { throw CaptureCopyError.sourceChanged }
    }

    private func states(for descriptors: CaptureFileCloneDescriptors) throws -> (root: CaptureCopyFileState, office: CaptureCopyFileState, inbox: CaptureCopyFileState, sourceParent: CaptureCopyFileState, source: CaptureCopyFileState) {
        (try fileState(descriptors.root), try fileState(descriptors.office), try fileState(descriptors.inbox), try fileState(descriptors.sourceParent), try fileState(descriptors.source))
    }

    private func validateProductionsLoader(root: URL) throws {
        let state = ProductionsLoader(reader: LocalFileSystem()).load(configuration: .init(schemaVersion: 2, productionsRootPath: root.path))
        guard state.issues.isEmpty else { throw CaptureCopyError.rejected("ProductionsLoader rejected the Productions root; no mutation was attempted.") }
    }

    private func validateBasename(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/") else {
            throw CaptureCopyError.rejected("Headless capture copy requires a visible regular file with an exact basename.")
        }
    }

    private func validateSourcePathHasNoSymlinkComponents(_ source: URL) throws {
        guard let pointer = realpath(source.path, nil) else { throw CaptureCopyError.sourceChanged }
        defer { free(pointer) }
        guard String(cString: pointer) == source.path else {
            throw CaptureCopyError.rejected("Headless capture copy rejects symbolic links in every source path component.")
        }
    }

    private func resolvedPath(_ url: URL) -> String {
        guard let pointer = realpath(url.path, nil) else { return url.standardizedFileURL.path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    private func unsupportedKind(state: CaptureCopyFileState) -> CaptureCopyError {
        state.isDirectory
            ? .rejected("Phase 3D headless capture copy supports regular files only; directories and packages remain GUI-only.")
            : .rejected("Phase 3D headless capture copy rejects symbolic links and special files.")
    }

    private func sameDirectory(_ first: Int32, _ second: Int32) -> Bool {
        guard let left = try? fileState(first), let right = try? fileState(second) else { return false }
        return left.hasSameIdentity(as: right)
    }

    private func openDirectory(parent: Int32, name: String) -> Int32 {
        name.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
    }

    private func fileState(_ descriptor: Int32) throws -> CaptureCopyFileState {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw CocoaError(.fileReadUnknown) }
        return Self.makeState(value)
    }

    private func entryState(parent: Int32, name: String) throws -> CaptureCopyFileState? {
        var value = stat()
        let result = name.withCString { fstatat(parent, $0, &value, AT_SYMLINK_NOFOLLOW) }
        if result != 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadUnknown)
        }
        return Self.makeState(value)
    }

    private func namedEntryMatches(parent: Int32, name: String, state: CaptureCopyFileState) throws -> Bool {
        guard let named = try entryState(parent: parent, name: name) else { return false }
        return named.hasSameIdentity(as: state)
    }

    private static func makeState(_ value: stat) -> CaptureCopyFileState {
        .init(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), mode: UInt32(value.st_mode), linkCount: UInt64(value.st_nlink), userID: UInt32(value.st_uid), groupID: UInt32(value.st_gid), size: Int64(value.st_size), modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec), changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }

    private func stableFileHash(_ descriptor: Int32, confirmed: CaptureCopyFileState) throws -> String {
        guard confirmed.isRegularFile else { throw CocoaError(.fileReadUnsupportedScheme) }
        var hasher = SHA256()
        var offset: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = pread(descriptor, &buffer, buffer.count, off_t(offset))
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            offset += Int64(count)
        }
        guard offset == confirmed.size, try fileState(descriptor) == confirmed else { throw CaptureCopyError.sourceChanged }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func treeHash(_ rootFD: Int32, excluding: Set<String> = [], includeTimestamps: Bool = true) throws -> String {
        var encoder = CanonicalFrameEncoder()
        encoder.append(["capture-copy-descriptor-tree", includeTimestamps ? "strict-1" : "post-publication-1"])
        try appendTree(directoryFD: rootFD, relative: "", excluding: excluding, includeTimestamps: includeTimestamps, encoder: &encoder)
        return SHA256.hash(data: encoder.data).map { String(format: "%02x", $0) }.joined()
    }

    private func appendTree(directoryFD: Int32, relative: String, excluding: Set<String>, includeTimestamps: Bool, encoder: inout CanonicalFrameEncoder) throws {
        let directoryState = try fileState(directoryFD)
        encoder.append([relative.isEmpty ? "." : relative, "directory", includeTimestamps ? fullStateFields(directoryState) : postPublicationDirectoryFields(directoryState)])
        for name in try directoryNames(directoryFD) {
            let path = relative.isEmpty ? name : "\(relative)/\(name)"
            if excluding.contains(path) || excluding.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            guard let state = try entryState(parent: directoryFD, name: name) else { throw CocoaError(.fileReadUnknown) }
            let kind = state.mode & UInt32(S_IFMT)
            if kind == UInt32(S_IFDIR) {
                let childFD = openDirectory(parent: directoryFD, name: name)
                guard childFD >= 0 else { throw CocoaError(.fileReadUnknown) }
                defer { close(childFD) }
                try appendTree(directoryFD: childFD, relative: path, excluding: excluding, includeTimestamps: includeTimestamps, encoder: &encoder)
            } else if kind == UInt32(S_IFREG) {
                let childFD = name.withCString { openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
                guard childFD >= 0 else { throw CocoaError(.fileReadUnknown) }
                let digest: String
                do { digest = try stableFileHash(childFD, confirmed: state) }
                catch { close(childFD); throw error }
                close(childFD)
                encoder.append([path, "file", includeTimestamps ? fullStateFields(state) : postPublicationStateFields(state), digest])
            } else if kind == UInt32(S_IFLNK) {
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                let count = name.withCString { readlinkat(directoryFD, $0, &buffer, buffer.count) }
                guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
                encoder.append([path, "symlink", includeTimestamps ? fullStateFields(state) : postPublicationStateFields(state), String(decoding: buffer[0..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)])
            } else {
                encoder.append([path, "special", includeTimestamps ? fullStateFields(state) : postPublicationStateFields(state)])
            }
        }
    }

    private func directoryNames(_ descriptor: Int32) throws -> [String] {
        let copied = dup(descriptor)
        guard copied >= 0, lseek(copied, 0, SEEK_SET) >= 0, let directory = fdopendir(copied) else {
            if copied >= 0 { close(copied) }
            throw CocoaError(.fileReadUnknown)
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names.sorted { Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8)) }
    }

    private func stableIdentityFields(_ state: CaptureCopyFileState) -> String {
        [state.device, state.inode, UInt64(state.mode), state.linkCount, UInt64(state.userID), UInt64(state.groupID)].map(String.init).joined(separator: ":")
    }

    private func fullStateFields(_ state: CaptureCopyFileState) -> String {
        "\(stableIdentityFields(state)):\(state.size):\(state.modifiedSeconds):\(state.modifiedNanoseconds):\(state.changedSeconds):\(state.changedNanoseconds)"
    }

    private func postPublicationStateFields(_ state: CaptureCopyFileState) -> String {
        "\(stableIdentityFields(state)):\(state.size)"
    }

    private func postPublicationDirectoryFields(_ state: CaptureCopyFileState) -> String {
        [state.device, state.inode, UInt64(state.mode), UInt64(state.userID), UInt64(state.groupID)].map(String.init).joined(separator: ":")
    }

    static func volumeSupportsClone(_ url: URL) -> Bool {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_CAPABILITIES)
        var values = [UInt32](repeating: 0, count: 9)
        let result = url.path.withCString { getattrlist($0, &attributes, &values, values.count * MemoryLayout<UInt32>.size, UInt32(FSOPT_NOFOLLOW_ANY)) }
        guard result == 0 else { return false }
        let interfaceCapabilities = values[2]
        let validInterfaces = values[6]
        return validInterfaces & UInt32(VOL_CAP_INT_CLONE) != 0 && interfaceCapabilities & UInt32(VOL_CAP_INT_CLONE) != 0
    }
}

extension ProductionsInboxCaptureService {
    func previewFileCopy(source: URL, productionsRoot: URL) throws -> CaptureCopyPreview {
        try CaptureFileCloneTransaction(runtime: captureFileCloneRuntime).preview(source: source, root: productionsRoot)
    }

    func commitFileCopy(source: URL, productionsRoot: URL, confirmedPreview: CaptureCopyPreview) throws -> URL {
        try CaptureFileCloneTransaction(runtime: captureFileCloneRuntime).commit(source: source, root: productionsRoot, confirmed: confirmedPreview)
    }
}

extension CaptureCopyPreview {
    func canonicalJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    func confirmedEnvelope() throws -> String { try canonicalJSON().base64EncodedString() }
    func confirmationToken() throws -> String {
        let digest = SHA256.hash(data: try canonicalJSON()).map { String(format: "%02x", $0) }.joined()
        return "confirm:capture-copy:v2:\(digest)"
    }
    static func decodeConfirmedEnvelope(_ encoded: String, token: String) throws -> Self {
        guard let data = Data(base64Encoded: encoded), let preview = try? JSONDecoder().decode(Self.self, from: data),
              preview.schema == schemaVersion, preview.actionDiscriminator == action,
              try preview.canonicalJSON() == data, try preview.confirmationToken() == token else { throw CaptureCopyError.confirmationRequired }
        return preview
    }
}

struct CaptureCopyCommand: Equatable {
    let source: String
    let confirmedPreview: String?
    let confirmation: String?
}

struct HeadlessCaptureCopyAdapter {
    let makeService: () -> ProductionsInboxCaptureService
    init(makeService: @escaping () -> ProductionsInboxCaptureService = { ProductionsInboxCaptureService() }) { self.makeService = makeService }
    func preview(_ command: CaptureCopyCommand, configuration: ProductionsConfiguration) throws -> CaptureCopyPreview {
        try makeService().previewFileCopy(source: URL(fileURLWithPath: command.source), productionsRoot: configuration.rootURL)
    }
    func execute(_ command: CaptureCopyCommand, configuration: ProductionsConfiguration) throws -> (URL, String) {
        guard let envelope = command.confirmedPreview, let confirmation = command.confirmation else { throw CaptureCopyError.confirmationRequired }
        let preview = try CaptureCopyPreview.decodeConfirmedEnvelope(envelope, token: confirmation)
        let suppliedSource = URL(fileURLWithPath: command.source)
        let source = suppliedSource.standardizedFileURL
        let root = configuration.rootURL.standardizedFileURL
        let authoritativeDestination = root.appending(path: "Office/Inbox", directoryHint: .isDirectory).appending(path: source.lastPathComponent, directoryHint: .notDirectory)
        guard preview.sourcePath == source.path, preview.productionsRoot == root.path, preview.destinationPath == authoritativeDestination.path else { throw CaptureCopyError.confirmationRequired }
        let destination = try makeService().commitFileCopy(source: suppliedSource, productionsRoot: root, confirmedPreview: preview)
        return (destination, preview.sourceSHA256)
    }
}

private struct CaptureCopyPreviewOutput: Codable {
    let preview: CaptureCopyPreview
    let confirmedPreview: String
    let confirmationToken: String
}

enum HeadlessCaptureCopyCommandLine {
    static let usage = "Usage: OperationsDashboard capture [preview] copy --productions-root <path> --source <regular-file> [--confirmed-preview <base64>] [--confirm <token>]"
    static func runIfRequested(arguments: [String] = CommandLine.arguments, adapter: HeadlessCaptureCopyAdapter = .init(), write: (String) -> Void = { print($0) }) -> Int32? {
        let values = Array(arguments.dropFirst())
        guard values.first == "capture", values.dropFirst().first == "copy" || (values.dropFirst().first == "preview" && values.dropFirst(2).first == "copy") else { return nil }
        do {
            let (isPreview, command, configuration) = try parse(values)
            if isPreview {
                let preview = try adapter.preview(command, configuration: configuration)
                let output = CaptureCopyPreviewOutput(preview: preview, confirmedPreview: try preview.confirmedEnvelope(), confirmationToken: try preview.confirmationToken())
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                write(String(decoding: try encoder.encode(output), as: UTF8.self))
            } else {
                let result = try adapter.execute(command, configuration: configuration)
                write("Capture copy committed to \(result.0.path); source preserved and destination SHA-256 verified (\(result.1)).")
            }
            return 0
        } catch let error as CaptureCopyError {
            if case let .uncertain(diagnostic) = error {
                write("Capture copy committed or may have committed; do not retry automatically. Service diagnostic: \(diagnostic)")
                return 3
            }
            write(error.localizedDescription)
            return 2
        } catch {
            write(error.localizedDescription)
            return 2
        }
    }

    private static func parse(_ arguments: [String]) throws -> (Bool, CaptureCopyCommand, ProductionsConfiguration) {
        let preview = arguments.dropFirst().first == "preview"
        let verbIndex = preview ? 2 : 1
        guard arguments.count > verbIndex, arguments[verbIndex] == "copy" else { throw CaptureCopyError.rejected(usage) }
        let allowed = ["--productions-root", "--source", "--confirmed-preview", "--confirm"]
        var options: [String: String] = [:]
        var index = verbIndex + 1
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option), index + 1 < arguments.count, options[option] == nil else { throw CaptureCopyError.rejected(usage) }
            options[option] = arguments[index + 1]; index += 2
        }
        guard let root = options["--productions-root"], !root.isEmpty, let source = options["--source"], !source.isEmpty else { throw CaptureCopyError.rejected(usage) }
        if !preview, options["--confirmed-preview"] == nil || options["--confirm"] == nil { throw CaptureCopyError.confirmationRequired }
        return (preview, .init(source: source, confirmedPreview: options["--confirmed-preview"], confirmation: options["--confirm"]), .init(schemaVersion: 2, productionsRootPath: root))
    }
}
