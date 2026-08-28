import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI

/// TASK-0043 capture boundary. These operations only create or transfer one
/// immediate Inbox payload; they intentionally have no Flow or ledger access.
enum ProductionsInboxCaptureOutcome: Equatable {
    case captured(URL)
    case verificationRequired(String)
    case deferred(String)
    case rejected(String)
}

struct TypedNotePublicationRuntime: Sendable {
    let beforeTemporaryCreation: @Sendable (String) throws -> Void
    let beforePublication: @Sendable (String) throws -> Void
    let afterPublication: @Sendable (String) throws -> Void
    let beforeResidueRevalidation: @Sendable (String) throws -> Void
    let afterCleanupValidation: @Sendable (String) throws -> Void
    let cleanupTransitionGate: @Sendable (Int32, String) -> Int32

    init(
        beforeTemporaryCreation: @escaping @Sendable (String) throws -> Void,
        beforePublication: @escaping @Sendable (String) throws -> Void,
        afterPublication: @escaping @Sendable (String) throws -> Void,
        cleanupTransitionGate: @escaping @Sendable (Int32, String) -> Int32,
        beforeResidueRevalidation: @escaping @Sendable (String) throws -> Void = { _ in },
        afterCleanupValidation: @escaping @Sendable (String) throws -> Void = { _ in }
    ) {
        self.beforeTemporaryCreation = beforeTemporaryCreation
        self.beforePublication = beforePublication
        self.afterPublication = afterPublication
        self.beforeResidueRevalidation = beforeResidueRevalidation
        self.afterCleanupValidation = afterCleanupValidation
        self.cleanupTransitionGate = cleanupTransitionGate
    }

    static let live = TypedNotePublicationRuntime(
        beforeTemporaryCreation: { _ in },
        beforePublication: { _ in },
        afterPublication: { _ in },
        cleanupTransitionGate: { _, _ in 0 },
        beforeResidueRevalidation: { _ in },
        afterCleanupValidation: { _ in }
    )
}

struct TypedNoteFileIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let ownerUID: UInt32
    let ownerGID: UInt32
    let linkCount: UInt64

    var isOwnedRegularFile: Bool {
        mode & UInt32(S_IFMT) == UInt32(S_IFREG) && ownerUID == geteuid() && linkCount == 1
    }
}

struct TypedNoteTemporaryResidue: Codable, Equatable {
    let name: String
    let operationFingerprint: String
    let identity: TypedNoteFileIdentity
}

struct TypedNoteDirectoryIdentity: Codable, Equatable {
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    func hasSameLocation(as other: Self) -> Bool { device == other.device && inode == other.inode }
}

struct TypedNoteInboxState: Codable, Equatable {
    let office: TypedNoteDirectoryIdentity
    let inbox: TypedNoteDirectoryIdentity

    func hasSameNamespace(as other: Self) -> Bool {
        office.hasSameLocation(as: other.office) && inbox.hasSameLocation(as: other.inbox)
    }
}

struct TypedNoteCapturePreview: Codable, Equatable {
    let schemaVersion: Int
    let productionsRoot: String
    let inboxPath: String
    let contents: String
    let contentSHA256: String
    let contentByteCount: Int
    let timestamp: String
    let timestampPolicy: String
    let filename: String
    let destinationAbsent: Bool
    let collisionOutcome: String
    let inboxState: TypedNoteInboxState
    let operationFingerprint: String
    let temporaryResidueNames: [String]
    let temporaryResidueOperationFingerprints: [String]
    let temporaryResidues: [TypedNoteTemporaryResidue]
    let unsafeTemporaryResidueCount: Int

    var requiresRecovery: Bool { !temporaryResidueNames.isEmpty || unsafeTemporaryResidueCount > 0 }
}

struct TypedNoteCaptureRedactedPreview: Codable, Equatable {
    let schemaVersion: Int
    let productionsRoot: String
    let inboxPath: String
    let contentSHA256: String
    let contentByteCount: Int
    let timestamp: String
    let timestampPolicy: String
    let filename: String
    let destinationAbsent: Bool
    let collisionOutcome: String
    let inboxState: TypedNoteInboxState
    let operationFingerprint: String
    let temporaryResidueOperationFingerprints: [String]
    let unsafeTemporaryResidueCount: Int
    let requiresRecovery: Bool

    init(_ preview: TypedNoteCapturePreview) {
        schemaVersion = preview.schemaVersion; productionsRoot = preview.productionsRoot; inboxPath = preview.inboxPath
        contentSHA256 = preview.contentSHA256; contentByteCount = preview.contentByteCount; timestamp = preview.timestamp
        timestampPolicy = preview.timestampPolicy; filename = preview.filename; destinationAbsent = preview.destinationAbsent
        collisionOutcome = preview.collisionOutcome; inboxState = preview.inboxState; operationFingerprint = preview.operationFingerprint
        temporaryResidueOperationFingerprints = preview.temporaryResidueOperationFingerprints
        unsafeTemporaryResidueCount = preview.unsafeTemporaryResidueCount; requiresRecovery = preview.requiresRecovery
    }
}

struct TypedNoteResidueRecovery: Equatable {
    let operationFingerprint: String
    let removedOperationFingerprints: [String]
    let quarantineNames: [String]
}

enum TypedNoteCommandExecutionOutcome: Equatable {
    case captured(URL)
    case recovered(TypedNoteResidueRecovery)
}

enum TypedNoteCaptureError: LocalizedError, Equatable {
    case rejected(String)
    case stalePreview
    case activeConcurrency
    case recoveryRequired(String)
    case namespaceUncertain(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .rejected(message), let .recoveryRequired(message), let .namespaceUncertain(message), let .verificationFailed(message): return message
        case .stalePreview: return "The capture inputs or Inbox state changed since preview. Re-run capture note preview and use its new confirmation token."
        case .activeConcurrency: return "Another Quick Capture operation currently owns the configured Office namespace. No recovery or publication was attempted."
        }
    }
}

