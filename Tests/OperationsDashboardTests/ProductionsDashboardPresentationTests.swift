import Foundation
import XCTest
@testable import OperationsDashboard

final class ProductionsDashboardPresentationTests: XCTestCase {
    func testNavigationSectionsUseReviewedIntakeFocusAndBrowseModes() {
        XCTAssertEqual(ProductionsDashboardPresentation.sections(in: .intake), [.inbox, .reconciliations, .managerRouting, .processing])
        XCTAssertEqual(ProductionsDashboardPresentation.sections(in: .focus), [.canvas, .crumbs, .mementos, .priorityWork])
        XCTAssertEqual(ProductionsDashboardPresentation.sections(in: .browse), [.workItems, .plans])
    }

    func testPendingReconciliationIsVisibleBesideInboxWithAccessibleOperationEvidence() throws {
        let operationID = UUID(uuidString: "12345678-1234-4234-8234-123456789ABC")!
        let entry = ReconciliationQueueItem(operationID: operationID, workID: "TASK-000001", workTitle: "Office task", fields: ["priority"], summary: "priority: High → Medium (registry)", occurred: Date(timeIntervalSince1970: 1_787_000_000))
        let item = try XCTUnwrap(ProductionsDashboardPresentation.items(for: .reconciliations, in: richState(reconciliations: [entry])).first)
        XCTAssertEqual(item.targetID, "TASK-000001")
        XCTAssertTrue(item.metadata.contains("Pending owner confirmation"))
        XCTAssertTrue(item.metadata.contains(operationID.uuidString))
        XCTAssertTrue(ProductionsPresentationAccessibility.rowLabel(item).contains("priority: High → Medium"))
    }

    func testManagerRoutingQueueShowsWaitingCategoryAgeAndOperationEvidence() throws {
        let operationID = UUID(uuidString: "22345678-1234-4234-8234-123456789ABC")!
        let route = ManagerRoutingQueueItem(
            operationID: operationID, taskID: "TASK-000001",
            targetThreadID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", state: .running,
            waitingFor: .target, ageSeconds: 90, unresolvedAgeSeconds: 30, overdue: true
        )
        let item = try XCTUnwrap(ProductionsDashboardPresentation.items(
            for: .managerRouting, in: richState(managerRouting: [route])
        ).first)
        XCTAssertTrue(item.title.contains("Waiting for target"))
        XCTAssertTrue(item.subtitle.contains("unresolved 30s"))
        XCTAssertTrue(item.metadata.contains("Age 90s"))
        XCTAssertTrue(item.metadata.contains("Overdue"))
        XCTAssertTrue(ProductionsPresentationAccessibility.rowLabel(item).contains(operationID.uuidString))
    }

    func testWorkItemsAndPlansSeparateEveryCanonicalKindWithoutInventingProductDepartment() throws {
        let state = richState()
        let workItems = ProductionsDashboardPresentation.items(for: .workItems, in: state)
        let plans = ProductionsDashboardPresentation.items(for: .plans, in: state)

        XCTAssertEqual(workItems.map(\.targetID), ["TASK-000001", "IDEA-000001"])
        XCTAssertEqual(plans.map(\.targetID), ["PROJ-000001", "INIT-000001", "PROD-000001"])
        XCTAssertEqual(workItems.map(\.metadata.first!), ["Task", "Idea"])
        XCTAssertEqual(plans.map(\.metadata.first!), ["Project", "Initiative", "Product"])
        let product = try XCTUnwrap(plans.last)
        XCTAssertNil(product.department)
        XCTAssertTrue(product.metadata.contains("Department not provided"))
    }

    func testPriorityWorkIncludesOnlyHighestOrHighNonDoneDurableWork() {
        let priority = ProductionsDashboardPresentation.items(for: .priorityWork, in: richState())

        XCTAssertEqual(priority.map(\.targetID), ["TASK-000001", "IDEA-000001"])
        XCTAssertFalse(priority.contains { $0.targetID == "PROJ-000001" }, "Medium work is not Priority Work.")
        XCTAssertFalse(priority.contains { $0.targetID == "INIT-000001" }, "Done High work is not Priority Work.")
        XCTAssertFalse(priority.contains { $0.targetID == "PROD-000001" }, "Products have no durable-work priority field.")
    }

