import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OperationsDashboard

final class LifecyclePriorityTransactionsTests: XCTestCase {
    private let operationID = UUID(uuidString: "12345678-1234-4234-8234-123456789ABC")!

    func testPreviewRegistryAuthoritativeRepairsBothRecognizedMirrorsWithoutMutation() throws {
        let fixture = try MetadataFixture(workspaceState: "Active / Paused", workspacePriority: "High")
        defer { fixture.remove() }
        let beforeRegistry = try Data(contentsOf: fixture.registryURL), beforeWorkspace = try Data(contentsOf: fixture.workspaceURL)
        let preview = try fixture.service(operationID: operationID).preview(request: fixture.request(rule: .registryAuthoritative), configuration: fixture.configuration)

        XCTAssertEqual(preview.lifecycle, "Active / Current")
        XCTAssertEqual(preview.priority, "Medium")
        XCTAssertEqual(preview.repairs.map(\.field), ["lifecycle", "priority"])
        XCTAssertEqual(try Data(contentsOf: fixture.registryURL), beforeRegistry)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceURL), beforeWorkspace)
        XCTAssertEqual(preview.registrySHA256Before, preview.registrySHA256After)
        XCTAssertNotEqual(preview.workspaceSHA256Before, preview.workspaceSHA256After)
    }

    func testMaximumPriorityUpdatesRegistryAndEveryWorkspaceMirrorAtomically() throws {
        let fixture = try MetadataFixture(workspaceState: "Active / Paused", workspacePriority: "High")
        defer { fixture.remove() }
        let request = fixture.request(rule: .deterministicMaximum)
        let preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
        let result = try fixture.service(operationID: operationID).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)

        XCTAssertEqual(result.outcome, "committed", result.diagnostic ?? "")
        XCTAssertEqual(result.priority, "High")
        XCTAssertEqual(result.queueDisposition, .pending)
        XCTAssertTrue(result.historicalCommitProven)
        XCTAssertTrue(result.journalFinalized)
        let registry = try String(contentsOf: fixture.registryURL, encoding: .utf8)
        let workspace = try String(contentsOf: fixture.workspaceURL, encoding: .utf8)
        XCTAssertTrue(registry.contains("| Active / Current | High |"))
        XCTAssertTrue(workspace.contains("Priority: High"))
        XCTAssertTrue(workspace.contains("This Task is `Active / Current` at `High` priority"))
        XCTAssertTrue(workspace.contains("Unrelated bytes stay exact."))
        XCTAssertEqual(try fixture.store.pending(productionsRootPath: fixture.root.path).map(\.operationUUID), [operationID])
        XCTAssertEqual(try fixture.service(operationID: operationID).pendingEntries(configuration: fixture.configuration).map(\.operationUUID), [operationID])
    }

    func testExplicitOwnerRegistryDecisionPreservesMediumAndRepairsStaleHigh() throws {
        let fixture = try MetadataFixture(workspacePriority: "High")
        defer { fixture.remove() }
        let request = fixture.request(rule: .registryAuthoritative)
        let preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
        XCTAssertEqual(preview.priority, "Medium")
        XCTAssertEqual(preview.repairs.first(where: { $0.field == "priority" })?.provenance, "owner-authorized Registry decision")
        let result = try fixture.service(operationID: operationID).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "committed", result.diagnostic ?? "")
        XCTAssertTrue(try String(contentsOf: fixture.workspaceURL, encoding: .utf8).contains("at `Medium` priority"))
    }

    func testExplicitLifecycleAndPriorityUpdateChangesRegistryAndMirrorsButNotCanvas() throws {
        let fixture = try MetadataFixture()
        defer { fixture.remove() }
        let canvasBefore = try Data(contentsOf: fixture.canvasURL)
        let request = fixture.request(rule: .registryAuthoritative, state: "Active / Blocked", priority: "Highest")
        let preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
        let result = try fixture.service(operationID: operationID).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        XCTAssertEqual(result.lifecycle, "Active / Blocked")
        XCTAssertEqual(result.priority, "Highest")
        XCTAssertEqual(try Data(contentsOf: fixture.canvasURL), canvasBefore)
    }

    func testOwnerAcknowledgementOnlyChangesDurableQueueDisposition() throws {
        let fixture = try MetadataFixture(workspacePriority: "High")
        defer { fixture.remove() }
        let request = fixture.request(rule: .registryAuthoritative)
        let preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
        _ = try fixture.service(operationID: operationID).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        let registry = try Data(contentsOf: fixture.registryURL), workspace = try Data(contentsOf: fixture.workspaceURL), canvas = try Data(contentsOf: fixture.canvasURL)

        let result = try fixture.service(operationID: operationID).acknowledge(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(result.classification, "acknowledged")
        XCTAssertEqual(result.queueDisposition, .confirmed)
        XCTAssertEqual(try Data(contentsOf: fixture.registryURL), registry)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceURL), workspace)
        XCTAssertEqual(try Data(contentsOf: fixture.canvasURL), canvas)
        XCTAssertTrue(try fixture.store.pending(productionsRootPath: fixture.root.path).isEmpty)
    }

    func testOwnerCorrectionUsesNormalTransactionAndStopsOldEntryResurfacing() throws {
        let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
        let firstID = operationID
        let firstRequest = fixture.request(rule: .registryAuthoritative)
        let firstPreview = try fixture.service(operationID: firstID).preview(request: firstRequest, configuration: fixture.configuration)
        _ = try fixture.service(operationID: firstID).perform(request: firstRequest, confirmationToken: firstPreview.confirmationToken, configuration: fixture.configuration)

        let correctionID = UUID(uuidString: "22345678-1234-4234-8234-123456789ABC")!
        let correction = LifecyclePriorityRequest(workID: fixture.workID, expectedRegistrySHA256: fixture.digest(try Data(contentsOf: fixture.registryURL)), expectedWorkspaceSHA256: fixture.digest(try Data(contentsOf: fixture.workspaceURL)), priorityRule: .registryAuthoritative, desiredLifecycle: nil, desiredPriority: "Low", correctsOperation: firstID)
        let preview = try fixture.service(operationID: correctionID).preview(request: correction, configuration: fixture.configuration)
        let result = try fixture.service(operationID: correctionID).perform(request: correction, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "committed", result.diagnostic ?? "")
        XCTAssertEqual(try fixture.store.journal(operationID: firstID)?.queueDisposition, .corrected)
        XCTAssertEqual(try fixture.store.journal(operationID: correctionID)?.queueDisposition, .confirmed)
        XCTAssertTrue(try fixture.store.pending(productionsRootPath: fixture.root.path).isEmpty)
    }

    func testInspectReconcilesExactPostimageAndRejectsAlternateRoot() throws {
        let fixture = try MetadataFixture(workspacePriority: "High")
        defer { fixture.remove() }
        let request = fixture.request(rule: .registryAuthoritative)
        let preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
        _ = try fixture.service(operationID: operationID).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        let current = try fixture.service(operationID: operationID).inspect(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(current.classification, "committed-and-current")

        let alternate = ProductionsConfiguration(schemaVersion: 2, productionsRootPath: "/private/tmp/not-the-bound-root")
        let frozen = try fixture.service(operationID: operationID).inspect(operationID: operationID, configuration: alternate)
        XCTAssertEqual(frozen.outcome, "uncertain")
        XCTAssertTrue(frozen.historicalCommitProven)
        XCTAssertTrue(frozen.diagnostic?.contains("Do not retry automatically") == true)
    }

    func testMalformedDuplicateAndUnknownMirrorsRejectBeforeJournal() throws {
        let variants = [
            "duplicate": "Priority: High\nPriority: Medium",
            "unknown": "Priority: Urgent",
            "summary": "This Task is maybe active at urgent priority.",
        ]
        for (name, mutation) in variants {
            let fixture = try MetadataFixture(); defer { fixture.remove() }
            if name == "summary" { try fixture.replace("This Task is `Active / Current` at `Medium` priority", with: mutation) }
            else { try fixture.replace("Priority: Medium", with: mutation) }
            XCTAssertThrowsError(try fixture.service(operationID: operationID).preview(request: fixture.requestFromCurrent(rule: .registryAuthoritative), configuration: fixture.configuration)) { error in
                XCTAssertEqual((error as? LifecyclePriorityCommandFailure)?.result.classification, "targetContractInvalid")
            }
            XCTAssertTrue((try? fixture.store.pending(productionsRootPath: fixture.root.path))?.isEmpty == true)
        }
    }

    func testHashConfirmationLockAndJournalFailuresArePremutation() throws {
        do {
            let fixture = try MetadataFixture(); defer { fixture.remove() }
            var request = fixture.request(rule: .registryAuthoritative)
            request = LifecyclePriorityRequest(workID: request.workID, expectedRegistrySHA256: String(repeating: "0", count: 64), expectedWorkspaceSHA256: request.expectedWorkspaceSHA256, priorityRule: request.priorityRule, desiredLifecycle: nil, desiredPriority: nil, correctsOperation: nil)
            XCTAssertThrowsError(try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration))
        }
        do {
            let fixture = try MetadataFixture(); defer { fixture.remove() }
            let before = try Data(contentsOf: fixture.workspaceURL), request = fixture.request(rule: .registryAuthoritative)
            XCTAssertThrowsError(try fixture.service(operationID: operationID, locking: MetadataDeniedLock()).perform(request: request, confirmationToken: "wrong", configuration: fixture.configuration)) { error in
                XCTAssertEqual((error as? LifecyclePriorityCommandFailure)?.result.classification, "lockUnavailable")
            }
            XCTAssertEqual(try Data(contentsOf: fixture.workspaceURL), before)
        }
        do {
            let fixture = try MetadataFixture(); defer { fixture.remove() }
            let request = fixture.request(rule: .registryAuthoritative), preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
            XCTAssertThrowsError(try fixture.service(operationID: operationID, store: MetadataFailingJournal()).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)) { error in
                let failure = error as? LifecyclePriorityCommandFailure
                XCTAssertEqual(failure?.result.classification, "journalCreateFailed")
                XCTAssertNil(failure?.result.inspectCommand)
            }
        }
    }

    func testPartialReplacementRestoresCompletePreimages() throws {
        let fixture = try MetadataFixture(workspaceState: "Active / Paused", workspacePriority: "High")
        defer { fixture.remove() }
        let beforeRegistry = try Data(contentsOf: fixture.registryURL), beforeWorkspace = try Data(contentsOf: fixture.workspaceURL)
        let request = fixture.request(rule: .deterministicMaximum), preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
        let result = try fixture.service(operationID: operationID, replacer: FailSecondMetadataReplacement()).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "not-committed", result.diagnostic ?? "")
        XCTAssertEqual(result.classification, "definite-no-commit")
        XCTAssertEqual(try Data(contentsOf: fixture.registryURL), beforeRegistry)
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceURL), beforeWorkspace)
    }

    func testMutationBetweenPreparationAndReplacementIsDefiniteNoCommitAndPreserved() throws {
        let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
        let request = fixture.request(rule: .registryAuthoritative)
        let preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
        let racingStore = MetadataRacingJournal(base: fixture.store, workspaceURL: fixture.workspaceURL)
        let result = try fixture.service(operationID: operationID, store: racingStore).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "not-committed")
        XCTAssertEqual(result.classification, "definite-no-commit")
        XCTAssertTrue(try String(contentsOf: fixture.workspaceURL, encoding: .utf8).contains("Concurrent authorized bytes."))
    }

    func testTerminalFinalizationUsesTypedFallbackAndNeverRetries() throws {
        let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
        let journal = MetadataMemoryJournal(); journal.failUpdates = true
        let request = fixture.request(rule: .registryAuthoritative)
        let preview = try fixture.service(operationID: operationID, store: journal).preview(request: request, configuration: fixture.configuration)
        let result = try fixture.service(operationID: operationID, store: journal).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "uncertain")
        XCTAssertTrue(result.historicalCommitProven)
        XCTAssertTrue(result.fallbackRecorded)
        XCTAssertFalse(result.journalFinalized)
        XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically") == true)
    }

    func testTerminalAndFallbackWriteFailuresReportOnlyDurableFlags() throws {
        let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
        let store = MetadataMemoryJournal(); store.failUpdates = true; store.failFallback = true
        let request = fixture.request(rule: .registryAuthoritative)
        let preview = try fixture.service(operationID: operationID, store: store).preview(request: request, configuration: fixture.configuration)
        let result = try fixture.service(operationID: operationID, store: store).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "uncertain")
        XCTAssertTrue(result.historicalCommitProven)
        XCTAssertFalse(result.journalFinalized)
        XCTAssertFalse(result.fallbackRecorded)
        XCTAssertNil(store.value?.terminalState)
        XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically") == true)
    }

    func testStartupRecoveryRestoresProcessLossAfterFirstRename() throws {
        let fixture = try MetadataFixture(workspaceState: "Active / Paused", workspacePriority: "High"); defer { fixture.remove() }
        let store = MetadataPersistThenThrowJournal()
        let request = fixture.request(rule: .deterministicMaximum)
        let preview = try fixture.service(operationID: operationID, store: store).preview(request: request, configuration: fixture.configuration)
        XCTAssertThrowsError(try fixture.service(operationID: operationID, store: store).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration))
        let journal = try XCTUnwrap(store.value)
        try journal.workspaceExpectedAfter.write(to: fixture.workspaceURL)
        XCTAssertEqual(fixture.service(operationID: operationID, store: store).startupRecovery().map(\.operationUUID), [operationID])

        let result = try fixture.service(operationID: operationID, store: store).inspect(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(result.classification, "definite-no-commit")
        XCTAssertEqual(result.outcome, "not-committed")
        XCTAssertEqual(try Data(contentsOf: fixture.workspaceURL), journal.workspacePreimage)
        XCTAssertEqual(try Data(contentsOf: fixture.registryURL), journal.registryPreimage)
        XCTAssertTrue(fixture.service(operationID: operationID, store: store).startupRecovery().isEmpty)
        XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically") == true)
    }

    func testDuplicateEmptyAttentionSectionAndHiddenRegistryFragmentsReject() throws {
        do {
            let fixture = try MetadataFixture(); defer { fixture.remove() }
            try fixture.appendWorkspace("\n## Lifecycle and Attention\n")
            XCTAssertThrowsError(try fixture.service(operationID: operationID).preview(request: fixture.requestFromCurrent(rule: .registryAuthoritative), configuration: fixture.configuration)) {
                XCTAssertEqual(($0 as? LifecyclePriorityCommandFailure)?.result.classification, "targetContractInvalid")
            }
        }
        for fragment in ["| IDEA-9999 | malformed |", "| malformed | fragment |"] {
            let fixture = try MetadataFixture(); defer { fixture.remove() }
            try fixture.appendRegistry("\n\(fragment)\n")
            XCTAssertThrowsError(try fixture.service(operationID: operationID).preview(request: fixture.requestFromCurrent(rule: .registryAuthoritative), configuration: fixture.configuration)) {
                XCTAssertEqual(($0 as? LifecyclePriorityCommandFailure)?.result.classification, "targetContractInvalid")
            }
        }
    }

    func testCommittedCorrectionInspectionConsumesFailedPriorQueueUpdate() throws {
        let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
        let firstRequest = fixture.request(rule: .registryAuthoritative)
        let firstPreview = try fixture.service(operationID: operationID).preview(request: firstRequest, configuration: fixture.configuration)
        _ = try fixture.service(operationID: operationID).perform(request: firstRequest, confirmationToken: firstPreview.confirmationToken, configuration: fixture.configuration)

        let correctionID = UUID(uuidString: "22345678-1234-4234-8234-123456789ABC")!
        let failing = MetadataFailPriorCorrectionStore(base: fixture.store, priorID: operationID)
        let correction = LifecyclePriorityRequest(workID: fixture.workID, expectedRegistrySHA256: fixture.digest(try Data(contentsOf: fixture.registryURL)), expectedWorkspaceSHA256: fixture.digest(try Data(contentsOf: fixture.workspaceURL)), priorityRule: .registryAuthoritative, desiredLifecycle: nil, desiredPriority: "Low", correctsOperation: operationID)
        let preview = try fixture.service(operationID: correctionID, store: failing).preview(request: correction, configuration: fixture.configuration)
        let committed = try fixture.service(operationID: correctionID, store: failing).perform(request: correction, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        XCTAssertEqual(committed.outcome, "committed-with-queue-failure")
        XCTAssertEqual(try fixture.store.journal(operationID: operationID)?.queueDisposition, .pending)

        let inspected = try fixture.service(operationID: correctionID, store: fixture.store).inspect(operationID: correctionID, configuration: fixture.configuration)
        XCTAssertEqual(inspected.outcome, "committed")
        XCTAssertEqual(try fixture.store.journal(operationID: operationID)?.queueDisposition, .corrected)
    }

    func testAcknowledgementUpdateFailureIsInspectableUncertainNoRetry() throws {
        let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
        let request = fixture.request(rule: .registryAuthoritative)
        let preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
        _ = try fixture.service(operationID: operationID).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        let failing = MetadataFailAcknowledgementStore(base: fixture.store)
        XCTAssertThrowsError(try fixture.service(operationID: operationID, store: failing).acknowledge(operationID: operationID, configuration: fixture.configuration)) {
            let failure = $0 as? LifecyclePriorityCommandFailure
            XCTAssertEqual(failure?.exitCode, 3)
            XCTAssertEqual(failure?.result.classification, "acknowledgement-state-uncertain")
            XCTAssertNotNil(failure?.result.inspectCommand)
            XCTAssertTrue(failure?.result.diagnostic?.contains("Do not retry automatically") == true)
        }
        XCTAssertEqual(try fixture.store.journal(operationID: operationID)?.queueDisposition, .pending)
        XCTAssertEqual(try fixture.service(operationID: operationID).inspect(operationID: operationID, configuration: fixture.configuration).classification, "committed-and-current")
    }

    func testAllDurableKindsAndLegacyFieldFormsPreview() throws {
        let cases: [(String, String, String, String)] = [
            ("IDEA-0006", "Idea", "Open", "Disposition"),
            ("PROJ-0008", "Project", "Active / Current", "State"),
            ("INIT-0002", "Initiative", "Active / Current", "State"),
        ]
        for (id, kind, lifecycle, field) in cases {
            let fixture = try MetadataFixture(workID: id, kindName: kind, registryLifecycle: lifecycle, workspaceState: lifecycle, lifecycleField: field, narrative: false)
            defer { fixture.remove() }
            let preview = try fixture.service(operationID: operationID).preview(request: fixture.request(rule: .registryAuthoritative), configuration: fixture.configuration)
            XCTAssertEqual(preview.lifecycle, lifecycle)
            XCTAssertEqual(preview.priority, "Medium")
        }
    }

    func testCLIParsesPreviewApplyListAcknowledgeAndMalformedOfficeStaysHeadless() throws {
        let fixture = try MetadataFixture(); defer { fixture.remove() }
        let request = fixture.request(rule: .registryAuthoritative)
        let base = ["OperationsDashboard", "office", "reconcile", "preview", "--productions-root", fixture.root.path, "--work", fixture.workID, "--priority-rule", "registry", "--expected-workspace-sha256", request.expectedWorkspaceSHA256, "--expected-registry-sha256", request.expectedRegistrySHA256]
        guard case .reconcilePreview = try HeadlessOfficeCommandLine.parse(Array(base.dropFirst())) else { return XCTFail("Expected preview") }
        guard case .reconciliationList = try HeadlessOfficeCommandLine.parse(["office", "reconciliation", "list", "--productions-root", fixture.root.path]) else { return XCTFail("Expected list") }
        guard case .reconciliationAcknowledge = try HeadlessOfficeCommandLine.parse(["office", "reconciliation", "acknowledge", "--productions-root", fixture.root.path, "--operation", operationID.uuidString]) else { return XCTFail("Expected acknowledge") }
        var output: [String] = []
        XCTAssertEqual(HeadlessOfficeCommandLine.runIfRequested(arguments: ["OperationsDashboard", "office", "reconcile"], lifecyclePriorityService: fixture.service(operationID: operationID), write: { output.append($0) }), 2)
        XCTAssertFalse(output.isEmpty)
    }

    func testProductionCLIApplyListAndAcknowledgeAdapters() throws {
        let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
        let request = fixture.request(rule: .registryAuthoritative)
        var output: [String] = []
        let previewArgs = ["OperationsDashboard", "office", "reconcile", "preview", "--productions-root", fixture.root.path, "--work", fixture.workID, "--priority-rule", "registry", "--expected-workspace-sha256", request.expectedWorkspaceSHA256, "--expected-registry-sha256", request.expectedRegistrySHA256]
        XCTAssertEqual(HeadlessOfficeCommandLine.runIfRequested(arguments: previewArgs, lifecyclePriorityService: fixture.service(operationID: operationID), write: { output.append($0) }), 0)
        let previewData = try XCTUnwrap(output.last?.data(using: .utf8))
        let previewObject = try XCTUnwrap(JSONSerialization.jsonObject(with: previewData) as? [String: Any])
        let token = try XCTUnwrap(previewObject["confirmationToken"] as? String)
        output.removeAll()
        XCTAssertEqual(HeadlessOfficeCommandLine.runIfRequested(arguments: previewArgs.map { $0 == "preview" ? "apply" : $0 } + ["--confirm", token], lifecyclePriorityService: fixture.service(operationID: operationID), write: { output.append($0) }), 0)
        XCTAssertTrue(output.last?.contains("committed") == true)
        output.removeAll()
        XCTAssertEqual(HeadlessOfficeCommandLine.runIfRequested(arguments: ["OperationsDashboard", "office", "reconciliation", "list", "--productions-root", fixture.root.path], lifecyclePriorityService: fixture.service(operationID: operationID), write: { output.append($0) }), 0)
        XCTAssertTrue(output.last?.contains(operationID.uuidString) == true)
        output.removeAll()
        XCTAssertEqual(HeadlessOfficeCommandLine.runIfRequested(arguments: ["OperationsDashboard", "office", "reconciliation", "acknowledge", "--productions-root", fixture.root.path, "--operation", operationID.uuidString], lifecyclePriorityService: fixture.service(operationID: operationID), write: { output.append($0) }), 0)
        XCTAssertTrue(output.last?.contains("acknowledged") == true)
    }

    func testQueueResolverSurfacesMalformedEnvelopeBadRootAndNonregularJournal() throws {
        for mutation in ["metadata", "root", "symlink"] {
            let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
            let request = fixture.request(rule: .registryAuthoritative)
            let preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
            _ = try fixture.service(operationID: operationID).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
            let journalURL = fixture.recovery.appending(path: "\(operationID.uuidString).json")
            if mutation == "symlink" {
                let real = fixture.recovery.appending(path: "real.json")
                try FileManager.default.moveItem(at: journalURL, to: real)
                try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: real)
            } else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
                if mutation == "metadata" { object["workTitle"] = "Substituted title" }
                else { object["productionsRootPath"] = "/private/tmp/another-canonical-root" }
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: journalURL)
            }
            let resolver = ApplicationSupportReconciliationQueueResolver(directory: fixture.recovery)
            XCTAssertThrowsError(try resolver.pendingEntries(productionsRootPath: fixture.root.path, now: Date()), mutation)
        }
    }

    func testConcurrentQueueAcknowledgementsAreSerializedAndCASValidated() throws {
        let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
        let request = fixture.request(rule: .registryAuthoritative)
        let preview = try fixture.service(operationID: operationID).preview(request: request, configuration: fixture.configuration)
        _ = try fixture.service(operationID: operationID).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration)
        let resolver = ApplicationSupportReconciliationQueueResolver(directory: fixture.recovery)
        let operation = operationID
        let rootPath = fixture.root.path
        let queue = DispatchQueue(label: "reconciliation-cas", attributes: .concurrent)
        let group = DispatchGroup()
        let results = MetadataConcurrentResults()
        for _ in 0..<2 {
            group.enter()
            queue.async {
                defer { group.leave() }
                do { results.append(try resolver.acknowledge(operationID: operation, productionsRootPath: rootPath).disposition) }
                catch { results.fail(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(results.errors.isEmpty, results.errors.map(\.localizedDescription).joined(separator: "\n"))
        XCTAssertEqual(results.dispositions, [.confirmed, .confirmed])
        XCTAssertEqual(try fixture.store.journal(operationID: operationID)?.queueDisposition, .confirmed)
    }

    func testSplitPublicationRecoveryRejectsTargetSwapAfterLock() throws {
        let fixture = try MetadataFixture(workspaceState: "Active / Paused", workspacePriority: "High"); defer { fixture.remove() }
        let base = fixture.store
        let interrupted = MetadataPersistThenThrowApplicationStore(base: base)
        let request = fixture.request(rule: .deterministicMaximum)
        let preview = try fixture.service(operationID: operationID, store: interrupted).preview(request: request, configuration: fixture.configuration)
        XCTAssertThrowsError(try fixture.service(operationID: operationID, store: interrupted).perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration))
        let journal = try XCTUnwrap(base.journal(operationID: operationID))
        try journal.workspaceExpectedAfter.write(to: fixture.workspaceURL)

        let swapLock = MetadataSwapTargetLock(target: fixture.workspaceURL)
        let result = try fixture.service(operationID: operationID, store: base, locking: swapLock)
            .inspect(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "uncertain")
        XCTAssertFalse(result.historicalCommitProven)
        XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically") == true)
        var status = stat()
        XCTAssertEqual(lstat(fixture.workspaceURL.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK)
    }

    func testJournalCoordinatorUsesRealCrossProcessLockAndRejectsStaleBytes() throws {
        let directory = URL(fileURLWithPath: "/private/tmp/OfficeJournalMultiprocess-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appending(path: "child-acquired")
        var token: OfficeJournalAtomicCoordinator.Token? = try OfficeJournalAtomicCoordinator.acquire(directory: directory)
        XCTAssertNotNil(token)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import fcntl,os,sys; fd=os.open(sys.argv[1],os.O_RDONLY); fcntl.flock(fd,fcntl.LOCK_EX); open(sys.argv[2],'wb').write(b'acquired')", directory.path, marker.path]
        try child.run()
        Thread.sleep(forTimeInterval: 0.15)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "Child process must block behind the shared journal flock.")
        token = nil
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: marker), Data("acquired".utf8))

        let journal = directory.appending(path: "stale.json")
        let original = Data("original".utf8), foreign = Data("foreign-process-write".utf8)
        try original.write(to: journal)
        let writer = Process()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        writer.arguments = ["-c", "open(__import__('sys').argv[1],'wb').write(b'foreign-process-write')", journal.path]
        try writer.run(); writer.waitUntilExit(); XCTAssertEqual(writer.terminationStatus, 0)
        XCTAssertThrowsError(try OfficeJournalAtomicCoordinator.withLock(directory: directory) {
            try OfficeJournalAtomicCoordinator.replaceIfUnchanged(
                expectedDurableBytes: original, proposedBytes: Data("proposed".utf8), at: journal, manager: .default
            )
        })
        XCTAssertEqual(try Data(contentsOf: journal), foreign)
    }

    func testResolverAndInspectorJournalRewritesSerializeWithoutLostProof() throws {
        let fixture = try MetadataFixture(workspacePriority: "High"); defer { fixture.remove() }
        let base = fixture.store
        let interrupted = MetadataPersistThenThrowApplicationStore(base: base)
        let request = fixture.request(rule: .registryAuthoritative)
        let preview = try fixture.service(operationID: operationID, store: interrupted).preview(request: request, configuration: fixture.configuration)
        XCTAssertThrowsError(try fixture.service(operationID: operationID, store: interrupted)
            .perform(request: request, confirmationToken: preview.confirmationToken, configuration: fixture.configuration))
        let initial = try XCTUnwrap(base.journal(operationID: operationID))
        try initial.workspaceExpectedAfter.write(to: fixture.workspaceURL)

        var gate: OfficeJournalAtomicCoordinator.Token? = try OfficeJournalAtomicCoordinator.acquire(directory: fixture.recovery)
        XCTAssertNotNil(gate)
        let results = MetadataInspectorResolverResults()
        let group = DispatchGroup()
        let operation = operationID
        let configuration = fixture.configuration
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { results.inspection = try fixture.service(operationID: operation, store: base).inspect(operationID: operation, configuration: configuration) }
            catch { results.inspectionError = error }
        }
        Thread.sleep(forTimeInterval: 0.05)
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { results.acknowledgement = try fixture.service(operationID: operation).acknowledge(operationID: operation, configuration: configuration) }
            catch { results.acknowledgementError = error }
        }
        gate = nil
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertNil(results.inspectionError)
        XCTAssertTrue(results.inspection?.historicalCommitProven == true)
        let durable = try XCTUnwrap(base.journal(operationID: operationID))
        XCTAssertTrue(durable.terminalState?.provesHistoricalCommit == true)
        XCTAssertTrue(durable.queueDisposition == .pending || durable.queueDisposition == .confirmed)
        if results.acknowledgement != nil { XCTAssertEqual(durable.queueDisposition, .confirmed) }
    }
}

