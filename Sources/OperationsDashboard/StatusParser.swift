import Foundation

enum StatusParseError: LocalizedError, Equatable {
    case invalidUTF8
    case missingHeader
    case invalidMetadata(String)
    case duplicateField(String)
    case invalidListItem(String)

    var errorDescription: String? {
        switch self {
        case .invalidUTF8: "Status record is not valid UTF-8."
        case .missingHeader: "First non-empty line must be '# Status'."
        case let .invalidMetadata(message), let .invalidListItem(message): message
        case let .duplicateField(field): "Duplicate supported field: \(field)."
        }
    }
}

struct StatusParser {
    private func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return date
    }

    func parse(data: Data, sourceModificationDate: Date? = nil) throws -> OperatingStatus {
        guard let text = String(data: data, encoding: .utf8) else { throw StatusParseError.invalidUTF8 }
        var lines = text.components(separatedBy: .newlines)
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { lines.removeFirst() }
        guard lines.first == "# Status" else { throw StatusParseError.missingHeader }

        var status: String?
        var lastUpdated: Date?
        var nextActions: [String] = []
        var blockers: [String] = []
        var activeList: ListKind?
        var hasSeenHeading = false
        var headings = Set<String>()

        for rawLine in lines.dropFirst() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                hasSeenHeading = true
                activeList = nil
                switch line {
                case "## Next actions", "## Blockers":
                    guard headings.insert(line).inserted else { throw StatusParseError.duplicateField(line) }
                    activeList = line == "## Next actions" ? .nextActions : .blockers
                default:
                    break
                }
                continue
            }

            if !hasSeenHeading {
                if line.isEmpty { continue }
                if line.hasPrefix("Status: ") {
                    guard status == nil else { throw StatusParseError.duplicateField("Status") }
                    let value = String(line.dropFirst("Status: ".count))
                    guard !value.isEmpty else { throw StatusParseError.invalidMetadata("Status must not be empty.") }
                    status = value
                } else if line.hasPrefix("Last updated: ") {
                    guard lastUpdated == nil else { throw StatusParseError.duplicateField("Last updated") }
                    let value = String(line.dropFirst("Last updated: ".count))
                    guard let parsed = date(from: value) else {
                        throw StatusParseError.invalidMetadata("Last updated must use YYYY-MM-DD.")
                    }
                    lastUpdated = parsed
                } else {
                    throw StatusParseError.invalidMetadata("Unexpected metadata content: \(line)")
                }
            } else if let activeList, !line.isEmpty {
                guard line.hasPrefix("- ") else { throw StatusParseError.invalidListItem("List items must begin with '- '.") }
                let value = String(line.dropFirst(2))
                guard !value.isEmpty else { throw StatusParseError.invalidListItem("List items must not be empty.") }
                switch activeList {
                case .nextActions: nextActions.append(value)
                case .blockers: blockers.append(value)
                }
            }
        }

        guard let status else { throw StatusParseError.invalidMetadata("Missing Status field.") }
        guard let lastUpdated else { throw StatusParseError.invalidMetadata("Missing Last updated field.") }
        return OperatingStatus(currentStatus: status, nextActions: nextActions, blockers: blockers, lastUpdated: lastUpdated, sourceModificationDate: sourceModificationDate)
    }

    private enum ListKind { case nextActions, blockers }
}