    func testDepartmentFiltersComeOnlyFromCanonicalRegistryAndAffectCounts() {
        let state = richState()
        let filters = ProductionsDashboardPresentation.departmentFilters(in: state)
        let office = ProductionsDepartmentFilter(department: "Office")
        let studio = ProductionsDepartmentFilter(department: "Studio")

        XCTAssertEqual(filters, [.all, office, studio])
        XCTAssertEqual(ProductionsDashboardPresentation.count(for: .inbox, in: state), 2)
        XCTAssertEqual(ProductionsDashboardPresentation.count(for: .inbox, in: state, departmentFilter: office), 1)
        XCTAssertEqual(ProductionsDashboardPresentation.count(for: .inbox, in: state, departmentFilter: studio), 0)
        XCTAssertEqual(ProductionsDashboardPresentation.count(for: .processing, in: state, departmentFilter: studio), 1)
        XCTAssertEqual(ProductionsDashboardPresentation.count(for: .workItems, in: state, departmentFilter: office), 1)
        XCTAssertEqual(ProductionsDashboardPresentation.count(for: .plans, in: state, departmentFilter: studio), 1)
    }

    func testDepartmentFilteringUsesWorkAndFlowDepartmentsAndKeepsUnknownOnlyUnderAll() throws {
        let state = richState()
        let office = ProductionsDepartmentFilter(department: "Office")
        let studio = ProductionsDepartmentFilter(department: "Studio")
        let allInbox = ProductionsDashboardPresentation.items(for: .inbox, in: state)

        XCTAssertEqual(allInbox.map(\.targetID), ["flow:FLOW-000001", "inbox:Office/Inbox/unregistered.md"])
        XCTAssertTrue(try XCTUnwrap(allInbox.last).metadata.contains("Unknown department"))
        XCTAssertEqual(ProductionsDashboardPresentation.items(for: .inbox, in: state, departmentFilter: office).map(\.targetID), ["flow:FLOW-000001"])
        XCTAssertTrue(ProductionsDashboardPresentation.items(for: .inbox, in: state, departmentFilter: studio).isEmpty)
        XCTAssertEqual(ProductionsDashboardPresentation.items(for: .processing, in: state, departmentFilter: studio).map(\.targetID), ["flow:BND-000001"])
    }

    func testCrumbsAndMementosInheritDurableAndProcessingTargetDepartments() {
        let state = richState()
        let office = ProductionsDepartmentFilter(department: "Office")
        let studio = ProductionsDepartmentFilter(department: "Studio")

        XCTAssertEqual(ProductionsDashboardPresentation.items(for: .crumbs, in: state, departmentFilter: office).map(\.targetID), ["TASK-000001"])
        XCTAssertEqual(ProductionsDashboardPresentation.items(for: .crumbs, in: state, departmentFilter: studio).map(\.targetID), ["BND-000001"])
        XCTAssertEqual(ProductionsDashboardPresentation.items(for: .mementos, in: state, departmentFilter: studio).map(\.targetID), ["IDEA-000001", "BND-000001"])
        XCTAssertEqual(ProductionsDashboardPresentation.targetDepartment("BND-000001", in: state), "Studio")
        XCTAssertNil(ProductionsDashboardPresentation.targetDepartment("PROD-000001", in: state))
    }

    func testSelectionReconciliationPreservesVisibleSelectionAndFallsBackWhenFilterHidesIt() throws {
        let state = richState()
        let all = ProductionsDepartmentFilter.all
        let studio = ProductionsDepartmentFilter(department: "Studio")
        let task = try XCTUnwrap(ProductionsDashboardPresentation.items(for: .priorityWork, in: state).first)

        XCTAssertEqual(
            ProductionsDashboardPresentation.reconciledSelection(currentTargetID: task.targetID, currentRowID: task.id, section: .priorityWork, state: state, departmentFilter: all),
            ProductionsSelection(rowID: task.id, targetID: task.targetID)
        )
        let filtered = try XCTUnwrap(ProductionsDashboardPresentation.items(for: .priorityWork, in: state, departmentFilter: studio).first)
        XCTAssertEqual(
            ProductionsDashboardPresentation.reconciledSelection(currentTargetID: task.targetID, currentRowID: task.id, section: .priorityWork, state: state, departmentFilter: studio),
            ProductionsSelection(rowID: filtered.id, targetID: "IDEA-000001")
        )
        XCTAssertNil(ProductionsDashboardPresentation.reconciledSelection(currentTargetID: task.targetID, currentRowID: task.id, section: .inbox, state: state, departmentFilter: studio))
    }

