import Foundation
import XCTest
@testable import OperationsDashboard

final class TaskRelationshipReconciliationTests: XCTestCase {
    func testCosmeticRelationshipDriftRepairsToExactRegistryDisplayAndPreservesUnrelatedBytes() throws {
        let original = workspace(
            initiative: "—", project: "PROJ-0008 — Product architecture",
            dependsOn: "TASK-0043 typed capture; TASK-0050 — session preparation"
        )
        let plan = try TaskRelationshipMirrorReconciler.task(
            registryRow: row(project: "PROJ-0008", dependsOn: "TASK-0043 capture; TASK-0050 session preparation"),
            workspaceData: Data(original.utf8)
        )
        let output = String(decoding: plan.workspaceAfter, as: UTF8.self)
        XCTAssertEqual(plan.repairs.map(\.field), ["relationship:Project", "relationship:Depends on"])
        XCTAssertTrue(output.contains("Project: PROJ-0008\n"))
        XCTAssertTrue(output.contains("Depends on: TASK-0043 capture; TASK-0050 session preparation\n"))
        XCTAssertTrue(output.contains("Unknown preserved line: byte-for-byte\n"))
        XCTAssertEqual(
            output.replacingOccurrences(of: "Project: PROJ-0008\n", with: "Project: PROJ-0008 — Product architecture\n")
                .replacingOccurrences(of: "Depends on: TASK-0043 capture; TASK-0050 session preparation\n", with: "Depends on: TASK-0043 typed capture; TASK-0050 — session preparation\n"),
            original
        )
    }

    func testSemanticRelationshipDifferencesAndMalformedDuplicatesBlock() throws {
        let registry = row(project: "PROJ-0008", dependsOn: "TASK-0043; TASK-0050")
        for candidate in [
            workspace(initiative: "—", project: "PROJ-0009", dependsOn: "TASK-0043; TASK-0050"),
            workspace(initiative: "—", project: "PROJ-0008", dependsOn: "TASK-0043"),
            workspace(initiative: "—", project: "PROJ-0008", dependsOn: "TASK-0043; TASK-0050; PROJ-0008"),
            workspace(initiative: "—", project: "PROJ-0008", dependsOn: "TASK-0043; TASK-0043; TASK-0050"),
            workspace(initiative: "—", project: "PROJ-0008", dependsOn: "TASK-0043; TASK-0050")
                .replacingOccurrences(of: "Project: PROJ-0008\n", with: "Project: PROJ-0008\nProject: PROJ-0008\n"),
        ] {
            XCTAssertThrowsError(try TaskRelationshipMirrorReconciler.task(
                registryRow: registry, workspaceData: Data(candidate.utf8)
            ))
        }
    }

    func testExactRelationshipMirrorsAreByteStableAndCreateNoQueueRepair() throws {
        let exact = workspace(initiative: "—", project: "PROJ-0008", dependsOn: "TASK-0043; TASK-0050")
        let plan = try TaskRelationshipMirrorReconciler.task(
            registryRow: row(project: "PROJ-0008", dependsOn: "TASK-0043; TASK-0050"),
            workspaceData: Data(exact.utf8)
        )
        XCTAssertEqual(plan.workspaceAfter, Data(exact.utf8))
        XCTAssertTrue(plan.repairs.isEmpty)
    }

    private func row(project: String, dependsOn: String) -> [String: String] {
        ["Initiative": "—", "Project": project, "Depends on": dependsOn, "Review after": "—"]
    }

    private func workspace(initiative: String, project: String, dependsOn: String) -> String {
        """
        # Synthetic Task

        ## Core Record

        ```text
        Title: Synthetic Task
        ID: TASK-0076
        Type: Task
        Initiative: \(initiative)
        Project: \(project)
        Depends on: \(dependsOn)
        Unknown preserved line: byte-for-byte
        ```

        ## Steps

        - [ ] **S06 — Continue**
        """ + "\n"
    }
}