private final class TypedNoteInboxNamespace {
    let productionsRootPath: String
    let inboxPath: String
    let officeDescriptor: Int32
    let inboxDescriptor: Int32
    let state: TypedNoteInboxState
    private let ownsLock: Bool

    private init(productionsRootPath: String, officeDescriptor: Int32, inboxDescriptor: Int32, state: TypedNoteInboxState, ownsLock: Bool) {
        self.productionsRootPath = productionsRootPath
        inboxPath = URL(fileURLWithPath: productionsRootPath, isDirectory: true).appending(path: "Office/Inbox", directoryHint: .isDirectory).path
        self.officeDescriptor = officeDescriptor; self.inboxDescriptor = inboxDescriptor; self.state = state; self.ownsLock = ownsLock
    }

    deinit {
        close(inboxDescriptor)
        if ownsLock { _ = flock(officeDescriptor, LOCK_UN) }
        close(officeDescriptor)
    }

    static func open(productionsRoot: URL, acquireLock: Bool) throws -> TypedNoteInboxNamespace {
        let rootPath = productionsRoot.path
        guard productionsRoot.isFileURL, rootPath.hasPrefix("/") else { throw TypedNoteCaptureError.rejected("The configured Productions root must be an absolute file path.") }
        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { throw TypedNoteCaptureError.rejected("The configured Productions namespace is unavailable.") }
        do {
            for component in rootPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
                let next = try openDirectory(parent: current, component: component)
                close(current); current = next
            }
            let office = try openDirectory(parent: current, component: "Office")
            close(current); current = -1
            if acquireLock, flock(office, LOCK_EX | LOCK_NB) != 0 {
                close(office)
                throw TypedNoteCaptureError.activeConcurrency
            }
            do {
                let inbox = try openDirectory(parent: office, component: "Inbox")
                do {
                    let state = TypedNoteInboxState(office: try identity(office), inbox: try identity(inbox))
                    return TypedNoteInboxNamespace(productionsRootPath: rootPath, officeDescriptor: office, inboxDescriptor: inbox, state: state, ownsLock: acquireLock)
                } catch {
                    close(inbox); throw error
                }
            } catch {
                if acquireLock { _ = flock(office, LOCK_UN) }
                close(office); throw error
            }
        } catch {
            if current >= 0 { close(current) }
            throw error
        }
    }

    func destinationIsAbsent(_ filename: String) throws -> Bool {
        var value = stat()
        let result = filename.withCString { fstatat(inboxDescriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }
        if result == 0 { return false }
        if errno == ENOENT { return true }
        throw TypedNoteCaptureError.rejected("The confirmed Inbox destination could not be inspected safely.")
    }

    func temporaryResidues() throws -> (recognized: [TypedNoteTemporaryResidue], unsafeCount: Int) {
        let names = try directoryNames()
        var recognized: [TypedNoteTemporaryResidue] = []; var unsafeCount = 0
        for name in names where name.hasPrefix(".capture-note-") && name.hasSuffix(".tmp") {
            let fingerprint = String(name.dropFirst(".capture-note-".count).dropLast(".tmp".count))
            let isHexFingerprint = fingerprint.utf8.count == 32 && fingerprint.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            let identity = try entryIdentity(name)
            if isHexFingerprint, let identity, identity.isOwnedRegularFile {
                recognized.append(.init(name: name, operationFingerprint: fingerprint, identity: identity))
            }
            else { unsafeCount += 1 }
        }
        return (recognized.sorted { $0.name < $1.name }, unsafeCount)
    }

    func entryIdentity(_ name: String) throws -> TypedNoteFileIdentity? {
        var value = stat()
        let result = name.withCString { fstatat(inboxDescriptor, $0, &value, AT_SYMLINK_NOFOLLOW) }
        if result == 0 { return Self.fileIdentity(value) }
        if errno == ENOENT { return nil }
        throw TypedNoteCaptureError.rejected("An Inbox entry could not be inspected safely (errno \(errno)).")
    }

    static func descriptorIdentity(_ descriptor: Int32) throws -> TypedNoteFileIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw TypedNoteCaptureError.rejected("A Quick Capture descriptor could not be inspected safely (errno \(errno)).")
        }
        return fileIdentity(value)
    }

    private func directoryNames() throws -> [String] {
        let duplicate = dup(inboxDescriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw TypedNoteCaptureError.rejected("Office/Inbox could not be enumerated safely.")
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    private static func openDirectory(parent: Int32, component: String) throws -> Int32 {
        guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
            throw TypedNoteCaptureError.rejected("The configured Productions namespace contains an invalid path component.")
        }
        let descriptor = component.withCString { openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw TypedNoteCaptureError.rejected("The configured Productions namespace contains a symbolic link, non-directory, or unavailable component; Quick Capture stopped without following it.")
        }
        do {
            _ = try identity(descriptor)
            return descriptor
        } catch {
            close(descriptor); throw error
        }
    }

    private static func identity(_ descriptor: Int32) throws -> TypedNoteDirectoryIdentity {
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & UInt16(S_IFMT) == UInt16(S_IFDIR) else {
            throw TypedNoteCaptureError.rejected("The configured Productions namespace contains a non-directory component.")
        }
        return .init(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec))
    }

    private static func fileIdentity(_ value: stat) -> TypedNoteFileIdentity {
        .init(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            mode: UInt32(value.st_mode),
            ownerUID: UInt32(value.st_uid),
            ownerGID: UInt32(value.st_gid),
            linkCount: UInt64(value.st_nlink)
        )
    }
}

struct ProductionsInboxCaptureService {
    private let manager: FileManager
    private let now: () -> Date
    private let typedNotePublicationRuntime: TypedNotePublicationRuntime
    let captureFileCloneRuntime: CaptureFileCloneRuntime
    let automaticCaptureContext: AutomaticCaptureContext
    private var observations: [String: Observation] = [:]

