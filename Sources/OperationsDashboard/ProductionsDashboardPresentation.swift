import Foundation

enum ProductionsNavigationGroup: String, CaseIterable, Identifiable {
    case intake = "Intake"
    case focus = "Focus"
    case browse = "Browse"

    var id: Self { self }
}

enum ProductionsNavigationSection: String, CaseIterable, Identifiable {
    case inbox
    case processing
    case canvas
    case crumbs
    case mementos
    case priorityWork
    case workItems
    case plans

    var id: Self { self }

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .processing: "Processing"
        case .canvas: "Canvas"
        case .crumbs: "Crumbs"
        case .mementos: "Mementos"
        case .priorityWork: "Priority Work"
        case .workItems: "Work Items"
        case .plans: "Plans"
        }
    }

    var emptyTitle: String {
        switch self {
        case .inbox: "Inbox is empty"
        case .processing: "No processing bundles"
        case .canvas: "Canvas is empty"
        case .crumbs: "No open Crumbs"
        case .mementos: "No current Mementos"
        case .priorityWork: "No Highest or High priority work"
        case .workItems: "No Tasks or Ideas"
        case .plans: "No Projects, Initiatives, or Products"
        }
    }

    var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .processing: "shippingbox"
        case .canvas: "rectangle.on.rectangle"
        case .crumbs: "circle.grid.3x3"
        case .mementos: "bookmark"
        case .priorityWork: "flag.fill"
        case .workItems: "checklist"
        case .plans: "map"
        }
    }

    var group: ProductionsNavigationGroup {
        switch self {
        case .inbox, .processing: .intake
        case .canvas, .crumbs, .mementos, .priorityWork: .focus
        case .workItems, .plans: .browse
        }
    }
}

struct ProductionsDepartmentFilter: Identifiable, Hashable {
    static let all = ProductionsDepartmentFilter(department: nil)
    let department: String?

    var id: String { department.map { "department:\($0)" } ?? "all-departments" }
    var title: String { department ?? "All Departments" }
}

struct ProductionsNavigationItem: Identifiable, Equatable {
    let id: String
    let targetID: String
    let title: String
    let subtitle: String
    let metadata: [String]
    let department: String?

    var searchableText: String {
        ([targetID, title, subtitle] + metadata).joined(separator: " ").localizedLowercase
    }
}

struct ProductionsSelection: Equatable {
    let rowID: String
    let targetID: String
}

enum ProductionsDashboardPresentation {
    static func sections(in group: ProductionsNavigationGroup) -> [ProductionsNavigationSection] {
        ProductionsNavigationSection.allCases.filter { $0.group == group }
    }

    static func departmentFilters(in state: ProductionsState) -> [ProductionsDepartmentFilter] {
        var seen = Set<String>()
        let canonical = state.departments.compactMap { record -> ProductionsDepartmentFilter? in
            let name = normalizedDepartment(record.name)
            guard let name, seen.insert(name).inserted else { return nil }
            return ProductionsDepartmentFilter(department: name)
        }
        return [.all] + canonical
    }

    static func count(for section: ProductionsNavigationSection, in state: ProductionsState, departmentFilter: ProductionsDepartmentFilter = .all) -> Int {
        items(for: section, in: state, departmentFilter: departmentFilter).count
    }

    static func items(for section: ProductionsNavigationSection, in state: ProductionsState, departmentFilter: ProductionsDepartmentFilter = .all) -> [ProductionsNavigationItem] {
        let unfiltered: [ProductionsNavigationItem] = switch section {
        case .inbox:
            state.inbox.map { item in
                ProductionsNavigationItem(
                    id: "inbox:\(item.id)",
                    targetID: item.id,
                    title: "\(item.flowID ?? "Unregistered") · \(item.label)",
                    subtitle: item.summary,
                    metadata: item.isUnregistered ? ["Unregistered", "Unknown department"] : [item.type, item.priority, departmentLabel(item.department)],
                    department: normalizedDepartment(item.department)
                )
            }
        case .processing:
            state.processing.map { item in
                ProductionsNavigationItem(
                    id: "processing:\(item.id)",
                    targetID: item.id,
                    title: "\(item.flowID ?? "Processing") · \(item.label)",
                    subtitle: item.summary,
                    metadata: [item.type, item.priority, departmentLabel(item.department)],
                    department: normalizedDepartment(item.department)
                )
            }
        case .canvas:
            workItems(state.work.filter { state.canvasCurrentIDs.contains($0.id) }, prefix: "canvas", state: state)
        case .crumbs:
            state.crumbs.map { crumb in
                let department = targetDepartment(crumb.target, in: state)
                return ProductionsNavigationItem(
                    id: "crumb:\(crumb.id)",
                    targetID: crumb.target,
                    title: "\(crumb.id) · \(crumb.summary)",
                    subtitle: "Target: \(crumb.target)",
                    metadata: [crumb.kind, crumb.priority, departmentLabel(department)],
                    department: department
                )
            }
        case .mementos:
            state.mementos.map { memento in
                let department = targetDepartment(memento.target, in: state)
                return ProductionsNavigationItem(
                    id: "memento:\(memento.id)",
                    targetID: memento.target,
                    title: "\(memento.id) · \(memento.summary)",
                    subtitle: memento.resumePoint,
                    metadata: ["Target: \(memento.target)", departmentLabel(department)],
                    department: department
                )
            }
        case .priorityWork:
            workItems(state.work.filter { !isDone($0) && ["Highest", "High"].contains($0.priority) }, prefix: "priority", state: state)
        case .workItems:
            workItems(state.work.filter { $0.kind == .task || $0.kind == .idea }, prefix: "work-item", state: state)
        case .plans:
            workItems(state.work.filter { $0.kind == .project || $0.kind == .initiative }, prefix: "plan", state: state) + state.products.map { product in
                ProductionsNavigationItem(
                    id: "product:\(product.id)",
                    targetID: product.id,
                    title: "\(product.id) · \(product.name)",
                    subtitle: product.canonicalWorkspace,
                    metadata: ["Product", product.lifecycle, "Department not provided"],
                    department: nil
                )
            }
        }
        guard let department = departmentFilter.department else { return unfiltered }
        return unfiltered.filter { $0.department == department }
    }

