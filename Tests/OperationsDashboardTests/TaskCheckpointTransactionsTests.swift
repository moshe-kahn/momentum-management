import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OperationsDashboard

final class TaskCheckpointTransactionsTests: XCTestCase {
    private let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000076")!
    private let date = ISO8601DateFormatter().date(from: "2026-08-29T22:30:00Z")!

    func testProductionServiceCommitsOnlyAuthorizedWorkspaceRegionsAndReturnsCompactProof() throws {
        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let journal = CheckpointMemoryJournal()
        let registryBefore = try fixture.read(fixture.registryURL)
        let workspaceBefore = try fixture.read(fixture.workspaceURL)
        let result = try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration)

        XCTAssertEqual(result.outcome, "committed")
        XCTAssertEqual(result.operationUUID, operationID)
        XCTAssertEqual(result.completedStep, "S03")
        XCTAssertEqual(result.registrySHA256, sha256(registryBefore))
        XCTAssertEqual(result.workspaceSHA256Before, sha256(workspaceBefore))
        XCTAssertEqual(result.workspaceSHA256After, sha256(try fixture.read(fixture.workspaceURL)))
        XCTAssertEqual(result.nextGate, "Authorize the next bounded phase.")
        XCTAssertEqual(result.canvasState, "focused")
        XCTAssertTrue(result.journalFinalized)
        XCTAssertFalse(result.fallbackRecorded)
        XCTAssertTrue(result.historicalCommitProven)
        XCTAssertEqual(try fixture.read(fixture.registryURL), registryBefore)