    init(manager: FileManager = .default, now: @escaping () -> Date = Date.init, typedNotePublicationRuntime: TypedNotePublicationRuntime = .live, captureFileCloneRuntime: CaptureFileCloneRuntime = .live, automaticCaptureContext: AutomaticCaptureContext = .live) {
        self.manager = manager; self.now = now
        self.typedNotePublicationRuntime = typedNotePublicationRuntime
        self.captureFileCloneRuntime = captureFileCloneRuntime; self.automaticCaptureContext = automaticCaptureContext
    }

    mutating func copyManual(source: URL, productionsRoot: URL) -> ProductionsInboxCaptureOutcome {
        guard let kind = eligibleKind(source) else { return .rejected("Select a readable, non-hidden file or folder; symbolic links and unsupported items cannot be captured.") }
        let inbox = productionsRoot.appending(path: "Office/Inbox", directoryHint: .isDirectory)
        guard validInbox(inbox) else { return .rejected("Office/Inbox is unavailable.") }
        let destination = inbox.appending(path: source.lastPathComponent, directoryHint: kind == .directory ? .isDirectory : .notDirectory)
        guard !manager.fileExists(atPath: destination.path) else { return .rejected("Inbox already contains an item named \(source.lastPathComponent).") }
        let temporary = inbox.appending(path: ".capture-\(UUID().uuidString)", directoryHint: kind == .directory ? .isDirectory : .notDirectory)
        do {
            try manager.copyItem(at: source, to: temporary)
            try manager.moveItem(at: temporary, to: destination)
            return .captured(destination)
        } catch {
            try? manager.removeItem(at: temporary)
            return .rejected("Manual capture failed: \(error.localizedDescription)")
        }
    }

    mutating func createTypedNote(text: String, productionsRoot: URL, now: Date = Date()) -> ProductionsInboxCaptureOutcome {
        do { let preview = try previewTypedNote(text: text, productionsRoot: productionsRoot, timestamp: now); return .captured(try commitTypedNote(text: text, productionsRoot: productionsRoot, timestamp: now, preview: preview)) }
        catch let error as TypedNoteCaptureError {
            if case let .verificationFailed(diagnostic) = error { return .verificationRequired(diagnostic) }
            if case let .namespaceUncertain(diagnostic) = error { return .verificationRequired(diagnostic) }
            return .rejected(error.localizedDescription)
        }
        catch { return .rejected("Quick Capture stopped without publishing. No note content was emitted.") }
    }

