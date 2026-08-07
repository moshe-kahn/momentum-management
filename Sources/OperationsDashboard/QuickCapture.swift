import Foundation

protocol QuickCaptureFileSystem {
    func exists(at url: URL) -> Bool
    func isReadable(at url: URL) -> Bool
    func isWritable(at url: URL) -> Bool
    func isDirectory(at url: URL) throws -> Bool
    func isSymbolicLink(at url: URL) throws -> Bool
    func createNewFile(at url: URL, contents: Data) throws
}

struct LocalQuickCaptureFileSystem: QuickCaptureFileSystem {
    private let manager = FileManager.default

    func exists(at url: URL) -> Bool { manager.fileExists(atPath: url.path) }
    func isReadable(at url: URL) -> Bool { manager.isReadableFile(atPath: url.path) }
    func isWritable(at url: URL) -> Bool { manager.isWritableFile(atPath: url.path) }
    func isDirectory(at url: URL) throws -> Bool { try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
    func isSymbolicLink(at url: URL) throws -> Bool { try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true }

    func createNewFile(at url: URL, contents: Data) throws {
        try contents.write(to: url, options: .withoutOverwriting)
    }
}

enum QuickCaptureFailure: Equatable, Sendable {
    case invalidText
    case destinationUnavailable
    case collisionExhausted
    case permissionDenied
    case writeFailed
    case configurationInvalid
}

enum QuickCaptureResult: Equatable, Sendable {
    case success(path: URL)
    case failure(QuickCaptureFailure, diagnostic: String)
}

protocol QuickCaptureWriting {
    func create(text: String, configuration: CaptureConfiguration, now: Date) -> QuickCaptureResult
}

struct QuickCaptureWriter: QuickCaptureWriting {
    static let maximumCollisionAttempts = 100
    let fileSystem: any QuickCaptureFileSystem

    init(fileSystem: any QuickCaptureFileSystem = LocalQuickCaptureFileSystem()) {
        self.fileSystem = fileSystem
    }

    func create(text: String, configuration: CaptureConfiguration, now: Date = Date()) -> QuickCaptureResult {
        guard Self.isValid(text: text) else {
            return .failure(.invalidText, diagnostic: "Enter non-whitespace Quick Capture text.")
        }

        let validated: CaptureConfiguration
        do {
            validated = try configuration.validated()
        } catch {
            return .failure(.configurationInvalid, diagnostic: error.localizedDescription)
        }

        let destination = validated.enterpriseInboxURL.standardizedFileURL
        guard isAvailableDestination(destination) else {
            return .failure(.destinationUnavailable, diagnostic: "Enterprise Inbox destination is unavailable.")
        }

        let contents = markdown(text: text, now: now)
        guard let data = contents.data(using: .utf8) else {
            return .failure(.writeFailed, diagnostic: "Quick Capture text could not be encoded as UTF-8.")
        }

        for attempt in 1...Self.maximumCollisionAttempts {
            let candidate = destination.appending(path: filename(now: now, attempt: attempt), directoryHint: .notDirectory)
            guard !fileSystem.exists(at: candidate) else { continue }
            do {
                try fileSystem.createNewFile(at: candidate, contents: data)
                return .success(path: candidate)
            } catch {
                if fileSystem.exists(at: candidate) { continue }
                return .failure(isPermissionError(error) ? .permissionDenied : .writeFailed, diagnostic: error.localizedDescription)
            }
        }

        return .failure(.collisionExhausted, diagnostic: "No collision-safe Quick Capture filename was available.")
    }

    static func isValid(text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func filename(now: Date, attempt: Int) -> String {
        let suffix = attempt == 1 ? "" : " (\(attempt))"
        return "Quick Capture \(Self.filenameTimestamp.string(from: now))\(suffix).md"
    }

    func markdown(text: String, now: Date) -> String {
        let body = text.hasSuffix("\n") ? text : "\(text)\n"
        return "# Quick Capture\n\nCreated: \(Self.metadataTimestamp.string(from: now))\nSource: Operations Dashboard / Quick Capture\n\n\(body)"
    }

    private func isAvailableDestination(_ url: URL) -> Bool {
        guard fileSystem.exists(at: url), fileSystem.isReadable(at: url), fileSystem.isWritable(at: url) else { return false }
        do {
            return try fileSystem.isDirectory(at: url) && !(try fileSystem.isSymbolicLink(at: url))
        } catch {
            return false
        }
    }

    private func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code)
    }

    private static let filenameTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    private static let metadataTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }()
}
