import AppKit
import Foundation

enum SourceAction: CaseIterable, Identifiable, Hashable {
    case productFolder
    case inboxFolder
    case statusRecord

    var id: Self { self }

    var title: String {
        switch self {
        case .productFolder: "Open Product Folder"
        case .inboxFolder: "Open Inbox Folder"
        case .statusRecord: "Open Status Record"
        }
    }

    var roleLabel: String {
        switch self {
        case .productFolder: "Product root"
        case .inboxFolder: "Inbox"
        case .statusRecord: "Status record"
        }
    }

    func targetURL(for product: ConfiguredProduct) -> URL {
        switch self {
        case .productFolder:
            URL(fileURLWithPath: product.productRootPath, isDirectory: true)
        case .inboxFolder:
            product.resolved(product.inboxRelativePath)
        case .statusRecord:
            product.resolved(product.statusRecordRelativePath)
        }
    }
}

enum SourceOpenError: LocalizedError, Equatable {
    case failedToOpen(String)

    var errorDescription: String? {
        switch self {
        case let .failedToOpen(name): "Could not open \(name)."
        }
    }
}

protocol SourceOpening {
    func open(_ url: URL) throws
}

enum StatusListDisplay {
    static func items(_ items: [String]) -> [String] {
        items.isEmpty ? ["None"] : items
    }
}

struct WorkspaceSourceOpener: SourceOpening {
    func open(_ url: URL) throws {
        guard NSWorkspace.shared.open(url) else {
            throw SourceOpenError.failedToOpen(url.lastPathComponent)
        }
    }
}