    func previewTypedNote(text: String, productionsRoot: URL, timestamp: Date) throws -> TypedNoteCapturePreview {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TypedNoteCaptureError.rejected("Enter a nonblank note.") }
        let namespace = try TypedNoteInboxNamespace.open(productionsRoot: productionsRoot, acquireLock: true)
        return try Self.preview(text: text, timestamp: timestamp, namespace: namespace)
    }

    private static func preview(text: String, timestamp: Date, namespace: TypedNoteInboxNamespace) throws -> TypedNoteCapturePreview {
        let formatter = Self.timestampFormatter(); let renderedTimestamp = formatter.string(from: timestamp)
        let filename = "Quick Capture \(renderedTimestamp.replacingOccurrences(of: ":", with: "-")).md"
        let contents = "# Quick Capture\n\nCreated: \(renderedTimestamp)\nSource: Operations Dashboard\n\n\(text.hasSuffix("\n") ? text : text + "\n")"
        let bytes = Data(contents.utf8)
        let destinationAbsent = try namespace.destinationIsAbsent(filename)
        let residues = try namespace.temporaryResidues()
        let contentHash = Self.hash(bytes)
        let fingerprintMaterial = "typed-note-v2\n\(namespace.productionsRootPath)\n\(renderedTimestamp)\n\(filename)\n\(contentHash)\n\(namespace.state.office.device):\(namespace.state.office.inode)\n\(namespace.state.inbox.device):\(namespace.state.inbox.inode)"
        let operationFingerprint = String(Self.hash(Data(fingerprintMaterial.utf8)).prefix(32))
        return .init(
            schemaVersion: 2,
            productionsRoot: namespace.productionsRootPath,
            inboxPath: namespace.inboxPath,
            contents: contents,
            contentSHA256: contentHash,
            contentByteCount: bytes.count,
            timestamp: renderedTimestamp,
            timestampPolicy: "ISO-8601 UTC; filename replaces colons with hyphens",
            filename: filename,
            destinationAbsent: destinationAbsent,
            collisionOutcome: destinationAbsent ? "destination absent" : "Inbox already contains \(filename).",
            inboxState: namespace.state,
            operationFingerprint: operationFingerprint,
            temporaryResidueNames: residues.recognized.map(\.name),
            temporaryResidueOperationFingerprints: residues.recognized.map(\.operationFingerprint),
            temporaryResidues: residues.recognized,
            unsafeTemporaryResidueCount: residues.unsafeCount
        )
    }

    func commitTypedNote(text: String, productionsRoot: URL, timestamp: Date, preview: TypedNoteCapturePreview) throws -> URL {
        let namespace = try TypedNoteInboxNamespace.open(productionsRoot: productionsRoot, acquireLock: true)
        let current = try Self.preview(text: text, timestamp: timestamp, namespace: namespace)
        guard current == preview else { throw TypedNoteCaptureError.stalePreview }
        guard !preview.requiresRecovery else {
            throw TypedNoteCaptureError.recoveryRequired(Self.recoveryDiagnostic(preview: preview, prefix: "Temporary Quick Capture residue requires a separately confirmed cleanup operation."))
        }
        guard preview.destinationAbsent else { throw TypedNoteCaptureError.rejected(preview.collisionOutcome) }
        let bytes = Data(preview.contents.utf8)
        return try Self.atomicPublish(bytes, preview: preview, namespace: namespace, runtime: typedNotePublicationRuntime)
    }

    func recoverTypedNoteResidue(text: String, productionsRoot: URL, timestamp: Date, preview: TypedNoteCapturePreview) throws -> TypedNoteResidueRecovery {
        let namespace = try TypedNoteInboxNamespace.open(productionsRoot: productionsRoot, acquireLock: true)
        let current = try Self.preview(text: text, timestamp: timestamp, namespace: namespace)
        guard current == preview else { throw TypedNoteCaptureError.stalePreview }
        guard current.requiresRecovery else { throw TypedNoteCaptureError.stalePreview }
        guard current.unsafeTemporaryResidueCount == 0 else {
            throw TypedNoteCaptureError.recoveryRequired(Self.recoveryDiagnostic(preview: current, prefix: "Unsafe Quick Capture residue requires manual Office recovery; no entry was removed."))
        }
        var removed: [String] = []
        var quarantineNames: [String] = []
        for residue in current.temporaryResidues {
            do { try typedNotePublicationRuntime.beforeResidueRevalidation(residue.operationFingerprint) }
            catch let typed as TypedNoteCaptureError { throw typed }
            catch {
                throw TypedNoteCaptureError.namespaceUncertain(Self.residueIdentityDiagnostic(fingerprint: residue.operationFingerprint, removedCount: removed.count, reason: "cleanup was interrupted before identity revalidation"))
            }
            guard let liveIdentity = try namespace.entryIdentity(residue.name), liveIdentity == residue.identity, liveIdentity.isOwnedRegularFile else {
                throw TypedNoteCaptureError.namespaceUncertain(Self.residueIdentityDiagnostic(fingerprint: residue.operationFingerprint, removedCount: removed.count, reason: "the confirmed residue entry was replaced or changed"))
            }
            let quarantineName = try Self.quarantineTemporary(
                name: residue.name,
                fingerprint: residue.operationFingerprint,
                expectedIdentity: residue.identity,
                namespace: namespace,
                runtime: typedNotePublicationRuntime
            )
            removed.append(residue.operationFingerprint)
            quarantineNames.append(quarantineName)
        }
        guard fsync(namespace.inboxDescriptor) == 0 else {
            throw TypedNoteCaptureError.recoveryRequired("Quick Capture quarantine durability failed for operation \(current.operationFingerprint) after preserving \(removed.count) residue item(s) (errno \(errno)). No payload was published and automatic retry is prohibited.")
        }
        let remaining = try namespace.temporaryResidues()
        guard remaining.recognized.isEmpty, remaining.unsafeCount == 0 else {
            throw TypedNoteCaptureError.recoveryRequired("Quick Capture cleanup verification failed for operation \(current.operationFingerprint). No payload was published and automatic retry is prohibited.")
        }
        let confirmed = try TypedNoteInboxNamespace.open(productionsRoot: productionsRoot, acquireLock: false)
        guard namespace.state.hasSameNamespace(as: confirmed.state) else {
            throw TypedNoteCaptureError.namespaceUncertain("The configured Inbox namespace changed during cleanup for operation \(current.operationFingerprint). No payload was published; inspect the operation before any retry.")
        }
        return .init(operationFingerprint: current.operationFingerprint, removedOperationFingerprints: removed, quarantineNames: quarantineNames)
    }

    mutating func observeAutomatic(sourceFolder: URL, productionsRoot: URL) -> [ProductionsInboxCaptureOutcome] {
        guard validFolder(sourceFolder) else { return [.rejected("Configured automatic source is not a readable non-symbolic-link folder.")] }
        let inbox = productionsRoot.appending(path: "Office/Inbox", directoryHint: .isDirectory)
        guard validInbox(inbox) else { return [.rejected("Office/Inbox is unavailable.")] }
        let entries: [URL]
        do { entries = try manager.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]).sorted { $0.path < $1.path } }
        catch { return [.rejected("Cannot enumerate automatic source: \(error.localizedDescription)")] }
        var results: [ProductionsInboxCaptureOutcome] = []
        for item in entries {
            guard let kind = eligibleKind(item), let current = fingerprint(item, kind: kind) else { results.append(.rejected("\(item.lastPathComponent) is hidden, symbolic, unreadable, or unsupported.")); continue }
            let key = item.standardizedFileURL.path
            guard let previous = observations[key], previous.fingerprint == current else { observations[key] = Observation(fingerprint: current, firstObserved: now()); results.append(.deferred("\(item.lastPathComponent) is waiting to remain unchanged for 2 seconds.")); continue }
            guard now().timeIntervalSince(previous.firstObserved) >= 2 else { results.append(.deferred("\(item.lastPathComponent) is waiting to remain unchanged for 2 seconds.")); continue }
            let destination = inbox.appending(path: item.lastPathComponent, directoryHint: kind == .directory ? .isDirectory : .notDirectory)
            guard !manager.fileExists(atPath: destination.path) else { results.append(.rejected("Inbox already contains an item named \(item.lastPathComponent).")); break }
            do { try manager.moveItem(at: item, to: destination); observations.removeValue(forKey: key); results.append(.captured(destination)) }
            catch { results.append(.rejected("Automatic capture failed for \(item.lastPathComponent): \(error.localizedDescription)")); break }
        }
        return results
    }

    private enum Kind { case file, directory }
    private struct CaptureFingerprint: Equatable { let kind: Kind; let size: Int; let modified: Date }
    private struct Observation { let fingerprint: CaptureFingerprint; let firstObserved: Date }
    private func validInbox(_ url: URL) -> Bool { validFolder(url) }
    private func validFolder(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory) == true && (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && manager.isReadableFile(atPath: url.path) && manager.isWritableFile(atPath: url.path) }
    private func eligibleKind(_ url: URL) -> Kind? {
        guard !url.lastPathComponent.hasPrefix("."), manager.isReadableFile(atPath: url.path) else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
        if values.isRegularFile == true { return .file }; if values.isDirectory == true { return .directory }; return nil
    }
    private func fingerprint(_ url: URL, kind: Kind) -> CaptureFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
        return CaptureFingerprint(kind: kind, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
    }
    private static func timestampFormatter() -> ISO8601DateFormatter { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]; return formatter }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func atomicPublish(_ data: Data, preview: TypedNoteCapturePreview, namespace: TypedNoteInboxNamespace, runtime: TypedNotePublicationRuntime) throws -> URL {
        let temporaryName = ".capture-note-\(preview.operationFingerprint).tmp"
        do { try runtime.beforeTemporaryCreation(preview.operationFingerprint) }
        catch let typed as TypedNoteCaptureError { throw typed }
        catch { throw TypedNoteCaptureError.rejected("Quick Capture could not begin operation \(preview.operationFingerprint). No note content was emitted.") }
        let descriptor = temporaryName.withCString { openat(namespace.inboxDescriptor, $0, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600) }
        guard descriptor >= 0 else {
            if errno == EEXIST { throw TypedNoteCaptureError.recoveryRequired("Quick Capture operation \(preview.operationFingerprint) already has temporary residue. No payload was published and automatic retry is prohibited.") }
            throw TypedNoteCaptureError.rejected("Quick Capture could not create its temporary operation file (errno \(errno)).")
        }
        var published = false
        var descriptorOpen = true
        var temporaryExists = true
        var cleanupAttempted = false
        var cleanupProhibited = false
        var expectedFileIdentity: TypedNoteFileIdentity?
        do {
            let createdIdentity = try TypedNoteInboxNamespace.descriptorIdentity(descriptor)
            guard createdIdentity.isOwnedRegularFile else {
                cleanupProhibited = true
                throw TypedNoteCaptureError.namespaceUncertain(publicationIdentityDiagnostic(fingerprint: preview.operationFingerprint, stage: "temporary descriptor creation"))
            }
            expectedFileIdentity = createdIdentity
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw TypedNoteCaptureError.rejected("Quick Capture could not durably write operation \(preview.operationFingerprint) (errno \(errno)).") }
            try runtime.beforePublication(preview.operationFingerprint)

            let confirmed = try TypedNoteInboxNamespace.open(productionsRoot: URL(fileURLWithPath: preview.productionsRoot, isDirectory: true), acquireLock: false)
            guard namespace.state.hasSameNamespace(as: confirmed.state) else {
                cleanupAttempted = true
                let quarantineName = try quarantineTemporary(name: temporaryName, fingerprint: preview.operationFingerprint, expectedIdentity: createdIdentity, namespace: namespace, runtime: runtime)
                temporaryExists = false
                guard close(descriptor) == 0 else { throw TypedNoteCaptureError.recoveryRequired("Quick Capture operation \(preview.operationFingerprint) stopped before publication but its descriptor could not be closed (errno \(errno)). Inspect before retry.") }
                descriptorOpen = false
                throw TypedNoteCaptureError.recoveryRequired(quarantineDiagnostic(fingerprint: preview.operationFingerprint, quarantineName: quarantineName, reason: "the configured Inbox namespace changed before publication"))
            }
            guard try TypedNoteInboxNamespace.descriptorIdentity(descriptor) == createdIdentity,
                  try namespace.entryIdentity(temporaryName) == createdIdentity else {
                cleanupProhibited = true
                throw TypedNoteCaptureError.namespaceUncertain(publicationIdentityDiagnostic(fingerprint: preview.operationFingerprint, stage: "temporary source entry before publication"))
            }
            let result = temporaryName.withCString { source in
                preview.filename.withCString { target in renameatx_np(namespace.inboxDescriptor, source, confirmed.inboxDescriptor, target, UInt32(RENAME_EXCL)) }
            }
            if result != 0 {
                let savedErrno = errno
                cleanupAttempted = true
                let quarantineName = try quarantineTemporary(name: temporaryName, fingerprint: preview.operationFingerprint, expectedIdentity: createdIdentity, namespace: namespace, runtime: runtime)
                temporaryExists = false
                guard close(descriptor) == 0 else { throw TypedNoteCaptureError.recoveryRequired("Quick Capture operation \(preview.operationFingerprint) was not published but its descriptor could not be closed (errno \(errno)). Inspect before retry.") }
                descriptorOpen = false
                let reason = savedErrno == EEXIST ? "the final destination already existed" : "publication failed with errno \(savedErrno)"
                throw TypedNoteCaptureError.recoveryRequired(quarantineDiagnostic(fingerprint: preview.operationFingerprint, quarantineName: quarantineName, reason: reason))
            }
            published = true
            temporaryExists = false
            guard try confirmed.entryIdentity(preview.filename) == createdIdentity,
                  try TypedNoteInboxNamespace.descriptorIdentity(descriptor) == createdIdentity else {
                throw TypedNoteCaptureError.namespaceUncertain(publicationIdentityDiagnostic(fingerprint: preview.operationFingerprint, stage: "final entry immediately after publication"))
            }
            try runtime.afterPublication(preview.operationFingerprint)
            guard fsync(confirmed.inboxDescriptor) == 0 else { throw TypedNoteCaptureError.rejected("Quick Capture directory durability failed for operation \(preview.operationFingerprint) (errno \(errno)).") }
            let postPublication = try TypedNoteInboxNamespace.open(productionsRoot: URL(fileURLWithPath: preview.productionsRoot, isDirectory: true), acquireLock: false)
            guard confirmed.state.hasSameNamespace(as: postPublication.state) else {
                throw TypedNoteCaptureError.namespaceUncertain(namespaceUncertainDiagnostic(fingerprint: preview.operationFingerprint, opened: confirmed.state.inbox))
            }
            try verifyPublishedEntry(data, name: preview.filename, expectedIdentity: createdIdentity, namespace: confirmed, fingerprint: preview.operationFingerprint)
            guard try TypedNoteInboxNamespace.descriptorIdentity(descriptor) == createdIdentity else {
                throw TypedNoteCaptureError.namespaceUncertain(publicationIdentityDiagnostic(fingerprint: preview.operationFingerprint, stage: "descriptor after final entry verification"))
            }
            guard close(descriptor) == 0 else { throw TypedNoteCaptureError.rejected("Quick Capture payload close failed for operation \(preview.operationFingerprint) (errno \(errno)).") }
            descriptorOpen = false
            return URL(fileURLWithPath: preview.inboxPath, isDirectory: true).appending(path: preview.filename, directoryHint: .notDirectory)
        } catch {
            if descriptorOpen { _ = close(descriptor) }
            if published {
                let post = try? TypedNoteInboxNamespace.open(productionsRoot: URL(fileURLWithPath: preview.productionsRoot, isDirectory: true), acquireLock: false)
                if post == nil || !(post!.state.hasSameNamespace(as: namespace.state)) {
                    throw TypedNoteCaptureError.namespaceUncertain(namespaceUncertainDiagnostic(fingerprint: preview.operationFingerprint, opened: namespace.state.inbox))
                }
                if let typed = error as? TypedNoteCaptureError, case .namespaceUncertain = typed { throw typed }
                if let expectedFileIdentity {
                    do {
                        try verifyPublishedEntry(data, name: preview.filename, expectedIdentity: expectedFileIdentity, namespace: post!, fingerprint: preview.operationFingerprint)
                    } catch let typed as TypedNoteCaptureError {
                        if case .namespaceUncertain = typed { throw typed }
                    } catch {}
                } else {
                    throw TypedNoteCaptureError.namespaceUncertain(publicationIdentityDiagnostic(fingerprint: preview.operationFingerprint, stage: "published entry recovery verification"))
                }
                throw TypedNoteCaptureError.verificationFailed("Quick Capture operation \(preview.operationFingerprint) was published at \(preview.inboxPath)/\(preview.filename), but durable post-write verification did not complete. Inspect that exact payload before recovery; do not retry automatically.")
            }
            if temporaryExists && !cleanupAttempted && !cleanupProhibited, let expectedFileIdentity {
                cleanupAttempted = true
                do {
                    let quarantineName = try quarantineTemporary(name: temporaryName, fingerprint: preview.operationFingerprint, expectedIdentity: expectedFileIdentity, namespace: namespace, runtime: runtime)
                    throw TypedNoteCaptureError.recoveryRequired(quarantineDiagnostic(fingerprint: preview.operationFingerprint, quarantineName: quarantineName, reason: "the operation stopped before publication"))
                } catch { throw error }
            }
            if let typed = error as? TypedNoteCaptureError { throw typed }
            throw TypedNoteCaptureError.rejected("Quick Capture stopped before publication for operation \(preview.operationFingerprint). No note content was emitted.")
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let result = write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if result < 0, errno == EINTR { continue }
                guard result > 0 else { throw TypedNoteCaptureError.rejected("Quick Capture temporary write failed (errno \(errno)).") }
                offset += result
            }
        }
    }

    private static func verify(_ expected: Data, descriptor: Int32, fingerprint: String) throws {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else { throw TypedNoteCaptureError.rejected("Quick Capture verification seek failed for operation \(fingerprint) (errno \(errno)).") }
        var actual = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TypedNoteCaptureError.rejected("Quick Capture verification read failed for operation \(fingerprint) (errno \(errno)).") }
            if count == 0 { break }
            actual.append(contentsOf: buffer.prefix(count))
        }
        guard actual == expected else { throw TypedNoteCaptureError.rejected("Quick Capture verification mismatch for operation \(fingerprint).") }
    }

    private static func verifyPublishedEntry(_ expected: Data, name: String, expectedIdentity: TypedNoteFileIdentity, namespace: TypedNoteInboxNamespace, fingerprint: String) throws {
        let descriptor = name.withCString { openat(namespace.inboxDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            throw TypedNoteCaptureError.namespaceUncertain(publicationIdentityDiagnostic(fingerprint: fingerprint, stage: "final entry open after publication"))
        }
        var descriptorOpen = true
        do {
            guard try TypedNoteInboxNamespace.descriptorIdentity(descriptor) == expectedIdentity,
                  try namespace.entryIdentity(name) == expectedIdentity else {
                throw TypedNoteCaptureError.namespaceUncertain(publicationIdentityDiagnostic(fingerprint: fingerprint, stage: "final entry identity after publication"))
            }
            try verify(expected, descriptor: descriptor, fingerprint: fingerprint)
            guard try TypedNoteInboxNamespace.descriptorIdentity(descriptor) == expectedIdentity,
                  try namespace.entryIdentity(name) == expectedIdentity else {
                throw TypedNoteCaptureError.namespaceUncertain(publicationIdentityDiagnostic(fingerprint: fingerprint, stage: "final entry identity after byte verification"))
            }
            guard close(descriptor) == 0 else { throw TypedNoteCaptureError.rejected("Quick Capture final entry close failed for operation \(fingerprint) (errno \(errno)).") }
            descriptorOpen = false
        } catch {
            if descriptorOpen { _ = close(descriptor) }
            throw error
        }
    }

    private static func quarantineTemporary(name: String, fingerprint: String, expectedIdentity: TypedNoteFileIdentity, namespace: TypedNoteInboxNamespace, runtime: TypedNotePublicationRuntime) throws -> String {
        guard let liveIdentity = try namespace.entryIdentity(name), liveIdentity == expectedIdentity, liveIdentity.isOwnedRegularFile else {
            throw TypedNoteCaptureError.namespaceUncertain(publicationIdentityDiagnostic(fingerprint: fingerprint, stage: "temporary cleanup entry"))
        }
        do { try runtime.afterCleanupValidation(fingerprint) }
        catch let typed as TypedNoteCaptureError { throw typed }
        catch {
            throw TypedNoteCaptureError.namespaceUncertain("Quick Capture operation \(fingerprint) was interrupted after cleanup identity validation. The entry was not deleted; preserve it for manual recovery and do not retry automatically; automatic retry is prohibited.")
        }
        guard runtime.cleanupTransitionGate(namespace.inboxDescriptor, name) == 0 else {
            throw TypedNoteCaptureError.recoveryRequired("Quick Capture cleanup transition failed for operation \(fingerprint) (errno \(errno)). The entry was not deleted; preserve it for manual recovery and do not retry automatically; automatic retry is prohibited.")
        }
        let quarantineName = ".quick-capture-quarantine-\(fingerprint)-\(expectedIdentity.device)-\(expectedIdentity.inode)"
        let renameResult = name.withCString { source in
            quarantineName.withCString { destination in
                renameatx_np(namespace.inboxDescriptor, source, namespace.inboxDescriptor, destination, UInt32(RENAME_EXCL))
            }
        }
        guard renameResult == 0 else {
            throw TypedNoteCaptureError.namespaceUncertain("Quick Capture operation \(fingerprint) could not move its validated entry into operation-owned quarantine (errno \(errno)). Nothing was deleted; preserve the encountered entries for manual recovery and do not retry automatically; automatic retry is prohibited.")
        }
        guard let quarantinedIdentity = try namespace.entryIdentity(quarantineName), quarantinedIdentity == expectedIdentity else {
            let restoreResult = quarantineName.withCString { source in
                name.withCString { destination in
                    renameatx_np(namespace.inboxDescriptor, source, namespace.inboxDescriptor, destination, UInt32(RENAME_EXCL))
                }
            }
            let preservation = restoreResult == 0 ? "The replacement was restored to its encountered name." : "The replacement remains preserved as \(quarantineName) because restoration failed with errno \(errno)."
            throw TypedNoteCaptureError.namespaceUncertain("Quick Capture operation \(fingerprint) encountered a post-validation replacement during cleanup. \(preservation) Nothing was deleted; inspect manually and do not retry automatically; automatic retry is prohibited.")
        }
        guard fsync(namespace.inboxDescriptor) == 0 else {
            throw TypedNoteCaptureError.recoveryRequired("Quick Capture operation \(fingerprint) was quarantined as \(quarantineName), but quarantine durability failed (errno \(errno)). Nothing was deleted; inspect manually and do not retry automatically; automatic retry is prohibited.")
        }
        return quarantineName
    }

    private static func recoveryDiagnostic(preview: TypedNoteCapturePreview, prefix: String) -> String {
        "\(prefix) Operation \(preview.operationFingerprint); recognized residue operations: \(preview.temporaryResidueOperationFingerprints.joined(separator: ", ")); unsafe residue count: \(preview.unsafeTemporaryResidueCount). No payload was published and automatic retry is prohibited."
    }

    private static func namespaceUncertainDiagnostic(fingerprint: String, opened: TypedNoteDirectoryIdentity) -> String {
        "Quick Capture operation \(fingerprint) published into opened Inbox identity \(opened.device):\(opened.inode), but the configured namespace changed before outcome confirmation. No reliable pathname can be reported. Inspect that operation before recovery; automatic retry is prohibited."
    }

    private static func publicationIdentityDiagnostic(fingerprint: String, stage: String) -> String {
        "Quick Capture operation \(fingerprint) lost exact regular-file inode/type/ownership binding at \(stage). No reliable pathname can be reported; preserve the encountered entries for recovery and do not retry automatically."
    }

    private static func residueIdentityDiagnostic(fingerprint: String, removedCount: Int, reason: String) -> String {
        "Quick Capture residue operation \(fingerprint) was not quarantined because \(reason) after \(removedCount) prior quarantine(s). Preserve the encountered entry for recovery; automatic retry is prohibited."
    }

    private static func quarantineDiagnostic(fingerprint: String, quarantineName: String, reason: String) -> String {
        "Quick Capture operation \(fingerprint) was not published because \(reason). Its exact temporary inode was preserved as \(quarantineName); nothing was deleted. Inspect manually and do not retry automatically; automatic retry is prohibited."
    }
}