        let postimage = String(decoding: try fixture.read(fixture.workspaceURL), as: UTF8.self)
        XCTAssertTrue(postimage.contains("- [x] **S03 — Implement checkpoint.**"))
        XCTAssertTrue(postimage.contains("Next step: Authorize the next bounded phase."))
        XCTAssertTrue(postimage.contains("Last validated state: Deterministic checkpoint validation passed."))
        XCTAssertTrue(postimage.contains("### S03 - \(operationID.uuidString)"))
        XCTAssertTrue(postimage.contains("- Unit suite passed."))
        XCTAssertTrue(postimage.contains("- Production adapter passed."))
        XCTAssertTrue(postimage.contains("Unknown field: Preserve this exactly."))
        XCTAssertTrue(postimage.contains("## Unrecognized Section\n\nByte-for-byte retained."))
        XCTAssertEqual(journal.values.last?.terminalState, .committedAndCurrent)
    }

    func testAbsentCheckpointEvidenceIsCreatedAtDocumentEndAndExistingEvidenceAppends() throws {
        for existing in [false, true] {
            let fixture = try CheckpointFixture(existingEvidence: existing); defer { fixture.remove() }
            _ = try service().perform(request: fixture.request(), configuration: fixture.configuration)
            let text = String(decoding: try fixture.read(fixture.workspaceURL), as: UTF8.self)
            XCTAssertEqual(text.components(separatedBy: "## Checkpoint Evidence").count, 2)
            XCTAssertTrue(text.hasSuffix("- Production adapter passed.\n"))
            if existing { XCTAssertTrue(text.contains("### S02 - 00000000-0000-0000-0000-000000000002")) }
        }
    }

    func testCheckpointEvidenceMayPrecedeUnknownAndMachineSectionsAndVariableSizeFieldsPreserveSuffix() throws {
        let fixture = try CheckpointFixture(existingEvidence: true, laterSections: true); defer { fixture.remove() }
        let before = String(decoding: try fixture.read(fixture.workspaceURL), as: UTF8.self)
        let suffixStart = try XCTUnwrap(before.range(of: "## Accepted Handoffs"))
        let suffix = String(before[suffixStart.lowerBound...])
        let request = fixture.request(
            nextStep: "Short.",
            lastValidatedState: "A substantially longer replacement line.\nA continuation with a different line count."
        )
        _ = try service().perform(request: request, configuration: fixture.configuration)
        let after = String(decoding: try fixture.read(fixture.workspaceURL), as: UTF8.self)
        let afterSuffixStart = try XCTUnwrap(after.range(of: "## Accepted Handoffs"))
        XCTAssertEqual(String(after[afterSuffixStart.lowerBound...]), suffix)
        let evidence = try XCTUnwrap(after.range(of: "### S03 - \(operationID.uuidString)"))
        XCTAssertLessThan(evidence.lowerBound, afterSuffixStart.lowerBound)
        XCTAssertTrue(after.contains("## Later Unknown Section\n\nLater bytes remain exact."))
    }

    func testExhaustiveTerminalProofStartupAndMonotonicAlgebra() {
        let proving: Set<OfficeWorkspaceTerminalState> = [
            .committedAndCurrent, .reconciledCommittedAndCurrent,
            .historicallyCommittedAndSuperseded, .historicallyCommittedWithCurrentStateUncertain,
            .committedReloadFailed, .journalFinalizationFailedCommittedAndCurrent,
            .journalFinalizationFailedHistoricallyCommittedAndSuperseded,
            .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain,
        ]
        XCTAssertEqual(Set(OfficeWorkspaceTerminalState.allCases.filter(\.provesHistoricalCommit)), proving)
        XCTAssertEqual(
            Set(OfficeWorkspaceTerminalState.allCases.filter(\.isStartupIncomplete)),
            [.uncertain, .committedReloadFailed, .historicallyCommittedWithCurrentStateUncertain]
        )
        XCTAssertEqual(OfficeWorkspaceTerminalState.merging(current: .definiteNoCommit, proposed: .committedAndCurrent), .definiteNoCommit)
        XCTAssertEqual(OfficeWorkspaceTerminalState.merging(current: .uncertain, proposed: .reconciledCommittedAndCurrent), .reconciledCommittedAndCurrent)
        XCTAssertEqual(OfficeWorkspaceTerminalState.merging(current: .committedAndCurrent, proposed: .historicallyCommittedAndSuperseded), .historicallyCommittedAndSuperseded)
        XCTAssertEqual(OfficeWorkspaceTerminalState.merging(current: .historicallyCommittedAndSuperseded, proposed: .uncertain), .historicallyCommittedWithCurrentStateUncertain)
        XCTAssertEqual(OfficeWorkspaceTerminalState.merging(current: .journalFinalizationFailedCommittedAndCurrent, proposed: .historicallyCommittedAndSuperseded), .journalFinalizationFailedHistoricallyCommittedAndSuperseded)
        XCTAssertEqual(OfficeWorkspaceTerminalState.merging(current: .committedAndCurrent, proposed: .journalFinalizationFailedCommittedAndCurrent), .journalFinalizationFailedCommittedAndCurrent)
        XCTAssertEqual(OfficeWorkspaceTerminalState.merging(current: .definiteNoCommit, proposed: .journalFinalizationFailedDefiniteNoCommit), .journalFinalizationFailedDefiniteNoCommit)
    }

    func testContractGateRejectsBeforeUUIDLockJournalOrMutation() throws {
        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let journal = CheckpointMemoryJournal()
        let lock = RecordingCheckpointLock()
        let before = try fixture.snapshot()
        let checkpointService = TaskCheckpointService(
            journalStore: journal, locking: lock,
            contractValidator: RejectingV112Validator(), makeOperationID: { XCTFail("UUID must not be issued"); return UUID() }
        )
        let failure = try captureFailure { try checkpointService.perform(request: fixture.request(), configuration: fixture.configuration) }
        XCTAssertEqual(failure.exitCode, 2)
        XCTAssertEqual(failure.result.classification, "contractNotAdopted")
        XCTAssertNil(failure.result.operationUUID)
        XCTAssertFalse(lock.acquired)
        XCTAssertTrue(journal.values.isEmpty)
        XCTAssertEqual(try fixture.snapshot(), before)
        try assertPrejournalFailure(failure, service: checkpointService, configuration: fixture.configuration)
    }

    func testHashStepCoreIdentityRelationshipDoneAndInputFailuresArePremutation() throws {
        let cases: [(String, (CheckpointFixture) throws -> TaskCheckpointRequest)] = [
            ("workspace hash", { fixture in fixture.request(workspaceHash: String(repeating: "0", count: 64)) }),
            ("registry hash", { fixture in fixture.request(registryHash: String(repeating: "0", count: 64)) }),
            ("step", { fixture in fixture.request(step: "S09") }),
            ("evidence", { fixture in fixture.request(evidence: []) }),
        ]
        for (_, makeRequest) in cases {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal(), before = try fixture.snapshot()
            let checkpointService = service(journal: journal, locking: RecordingCheckpointLock())
            let failure = try captureFailure { try checkpointService.perform(request: try makeRequest(fixture), configuration: fixture.configuration) }
            XCTAssertEqual(failure.exitCode, 2)
            XCTAssertFalse(failure.result.historicalCommitProven)
            XCTAssertTrue(journal.values.isEmpty)
            XCTAssertEqual(try fixture.snapshot(), before)
            try assertPrejournalFailure(failure, service: checkpointService, configuration: fixture.configuration)
        }

        let malformed: [(String, String)] = [
            ("done", "Done / Complete"),
            ("lead", ""),
            ("project", "PROJ-9999"),
            ("dependency", "TASK-9999 other"),
        ]
        for (kind, replacement) in malformed {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            switch kind {
            case "done": try fixture.replaceRegistry("Active / Current", with: replacement)
            case "lead": try fixture.replaceRegistry("| Office | — |", with: "| \(replacement) | — |")
            case "project": try fixture.replaceWorkspace("Project: PROJ-0008 — Synthetic Project", with: "Project: \(replacement)")
            default: try fixture.replaceWorkspace("Depends on: TASK-0001 baseline", with: "Depends on: \(replacement)")
            }
            let journal = CheckpointMemoryJournal(), before = try fixture.snapshot()
            let checkpointService = service(journal: journal)
            let failure = try captureFailure { try checkpointService.perform(request: fixture.request(), configuration: fixture.configuration) }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid")
            XCTAssertTrue(journal.values.isEmpty)
            XCTAssertEqual(try fixture.snapshot(), before)
            try assertPrejournalFailure(failure, service: checkpointService, configuration: fixture.configuration)
        }
    }

    func testLockAndInitialJournalFailureAreDefinitePremutation() throws {
        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        let denied = service(locking: DeniedCheckpointLock())
        let lockFailure = try captureFailure { try denied.perform(request: fixture.request(), configuration: fixture.configuration) }
        XCTAssertEqual(lockFailure.result.classification, "lockUnavailable")
        XCTAssertEqual(lockFailure.exitCode, 2)
        XCTAssertEqual(try fixture.snapshot(), before)
        try assertPrejournalFailure(lockFailure, service: denied, configuration: fixture.configuration)

        let journal = CheckpointMemoryJournal(); journal.failPersist = true
        let journalService = service(journal: journal)
        let journalFailure = try captureFailure { try journalService.perform(request: fixture.request(), configuration: fixture.configuration) }
        XCTAssertEqual(journalFailure.result.classification, "journalCreateFailed")
        XCTAssertEqual(journalFailure.exitCode, 2)
        XCTAssertEqual(try fixture.snapshot(), before)
        try assertPrejournalFailure(journalFailure, service: journalService, configuration: fixture.configuration)
    }

    func testPreparationRaceFinalizesDefiniteNoCommitWithoutOverwrite() throws {
        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let journal = CheckpointMemoryJournal()
        journal.afterPersist = { try? fixture.replaceWorkspace("Byte-for-byte retained.", with: "Concurrent valid-looking mutation.") }
        let result = try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "not-committed")
        XCTAssertEqual(result.classification, "definite-no-commit")
        XCTAssertEqual(journal.values.last?.terminalState, .definiteNoCommit)
        XCTAssertTrue(String(decoding: try fixture.read(fixture.workspaceURL), as: UTF8.self).contains("Concurrent valid-looking mutation."))
    }

    func testReplacementThrowPreimageIsDefiniteNoCommitAndWriteThenThrowReconciles() throws {
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal()
            let result = try service(journal: journal, replacer: ThrowingCheckpointReplacer()).perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "not-committed")
            XCTAssertEqual(result.classification, "definite-no-commit")
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
        }
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal()
            let result = try service(journal: journal, replacer: WriteThenThrowCheckpointReplacer()).perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "committed")
            XCTAssertEqual(journal.values.last?.terminalState, .reconciledCommittedAndCurrent)
            XCTAssertTrue(result.historicalCommitProven)
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
        }
    }

    func testPartialPostimageAndJournalReadFailureAfterReplacementThrowAreUncertainNoRetry() throws {
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal()
            let result = try service(journal: journal, replacer: PartialThenThrowCheckpointReplacer()).perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "uncertain")
            XCTAssertEqual(result.classification, "uncertain")
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
        }
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal(); journal.failRead = true
            let failure = try captureFailure {
                try service(journal: journal, replacer: ThrowingCheckpointReplacer()).perform(request: fixture.request(), configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertEqual(failure.result.classification, "possible-commit")
            XCTAssertFalse(failure.result.historicalCommitProven)
        }
    }

    func testSuccessfulReplacementReloadFailureAndJournalReadFailurePreserveCommitProof() throws {
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal()
            let result = try service(journal: journal, replacer: CorruptAfterWriteCheckpointReplacer()).perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "uncertain")
            XCTAssertEqual(result.classification, "historically-committed-current-state-uncertain")
            XCTAssertTrue(result.historicalCommitProven)
            XCTAssertEqual(journal.values.last?.terminalState, .committedReloadFailed)
        }
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal(); journal.failReadAfterPersist = true
            let failure = try captureFailure {
                try service(journal: journal, replacer: CorruptAfterWriteCheckpointReplacer()).perform(request: fixture.request(), configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertTrue(failure.result.historicalCommitProven)
            XCTAssertFalse(failure.result.journalFinalized)
        }
    }

    func testProvenCommitAndDefiniteNoCommitFinalizationFallbackFlagsAreExact() throws {
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal(); journal.failNormalUpdates = true
            let failure = try captureFailure { try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration) }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertTrue(failure.result.historicalCommitProven)
            XCTAssertFalse(failure.result.journalFinalized)
            XCTAssertTrue(failure.result.fallbackRecorded)
            XCTAssertEqual(journal.values.last?.terminalState, .journalFinalizationFailedCommittedAndCurrent)
        }
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal(); journal.failNormalUpdates = true
            let failure = try captureFailure {
                try service(journal: journal, replacer: ThrowingCheckpointReplacer()).perform(request: fixture.request(), configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.exitCode, 2)
            XCTAssertFalse(failure.result.historicalCommitProven)
            XCTAssertTrue(failure.result.fallbackRecorded)
            XCTAssertEqual(journal.values.last?.terminalState, .journalFinalizationFailedDefiniteNoCommit)
        }
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal(); journal.failNormalUpdates = true; journal.failFallback = true
            let failure = try captureFailure { try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration) }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertFalse(failure.result.fallbackRecorded)
            XCTAssertTrue(failure.result.historicalCommitProven)
        }
    }

    func testJournalFirstInspectionCurrentSupersededReturnToPreimageAndNoCommit() throws {
        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let journal = CheckpointMemoryJournal()
        let checkpointService = service(journal: journal)
        _ = try checkpointService.perform(request: fixture.request(), configuration: fixture.configuration)
        var inspection = try checkpointService.inspect(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(inspection.classification, "committed-and-current")
        XCTAssertTrue(inspection.historicalCommitProven)

        try fixture.replaceWorkspace("Byte-for-byte retained.", with: "Later valid canonical mutation.")
        inspection = try checkpointService.inspect(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(inspection.classification, "historically-committed-and-superseded")
        XCTAssertTrue(inspection.historicalCommitProven)

        try journal.restoreWorkspacePreimage(to: fixture.workspaceURL, operationID: operationID)
        inspection = try checkpointService.inspect(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(inspection.classification, "historically-committed-current-state-uncertain")
        XCTAssertTrue(inspection.historicalCommitProven)

        let noCommitFixture = try CheckpointFixture(); defer { noCommitFixture.remove() }
        let noCommitJournal = CheckpointMemoryJournal()
        let noCommitService = service(journal: noCommitJournal, replacer: ThrowingCheckpointReplacer())
        _ = try noCommitService.perform(request: noCommitFixture.request(), configuration: noCommitFixture.configuration)
        noCommitFixture.remove()
        let noCommitInspection = try noCommitService.inspect(operationID: operationID, configuration: noCommitFixture.configuration)
        XCTAssertEqual(noCommitInspection.outcome, "not-committed")
        XCTAssertEqual(noCommitInspection.classification, "definite-no-commit")
    }

    func testInspectionAcceptsLaterDoneCompleteIdentityAsHistoricallyCommittedAndSuperseded() throws {
        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let journal = CheckpointMemoryJournal()
        let checkpointService = service(journal: journal)
        _ = try checkpointService.perform(request: fixture.request(), configuration: fixture.configuration)
        try fixture.replaceRegistry("Active / Current", with: "Done / Complete")
        let inspection = try checkpointService.inspect(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(inspection.outcome, "committed")
        XCTAssertEqual(inspection.classification, "historically-committed-and-superseded")
        XCTAssertTrue(inspection.historicalCommitProven)
    }

    func testStartupRecoveryFiltersExactlyAndNeverReplays() throws {
        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let seedStore = CheckpointMemoryJournal()
        let source = try service(journal: seedStore).perform(request: fixture.request(), configuration: fixture.configuration)
        XCTAssertEqual(source.outcome, "committed")
        let templateJournal = try XCTUnwrap(seedStore.values.last)
        let store = CheckpointMemoryJournal()
        for (index, state) in OfficeWorkspaceTerminalState.allCases.enumerated() {
            var copy = templateJournal
            copy = copy.with(operationID: UUID(), state: state)
            store.values.append(copy)
            XCTAssertEqual(copy.terminalState?.isStartupIncomplete, [.uncertain, .committedReloadFailed, .historicallyCommittedWithCurrentStateUncertain].contains(state), "state \(index)")
        }
        let before = try fixture.snapshot()
        XCTAssertEqual(TaskCheckpointService(journalStore: store, contractValidator: AcceptingV112Validator()).startupRecovery().count, 3)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testCLIParserPreservesEvidenceOrderMalformedInvocationsRemainHeadlessAndJSONFlagsArePresent() throws {
        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let arguments = fixture.arguments()
        let invocation = try HeadlessOfficeCommandLine.parse(Array(arguments.dropFirst()))
        guard case let .checkpoint(request, configuration) = invocation else { return XCTFail("Expected checkpoint invocation") }
        XCTAssertEqual(request.acceptedEvidence, ["Unit suite passed.", "Production adapter passed."])
        XCTAssertEqual(configuration.productionsRootPath, fixture.root.path)
        XCTAssertEqual(configuration.rootURL, fixture.configuration.rootURL)

        var output: [String] = []
        let commandStore = CheckpointMemoryJournal()
        let commandService = service(journal: commandStore)
        let exitCode = HeadlessOfficeCommandLine.runIfRequested(arguments: arguments, service: commandService, write: { output.append($0) })
        XCTAssertEqual(exitCode, 0)
        let decoded = try JSONDecoder().decode(TaskCheckpointCommandResult.self, from: XCTUnwrap(output.first).data(using: .utf8)!)
        XCTAssertTrue(decoded.journalFinalized)
        XCTAssertFalse(decoded.fallbackRecorded)
        XCTAssertTrue(decoded.historicalCommitProven)

        output.removeAll()
        let inspectArguments = [
            "OperationsDashboard", "office", "inspect", "--productions-root", fixture.root.path,
            "--operation", operationID.uuidString,
        ]
        XCTAssertEqual(HeadlessOfficeCommandLine.runIfRequested(arguments: inspectArguments, service: commandService, write: { output.append($0) }), 0)
        XCTAssertEqual(try decodeResult(output).classification, "committed-and-current")

        output.removeAll()
        XCTAssertEqual(HeadlessOfficeCommandLine.runIfRequested(arguments: ["OperationsDashboard", "task", "bogus"], service: service(), write: { output.append($0) }), 2)
        XCTAssertEqual(try JSONDecoder().decode(TaskCheckpointCommandResult.self, from: XCTUnwrap(output.first).data(using: .utf8)!).classification, "usage")
        XCTAssertNil(HeadlessOfficeCommandLine.runIfRequested(arguments: ["OperationsDashboard"], service: service()))
    }

    func testProductionCommandAdapterPreservesFailureExitCodesNoRetryAndStableFlags() throws {
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            var output: [String] = []
            let code = HeadlessOfficeCommandLine.runIfRequested(
                arguments: fixture.arguments(), service: service(locking: DeniedCheckpointLock()),
                write: { output.append($0) }
            )
            let result = try decodeResult(output)
            XCTAssertEqual(code, 2)
            XCTAssertEqual(result.classification, "lockUnavailable")
            XCTAssertFalse(result.historicalCommitProven)
            XCTAssertFalse(result.journalFinalized)
            XCTAssertFalse(result.fallbackRecorded)
            XCTAssertNil(result.inspectCommand)
            XCTAssertTrue(result.diagnostic?.contains("No operation journal was created") == true)
        }
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal(); journal.failPersist = true
            var output: [String] = []
            let code = HeadlessOfficeCommandLine.runIfRequested(
                arguments: fixture.arguments(), service: service(journal: journal),
                write: { output.append($0) }
            )
            let result = try decodeResult(output)
            XCTAssertEqual(code, 2)
            XCTAssertEqual(result.classification, "journalCreateFailed")
            XCTAssertFalse(result.historicalCommitProven)
            XCTAssertNil(result.inspectCommand)
            XCTAssertTrue(result.diagnostic?.contains("no durable operation journal was created") == true)
        }
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            var output: [String] = []
            let code = HeadlessOfficeCommandLine.runIfRequested(
                arguments: fixture.arguments(), service: service(replacer: PartialThenThrowCheckpointReplacer()),
                write: { output.append($0) }
            )
            let result = try decodeResult(output)
            XCTAssertEqual(code, 3)
            XCTAssertEqual(result.outcome, "uncertain")
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
            XCTAssertNotNil(result.operationUUID)
            XCTAssertEqual(
                result.inspectCommand,
                "OperationsDashboard office inspect --productions-root \(fixture.root.path) --operation \(operationID.uuidString)"
            )
        }
        do {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journal = CheckpointMemoryJournal(); journal.failNormalUpdates = true
            var output: [String] = []
            let code = HeadlessOfficeCommandLine.runIfRequested(
                arguments: fixture.arguments(), service: service(journal: journal),
                write: { output.append($0) }
            )
            let result = try decodeResult(output)
            XCTAssertEqual(code, 3)
            XCTAssertTrue(result.historicalCommitProven)
            XCTAssertFalse(result.journalFinalized)
            XCTAssertTrue(result.fallbackRecorded)
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
        }
    }

    func testLiveAdoptedV112RuntimeGatePassesReadOnlyCanonicalInspection() throws {
        let configuration = ProductionsConfiguration(schemaVersion: 2, productionsRootPath: "/Users/kahntra/Productions")
        XCTAssertNoThrow(try AdoptedOfficeV112ContractValidator().validate(configuration: configuration))
    }

    func testExactAdoptedPackageMembersAndDocumentRegistryRowsGateBeforeUUIDLockJournalAndWrite() throws {
        let baseline = try ActivationFixture(); defer { baseline.remove() }
        XCTAssertNoThrow(try AdoptedOfficeV112ContractValidator().validate(configuration: baseline.configuration))

        for path in AdoptedOfficeV112ContractValidator.immutableSHA256.keys.sorted() {
            for variant in ActivationFixture.ImmutableMutation.allCases {
                let fixture = try ActivationFixture(); defer { fixture.remove() }
                try fixture.mutateImmutable(path: path, variant: variant)
                try assertContractGateIsPrejournal(fixture)
            }
        }
        for documentID in ["DOC-0004", "DOC-0005", "DOC-0010", "DOC-0016"] {
            for variant in ActivationFixture.RegistryRowMutation.allCases {
                let fixture = try ActivationFixture(); defer { fixture.remove() }
                try fixture.mutateDocumentRegistry(documentID: documentID, variant: variant)
                try assertContractGateIsPrejournal(fixture)
            }
        }
    }

    func testMutableRegistryAndProvisionalWorkspaceMigrationContradictionsGateBeforeUUIDOrJournal() throws {
        let mutations: [(ActivationFixture) throws -> Void] = [
            { try $0.replace(path: "Office/Registry/Tasks.md", old: "Review after", new: "Review afterwards", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Ideas.md", old: "Review after", new: "Review afterwards", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Projects.md", old: "Review after", new: "Review afterwards", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Initiatives.md", old: "Review after", new: "Review afterwards", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Tasks.md", old: "| TASK-", new: "| BAD-", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Ideas.md", old: "| IDEA-", new: "| BAD-", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Projects.md", old: "| PROJ-", new: "| BAD-", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Initiatives.md", old: "| INIT-", new: "| BAD-", firstOnly: true) },
            { try $0.replace(path: "Warehouse/Reference/Document Registry.md", old: "Revision date: 2026-08-29", new: "Revision date: 2026-08-28", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Tasks.md", old: "| --- | --- |", new: "| -- | --- |", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Ideas.md", old: "TASK-0017@done-complete", new: "TASK-0017@accepted-handoff:wrong", firstOnly: true) },
            { try $0.replace(path: "Workspace/IDEA-0006/IDEA-0006.md", old: "| TASK-0017@done-complete |", new: "| TASK-0017@accepted-handoff:wrong |", firstOnly: true) },
            { try $0.replace(path: "Workspace/IDEA-0006/IDEA-0006.md", old: "| --- | --- | --- | --- | --- | --- |", new: "| -- | --- | --- | --- | --- | --- |", firstOnly: true) },
            { try $0.append(path: "Workspace/TASK-0017/TASK-0017.md", text: "\n## Provisional Completion-Review Hook\n\nParallel mechanism.\n") },
            { try $0.append(path: "Workspace/TASK-0017/TASK-0017.md", text: "\n## Eligibility Reviews\n\n| Hook | Review question | Disposition | Decided at | Reconsider after | Replacement |\n| --- | --- | --- | --- | --- | --- |\n") },
            { try $0.replace(path: "Office/Registry/Ideas.md", old: "[IDEA-0006](../../Workspace/IDEA-0006/IDEA-0006.md)", new: "[IDEA-0006](../../Workspace/IDEA-9999/IDEA-9999.md)", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Ideas.md", old: "Explore Product Provisioning and Repair Tool", new: "Wrong Idea title", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Tasks.md", old: "[TASK-0017](../../Workspace/TASK-0017/TASK-0017.md)", new: "[TASK-0017](../../Workspace/TASK-9999/TASK-9999.md)", firstOnly: true) },
            { try $0.replace(path: "Office/Registry/Tasks.md", old: "Decide Repository and Reference-Storage Structure", new: "Wrong Task title", firstOnly: true) },
            { try $0.replace(path: "Workspace/IDEA-0006/IDEA-0006.md", old: "# Explore Product Provisioning and Repair Tool", new: "# Wrong Idea title", firstOnly: true) },
            { try $0.replace(path: "Workspace/IDEA-0006/IDEA-0006.md", old: "## Idea Record", new: "## Task Record", firstOnly: true) },
            { try $0.replace(path: "Workspace/IDEA-0006/IDEA-0006.md", old: "Idea ID: IDEA-0006", new: "Idea ID: IDEA-9999", firstOnly: true) },
            { try $0.replace(path: "Workspace/IDEA-0006/IDEA-0006.md", old: "Disposition: Open", new: "Disposition: Archived", firstOnly: true) },
            { try $0.replace(path: "Workspace/IDEA-0006/IDEA-0006.md", old: "Priority: Low", new: "Priority: High", firstOnly: true) },
            { try $0.replace(path: "Workspace/IDEA-0006/IDEA-0006.md", old: "Current lead: Office", new: "Current lead: Product", firstOnly: true) },
            { try $0.replace(path: "Workspace/IDEA-0006/IDEA-0006.md", old: "Workspace: `Workspace/IDEA-0006/`", new: "Workspace: `Workspace/IDEA-9999/`", firstOnly: true) },
            { try $0.replace(path: "Workspace/TASK-0017/TASK-0017.md", old: "# Decide Repository and Reference-Storage Structure", new: "# Wrong Task title", firstOnly: true) },
            { try $0.replace(path: "Workspace/TASK-0017/TASK-0017.md", old: "## Core Record", new: "## Idea Record", firstOnly: true) },
            { try $0.replace(path: "Workspace/TASK-0017/TASK-0017.md", old: "Task ID: TASK-0017", new: "Task ID: TASK-9999", firstOnly: true) },
            { try $0.replace(path: "Workspace/TASK-0017/TASK-0017.md", old: "Title: Decide Repository and Reference-Storage Structure", new: "Title: Wrong Task title", firstOnly: true) },
            { try $0.replace(path: "Workspace/TASK-0017/TASK-0017.md", old: "Status source: Productions/Office/Registry/Tasks.md", new: "Status source: Office/Registry/Ideas.md", firstOnly: true) },
        ]
        for mutate in mutations {
            let fixture = try ActivationFixture(); defer { fixture.remove() }
            try mutate(fixture)
            try assertContractGateIsPrejournal(fixture)
        }
    }

    func testMalformedSectionsFieldsStepsAndSymlinkedTargetsRejectBeforeJournal() throws {
        let workspaceMutations: [(String, String)] = [
            ("## Steps", "## Steps\n\n- [ ] **S03 — Duplicate.**\n\n## Steps"),
            ("Next step: Implement the transaction.", "Next step: First.\nNext step: Second."),
            ("- [ ] **S03 — Implement checkpoint.**", "- [x] **S03 — Implement checkpoint.**"),
            ("- [ ] **S04 — Later work.**", "- [ ] **S03 — Duplicate key.**"),
            ("# Synthetic checkpoint", "No top-level title"),
            ("# Synthetic checkpoint", "# Wrong title"),
            ("# Synthetic checkpoint", "# Synthetic checkpoint\n\n# Synthetic checkpoint"),
            ("# Synthetic checkpoint", "```text\n# Synthetic checkpoint\n```"),
        ]
        for (old, new) in workspaceMutations {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            try fixture.replaceWorkspace(old, with: new)
            let journal = CheckpointMemoryJournal(), before = try fixture.snapshot()
            let failure = try captureFailure { try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration) }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid")
            XCTAssertTrue(journal.values.isEmpty)
            XCTAssertEqual(try fixture.snapshot(), before)
        }

        for (old, new) in [
            ("| Task ID | Title |", "| Task identifier | Title |"),
            ("| --- | --- |", "| -- | --- |"),
        ] {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            try fixture.replaceRegistry(old, with: new)
            let journal = CheckpointMemoryJournal(), before = try fixture.snapshot()
            let checkpointService = service(journal: journal)
            let failure = try captureFailure { try checkpointService.perform(request: fixture.request(), configuration: fixture.configuration) }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid")
            XCTAssertTrue(journal.values.isEmpty)
            XCTAssertEqual(try fixture.snapshot(), before)
            try assertPrejournalFailure(failure, service: checkpointService, configuration: fixture.configuration)
        }

        for target in ["registry", "workspace"] {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            try fixture.replaceTargetWithSymlink(target)
            let journal = CheckpointMemoryJournal(), before = try fixture.snapshot()
            let failure = try captureFailure { try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration) }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid")
            XCTAssertTrue(journal.values.isEmpty)
            XCTAssertEqual(try fixture.snapshot(), before)
        }
    }

    func testPrivateTmpLiteralRootSurvivesFoundationStandardizationAndUnsafeAliasesRemainRejected() throws {
        let manager = FileManager.default
        let fixedHome = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: "TaskCheckpointFixedHome-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: fixedHome, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: fixedHome) }

        let previousFixedHome = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        XCTAssertEqual(setenv("CFFIXED_USER_HOME", fixedHome.path, 1), 0)
        defer {
            if let previousFixedHome {
                setenv("CFFIXED_USER_HOME", previousFixedHome, 1)
            } else {
                unsetenv("CFFIXED_USER_HOME")
            }
        }

        let privateTmpRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        let activationFixture = try ActivationFixture(rootParent: privateTmpRoot)
        defer { activationFixture.remove() }
        XCTAssertNoThrow(
            try AdoptedOfficeV112ContractValidator().validate(configuration: activationFixture.configuration)
        )

        let normalizationDirectory = try NormalizationEquivalentDirectory(parent: privateTmpRoot)
        defer { normalizationDirectory.remove() }
        let fixture = try CheckpointFixture(rootParent: normalizationDirectory.canonicalURL)
        defer { fixture.remove() }
        let normalizationAlias = try normalizationDirectory.alias(for: fixture.root)
        XCTAssertEqual(normalizationAlias, fixture.root.path)
        XCTAssertFalse(normalizationAlias.utf8.elementsEqual(fixture.root.path.utf8))
        let standardizedAlias = fixture.root.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/", options: .anchored)
        XCTAssertEqual(fixture.root.standardizedFileURL.path, standardizedAlias)
        XCTAssertEqual(fixture.configuration.productionsRootPath, fixture.root.path)

        let journal = CheckpointMemoryJournal()
        let checkpointService = service(journal: journal)
        var commandOutput: [String] = []
        XCTAssertEqual(
            HeadlessOfficeCommandLine.runIfRequested(
                arguments: fixture.arguments(), service: checkpointService,
                write: { commandOutput.append($0) }
            ),
            0
        )
        let committed = try decodeResult(commandOutput)
        XCTAssertEqual(committed.outcome, "committed")
        XCTAssertEqual(committed.classification, "committed-and-current")
        XCTAssertTrue(try XCTUnwrap(journal.values.first?.productionsRootPath).utf8.elementsEqual(fixture.root.path.utf8))
        XCTAssertEqual(
            try checkpointService.inspect(operationID: operationID, configuration: fixture.configuration).classification,
            "committed-and-current"
        )
        let frozenJournal = journal.values
        for alias in [standardizedAlias, normalizationAlias] {
            let aliasInspection = try checkpointService.inspect(
                operationID: operationID,
                configuration: ProductionsConfiguration(schemaVersion: 2, productionsRootPath: alias)
            )
            XCTAssertEqual(aliasInspection.classification, "historically-committed-current-state-uncertain", alias)
            XCTAssertTrue(aliasInspection.historicalCommitProven, alias)
        }
        XCTAssertEqual(journal.values, frozenJournal)

        let normalizationJournal = CheckpointMemoryJournal()
        let normalizationService = service(journal: normalizationJournal)
        var normalizationArguments = fixture.arguments()
        let rootOption = try XCTUnwrap(normalizationArguments.firstIndex(of: "--productions-root"))
        normalizationArguments[rootOption + 1] = normalizationAlias
        let beforeNormalizationAttempt = try fixture.snapshot()
        var normalizationOutput: [String] = []
        XCTAssertEqual(
            HeadlessOfficeCommandLine.runIfRequested(
                arguments: normalizationArguments, service: normalizationService,
                write: { normalizationOutput.append($0) }
            ),
            2
        )
        let normalizationFailure = try decodeResult(normalizationOutput)
        XCTAssertEqual(normalizationFailure.outcome, "not-committed")
        XCTAssertEqual(normalizationFailure.classification, "contractNotAdopted")
        XCTAssertNil(normalizationFailure.operationUUID)
        XCTAssertTrue(normalizationFailure.diagnostic?.contains("one exact absolute spelling") == true)
        XCTAssertTrue(normalizationJournal.values.isEmpty)
        XCTAssertEqual(try fixture.snapshot(), beforeNormalizationAttempt)

        let lexicalAliases = [
            fixture.root.path + "/",
            fixture.root.path.replacingOccurrences(of: "/private/tmp/", with: "/private//tmp/", options: .anchored),
            fixture.root.path.replacingOccurrences(of: "/private/tmp/", with: "/private/tmp/./", options: .anchored),
            fixture.root.deletingLastPathComponent().path + "/unused/../" + fixture.root.lastPathComponent,
            String(fixture.root.path.dropFirst()),
        ]
        for alias in lexicalAliases {
            let aliasJournal = CheckpointMemoryJournal()
            var issuedUUID = false
            let aliasService = TaskCheckpointService(
                journalStore: aliasJournal, contractValidator: AcceptingV112Validator(),
                makeOperationID: { issuedUUID = true; return self.operationID }
            )
            let before = try fixture.snapshot()
            let failure = try captureFailure {
                try aliasService.perform(
                    request: fixture.request(),
                    configuration: ProductionsConfiguration(schemaVersion: 2, productionsRootPath: alias)
                )
            }
            XCTAssertEqual(failure.result.classification, "contractNotAdopted", alias)
            XCTAssertNil(failure.result.operationUUID, alias)
            XCTAssertFalse(issuedUUID, alias)
            XCTAssertTrue(aliasJournal.values.isEmpty, alias)
            XCTAssertEqual(try fixture.snapshot(), before, alias)
        }

        let symlinkAlias = fixture.root.deletingLastPathComponent()
            .appending(path: "TaskCheckpointAlias-\(UUID().uuidString)")
        try manager.createSymbolicLink(at: symlinkAlias, withDestinationURL: fixture.root)
        defer { try? manager.removeItem(at: symlinkAlias) }
        let unsafeAliases = [
            (standardizedAlias, "symbolic link"),
            (symlinkAlias.path, "symbolic link"),
            (fixture.root.path.replacingOccurrences(of: "/private/", with: "/Private/", options: .anchored), "exact canonical spelling"),
        ]
        for (alias, diagnosticFragment) in unsafeAliases {
            let aliasJournal = CheckpointMemoryJournal()
            let aliasService = service(journal: aliasJournal)
            let before = try fixture.snapshot()
            let failure = try captureFailure {
                try aliasService.perform(
                    request: fixture.request(),
                    configuration: ProductionsConfiguration(schemaVersion: 2, productionsRootPath: alias)
                )
            }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid", alias)
            XCTAssertTrue(failure.result.diagnostic?.contains(diagnosticFragment) == true, alias)
            XCTAssertTrue(aliasJournal.values.isEmpty, alias)
            XCTAssertEqual(try fixture.snapshot(), before, alias)
        }
    }

    func testEveryMalformedDuplicateRequestedStepOccurrenceRejectsBeforeJournalOrWrite() throws {
        let malformedDuplicates = [
            "- [] **S03 — malformed empty brackets.**",
            "- [  ] **S03 — malformed marker spacing.**",
            "- [ ] S03 — missing bold markers.",
            "- [ ] *S03 — malformed bold marker.*",
            " - [ ] **S03 — malformed leading spacing.**",
            "- [ ] ** S03 — malformed identifier spacing.**",
        ]
        for malformed in malformedDuplicates {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            try fixture.replaceWorkspace("- [ ] **S04 — Later work.**", with: malformed)
            let journal = CheckpointMemoryJournal()
            let before = try fixture.snapshot()
            let checkpointService = service(journal: journal)
            let failure = try captureFailure {
                try checkpointService.perform(request: fixture.request(), configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid")
            XCTAssertTrue(failure.result.diagnostic?.contains("requested Step ID must occur exactly once") == true)
            XCTAssertTrue(journal.values.isEmpty)
            XCTAssertEqual(try fixture.snapshot(), before)
            try assertPrejournalFailure(failure, service: checkpointService, configuration: fixture.configuration)
        }
    }

    func testCanonicalTargetsAndReloadsRejectNonRegularFilesWithoutFollowingThem() throws {
        for target in ["registry", "workspace"] {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let request = fixture.request()
            let targetURL = target == "registry" ? fixture.registryURL : fixture.workspaceURL
            let saved = targetURL.deletingLastPathComponent().appending(path: ".saved-\(targetURL.lastPathComponent)")
            try FileManager.default.moveItem(at: targetURL, to: saved)
            XCTAssertEqual(mkfifo(targetURL.path, mode_t(0o600)), 0)
            let journal = CheckpointMemoryJournal()
            let checkpointService = service(journal: journal)
            let failure = try captureFailure { try checkpointService.perform(request: request, configuration: fixture.configuration) }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid")
            XCTAssertTrue(journal.values.isEmpty)
            try assertPrejournalFailure(failure, service: checkpointService, configuration: fixture.configuration)
        }

        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let journal = CheckpointMemoryJournal()
        let result = try service(journal: journal, replacer: FIFOAfterWriteCheckpointReplacer())
            .perform(request: fixture.request(), configuration: fixture.configuration)
        XCTAssertEqual(result.classification, "historically-committed-current-state-uncertain")
        XCTAssertTrue(result.historicalCommitProven)
        XCTAssertEqual(journal.values.last?.terminalState, .committedReloadFailed)
    }

    func testDurableProductionJournalStorePersistsAndFreshInspectorReadsOperation() throws {
        let fixture = try CheckpointFixture(); defer { fixture.remove() }
        let journalDirectory = fixture.root.deletingLastPathComponent()
            .appending(path: "TaskCheckpointJournalTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        let store = ApplicationSupportTaskCheckpointJournalStore(directory: journalDirectory)
        let writer = TaskCheckpointService(
            journalStore: store, contractValidator: AcceptingV112Validator(),
            now: { self.date }, makeOperationID: { self.operationID }
        )
        let committed = try writer.perform(request: fixture.request(), configuration: fixture.configuration)
        XCTAssertEqual(committed.outcome, "committed")
        let journalURL = journalDirectory.appending(path: "\(operationID.uuidString).json")
        let attributes = try FileManager.default.attributesOfItem(atPath: journalURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let freshStore = ApplicationSupportTaskCheckpointJournalStore(directory: journalDirectory)
        let inspector = TaskCheckpointService(journalStore: freshStore, contractValidator: AcceptingV112Validator())
        let inspected = try inspector.inspect(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(inspected.classification, "committed-and-current")
        XCTAssertTrue(inspected.historicalCommitProven)
        XCTAssertTrue(inspector.startupRecovery().isEmpty)
    }

    func testDurableInspectorAndCLIFreezeJournalProofAcrossAlternateRootsBeforeLiveReads() throws {
        enum AlternateBytes: Equatable { case preimage, postimage, superseding, unavailableDefiniteNoCommit }
        let cases: [(UUID, AlternateBytes, Bool)] = [
            (UUID(uuidString: "00000000-0000-0000-0000-000000000171")!, .preimage, false),
            (UUID(uuidString: "00000000-0000-0000-0000-000000000172")!, .postimage, false),
            (UUID(uuidString: "00000000-0000-0000-0000-000000000173")!, .superseding, true),
            (UUID(uuidString: "00000000-0000-0000-0000-000000000174")!, .unavailableDefiniteNoCommit, false),
        ]
        for (operation, alternateBytes, shouldProveCommit) in cases {
            let source = try CheckpointFixture(); defer { source.remove() }
            let alternate = try CheckpointFixture(); defer { alternate.remove() }
            let journalDirectory = source.root.deletingLastPathComponent()
                .appending(path: "TaskCheckpointAlternateRoot-\(operation.uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: journalDirectory) }
            let store = ApplicationSupportTaskCheckpointJournalStore(directory: journalDirectory)
            let replacer: any AtomicFileReplacing
            switch alternateBytes {
            case .unavailableDefiniteNoCommit: replacer = ThrowingCheckpointReplacer()
            case .superseding: replacer = DurableReplacement()
            case .preimage, .postimage: replacer = PartialThenThrowCheckpointReplacer()
            }
            let writer = TaskCheckpointService(
                journalStore: store, replacer: replacer, contractValidator: AcceptingV112Validator(),
                now: { self.date }, makeOperationID: { operation }
            )
            _ = try writer.perform(request: source.request(), configuration: source.configuration)
            let journal = try XCTUnwrap(try store.journal(operationID: operation))
            switch alternateBytes {
            case .preimage, .unavailableDefiniteNoCommit:
                break
            case .postimage:
                try journal.workspaceExpectedAfter.write(to: alternate.workspaceURL)
            case .superseding:
                try journal.workspaceExpectedAfter.write(to: alternate.workspaceURL)
                try alternate.replaceWorkspace("Byte-for-byte retained.", with: "A valid later canonical mutation.")
            }
            if alternateBytes == .unavailableDefiniteNoCommit { alternate.remove() }

            let journalURL = journalDirectory.appending(path: "\(operation.uuidString).json")
            let frozenJournal = try Data(contentsOf: journalURL)
            let inspector = TaskCheckpointService(journalStore: ApplicationSupportTaskCheckpointJournalStore(directory: journalDirectory), contractValidator: AcceptingV112Validator())
            var output: [String] = []
            let code = HeadlessOfficeCommandLine.runIfRequested(
                arguments: [
                    "OperationsDashboard", "office", "inspect", "--productions-root", alternate.root.path,
                    "--operation", operation.uuidString,
                ],
                service: inspector,
                write: { output.append($0) }
            )
            XCTAssertEqual(code, 0)
            let result = try decodeResult(output)
            if alternateBytes == .unavailableDefiniteNoCommit {
                XCTAssertEqual(result.classification, "definite-no-commit")
                XCTAssertEqual(result.outcome, "not-committed")
            } else {
                XCTAssertEqual(result.classification, shouldProveCommit ? "historically-committed-current-state-uncertain" : "uncertain")
                XCTAssertEqual(result.historicalCommitProven, shouldProveCommit)
                XCTAssertTrue(result.diagnostic?.contains("does not match the immutable journal-bound root") == true)
            }
            XCTAssertEqual(try Data(contentsOf: journalURL), frozenJournal)
        }
    }

    func testDurableJournalEnvelopeBindsFilenameUUIDSchemaKindPathsAndIDsBeforeProofReadOrUpdate() throws {
        enum EnvelopeMutation: CaseIterable, Equatable {
            case filename, operationUUID, schemaVersion, operationKind, taskID, stepID
            case registryPath, workspacePath, productionsRootPath, boundHash
        }
        let operation = UUID(uuidString: "A0000000-0000-0000-0000-000000000076")!
        let otherOperation = UUID(uuidString: "B0000000-0000-0000-0000-000000000076")!
        for mutation in EnvelopeMutation.allCases {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journalDirectory = fixture.root.deletingLastPathComponent()
                .appending(path: "TaskCheckpointEnvelope-\(mutation)-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: journalDirectory) }
            let store = ApplicationSupportTaskCheckpointJournalStore(directory: journalDirectory)
            let writer = TaskCheckpointService(
                journalStore: store, replacer: PartialThenThrowCheckpointReplacer(),
                contractValidator: AcceptingV112Validator(), now: { self.date }, makeOperationID: { operation }
            )
            _ = try writer.perform(request: fixture.request(), configuration: fixture.configuration)
            let validJournal = try XCTUnwrap(try store.journal(operationID: operation))
            let originalURL = journalDirectory.appending(path: "\(operation.uuidString).json")
            var actualURL = originalURL
            var requestedOperation = operation
            if mutation == .filename {
                actualURL = journalDirectory.appending(path: "\(otherOperation.uuidString).json")
                try FileManager.default.moveItem(at: originalURL, to: actualURL)
                requestedOperation = otherOperation
            } else {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: originalURL)) as? [String: Any])
                switch mutation {
                case .filename: break
                case .operationUUID: object["operationUUID"] = otherOperation.uuidString
                case .schemaVersion: object["schemaVersion"] = 2
                case .operationKind: object["operationKind"] = "accepted-handoff"
                case .taskID: object["taskID"] = "IDEA-0006"
                case .stepID: object["stepID"] = "S3"
                case .registryPath: object["registryPath"] = "Office/Registry/Ideas.md"
                case .workspacePath: object["workspacePath"] = "Workspace/TASK-9999/TASK-9999.md"
                case .productionsRootPath: object["productionsRootPath"] = "relative/Productions"
                case .boundHash: object["registrySHA256"] = String(repeating: "0", count: 64)
                }
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: originalURL)
            }
            let frozen = try Data(contentsOf: actualURL)
            XCTAssertThrowsError(try store.journal(operationID: requestedOperation), "\(mutation)")
            XCTAssertThrowsError(try store.update(validJournal), "\(mutation)")
            XCTAssertThrowsError(try store.recordFallback(validJournal), "\(mutation)")

            let inspector = TaskCheckpointService(journalStore: store, contractValidator: AcceptingV112Validator())
            let failure = try captureFailure {
                try inspector.inspect(operationID: requestedOperation, configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertEqual(failure.result.outcome, "uncertain")
            XCTAssertEqual(failure.result.classification, "journal-read-failed")
            XCTAssertNil(failure.result.inspectCommand)

            var output: [String] = []
            let code = HeadlessOfficeCommandLine.runIfRequested(
                arguments: [
                    "OperationsDashboard", "office", "inspect", "--productions-root", fixture.root.path,
                    "--operation", requestedOperation.uuidString,
                ],
                service: inspector,
                write: { output.append($0) }
            )
            XCTAssertEqual(code, 3)
            XCTAssertEqual(try decodeResult(output).classification, "journal-read-failed")
            XCTAssertTrue(inspector.startupRecovery().isEmpty)
            XCTAssertEqual(try Data(contentsOf: actualURL), frozen)
        }
    }

    func testDurableUpdatesRejectEveryImmutableEnvelopeSubstitutionAndPreserveFreshReaders() throws {
        let normalizationDirectory = try NormalizationEquivalentDirectory()
        defer { normalizationDirectory.remove() }
        let fixture = try CheckpointFixture(rootParent: normalizationDirectory.canonicalURL)
        defer { fixture.remove() }
        let normalizationAlias = try normalizationDirectory.alias(for: fixture.root)
        let journalDirectory = fixture.root.deletingLastPathComponent()
            .appending(path: "TaskCheckpointImmutableEnvelope-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        let store = ApplicationSupportTaskCheckpointJournalStore(directory: journalDirectory)
        let writer = TaskCheckpointService(
            journalStore: store, contractValidator: AcceptingV112Validator(),
            now: { self.date }, makeOperationID: { self.operationID }
        )
        _ = try writer.perform(request: fixture.request(), configuration: fixture.configuration)
        let durable = try XCTUnwrap(try store.journal(operationID: operationID))
        let journalURL = journalDirectory.appending(path: "\(operationID.uuidString).json")
        let frozen = try Data(contentsOf: journalURL)
        let otherOperation = UUID(uuidString: "A0000000-0000-0000-0000-000000000077")!
        let replacementRegistry = Data("replacement registry".utf8)
        let replacementWorkspace = Data("replacement workspace".utf8)
        let substitutions: [(String, (inout [String: Any]) -> Void)] = [
            ("schemaVersion", { $0["schemaVersion"] = 2 }),
            ("operationUUID", { $0["operationUUID"] = otherOperation.uuidString }),
            ("productionsRootPath", { $0["productionsRootPath"] = "/private/tmp/other-productions" }),
            ("taskID/workspacePath", { $0["taskID"] = "TASK-9999"; $0["workspacePath"] = "Workspace/TASK-9999/TASK-9999.md" }),
            ("stepID", { $0["stepID"] = "S04" }),
            ("timestamp", { $0["timestamp"] = (($0["timestamp"] as? NSNumber)?.doubleValue ?? 0) + 1 }),
            ("operationKind", { $0["operationKind"] = "accepted-handoff" }),
            ("registryPath", { $0["registryPath"] = "Office/Registry/Ideas.md" }),
            ("registryPreimage/hash", { $0["registryPreimage"] = replacementRegistry.base64EncodedString(); $0["registrySHA256"] = sha256(replacementRegistry) }),
            ("workspacePath", { $0["workspacePath"] = "Workspace/TASK-9999/TASK-9999.md" }),
            ("workspacePreimage/hash", { $0["workspacePreimage"] = replacementWorkspace.base64EncodedString(); $0["workspaceSHA256Before"] = sha256(replacementWorkspace) }),
            ("workspaceExpectedAfter/hash", { $0["workspaceExpectedAfter"] = replacementWorkspace.base64EncodedString(); $0["workspaceSHA256ExpectedAfter"] = sha256(replacementWorkspace) }),
            ("targetFingerprint", { $0["targetFingerprint"] = String(repeating: "a", count: 64) }),
            ("acceptedEvidence", { $0["acceptedEvidence"] = ["Substituted evidence."] }),
            ("nextStep", { $0["nextStep"] = "Substituted next step." }),
            ("lastValidatedState", { $0["lastValidatedState"] = "Substituted state." }),
        ]
        for (name, mutate) in substitutions {
            let proposed = try mutatedJournal(durable, mutate: mutate)
            XCTAssertThrowsError(try store.update(proposed), name)
            XCTAssertThrowsError(try store.recordFallback(proposed), name)
            XCTAssertEqual(try Data(contentsOf: journalURL), frozen, name)
        }

        let normalizationUpdate = try mutatedJournal(durable) {
            $0["productionsRootPath"] = normalizationAlias
        }
        XCTAssertEqual(normalizationUpdate.productionsRootPath, durable.productionsRootPath)
        XCTAssertFalse(normalizationUpdate.productionsRootPath.utf8.elementsEqual(durable.productionsRootPath.utf8))
        XCTAssertThrowsError(try store.update(normalizationUpdate), "normalization-equivalent root substitution")
        XCTAssertEqual(try Data(contentsOf: journalURL), frozen)

        let normalizationFallback = try mutatedJournal(durable) {
            $0["productionsRootPath"] = normalizationAlias
            $0["terminalState"] = OfficeWorkspaceTerminalState.journalFinalizationFailedCommittedAndCurrent.rawValue
            $0["journalFinalized"] = false
            $0["fallbackRecorded"] = true
            $0["diagnostic"] = "Synthetic fallback must not substitute the immutable root envelope."
        }
        XCTAssertThrowsError(try store.recordFallback(normalizationFallback), "normalization-equivalent fallback root substitution")
        XCTAssertEqual(try Data(contentsOf: journalURL), frozen)

        let controlDirectory = fixture.root.deletingLastPathComponent()
            .appending(path: "TaskCheckpointImmutableEnvelopeControl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: controlDirectory) }
        try FileManager.default.createDirectory(at: controlDirectory, withIntermediateDirectories: false)
        let controlURL = controlDirectory.appending(path: "\(operationID.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(durable).write(to: controlURL)
        let controlStore = ApplicationSupportTaskCheckpointJournalStore(directory: controlDirectory)
        XCTAssertNoThrow(try controlStore.update(durable))
        let exactFallback = try mutatedJournal(durable) {
            $0["terminalState"] = OfficeWorkspaceTerminalState.journalFinalizationFailedCommittedAndCurrent.rawValue
            $0["journalFinalized"] = false
            $0["fallbackRecorded"] = true
            $0["diagnostic"] = "Exact-envelope fallback control."
        }
        XCTAssertNoThrow(try controlStore.recordFallback(exactFallback))

        let freshInspector = TaskCheckpointService(
            journalStore: ApplicationSupportTaskCheckpointJournalStore(directory: journalDirectory),
            contractValidator: AcceptingV112Validator()
        )
        XCTAssertEqual(try freshInspector.inspect(operationID: operationID, configuration: fixture.configuration).classification, "committed-and-current")
        var output: [String] = []
        XCTAssertEqual(HeadlessOfficeCommandLine.runIfRequested(
            arguments: ["OperationsDashboard", "office", "inspect", "--productions-root", fixture.root.path, "--operation", operationID.uuidString],
            service: freshInspector, write: { output.append($0) }
        ), 0)
        XCTAssertEqual(try decodeResult(output).classification, "committed-and-current")
        XCTAssertTrue(freshInspector.startupRecovery().isEmpty)
        XCTAssertEqual(try Data(contentsOf: journalURL), frozen)
    }

    func testEveryProvingTerminalRejectsEveryNonprovingDowngradeWithoutChangingDurableProof() throws {
        let proving: [OfficeWorkspaceTerminalState] = [
            .committedAndCurrent, .reconciledCommittedAndCurrent,
            .historicallyCommittedAndSuperseded, .historicallyCommittedWithCurrentStateUncertain,
            .committedReloadFailed, .journalFinalizationFailedCommittedAndCurrent,
            .journalFinalizationFailedHistoricallyCommittedAndSuperseded,
            .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain,
        ]
        let nonproving: [OfficeWorkspaceTerminalState] = [
            .definiteNoCommit, .uncertain, .journalFinalizationFailedDefiniteNoCommit,
        ]
        for provingState in proving {
            let fixture = try CheckpointFixture(); defer { fixture.remove() }
            let journalDirectory = fixture.root.deletingLastPathComponent()
                .appending(path: "TaskCheckpointProofDowngrade-\(provingState.rawValue)-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: journalDirectory) }
            let store = ApplicationSupportTaskCheckpointJournalStore(directory: journalDirectory)
            let writer = TaskCheckpointService(
                journalStore: store, contractValidator: AcceptingV112Validator(),
                now: { self.date }, makeOperationID: { self.operationID }
            )
            _ = try writer.perform(request: fixture.request(), configuration: fixture.configuration)
            let journalURL = journalDirectory.appending(path: "\(operationID.uuidString).json")
            let committed = try XCTUnwrap(try store.journal(operationID: operationID))
            let provingJournal = try mutatedJournal(committed) { object in
                object["terminalState"] = provingState.rawValue
                object["journalFinalized"] = !provingState.hasFallback
                object["fallbackRecorded"] = provingState.hasFallback
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(provingJournal).write(to: journalURL)
            let frozen = try Data(contentsOf: journalURL)
            let durable = try XCTUnwrap(try store.journal(operationID: operationID))
            for nonprovingState in nonproving {
                let proposed = try mutatedJournal(durable) { object in
                    object["terminalState"] = nonprovingState.rawValue
                    object["journalFinalized"] = !nonprovingState.hasFallback
                    object["fallbackRecorded"] = nonprovingState.hasFallback
                }
                XCTAssertThrowsError(try store.update(proposed), "\(provingState) -> \(nonprovingState)")
                XCTAssertThrowsError(try store.recordFallback(proposed), "\(provingState) -> \(nonprovingState)")
                XCTAssertEqual(try Data(contentsOf: journalURL), frozen)
            }

            let freshInspector = TaskCheckpointService(
                journalStore: ApplicationSupportTaskCheckpointJournalStore(directory: journalDirectory),
                contractValidator: AcceptingV112Validator()
            )
            let inspected = try freshInspector.inspect(operationID: operationID, configuration: fixture.configuration)
            XCTAssertTrue(inspected.historicalCommitProven)
            var output: [String] = []
            XCTAssertEqual(HeadlessOfficeCommandLine.runIfRequested(
                arguments: ["OperationsDashboard", "office", "inspect", "--productions-root", fixture.root.path, "--operation", operationID.uuidString],
                service: freshInspector, write: { output.append($0) }
            ), 0)
            XCTAssertTrue(try decodeResult(output).historicalCommitProven)
            XCTAssertEqual(freshInspector.startupRecovery().count, provingState.isStartupIncomplete ? 1 : 0)
            XCTAssertEqual(try Data(contentsOf: journalURL), frozen)
        }
    }

    private func service(
        journal: CheckpointMemoryJournal = CheckpointMemoryJournal(),
        replacer: (any AtomicFileReplacing)? = nil,
        locking: any TaskCheckpointLocking = LocalTaskCheckpointLocking()
    ) -> TaskCheckpointService {
        TaskCheckpointService(
            journalStore: journal, replacer: replacer, locking: locking,
            contractValidator: AcceptingV112Validator(), now: { self.date }, makeOperationID: { self.operationID }
        )
    }

    private func captureFailure(_ body: () throws -> TaskCheckpointCommandResult) throws -> TaskCheckpointCommandFailure {
        do { _ = try body(); XCTFail("Expected TaskCheckpointCommandFailure"); throw syntheticError(99) }
        catch let failure as TaskCheckpointCommandFailure { return failure }
    }

    private func decodeResult(_ output: [String]) throws -> TaskCheckpointCommandResult {
        try JSONDecoder().decode(TaskCheckpointCommandResult.self, from: XCTUnwrap(output.first).data(using: .utf8)!)
    }

    private func assertPrejournalFailure(
        _ failure: TaskCheckpointCommandFailure,
        service: TaskCheckpointService,
        configuration: ProductionsConfiguration
    ) throws {
        XCTAssertNil(failure.result.inspectCommand)
        let diagnostic = failure.result.diagnostic?.lowercased() ?? ""
        XCTAssertTrue(diagnostic.contains("no operation journal") || diagnostic.contains("no durable operation journal"))
        let inspection = try captureFailure { try service.inspect(operationID: operationID, configuration: configuration) }
        XCTAssertEqual(inspection.result.classification, "journal-read-failed")
        XCTAssertNil(inspection.result.inspectCommand)
    }

    private func assertContractGateIsPrejournal(_ fixture: ActivationFixture) throws {
        let journal = CheckpointMemoryJournal()
        let lock = RecordingCheckpointLock()
        var issuedUUID = false
        let before = try fixture.snapshot()
        let checkpointService = TaskCheckpointService(
            journalStore: journal, locking: lock, contractValidator: AdoptedOfficeV112ContractValidator(),
            makeOperationID: { issuedUUID = true; return self.operationID }
        )
        let failure = try captureFailure { try checkpointService.perform(request: fixture.request, configuration: fixture.configuration) }
        XCTAssertEqual(failure.result.classification, "contractNotAdopted")
        XCTAssertNil(failure.result.operationUUID)
        XCTAssertNil(failure.result.inspectCommand)
        XCTAssertFalse(issuedUUID)
        XCTAssertFalse(lock.acquired)
        XCTAssertTrue(journal.values.isEmpty)
        XCTAssertEqual(try fixture.snapshot(), before)
    }
}

private struct AcceptingV112Validator: OfficeV112ContractValidating {
    func validate(configuration: ProductionsConfiguration) throws {}
}

private struct RejectingV112Validator: OfficeV112ContractValidating {
    func validate(configuration: ProductionsConfiguration) throws {
        throw OfficeContractValidationError.contractNotAdopted("Synthetic gate rejection.")
    }
}

private final class CheckpointMemoryJournal: TaskCheckpointJournalStore {
    var values: [TaskCheckpointJournal] = []
    var failPersist = false
    var failNormalUpdates = false
    var failFallback = false
    var failRead = false
    var failReadAfterPersist = false
    var afterPersist: (() -> Void)?

    func persist(_ journal: TaskCheckpointJournal) throws {
        if failPersist { throw syntheticError(1) }
        values.append(journal)
        afterPersist?()
    }

    func update(_ journal: TaskCheckpointJournal) throws {
        if failNormalUpdates { throw syntheticError(2) }
        try replace(journal)
    }

    func recordFallback(_ journal: TaskCheckpointJournal) throws {
        if failFallback { throw syntheticError(3) }
        try replace(journal)
    }

    func journal(operationID: UUID) throws -> TaskCheckpointJournal? {
        if failRead || (failReadAfterPersist && !values.isEmpty) { throw syntheticError(4) }
        return values.first { $0.operationUUID == operationID }
    }

    func incomplete() throws -> [TaskCheckpointJournal] {
        values.filter { $0.terminalState == nil || $0.terminalState?.isStartupIncomplete == true }
    }

    func restoreWorkspacePreimage(to url: URL, operationID: UUID) throws {
        let journal = try XCTUnwrap(values.first { $0.operationUUID == operationID })
        try journal.workspacePreimage.write(to: url)
    }

    private func replace(_ journal: TaskCheckpointJournal) throws {
        guard let index = values.firstIndex(where: { $0.operationUUID == journal.operationUUID }) else { throw syntheticError(5) }
        values[index] = journal
    }
}

private extension TaskCheckpointJournal {
    func with(operationID: UUID, state: OfficeWorkspaceTerminalState) -> TaskCheckpointJournal {
        var copy = TaskCheckpointJournal(
            schemaVersion: schemaVersion, operationUUID: operationID,
            productionsRootPath: productionsRootPath, taskID: taskID, stepID: stepID,
            timestamp: timestamp, operationKind: operationKind, registryPath: registryPath,
            registrySHA256: registrySHA256, registryPreimage: registryPreimage,
            workspacePath: workspacePath, workspaceSHA256Before: workspaceSHA256Before,
            workspacePreimage: workspacePreimage, workspaceSHA256ExpectedAfter: workspaceSHA256ExpectedAfter,
            workspaceExpectedAfter: workspaceExpectedAfter, targetFingerprint: targetFingerprint,
            acceptedEvidence: acceptedEvidence, nextStep: nextStep, lastValidatedState: lastValidatedState,
            terminalState: nil, journalFinalized: false, fallbackRecorded: false, diagnostic: nil
        )
        copy.transition(to: state, diagnostic: nil, finalized: true)
        return copy
    }
}

private final class RecordingCheckpointLock: TaskCheckpointLocking {
    var acquired = false
    func acquire(registryURL: URL) -> AnyObject? { acquired = true; return NSObject() }
}

private struct DeniedCheckpointLock: TaskCheckpointLocking {
    func acquire(registryURL: URL) -> AnyObject? { nil }
}

private struct ThrowingCheckpointReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { throw syntheticError(10) }
}

private struct WriteThenThrowCheckpointReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { try data.write(to: target); throw syntheticError(11) }
}

private struct PartialThenThrowCheckpointReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { try Data(data.prefix(data.count / 2)).write(to: target); throw syntheticError(12) }
}

private struct CorruptAfterWriteCheckpointReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { try (data + Data("foreign".utf8)).write(to: target) }
}

private struct FIFOAfterWriteCheckpointReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws {
        try data.write(to: target)
        try FileManager.default.removeItem(at: target)
        guard mkfifo(target.path, mode_t(0o600)) == 0 else { throw syntheticError(13) }
    }
}

private final class NormalizationEquivalentDirectory {
    let canonicalURL: URL
    let aliasParentPath: String
    private let manager = FileManager.default

    init(parent: URL = URL(fileURLWithPath: "/private/tmp", isDirectory: true)) throws {
        let token = UUID().uuidString
        let requestedName = "TaskCheckpoint-é-\(token)"
        try manager.createDirectory(
            at: parent.appending(path: requestedName, directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        let storedName = try XCTUnwrap(
            manager.contentsOfDirectory(atPath: parent.path).first(where: { $0.hasSuffix(token) })
        )
        canonicalURL = parent.appending(path: storedName, directoryHint: .isDirectory)
        let composed = storedName.precomposedStringWithCanonicalMapping
        let decomposed = storedName.decomposedStringWithCanonicalMapping
        let aliasName = storedName.utf8.elementsEqual(composed.utf8) ? decomposed : composed
        guard !storedName.utf8.elementsEqual(aliasName.utf8) else { throw syntheticError(14) }
        aliasParentPath = parent.path + "/" + aliasName
    }

    func alias(for child: URL) throws -> String {
        let prefix = canonicalURL.path + "/"
        guard child.path.utf8.starts(with: prefix.utf8) else { throw syntheticError(15) }
        let suffix = String(decoding: child.path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        return aliasParentPath + "/" + suffix
    }

    func remove() { try? manager.removeItem(at: canonicalURL) }
}

private final class CheckpointFixture {
    let root: URL
    private let manager = FileManager.default
    let existingEvidence: Bool
    let laterSections: Bool

    init(
        existingEvidence: Bool = false,
        laterSections: Bool = false,
        rootParent: URL? = nil
    ) throws {
        self.existingEvidence = existingEvidence
        self.laterSections = laterSections
        root = (rootParent ?? URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true))
            .appending(path: "TaskCheckpointTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try write(registry, to: registryURL)
        try write(workspace, to: workspaceURL)
        try write("| Occurred | Work ID | Event | Reason | Context |\n| --- | --- | --- | --- | --- |\n| 2026-08-29T20:00:00Z | TASK-0076 | Placed | Test. | Fixture. |", to: root.appending(path: "Office/Threads/Canvas.md"))
    }

    var configuration: ProductionsConfiguration { ProductionsConfiguration(schemaVersion: 2, productionsRootPath: root.path) }
    var registryURL: URL { root.appending(path: "Office/Registry/Tasks.md") }
    var workspaceURL: URL { root.appending(path: "Workspace/TASK-0076/TASK-0076.md") }

    func remove() { try? manager.removeItem(at: root) }
    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func snapshot() throws -> [String: Data] {
        let paths = try manager.subpathsOfDirectory(atPath: root.path).sorted()
        return Dictionary(uniqueKeysWithValues: try paths.compactMap { path in
            let url = root.appending(path: path)
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return nil }
            return (path, try Data(contentsOf: url))
        })
    }

    func request(
        workspaceHash: String? = nil,
        registryHash: String? = nil,
        step: String = "S03",
        evidence: [String] = ["Unit suite passed.", "Production adapter passed."],
        nextStep: String = "Authorize the next bounded phase.",
        lastValidatedState: String = "Deterministic checkpoint validation passed."
    ) -> TaskCheckpointRequest {
        TaskCheckpointRequest(
            taskID: "TASK-0076",
            expectedWorkspaceSHA256: workspaceHash ?? sha256(try! read(workspaceURL)),
            expectedRegistrySHA256: registryHash ?? sha256(try! read(registryURL)),
            unfinishedStep: step, acceptedEvidence: evidence,
            nextStep: nextStep,
            lastValidatedState: lastValidatedState
        )
    }

    func arguments() -> [String] {
        let request = request()
        return [
            "OperationsDashboard", "task", "checkpoint", "--productions-root", root.path,
            "--task", request.taskID, "--expected-workspace-sha256", request.expectedWorkspaceSHA256,
            "--expected-registry-sha256", request.expectedRegistrySHA256,
            "--unfinished-step", request.unfinishedStep,
            "--evidence", request.acceptedEvidence[0], "--evidence", request.acceptedEvidence[1],
            "--next-step", request.nextStep, "--last-validated-state", request.lastValidatedState,
        ]
    }

    func replaceWorkspace(_ old: String, with new: String) throws {
        let text = String(decoding: try read(workspaceURL), as: UTF8.self).replacingOccurrences(of: old, with: new)
        try write(text, to: workspaceURL)
    }

    func replaceRegistry(_ old: String, with new: String) throws {
        let text = String(decoding: try read(registryURL), as: UTF8.self).replacingOccurrences(of: old, with: new)
        try write(text, to: registryURL)
    }

    func replaceTargetWithSymlink(_ target: String) throws {
        let url = target == "registry" ? registryURL : workspaceURL
        let real = url.deletingLastPathComponent().appending(path: ".real-\(url.lastPathComponent)")
        try manager.moveItem(at: url, to: real)
        try manager.createSymbolicLink(at: url, withDestinationURL: real)
    }

    private func write(_ text: String, to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private var registry: String {
        """
        # Tasks — Canonical Registry

        | Task ID | Title | State | Priority | Current lead | Initiative | Project | Depends on | Review after | Short description | Workspace |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | TASK-0076 | Synthetic checkpoint | Active / Current | Medium | Office | — | PROJ-0008 | TASK-0001 baseline | — | Preserve registry. | [TASK-0076](../../Workspace/TASK-0076/TASK-0076.md) |
        """ + "\n"
    }

    private var workspace: String {
        var value = """
        # Synthetic checkpoint

        ## Core Record

        ```text
        Title: Synthetic checkpoint
        ID: TASK-0076
        Type: Task
        Current lead: Office
        Associated product(s): PROD-0003
        Primary department: Office
        Status source: Office/Registry/Tasks.md
        Project: PROJ-0008 — Synthetic Project
        Initiative: —

        Objective or question: Exercise the checkpoint writer.
        Next step: Implement the transaction.
        Completion or resolution criterion: Exact durable proof.
        Last validated state: Design accepted.
        Relevant locations: Synthetic fixture.
        Depends on: TASK-0001 baseline
        Related records: DOC-0016
        Unknown field: Preserve this exactly.
        ```

        ## Steps

        - [x] **S02 — Preserve earlier work.**
        - [ ] **S03 — Implement checkpoint.**
              Wrapped wording remains exact.
        - [ ] **S04 — Later work.**

        ## Unrecognized Section

        Byte-for-byte retained.
        """
        if existingEvidence {
            value += """


            ## Checkpoint Evidence

            ### S02 - 00000000-0000-0000-0000-000000000002

            Recorded: 2026-08-28T20:00:00Z

            Accepted evidence:

            - Earlier evidence.
            """
        }
        if laterSections {
            value += """


            ## Accepted Handoffs

            | Marker | Accepted at | Evidence |
            | --- | --- | --- |
            | prior-marker | 2026-08-28T20:00:00Z | Warehouse/Evidence/prior.md |

            ## Eligibility Reviews

            | Hook | Review question | Disposition | Decided at | Reconsider after | Replacement |
            | --- | --- | --- | --- | --- | --- |
            | TASK-0001@done-complete | Keep this later section unchanged. | Pending | — | — | — |

            ## Later Unknown Section

            Later bytes remain exact.
            """
        }
        return value + "\n"
    }
}

private final class ActivationFixture {
    enum ImmutableMutation: CaseIterable { case omission, mismatch, contradiction }
    enum RegistryRowMutation: CaseIterable { case omission, mismatch, contradiction }

    let root: URL
    private let manager = FileManager.default
    private let liveRoot = URL(fileURLWithPath: "/Users/kahntra/Productions", isDirectory: true)

    init(rootParent: URL? = nil) throws {
        root = (rootParent ?? URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true))
            .appending(path: "TaskCheckpointActivationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let paths = Array(AdoptedOfficeV112ContractValidator.immutableSHA256.keys) + [
            "Warehouse/Reference/Document Registry.md",
            "Office/Registry/Tasks.md", "Office/Registry/Ideas.md",
            "Office/Registry/Projects.md", "Office/Registry/Initiatives.md",
            "Workspace/IDEA-0006/IDEA-0006.md", "Workspace/TASK-0017/TASK-0017.md",
        ]
        for path in paths {
            try write(try Data(contentsOf: liveRoot.appending(path: path)), path: path)
        }
    }

    var configuration: ProductionsConfiguration { ProductionsConfiguration(schemaVersion: 2, productionsRootPath: root.path) }
    var request: TaskCheckpointRequest {
        TaskCheckpointRequest(
            taskID: "TASK-0076", expectedWorkspaceSHA256: String(repeating: "0", count: 64),
            expectedRegistrySHA256: String(repeating: "0", count: 64), unfinishedStep: "S03",
            acceptedEvidence: ["Gate rejection."], nextStep: "Remain stopped.", lastValidatedState: "Gate rejected."
        )
    }

    func remove() { try? manager.removeItem(at: root) }

    func snapshot() throws -> [String: Data] {
        let paths = try manager.subpathsOfDirectory(atPath: root.path).sorted()
        return Dictionary(uniqueKeysWithValues: try paths.compactMap { path in
            let url = root.appending(path: path)
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return nil }
            return (path, try Data(contentsOf: url))
        })
    }

    func mutateImmutable(path: String, variant: ImmutableMutation) throws {
        let url = root.appending(path: path)
        switch variant {
        case .omission:
            try manager.removeItem(at: url)
        case .mismatch:
            var data = try Data(contentsOf: url)
            data.append(Data("\n".utf8))
            try data.write(to: url)
        case .contradiction:
            var data = Data("Contradictory preface.\n".utf8)
            data.append(try Data(contentsOf: url))
            try data.write(to: url)
        }
    }

    func mutateDocumentRegistry(documentID: String, variant: RegistryRowMutation) throws {
        let path = "Warehouse/Reference/Document Registry.md"
        let url = root.appending(path: path)
        var lines = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let index = try XCTUnwrap(lines.firstIndex(where: { $0.hasPrefix("| \(documentID) |") }))
        switch variant {
        case .omission:
            lines.remove(at: index)
        case .mismatch:
            lines[index] = lines[index].replacingOccurrences(of: "| Current |", with: "| Obsolete |")
        case .contradiction:
            lines.insert(lines[index], at: index + 1)
        }
        try write(Data(lines.joined(separator: "\n").utf8), path: path)
    }

    func replace(path: String, old: String, new: String, firstOnly: Bool) throws {
        let url = root.appending(path: path)
        var text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        if firstOnly, let range = text.range(of: old) {
            text.replaceSubrange(range, with: new)
        } else {
            text = text.replacingOccurrences(of: old, with: new)
        }
        try write(Data(text.utf8), path: path)
    }

    func append(path: String, text: String) throws {
        let url = root.appending(path: path)
        var data = try Data(contentsOf: url)
        data.append(Data(text.utf8))
        try write(data, path: path)
    }

    private func write(_ data: Data, path: String) throws {
        let url = root.appending(path: path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func mutatedJournal(
    _ journal: TaskCheckpointJournal,
    mutate: (inout [String: Any]) -> Void
) throws -> TaskCheckpointJournal {
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(journal)) as? [String: Any])
    mutate(&object)
    return try JSONDecoder().decode(
        TaskCheckpointJournal.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}

private func syntheticError(_ code: Int) -> NSError {
    NSError(domain: "TaskCheckpointTransactionsTests", code: code)
}