    func testSearchReconciliationPreservesAStillVisibleSelection() throws {
        let state = richState()
        let idea = try XCTUnwrap(ProductionsDashboardPresentation.items(for: .workItems, in: state).last)

        XCTAssertEqual(
            ProductionsDashboardPresentation.reconciledSelection(currentTargetID: idea.targetID, currentRowID: idea.id, section: .workItems, state: state, searchText: "studio"),
            ProductionsSelection(rowID: idea.id, targetID: idea.targetID)
        )
    }

    func testSearchReconciliationFallsBackWhenCurrentSelectionIsHidden() throws {
        let state = richState()
        let items = ProductionsDashboardPresentation.items(for: .workItems, in: state)
        let task = try XCTUnwrap(items.first)
        let idea = try XCTUnwrap(items.last)

        XCTAssertEqual(
            ProductionsDashboardPresentation.reconciledSelection(currentTargetID: idea.targetID, currentRowID: idea.id, section: .workItems, state: state, searchText: "office"),
            ProductionsSelection(rowID: task.id, targetID: task.targetID)
        )
    }

    @MainActor
    func testSearchWithNoMatchesClearsRowAndDetailSelection() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        let model = ProductionsDashboardViewModel(reader: LocalFileSystem(), initialConfiguration: fixture.configuration)
        let state = try XCTUnwrap(model.state)
        let task = try XCTUnwrap(ProductionsDashboardPresentation.items(for: .workItems, in: state).first)
        model.select(targetID: task.targetID)

        let selection = model.reconcileSelection(for: .workItems, searchText: "no visible match", currentRowID: task.id)

        XCTAssertNil(selection, "The binding receives nil and clears selectedRowID.")
        XCTAssertNil(model.selectedID, "Details must not retain a target hidden by search.")
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testClearingSearchRestoresAValidVisibleSelection() throws {
        let state = richState()
        let task = try XCTUnwrap(ProductionsDashboardPresentation.items(for: .workItems, in: state).first)
        XCTAssertNil(ProductionsDashboardPresentation.reconciledSelection(currentTargetID: task.targetID, currentRowID: task.id, section: .workItems, state: state, searchText: "no visible match"))

        XCTAssertEqual(
            ProductionsDashboardPresentation.reconciledSelection(currentTargetID: nil, currentRowID: nil, section: .workItems, state: state, searchText: ""),
            ProductionsSelection(rowID: task.id, targetID: task.targetID)
        )
    }

    func testDepartmentAndSearchReconciliationCannotRetainHiddenDetail() throws {
        let state = richState()
        let officeTask = try XCTUnwrap(ProductionsDashboardPresentation.items(for: .workItems, in: state).first)
        let studio = ProductionsDepartmentFilter(department: "Studio")

        XCTAssertNil(
            ProductionsDashboardPresentation.reconciledSelection(
                currentTargetID: officeTask.targetID,
                currentRowID: officeTask.id,
                section: .workItems,
                state: state,
                departmentFilter: studio,
                searchText: "office"
            )
        )
    }

    func testSearchMatchesIdentityTitleStatusAndDepartmentWithoutReordering() {
        let state = richState()
        let all = ProductionsDashboardPresentation.items(for: .workItems, in: state)

        XCTAssertEqual(ProductionsDashboardPresentation.filteredItems(for: .workItems, in: state, searchText: "TASK-000001").map(\.targetID), ["TASK-000001"])
        XCTAssertEqual(ProductionsDashboardPresentation.filteredItems(for: .workItems, in: state, searchText: "studio").map(\.targetID), ["IDEA-000001"])
        XCTAssertEqual(ProductionsDashboardPresentation.filteredItems(for: .workItems, in: state, searchText: "active").map(\.targetID), ["TASK-000001"])
        XCTAssertEqual(ProductionsDashboardPresentation.filteredItems(for: .workItems, in: state, searchText: "").map(\.targetID), all.map(\.targetID))
        XCTAssertTrue(ProductionsDashboardPresentation.filteredItems(for: .workItems, in: state, searchText: "no match").isEmpty)
    }