/// App/ViewModel-owned lifecycle for the configured automatic source. It
/// continues after the capture sheet closes and owns exactly one polling task.
@MainActor
final class ProductionsAutomaticCaptureMonitor: ObservableObject {
    @Published private(set) var sourcePath: String
    @Published private(set) var latestOutcome: ProductionsInboxCaptureOutcome?
    private var service: ProductionsInboxCaptureService
    private var pollingTask: Task<Void, Never>?
    private var rootPath = ""
    private let storage: UserDefaults
    private let pollInterval: Duration
    static let sourceKey = AutomaticCaptureContext.preferencesSourceKey

    init(storage: UserDefaults = UserDefaults(suiteName: AutomaticCaptureContext.preferencesSuiteName)!, pollInterval: Duration = .seconds(2), service: ProductionsInboxCaptureService = ProductionsInboxCaptureService()) {
        self.storage = storage; self.pollInterval = pollInterval; self.service = service
        sourcePath = storage.string(forKey: Self.sourceKey) ?? ""
    }
    var isMonitoring: Bool { pollingTask != nil }
    func start(productionsRootPath: String) {
        rootPath = productionsRootPath
        guard !sourcePath.isEmpty, !rootPath.isEmpty, pollingTask == nil else { return }
        let interval = pollInterval
        pollingTask = Task { [weak self, interval] in
            while !Task.isCancelled {
                guard self != nil else { return }
                self?.observeNow()
                try? await Task.sleep(for: interval)
            }
        }
    }
    func configure(source: URL, productionsRootPath: String) {
        stop(); rootPath = productionsRootPath; sourcePath = source.standardizedFileURL.path
        storage.set(sourcePath, forKey: Self.sourceKey)
        latestOutcome = nil
        start(productionsRootPath: productionsRootPath)
    }
    func observeNow() {
        guard !sourcePath.isEmpty, !rootPath.isEmpty else { return }
        let outcomes = service.observeAutomatic(sourceFolder: URL(fileURLWithPath: sourcePath, isDirectory: true), productionsRoot: URL(fileURLWithPath: rootPath, isDirectory: true))
        latestOutcome = outcomes.last
    }
    func stop() { pollingTask?.cancel(); pollingTask = nil }
    deinit { pollingTask?.cancel() }
}