private final class MetadataConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var dispositions: [ReconciliationDisposition] = []
    private(set) var errors: [Error] = []
    func append(_ value: ReconciliationDisposition) { lock.lock(); dispositions.append(value); dispositions.sort { $0.rawValue < $1.rawValue }; lock.unlock() }
    func fail(_ error: Error) { lock.lock(); errors.append(error); lock.unlock() }
}

private final class MetadataInspectorResolverResults: @unchecked Sendable {
    private let lock = NSLock()
    private var _inspection: LifecyclePriorityCommandResult?
    private var _acknowledgement: LifecyclePriorityCommandResult?
    private var _inspectionError: Error?
    private var _acknowledgementError: Error?
    var inspection: LifecyclePriorityCommandResult? { get { locked { _inspection } } set { locked { _inspection = newValue } } }
    var acknowledgement: LifecyclePriorityCommandResult? { get { locked { _acknowledgement } } set { locked { _acknowledgement = newValue } } }
    var inspectionError: Error? { get { locked { _inspectionError } } set { locked { _inspectionError = newValue } } }
    var acknowledgementError: Error? { get { locked { _acknowledgementError } } set { locked { _acknowledgementError = newValue } } }
    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
}

private struct MetadataAcceptingValidator: OfficeV112ContractValidating { func validate(configuration: ProductionsConfiguration) throws {} }
private struct MetadataDeniedLock: TaskCheckpointLocking { func acquire(registryURL: URL) -> AnyObject? { nil } }