    static func filteredItems(
        for section: ProductionsNavigationSection,
        in state: ProductionsState,
        departmentFilter: ProductionsDepartmentFilter = .all,
        searchText: String
    ) -> [ProductionsNavigationItem] {
        let items = items(for: section, in: state, departmentFilter: departmentFilter)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return items }
        return items.filter { $0.searchableText.contains(query) }
    }

    static func reconciledSelection(
        currentTargetID: String?,
        currentRowID: String?,
        section: ProductionsNavigationSection,
        state: ProductionsState,
        departmentFilter: ProductionsDepartmentFilter = .all,
        searchText: String = ""
    ) -> ProductionsSelection? {
        let visibleItems = filteredItems(for: section, in: state, departmentFilter: departmentFilter, searchText: searchText)
        if let currentRowID,
           let row = visibleItems.first(where: { $0.id == currentRowID && $0.targetID == currentTargetID }) {
            return ProductionsSelection(rowID: row.id, targetID: row.targetID)
        }
        if let currentTargetID, let row = visibleItems.first(where: { $0.targetID == currentTargetID }) {
            return ProductionsSelection(rowID: row.id, targetID: row.targetID)
        }
        guard let first = visibleItems.first else { return nil }
        return ProductionsSelection(rowID: first.id, targetID: first.targetID)
    }

    static func targetDepartment(_ targetID: String, in state: ProductionsState) -> String? {
        if let work = state.work.first(where: { $0.id == targetID }) {
            return normalizedDepartment(work.department)
        }
        if let bundle = state.processing.first(where: { $0.flowID == targetID || $0.id == targetID }) {
            return normalizedDepartment(bundle.department)
        }
        return nil
    }

    private static func workItems(_ work: [WorkItem], prefix: String, state: ProductionsState) -> [ProductionsNavigationItem] {
        work.map { work in
            let department = normalizedDepartment(work.department)
            var metadata = [work.kind.rawValue, work.lifecycle, work.priority, departmentLabel(department)]
            if state.canvasCurrentIDs.contains(work.id) { metadata.append("On Canvas") }
            if state.mementos.contains(where: { $0.target == work.id }) { metadata.append("Memento") }
            return ProductionsNavigationItem(
                id: "\(prefix):\(work.id)",
                targetID: work.id,
                title: "\(work.id) · \(work.title)",
                subtitle: work.registryDescription,
                metadata: metadata,
                department: department
            )
        }
    }

    private static func isDone(_ work: WorkItem) -> Bool {
        work.lifecycle.hasPrefix("Done") || ["Promoted", "Archived", "Discarded"].contains(work.lifecycle)
    }

    private static func normalizedDepartment(_ value: String?) -> String? {
        let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty || value == "—" ? nil : value
    }

    private static func departmentLabel(_ value: String?) -> String {
        normalizedDepartment(value).map { "Department: \($0)" } ?? "Unknown department"
    }
}

struct ProductionsWorkActionAvailability: Equatable {
    let canStart: Bool
    let canStop: Bool
    let canPrepare: Bool
    let mementoActionTitle: String
    let canResolveMemento: Bool

    init(work: WorkItem, isOnCanvas: Bool, currentMemento: Memento?) {
        canStart = !work.lifecycle.hasPrefix("Done")
        canStop = true
        canPrepare = true
        mementoActionTitle = currentMemento == nil ? "Leave Memento…" : "Supersede Memento…"
        canResolveMemento = currentMemento != nil
    }
}

struct ProductionsBundleActionAvailability: Equatable {
    let canPrepare: Bool
    let mementoActionTitle: String
    let canResolveMemento: Bool

    init(currentMemento: Memento?) {
        canPrepare = currentMemento != nil
        mementoActionTitle = currentMemento == nil ? "Leave Memento…" : "Supersede Memento…"
        canResolveMemento = currentMemento != nil
    }
}

enum ProductionsNoticeSeverity: String, Equatable {
    case information
    case success
    case warning
    case failure

    var systemImage: String {
        switch self {
        case .information: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .failure: "xmark.octagon"
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .information: "Information"
        case .success: "Success"
        case .warning: "Warning"
        case .failure: "Error"
        }
    }
}

enum ProductionsPresentationAccessibility {
    static let selectionHint = "Selects this item and displays its details."

    static func rowLabel(_ item: ProductionsNavigationItem) -> String {
        ([item.title, item.subtitle] + item.metadata).filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func selectionValue(isSelected: Bool) -> String {
        isSelected ? "Selected" : "Not selected"
    }

    static func noticeLabel(message: String, severity: ProductionsNoticeSeverity) -> String {
        "\(severity.accessibilityPrefix): \(message)"
    }
}