/// Thin TASK-0043 UI: all copying, typed-note creation, and stability checks
/// live in ProductionsInboxCaptureService and never call Flow registration.
struct ProductionsInboxCaptureFeedback: Equatable {
    let message: String
    let accessibilityAnnouncement: String
    let succeeded: Bool
    let published: Bool
}

@MainActor
struct ProductionsInboxCaptureFeedbackPresenter {
    let announce: (String) -> Void

    static let live = ProductionsInboxCaptureFeedbackPresenter { message in
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    func present(_ outcome: ProductionsInboxCaptureOutcome, operationName: String = "Quick Capture") -> ProductionsInboxCaptureFeedback {
        let feedback: ProductionsInboxCaptureFeedback
        switch outcome {
        case let .captured(url):
            feedback = .init(message: "Captured \(url.lastPathComponent).", accessibilityAnnouncement: "\(operationName) succeeded. Captured \(url.lastPathComponent) as an unregistered Inbox payload.", succeeded: true, published: true)
        case let .verificationRequired(reason):
            feedback = .init(message: reason, accessibilityAnnouncement: "\(operationName) needs recovery review. \(reason)", succeeded: false, published: true)
        case let .deferred(reason):
            feedback = .init(message: reason, accessibilityAnnouncement: "\(operationName) deferred. \(reason)", succeeded: false, published: false)
        case let .rejected(reason):
            feedback = .init(message: reason, accessibilityAnnouncement: "\(operationName) failed. \(reason)", succeeded: false, published: false)
        }
        announce(feedback.accessibilityAnnouncement)
        return feedback
    }
}

@MainActor
struct ProductionsInboxCaptureSheet: View {
    let rootPath: String
    @ObservedObject var monitor: ProductionsAutomaticCaptureMonitor
    let feedbackPresenter: ProductionsInboxCaptureFeedbackPresenter
    @Environment(\.dismiss) private var dismiss
    @State private var service = ProductionsInboxCaptureService()
    @State private var note = ""
    @State private var feedback: ProductionsInboxCaptureFeedback?

