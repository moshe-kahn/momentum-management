import Darwin
import Foundation

/// Automatic Inbox intake observes an eligible payload twice before issuing an
/// ID. A payload is quiescent only when its kind, inode, byte size, and mtime
/// are identical across observations separated by `quiescenceInterval`.
struct InboxIntakeResult: Identifiable, Equatable {
    enum Outcome: Equatable { case deferred, registered(String), problem, investigationRequired, suspended }
    let payloadPath: String
    let outcome: Outcome
    let reason: String
    var id: String { payloadPath }
}

final class InboxAutomaticIntake {
    private struct Fingerprint: Equatable {
        let kind, inode, size, modifiedSeconds, modifiedNanoseconds: Int64
    }
    private struct Observation { let fingerprint: Fingerprint; let observedAt: Date }

    private var observations: [String: Observation] = [:]
    private var terminalProblems: [String: String] = [:]
    private let registration: FlowRegistrationService
    private let manager: FileManager
    private let now: () -> Date
    let quiescenceInterval: TimeInterval

    init(registration: FlowRegistrationService = FlowRegistrationService(), manager: FileManager = .default, quiescenceInterval: TimeInterval = 2, now: @escaping () -> Date = Date.init) {
        self.registration = registration
        self.manager = manager
        self.quiescenceInterval = quiescenceInterval
        self.now = now
    }

    /// Call from startup, refresh, and filesystem watcher notifications. New
    /// payloads are always deferred until a later unchanged observation.
    func scan(configuration: ProductionsConfiguration, candidates: [FlowItem], reload: (ProductionsConfiguration) -> ProductionsState) -> [InboxIntakeResult] {
        process(configuration: configuration, candidates: candidates, reload: reload, forcePaths: [])
    }

    func retry(configuration: ProductionsConfiguration, payload: FlowItem, reload: (ProductionsConfiguration) -> ProductionsState) -> InboxIntakeResult {
        terminalProblems.removeValue(forKey: payload.location)
        return process(configuration: configuration, candidates: [payload], reload: reload, forcePaths: [payload.location]).first ?? InboxIntakeResult(payloadPath: payload.location, outcome: .problem, reason: "Payload is unavailable.")
    }

    private func process(configuration: ProductionsConfiguration, candidates: [FlowItem], reload: (ProductionsConfiguration) -> ProductionsState, forcePaths: Set<String>) -> [InboxIntakeResult] {
        var results: [InboxIntakeResult] = []
        for payload in candidates.filter(\.isUnregistered).sorted(by: { $0.location.localizedStandardCompare($1.location) == .orderedAscending }) {
            if let reason = terminalProblems[payload.location] {
                results.append(InboxIntakeResult(payloadPath: payload.location, outcome: .investigationRequired, reason: reason))
                continue
            }
            let snapshot: Fingerprint
            do { snapshot = try fingerprint(configuration: configuration, payload: payload) }
            catch { results.append(InboxIntakeResult(payloadPath: payload.location, outcome: .problem, reason: error.localizedDescription)); continue }
            let timestamp = now()
            if !forcePaths.contains(payload.location) {
                guard let previous = observations[payload.location], previous.fingerprint == snapshot, timestamp.timeIntervalSince(previous.observedAt) >= quiescenceInterval else {
                    observations[payload.location] = Observation(fingerprint: snapshot, observedAt: timestamp)
                    results.append(InboxIntakeResult(payloadPath: payload.location, outcome: .deferred, reason: "Waiting for the payload to remain unchanged for \(Int(quiescenceInterval)) seconds."))
                    continue
                }
            }
            do {
                let metadata = try registration.automaticDefaults(configuration: configuration, payload: payload)
                let preview = try registration.preview(configuration: configuration, payload: payload, metadata: metadata)
                try registration.commit(configuration: configuration, payload: payload, metadata: metadata, preview: preview, reload: reload)
                observations.removeValue(forKey: payload.location)
                results.append(InboxIntakeResult(payloadPath: payload.location, outcome: .registered(preview.flowID), reason: "Registered automatically."))
            } catch let error as FlowRegistrationError {
                let message = error.localizedDescription
                switch error {
                case .lockUnavailable, .conflict, .invalidMetadata:
                    results.append(InboxIntakeResult(payloadPath: payload.location, outcome: .suspended, reason: message))
                    return results // shared-contract conflict: do not mutate later payloads
                case .flowWriteFailed, .reloadFailed:
                    terminalProblems[payload.location] = message
                    results.append(InboxIntakeResult(payloadPath: payload.location, outcome: .investigationRequired, reason: message))
                default:
                    results.append(InboxIntakeResult(payloadPath: payload.location, outcome: .problem, reason: message))
                }
            } catch {
                results.append(InboxIntakeResult(payloadPath: payload.location, outcome: .problem, reason: error.localizedDescription))
            }
        }
        return results
    }

    private func fingerprint(configuration: ProductionsConfiguration, payload: FlowItem) throws -> Fingerprint {
        guard payload.isUnregistered, payload.stage == "Inbox", payload.location.hasPrefix("Office/Inbox/") else { throw FlowRegistrationError.ineligible("Only Unregistered Inbox payloads can be registered.") }
        let name = String(payload.location.dropFirst("Office/Inbox/".count))
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { throw FlowRegistrationError.ineligible("Hidden or nested Inbox payloads cannot be registered.") }
        let url = configuration.rootURL.appending(path: payload.location)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw FlowRegistrationError.ineligible("Inbox payload no longer exists.") }
        let kind = info.st_mode & S_IFMT
        guard kind != S_IFLNK else { throw FlowRegistrationError.ineligible("Inbox symlinks cannot be registered.") }
        guard kind == S_IFREG || kind == S_IFDIR else { throw FlowRegistrationError.ineligible("Inbox payload has an unsupported filesystem type.") }
        return Fingerprint(kind: Int64(kind), inode: Int64(info.st_ino), size: Int64(info.st_size), modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
}