    func testActionAvailabilityReflectsOnlyExistingPresentationBoundaries() throws {
        let state = richState()
        let work = try XCTUnwrap(state.work.first)
        let memento = try XCTUnwrap(state.mementos.first)
        let active = ProductionsWorkActionAvailability(work: work, isOnCanvas: true, currentMemento: memento)

        XCTAssertTrue(active.canStart)
        XCTAssertTrue(active.canStop)
        XCTAssertTrue(active.canPrepare)
        XCTAssertEqual(active.mementoActionTitle, "Supersede Memento…")
        XCTAssertTrue(active.canResolveMemento)
        let done = WorkItem(id: work.id, kind: work.kind, title: work.title, lifecycle: "Done / Complete", priority: "Unranked", lead: work.lead, department: work.department, product: work.product, workspacePath: work.workspacePath, related: work.related, content: work.content)
        XCTAssertFalse(ProductionsWorkActionAvailability(work: done, isOnCanvas: false, currentMemento: nil).canStart)
        XCTAssertTrue(ProductionsWorkActionAvailability(work: done, isOnCanvas: false, currentMemento: nil).canStop)
        XCTAssertFalse(ProductionsBundleActionAvailability(currentMemento: nil).canPrepare)
        XCTAssertTrue(ProductionsBundleActionAvailability(currentMemento: memento).canPrepare)
    }

    func testNoticeSeverityAndAccessibilityRemainTextBacked() throws {
        let item = try XCTUnwrap(ProductionsDashboardPresentation.items(for: .workItems, in: richState()).first)

        XCTAssertEqual(ProductionsNoticeSeverity.success.systemImage, "checkmark.circle")
        XCTAssertEqual(ProductionsNoticeSeverity.warning.accessibilityPrefix, "Warning")
        XCTAssertEqual(ProductionsNoticeSeverity.failure.accessibilityPrefix, "Error")
        XCTAssertTrue(ProductionsPresentationAccessibility.rowLabel(item).contains("Office"))
        XCTAssertEqual(ProductionsPresentationAccessibility.selectionValue(isSelected: true), "Selected")
        XCTAssertEqual(ProductionsPresentationAccessibility.selectionValue(isSelected: false), "Not selected")
        XCTAssertEqual(ProductionsPresentationAccessibility.noticeLabel(message: "Copied", severity: .success), "Success: Copied")
    }

    @MainActor
    func testViewModelDepartmentReconciliationIsMemoryOnlyAndNoticeSeverityTracksEveryOutcome() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        let pasteboard = PresentationRecordingPasteboard()
        let model = ProductionsDashboardViewModel(
            reader: LocalFileSystem(),
            sessionService: SessionPreparationService(pasteboard: pasteboard),
            initialConfiguration: fixture.configuration
        )
        let office = ProductionsDepartmentFilter(department: "Office")

        let selection = model.reconcileSelection(for: .inbox, departmentFilter: office)

        XCTAssertEqual(selection?.targetID, fixture.load().inbox.first?.id)
        XCTAssertEqual(model.selectedID, selection?.targetID)
        XCTAssertEqual(try fixture.snapshot(), before)

        model.copyPreparedSession()
        XCTAssertEqual(model.noticeSeverity, .warning)

        model.prepareSession(targetID: "TASK-999999", authorization: .readOnly, model: "Codex", reasoning: "high")
        XCTAssertEqual(model.noticeSeverity, .failure)

        model.prepareSession(targetID: "TASK-000001", authorization: .readOnly, model: "Codex", reasoning: "high")
        XCTAssertEqual(model.noticeSeverity, .success)
        XCTAssertEqual(try fixture.snapshot(), before)