    init(rootPath: String, monitor: ProductionsAutomaticCaptureMonitor, feedbackPresenter: ProductionsInboxCaptureFeedbackPresenter = .live) {
        self.rootPath = rootPath; self.monitor = monitor; self.feedbackPresenter = feedbackPresenter
    }

    private var root: URL { URL(fileURLWithPath: rootPath, isDirectory: true) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add to Inbox").font(.title2)
            Text("Capture creates an Inbox payload only. Flow registration happens separately after it arrives.").foregroundStyle(.secondary)
            GroupBox("File or folder") {
                HStack { Button("Choose and Copy…", action: copyManual); Spacer() }
            }
            GroupBox("Quick Capture") {
                TextEditor(text: $note).frame(minHeight: 100)
                HStack { Spacer(); Button("Save Note") { report(service.createTypedNote(text: note, productionsRoot: root)) }.disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
            GroupBox("Automatic capture folder") {
                Text(monitor.sourcePath.isEmpty ? "No folder configured." : monitor.sourcePath).font(.caption).textSelection(.enabled)
                HStack {
                    Button("Choose Folder…", action: chooseAutomaticFolder)
                    Button("Check Now", action: monitor.observeNow).disabled(monitor.sourcePath.isEmpty)
                }
                Text(monitor.isMonitoring ? "Monitoring continues while the dashboard is open." : "Monitoring starts when a folder is configured and the dashboard is open.").font(.caption).foregroundStyle(.secondary)
                Text("Eligible immediate items are moved only after two unchanged observations. Conflicts remain in the source folder.").font(.caption).foregroundStyle(.secondary)
            }
            if let outcome = monitor.latestOutcome { outcomeText(outcome) }
            if let feedback {
                Text(feedback.message)
                    .foregroundStyle(feedback.succeeded ? .green : .orange)
                    .textSelection(.enabled)
                    .accessibilityLabel(feedback.accessibilityAnnouncement)
            }
            HStack { Spacer(); Button("Done") { dismiss() } }
        }
        .padding().frame(minWidth: 620, minHeight: 460)
    }
    private func copyManual() { let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Copy to Inbox"; guard panel.runModal() == .OK, let source = panel.url else { return }; report(service.copyManual(source: source, productionsRoot: root), operationName: "Inbox copy") }
    private func chooseAutomaticFolder() { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Use Capture Folder"; guard panel.runModal() == .OK, let source = panel.url else { return }; monitor.configure(source: source, productionsRootPath: rootPath) }
    @ViewBuilder private func outcomeText(_ outcome: ProductionsInboxCaptureOutcome) -> some View {
        switch outcome {
        case let .captured(url): Text("Captured \(url.lastPathComponent). ").foregroundStyle(.green)
        case let .verificationRequired(reason), let .deferred(reason), let .rejected(reason): Text(reason).foregroundStyle(.orange)
        }
    }
    private func report(_ outcome: ProductionsInboxCaptureOutcome, operationName: String = "Quick Capture") {
        feedback = feedbackPresenter.present(outcome, operationName: operationName)
        if feedback?.published == true { note = "" }
    }
}