private final class MetadataFailingJournal: LifecyclePriorityJournalStore {
    func persist(_ journal: LifecyclePriorityJournal) throws { throw CocoaError(.fileWriteNoPermission) }
    func update(_ journal: LifecyclePriorityJournal) throws {}
    func recordFallback(_ journal: LifecyclePriorityJournal) throws {}
    func journal(operationID: UUID) throws -> LifecyclePriorityJournal? { nil }
    func pending(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { [] }
}

private final class MetadataMemoryJournal: LifecyclePriorityJournalStore {
    var value: LifecyclePriorityJournal?
    var failUpdates = false
    var failFallback = false
    func persist(_ journal: LifecyclePriorityJournal) throws { value = journal }
    func update(_ journal: LifecyclePriorityJournal) throws { if failUpdates { throw CocoaError(.fileWriteUnknown) }; value = journal }
    func recordFallback(_ journal: LifecyclePriorityJournal) throws { if failFallback { throw CocoaError(.fileWriteUnknown) }; value = journal }
    func journal(operationID: UUID) throws -> LifecyclePriorityJournal? { value?.operationUUID == operationID ? value : nil }
    func pending(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { [] }
}

private final class MetadataPersistThenThrowJournal: LifecyclePriorityJournalStore {
    var value: LifecyclePriorityJournal?
    func persist(_ journal: LifecyclePriorityJournal) throws { value = journal; throw CocoaError(.fileWriteUnknown) }
    func update(_ journal: LifecyclePriorityJournal) throws { value = journal }
    func recordFallback(_ journal: LifecyclePriorityJournal) throws { value = journal }
    func journal(operationID: UUID) throws -> LifecyclePriorityJournal? { value?.operationUUID == operationID ? value : nil }
    func incomplete() throws -> [LifecyclePriorityJournal] {
        guard let value, value.terminalState == nil || value.terminalState?.isStartupIncomplete == true else { return [] }
        return [value]
    }
    func pending(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { [] }
}

private final class MetadataFailPriorCorrectionStore: LifecyclePriorityJournalStore {
    let base: ApplicationSupportLifecyclePriorityJournalStore
    let priorID: UUID
    var failed = false
    init(base: ApplicationSupportLifecyclePriorityJournalStore, priorID: UUID) { self.base = base; self.priorID = priorID }
    func persist(_ journal: LifecyclePriorityJournal) throws { try base.persist(journal) }
    func update(_ journal: LifecyclePriorityJournal) throws {
        if journal.operationUUID == priorID, journal.queueDisposition == .corrected, !failed { failed = true; throw CocoaError(.fileWriteUnknown) }
        try base.update(journal)
    }
    func recordFallback(_ journal: LifecyclePriorityJournal) throws { try base.recordFallback(journal) }
    func journal(operationID: UUID) throws -> LifecyclePriorityJournal? { try base.journal(operationID: operationID) }
    func all(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { try base.all(productionsRootPath: productionsRootPath) }
    func incomplete() throws -> [LifecyclePriorityJournal] { try base.incomplete() }
    func pending(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { try base.pending(productionsRootPath: productionsRootPath) }
}

private final class MetadataFailAcknowledgementStore: LifecyclePriorityJournalStore {
    let base: ApplicationSupportLifecyclePriorityJournalStore
    init(base: ApplicationSupportLifecyclePriorityJournalStore) { self.base = base }
    func persist(_ journal: LifecyclePriorityJournal) throws { try base.persist(journal) }
    func update(_ journal: LifecyclePriorityJournal) throws {
        if journal.queueDisposition == .confirmed { throw CocoaError(.fileWriteUnknown) }
        try base.update(journal)
    }
    func recordFallback(_ journal: LifecyclePriorityJournal) throws { try base.recordFallback(journal) }
    func journal(operationID: UUID) throws -> LifecyclePriorityJournal? { try base.journal(operationID: operationID) }
    func all(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { try base.all(productionsRootPath: productionsRootPath) }
    func incomplete() throws -> [LifecyclePriorityJournal] { try base.incomplete() }
    func pending(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { try base.pending(productionsRootPath: productionsRootPath) }
}

private final class MetadataPersistThenThrowApplicationStore: LifecyclePriorityJournalStore {
    let base: ApplicationSupportLifecyclePriorityJournalStore
    init(base: ApplicationSupportLifecyclePriorityJournalStore) { self.base = base }
    func persist(_ journal: LifecyclePriorityJournal) throws { try base.persist(journal); throw CocoaError(.fileWriteUnknown) }
    func update(_ journal: LifecyclePriorityJournal) throws { try base.update(journal) }
    func recordFallback(_ journal: LifecyclePriorityJournal) throws { try base.recordFallback(journal) }
    func journal(operationID: UUID) throws -> LifecyclePriorityJournal? { try base.journal(operationID: operationID) }
    func all(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { try base.all(productionsRootPath: productionsRootPath) }
    func incomplete() throws -> [LifecyclePriorityJournal] { try base.incomplete() }
    func pending(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { try base.pending(productionsRootPath: productionsRootPath) }
}

private final class MetadataSwapTargetLock: TaskCheckpointLocking {
    let target: URL
    init(target: URL) { self.target = target }
    func acquire(registryURL: URL) -> AnyObject? {
        let manager = FileManager.default
        let real = target.deletingLastPathComponent().appending(path: ".swapped-\(target.lastPathComponent)")
        do {
            try manager.moveItem(at: target, to: real)
            try manager.createSymbolicLink(at: target, withDestinationURL: real)
            return NSObject()
        } catch { return nil }
    }
}

private final class MetadataRacingJournal: LifecyclePriorityJournalStore {
    let base: ApplicationSupportLifecyclePriorityJournalStore
    let workspaceURL: URL
    init(base: ApplicationSupportLifecyclePriorityJournalStore, workspaceURL: URL) { self.base = base; self.workspaceURL = workspaceURL }
    func persist(_ journal: LifecyclePriorityJournal) throws {
        try base.persist(journal)
        var data = try Data(contentsOf: workspaceURL); data.append(Data("\nConcurrent authorized bytes.\n".utf8)); try data.write(to: workspaceURL)
    }
    func update(_ journal: LifecyclePriorityJournal) throws { try base.update(journal) }
    func recordFallback(_ journal: LifecyclePriorityJournal) throws { try base.recordFallback(journal) }
    func journal(operationID: UUID) throws -> LifecyclePriorityJournal? { try base.journal(operationID: operationID) }
    func pending(productionsRootPath: String) throws -> [LifecyclePriorityJournal] { try base.pending(productionsRootPath: productionsRootPath) }
}

private final class FailSecondMetadataReplacement: AtomicFileReplacing, @unchecked Sendable {
    private var count = 0
    private let durable = DurableReplacement()
    func replace(data: Data, at url: URL) throws {
        count += 1
        if count == 2 { throw CocoaError(.fileWriteUnknown) }
        try durable.replace(data: data, at: url)
    }
}

private final class MetadataFixture: @unchecked Sendable {
    let root: URL
    let recovery: URL
    let workID: String
    let registryURL: URL
    let workspaceURL: URL
    let canvasURL: URL
    let configuration: ProductionsConfiguration
    let store: ApplicationSupportLifecyclePriorityJournalStore

    init(workID: String = "TASK-0077", kindName: String = "Task", registryLifecycle: String = "Active / Current", workspaceState: String? = nil, workspacePriority: String = "Medium", lifecycleField: String = "State", narrative: Bool = true) throws {
        self.workID = workID
        root = URL(fileURLWithPath: "/private/tmp/LifecyclePriorityTests-\(UUID().uuidString)", isDirectory: true)
        recovery = URL(fileURLWithPath: "/private/tmp/LifecyclePriorityRecovery-\(UUID().uuidString)", isDirectory: true)
        let manager = FileManager.default
        let registryName = workID.hasPrefix("TASK-") ? "Tasks" : workID.hasPrefix("IDEA-") ? "Ideas" : workID.hasPrefix("PROJ-") ? "Projects" : "Initiatives"
        registryURL = root.appending(path: "Office/Registry/\(registryName).md")
        workspaceURL = root.appending(path: "Workspace/\(workID)/\(workID).md")
        canvasURL = root.appending(path: "Office/Threads/Canvas.md")
        try manager.createDirectory(at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: workspaceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createDirectory(at: canvasURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let kind = try metadataKind(workID)
        let headers = metadataHeaders(kind)
        var row = Dictionary(uniqueKeysWithValues: headers.map { ($0, "—") })
        row[metadataIDHeader(kind)] = workID; row["Title"] = "Synthetic \(kindName)"; row[metadataStateHeader(kind)] = registryLifecycle
        row["Priority"] = "Medium"; row["Current lead"] = "Office"; row["Workspace"] = "../../Workspace/\(workID)/\(workID).md"
        let registry = "# Registry\n\n| " + headers.joined(separator: " | ") + " |\n| " + Array(repeating: "---", count: headers.count).joined(separator: " | ") + " |\n| " + headers.map { row[$0]! }.joined(separator: " | ") + " |\n"
        try Data(registry.utf8).write(to: registryURL)
        let state = workspaceState ?? registryLifecycle
        let coreLifecycle = narrative ? "" : "\(lifecycleField): \(state)\n"
        let attention = narrative ? "\n## Lifecycle and Attention\n\nThis \(kindName) is `\(state)` at `\(workspacePriority)` priority and is off Canvas.\n" : ""
        let workspace = "# Synthetic \(kindName)\n\n## Core Record\n\n```text\nTitle: Synthetic \(kindName)\n\(metadataIDHeader(kind)): \(workID)\nType: \(kindName)\n\(coreLifecycle)Priority: \(workspacePriority)\nCurrent lead: Office\nStatus source: Office/Registry/\(registryName).md\n```\n\(attention)\n## Notes\n\nUnrelated bytes stay exact.\n"
        try Data(workspace.utf8).write(to: workspaceURL)
        try Data("# Canvas\n\n| Occurred | Work ID | Event | Reason | Context |\n| --- | --- | --- | --- | --- |\n".utf8).write(to: canvasURL)
        configuration = ProductionsConfiguration(schemaVersion: 2, productionsRootPath: root.path)
        store = ApplicationSupportLifecyclePriorityJournalStore(directory: recovery)
    }

    func request(rule: LifecyclePriorityRule, state: String? = nil, priority: String? = nil) -> LifecyclePriorityRequest {
        LifecyclePriorityRequest(workID: workID, expectedRegistrySHA256: digest(try! Data(contentsOf: registryURL)), expectedWorkspaceSHA256: digest(try! Data(contentsOf: workspaceURL)), priorityRule: rule, desiredLifecycle: state, desiredPriority: priority, correctsOperation: nil)
    }
    func requestFromCurrent(rule: LifecyclePriorityRule) -> LifecyclePriorityRequest { request(rule: rule) }
    func service(operationID: UUID, store override: (any LifecyclePriorityJournalStore)? = nil, replacer: (any AtomicFileReplacing)? = nil, locking: any TaskCheckpointLocking = LocalTaskCheckpointLocking()) -> LifecyclePriorityService {
        LifecyclePriorityService(journalStore: override ?? store, replacer: replacer, locking: locking, contractValidator: MetadataAcceptingValidator(), makeOperationID: { operationID })
    }
    func replace(_ old: String, with new: String) throws {
        let data = try Data(contentsOf: workspaceURL), text = String(decoding: data, as: UTF8.self)
        try Data(text.replacingOccurrences(of: old, with: new).utf8).write(to: workspaceURL)
    }
    func appendWorkspace(_ text: String) throws {
        var data = try Data(contentsOf: workspaceURL); data.append(Data(text.utf8)); try data.write(to: workspaceURL)
    }
    func appendRegistry(_ text: String) throws {
        var data = try Data(contentsOf: registryURL); data.append(Data(text.utf8)); try data.write(to: registryURL)
    }
    func remove() { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: recovery) }
    func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private func metadataKind(_ id: String) throws -> String {
    if id.hasPrefix("TASK-") { return "Task" }; if id.hasPrefix("IDEA-") { return "Idea" }; if id.hasPrefix("PROJ-") { return "Project" }; return "Initiative"
}
private func metadataIDHeader(_ kind: String) -> String { kind == "Project" ? "Project ID" : kind == "Initiative" ? "Initiative ID" : "\(kind) ID" }
private func metadataStateHeader(_ kind: String) -> String { kind == "Idea" ? "Disposition" : "State" }
private func metadataHeaders(_ kind: String) -> [String] {
    switch kind {
    case "Task": ["Task ID", "Title", "State", "Priority", "Current lead", "Initiative", "Project", "Depends on", "Review after", "Short description", "Workspace"]
    case "Idea": ["Idea ID", "Title", "Disposition", "Priority", "Current lead", "Related records", "Review after", "Source artifacts", "Short description", "Workspace"]
    case "Project": ["Project ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"]
    default: ["Initiative ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"]
    }
}