        try fixture.add(fixture.workspaceRecord + "\n\nConcurrent synthetic change.", at: "Workspace/TASK-000001/TASK-000001.md")
        model.copyPreparedSession()
        XCTAssertEqual(model.noticeSeverity, .failure)
        XCTAssertTrue(model.message?.localizedCaseInsensitiveContains("changed") == true)
        XCTAssertNil(model.sessionPackage, "A stale preview must be removed from the presentation.")
        XCTAssertNil(pasteboard.text, "Stale package bytes must never reach the pasteboard.")
    }

    private func richState(
        reconciliations: [ReconciliationQueueItem] = [], managerRouting: [ManagerRoutingQueueItem] = []
    ) -> ProductionsState {
        let task = work("TASK-000001", kind: .task, title: "Office task", lifecycle: "Active / Current", priority: "High", department: "Office")
        let idea = work("IDEA-000001", kind: .idea, title: "Studio idea", lifecycle: "Open", priority: "Highest", department: "Studio")
        let project = work("PROJ-000001", kind: .project, title: "Office project", lifecycle: "Active / Current", priority: "Medium", department: "Office")
        let initiative = work("INIT-000001", kind: .initiative, title: "Finished initiative", lifecycle: "Done / Complete", priority: "High", department: "Studio")
        let registered = FlowItem(viewIdentity: "flow:FLOW-000001", flowID: "FLOW-000001", label: "Registered", type: "Note", stage: "Inbox", priority: "High", location: "Office/Inbox/registered.md", summary: "Registered intake", department: "Office", bundleContent: nil)
        let unregistered = FlowItem(viewIdentity: "inbox:Office/Inbox/unregistered.md", flowID: nil, label: "unregistered.md", type: "Unregistered", stage: "Inbox", priority: "", location: "Office/Inbox/unregistered.md", summary: "Awaiting registration", bundleContent: nil)
        let bundle = FlowItem(viewIdentity: "flow:BND-000001", flowID: "BND-000001", label: "Studio bundle", type: "Bundle", stage: "Processing", priority: "High", location: "Office/Processing/BND-000001 - Studio", summary: "Route studio material", department: "Studio", bundleContent: "Synthetic bundle")
        let crumbs = [
            Crumb(id: "CRMB-000001", kind: "Action", target: task.id, priority: "High", summary: "Continue task", location: task.workspacePath),
            Crumb(id: "CRMB-000002", kind: "Decision", target: "BND-000001", priority: "Medium", summary: "Route bundle", location: bundle.location)
        ]
        let mementos = [
            memento("MEM-000001", target: idea.id),
            memento("MEM-000002", target: "BND-000001")
        ]
        return ProductionsState(
            configuration: ProductionsConfiguration(schemaVersion: 2, productionsRootPath: "/private/tmp/TASK-0050-presentation-fixture"),
            inbox: [registered, unregistered],
            processing: [bundle],
            work: [task, idea, project, initiative],
            products: [ProductRecord(id: "PROD-000001", name: "Synthetic Product", lifecycle: "Active", lead: "Studio", related: [], canonicalWorkspace: "Products/Synthetic")],
            departments: [DepartmentRecord(name: "Office", function: "Operations"), DepartmentRecord(name: "Studio", function: "Creative")],
            canvas: [CanvasEvent(occurred: Date(timeIntervalSince1970: 1), workID: task.id, event: "Placed", reason: "Focus", context: "Test", sequence: 0)],
            crumbs: crumbs,
            mementos: mementos,
            reconciliations: reconciliations,
            managerRouting: managerRouting,
            issues: []
        )
    }

    private func work(_ id: String, kind: WorkKind, title: String, lifecycle: String, priority: String, department: String) -> WorkItem {
        WorkItem(id: id, kind: kind, title: title, lifecycle: lifecycle, priority: priority, lead: department, department: department, product: "PROD-000001", workspacePath: "Workspace/\(id)/\(id).md", related: [], registryDescription: "\(title) description", content: "# \(id)")
    }

    private func memento(_ id: String, target: String) -> Memento {
        Memento(id: id, target: target, summary: "Pause", resumePoint: "Resume here", created: "2026-08-16", location: "Workspace/\(target)/\(target).md", currentState: "Validated", naturalResumePoint: "Resume here", openCrumbs: [], extendedPayloadPath: nil, extendedPayloadContent: nil)
    }
}

private final class PresentationRecordingPasteboard: SessionPasteboardWriting {
    var text: String?
    func write(_ text: String) throws { self.text = text }
}
