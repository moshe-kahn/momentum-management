import XCTest
@testable import OperationsDashboard

final class HeadlessCanvasCommandsTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-17T21:00:00Z")!

    func testCommandAndDirectServiceProduceTheSameCanvasBytes() throws {
        let commandFixture = try SyntheticProductionsFixture(); defer { commandFixture.remove() }
        let serviceFixture = try SyntheticProductionsFixture(); defer { serviceFixture.remove() }
        commandFixture.replaceCanvas(emptyCanvas); serviceFixture.replaceCanvas(emptyCanvas)
        let commandResult = try adapter().execute(try confirmedCommand(.start, fixture: commandFixture), configuration: configuration(commandFixture))
        let service = CanvasWorkTransactionService(journalStore: CommandJournal(), now: { self.date })
        let directResult = try service.perform(action: .start, configuration: configuration(serviceFixture), work: try XCTUnwrap(serviceFixture.load().work.first), reason: "Approved action.", context: "Command test.", reload: { _ in serviceFixture.load() })
        guard case let .started(commandTransaction, package) = commandResult else { return XCTFail("Expected prepared start outcome") }
        XCTAssertEqual(commandTransaction, directResult); XCTAssertEqual(package.brief.workID, "TASK-000001")
        XCTAssertEqual(try commandFixture.data(at: "Office/Threads/Canvas.md"), try serviceFixture.data(at: "Office/Threads/Canvas.md"))
    }

    func testStopCommandMatchesServiceAndDoesNotChangeRegistry() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let registryBefore = try fixture.data(at: "Office/Registry/Tasks.md")

        let outcome = try adapter().execute(try confirmedCommand(.stop, fixture: fixture), configuration: configuration(fixture))

        guard case let .stopped(result) = outcome else { return XCTFail("Expected stop outcome") }
        XCTAssertEqual(result.appendedEvents, ["Cleared"])
        XCTAssertEqual(try MarkdownTable.parse(String(decoding: fixture.data(at: "Office/Threads/Canvas.md"), as: UTF8.self), required: ["Occurred", "Work ID", "Event", "Reason", "Context"]).last?["Event"], "Cleared")
        XCTAssertEqual(try fixture.data(at: "Office/Registry/Tasks.md"), registryBefore)
    }

    func testUnavailableTargetAndInactiveStopLeaveCanonicalRecordsUntouched() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let unavailableBefore = try fixture.snapshot()
        let unavailable = HeadlessCanvasCommand(action: .start, workID: "TASK-999999", reason: "Reason.", context: "Context.")
        XCTAssertThrowsError(try adapter().execute(unavailable, configuration: configuration(fixture))) { error in
            guard case .targetUnavailable = error as? HeadlessCanvasCommandError else { return XCTFail("Expected unavailable target") }
        }
        XCTAssertEqual(try fixture.snapshot(), unavailableBefore)

        fixture.replaceCanvas(emptyCanvas)
        let inactiveBefore = try fixture.snapshot()
        XCTAssertThrowsError(try adapter().execute(try confirmedCommand(.stop, fixture: fixture), configuration: configuration(fixture))) { error in
            XCTAssertEqual(error as? CanvasWorkTransactionError, .notCurrent)
        }
        XCTAssertEqual(try fixture.snapshot(), inactiveBefore)
    }

    func testPreviewBindsRootActionTargetReasonContextAndCanvasHash() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let draft = command(.start)
        let preview = try adapter().preview(for: draft, configuration: configuration(fixture))
        let token = try ConfirmedCommand.token(preview: preview)
        XCTAssertEqual(preview.productionsRoot, fixture.root.standardizedFileURL.path)
        XCTAssertEqual(preview.action, .start); XCTAssertEqual(preview.targetID, "TASK-000001")
        XCTAssertEqual(preview.reason, draft.reason); XCTAssertEqual(preview.context, draft.context)
        let variants = [
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot + "-other", action: preview.action, targetID: preview.targetID, targetTitle: preview.targetTitle, reason: preview.reason, context: preview.context, canvasSHA256: preview.canvasSHA256),
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot, action: .stop, targetID: preview.targetID, targetTitle: preview.targetTitle, reason: preview.reason, context: preview.context, canvasSHA256: preview.canvasSHA256),
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot, action: preview.action, targetID: "TASK-999999", targetTitle: preview.targetTitle, reason: preview.reason, context: preview.context, canvasSHA256: preview.canvasSHA256),
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot, action: preview.action, targetID: preview.targetID, targetTitle: preview.targetTitle, reason: preview.reason, context: "Changed context.", canvasSHA256: preview.canvasSHA256),
            CanvasCommandPreview(schemaVersion: preview.schemaVersion, productionsRoot: preview.productionsRoot, action: preview.action, targetID: preview.targetID, targetTitle: preview.targetTitle, reason: preview.reason, context: preview.context, canvasSHA256: "changed")
        ]
        XCTAssertTrue(try variants.allSatisfy { try ConfirmedCommand.token(preview: $0) != token })
        let changedReason = HeadlessCanvasCommand(action: .start, workID: draft.workID, reason: "Changed reason.", context: draft.context, confirmation: ConfirmedCommand(confirmation: token))
        XCTAssertThrowsError(try adapter().execute(changedReason, configuration: configuration(fixture))) { guard case .confirmationRequired = $0 as? HeadlessCanvasCommandError else { return XCTFail("Expected changed-input rejection") } }
        fixture.replaceCanvas(emptyCanvas)
        let staleHash = HeadlessCanvasCommand(action: .start, workID: draft.workID, reason: draft.reason, context: draft.context, confirmation: ConfirmedCommand(confirmation: token))
        XCTAssertThrowsError(try adapter().execute(staleHash, configuration: configuration(fixture))) { guard case .confirmationRequired = $0 as? HeadlessCanvasCommandError else { return XCTFail("Expected changed-hash rejection") } }
    }

    func testMissingConfirmationAndInvalidFieldsDoNotWrite() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        XCTAssertThrowsError(try adapter().execute(command(.start), configuration: configuration(fixture)))
        let invalidDraft = HeadlessCanvasCommand(action: .start, workID: "TASK-000001", reason: "bad|reason", context: "Context.")
        let invalidPreview = try adapter().preview(for: invalidDraft, configuration: configuration(fixture))
        let invalid = HeadlessCanvasCommand(action: invalidDraft.action, workID: invalidDraft.workID, reason: invalidDraft.reason, context: invalidDraft.context, confirmation: ConfirmedCommand(confirmation: try ConfirmedCommand.token(preview: invalidPreview)))
        XCTAssertThrowsError(try adapter().execute(invalid, configuration: configuration(fixture))) { guard case .invalidInput = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected Canvas validation error") } }
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testCommandPreservesLockHashJournalReplacementAndMalformedStateFailures() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let originalCanvas = String(decoding: try fixture.data(at: ProductionsPath.canvas.rawValue), as: UTF8.self)
        let denied = CanvasWorkTransactionService(journalStore: CommandJournal(), locking: CommandDeniedLock(), now: { self.date })
        XCTAssertThrowsError(try adapter(service: denied).execute(try confirmedCommand(.start, fixture: fixture), configuration: configuration(fixture))) { XCTAssertEqual($0 as? CanvasWorkTransactionError, .lockUnavailable) }
        let concurrent = CommandJournal { fixture.replaceCanvas(self.emptyCanvas + "\n| 2026-08-17T20:59:00Z | TASK-000001 | Cleared | Concurrent. | Other writer. |") }
        XCTAssertThrowsError(try adapter(journal: concurrent).execute(try confirmedCommand(.start, fixture: fixture), configuration: configuration(fixture))) { guard case .conflict = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected hash conflict") } }
        fixture.replaceCanvas(originalCanvas)
        let replacement = CanvasWorkTransactionService(journalStore: CommandJournal(), replacer: CommandFailingReplacer(), now: { self.date })
        XCTAssertThrowsError(try adapter(service: replacement).execute(try confirmedCommand(.start, fixture: fixture), configuration: configuration(fixture))) { guard case .replacementFailed = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected replacement failure") } }
        let journalFailure = CommandJournal(failPersist: true)
        XCTAssertThrowsError(try adapter(journal: journalFailure).execute(try confirmedCommand(.start, fixture: fixture), configuration: configuration(fixture))) { guard case .journalFailed = $0 as? CanvasWorkTransactionError else { return XCTFail("Expected journal failure") } }
        fixture.replaceCanvas("| malformed |")
        XCTAssertThrowsError(try adapter().preview(for: command(.start), configuration: configuration(fixture)))
    }

    func testSuccessfulStartEmitsStableFullSessionPackageJSON() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let command = command(.start)
        let token = try ConfirmedCommand.token(preview: try adapter().preview(for: command, configuration: configuration(fixture)))
        var output: [String] = []
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: arguments(for: command, root: fixture.root.path, confirmation: token), adapter: adapter(), write: { output.append($0) }), 0, output.joined(separator: "\n"))
        let rendered = try XCTUnwrap(output.first)
        let package = try JSONDecoder().decode(SessionPackage.self, from: try XCTUnwrap(rendered.data(using: .utf8)))
        XCTAssertEqual(package.brief.workID, "TASK-000001")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(rendered, String(decoding: try encoder.encode(package), as: UTF8.self), "Package JSON output is stable for the exact committed result.")
    }

    func testPartialOutcomeUsesDistinctExitCodeAndNoRetryDiagnostic() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let command = try confirmedCommand(.start, fixture: fixture)
        let partialAdapter = HeadlessCanvasCommandAdapter(canvas: CanvasWorkTransactionService(journalStore: CommandJournal(), now: { self.date }), recommendedModel: "")
        var output: [String] = []
        let exitCode = HeadlessCanvasCommandLine.runIfRequested(arguments: arguments(for: command, root: fixture.root.path, confirmation: try XCTUnwrap(command.confirmation).confirmation), adapter: partialAdapter, write: { output.append($0) })
        XCTAssertEqual(exitCode, 3)
        XCTAssertTrue(output.joined().contains("Canvas must not be retried"))
    }

    func testCommittedReloadFailureUsesLiteralExitThreeAndNoRetryDiagnostic() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let reader = CommandCanvasReloadFailingReader()
        let service = CanvasWorkTransactionService(
            journalStore: CommandJournal(),
            replacer: CommandCanvasReloadFailingReplacer(reader: reader),
            now: { self.date }
        )
        let failingAdapter = HeadlessCanvasCommandAdapter(canvas: service, reader: reader)
        let draft = command(.stop)
        let token = try ConfirmedCommand.token(preview: failingAdapter.preview(for: draft, configuration: configuration(fixture)))
        var output: [String] = []

        let exitCode = HeadlessCanvasCommandLine.runIfRequested(
            arguments: arguments(for: draft, root: fixture.root.path, confirmation: token),
            adapter: failingAdapter,
            write: { output.append($0) }
        )

        XCTAssertEqual(exitCode, 3)
        let diagnostic = output.joined(separator: "\n")
        XCTAssertTrue(diagnostic.contains("Canvas mutation is committed"), diagnostic)
        XCTAssertTrue(diagnostic.contains("canonical reload or verification failed"), diagnostic)
        XCTAssertTrue(diagnostic.contains("Do not retry automatically."), diagnostic)
    }

    func testDefinitePremutationLockFailureRetainsLiteralExitTwo() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let denied = CanvasWorkTransactionService(journalStore: CommandJournal(), locking: CommandDeniedLock(), now: { self.date })
        let deniedAdapter = adapter(service: denied)
        let draft = command(.start)
        let token = try ConfirmedCommand.token(preview: deniedAdapter.preview(for: draft, configuration: configuration(fixture)))
        var output: [String] = []

        let exitCode = HeadlessCanvasCommandLine.runIfRequested(
            arguments: arguments(for: draft, root: fixture.root.path, confirmation: token),
            adapter: deniedAdapter,
            write: { output.append($0) }
        )

        XCTAssertEqual(exitCode, 2)
        XCTAssertEqual(output, ["Another Canvas write transaction is in progress."])
    }

    func testOrdinaryFocusAndClearUseCompactDesiredStateOutputWithoutSessionPackageOrDiagnostics() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let journal = CommandJournal()
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000076")!
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, now: { self.date }),
            retryPolicy: .init(maximumAttempts: 1, delay: 0),
            sleep: { _ in },
            makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention, reader: LocalFileSystem())
        var output: [String] = []
        let operationSuffix = "Operation \(operationID.uuidString)."

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 0)
        XCTAssertEqual(output, ["Focused TASK-000001. \(operationSuffix)"])
        XCTAssertFalse(output.joined().contains("confirmationToken"))
        XCTAssertTrue(output.joined().contains(operationID.uuidString))
        XCTAssertFalse(output.joined().contains("SessionPackage"))

        output.removeAll()
        let inspectionArguments = ["OperationsDashboard", "canvas", "inspect", "--productions-root", fixture.root.path, "--operation", operationID.uuidString]
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: inspectionArguments, attentionAdapter: attentionAdapter, write: { output.append($0) }), 0)
        let diagnostic = try JSONDecoder().decode(CanvasAttentionOperationDiagnostic.self, from: try XCTUnwrap(output.first?.data(using: .utf8)))
        XCTAssertEqual(diagnostic.operationID, operationID)
        XCTAssertEqual(diagnostic.terminalState, .committed)
        XCTAssertEqual(diagnostic.reconciliation, "committed-and-currently-satisfied")
        XCTAssertTrue(diagnostic.historicalCommitProven)
        XCTAssertTrue(diagnostic.currentRequestedBoundaryProven)

        output.removeAll()
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 0)
        XCTAssertEqual(output, ["TASK-000001 is already focused; no Canvas event was appended. \(operationSuffix)"])

        output.removeAll()
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("clear", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 0)
        XCTAssertEqual(output, ["Cleared TASK-000001. \(operationSuffix)"])

        output.removeAll()
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("clear", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 0)
        XCTAssertEqual(output, ["TASK-000001 is already clear; no Canvas event was appended. \(operationSuffix)"])
    }

    func testNormalCommitJournalFinalizationFailureIsExitThreeCurrentNoRetryAndTerminalFallback() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000176")!
        let journal = CommandJournal(failTerminalStates: [.committed])
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, now: { self.date }),
            retryPolicy: .init(maximumAttempts: 1, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        assertJournalFinalizationDiagnostic(output.joined(), operationID: operationID, classification: .committedAndCurrentlySatisfied)
        XCTAssertEqual(journal.journals.last?.terminalState, .journalFinalizationFailedCommittedAndCurrentlySatisfied)
        XCTAssertTrue(attention.canvas.startupRecovery().isEmpty)
        let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
        XCTAssertEqual(diagnostic.reconciliation, "committed-and-currently-satisfied")
        XCTAssertEqual(diagnostic.terminalState, .journalFinalizationFailedCommittedAndCurrentlySatisfied)
    }

    func testReconciledCurrentJournalFinalizationFailureIsExitThreeCurrentNoRetryAndTerminalFallback() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000276")!
        let journal = CommandJournal(failTerminalStates: [.reconciledCommit])
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, replacer: CommandWriteThenThrowReplacer(), now: { self.date }),
            retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        assertJournalFinalizationDiagnostic(output.joined(), operationID: operationID, classification: .committedAndCurrentlySatisfied)
        XCTAssertEqual(journal.journals.last?.terminalState, .journalFinalizationFailedCommittedAndCurrentlySatisfied)
        XCTAssertTrue(attention.canvas.startupRecovery().isEmpty)
        XCTAssertEqual(try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter).reconciliation, "committed-and-currently-satisfied")
    }

    func testSupersededCommitJournalFinalizationFailureIsExitThreeHistoricalNoRetryAndTerminalFallback() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000376")!
        let journal = CommandJournal(failTerminalStates: [.historicalCommitSuperseded])
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, replacer: CommandWriteThenSupersedeReplacer(), now: { self.date }),
            retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        assertJournalFinalizationDiagnostic(output.joined(), operationID: operationID, classification: .historicallyCommittedAndSuperseded)
        XCTAssertEqual(journal.journals.last?.terminalState, .journalFinalizationFailedHistoricallyCommittedAndSuperseded)
        XCTAssertTrue(attention.canvas.startupRecovery().isEmpty)
        let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
        XCTAssertEqual(diagnostic.reconciliation, "historically-committed-and-superseded")
        XCTAssertTrue(diagnostic.historicalCommitProven)
        XCTAssertFalse(diagnostic.currentRequestedBoundaryProven)
    }

    func testDefiniteNoCommitCLIIsExitTwoOperationAwareAndMatchesInspectionEvidence() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000476")!
        let journal = CommandJournal()
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, replacer: CommandFailingReplacer(), now: { self.date }),
            retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 2)
        let message = output.joined()
        XCTAssertTrue(message.contains(operationID.uuidString), message)
        XCTAssertTrue(message.contains("definitely did not commit"), message)
        XCTAssertTrue(message.contains("canvas inspect"), message)
        XCTAssertEqual(journal.journals.last?.terminalState, .definiteNoCommit)
        XCTAssertTrue(attention.canvas.startupRecovery().isEmpty)
        let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
        XCTAssertEqual(diagnostic.reconciliation, "not-committed")
        XCTAssertEqual(diagnostic.terminalState, .definiteNoCommit)
        XCTAssertFalse(diagnostic.historicalCommitProven)
        XCTAssertFalse(diagnostic.currentRequestedBoundaryProven)
    }

    func testCurrentStateUncertainJournalFinalizationFailureUsesThirdProductionClassification() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000576")!
        let journal = CommandJournal(
            failTerminalStates: [.committed],
            onFailedTerminalUpdate: { terminalState in
                if terminalState == .committed { fixture.replaceCanvas("| malformed |") }
            }
        )
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, now: { self.date }),
            retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        assertJournalFinalizationDiagnostic(output.joined(), operationID: operationID, classification: .historicallyCommittedWithCurrentStateUncertain)
        XCTAssertEqual(journal.journals.last?.terminalState, .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain)
        XCTAssertTrue(attention.canvas.startupRecovery().isEmpty)
        let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
        XCTAssertEqual(diagnostic.reconciliation, "historically-committed-with-current-state-uncertain")
        XCTAssertTrue(diagnostic.historicalCommitProven)
        XCTAssertFalse(diagnostic.currentRequestedBoundaryProven)
        XCTAssertTrue(try XCTUnwrap(diagnostic.diagnostic).contains("must not be retried"))
    }

    func testReturningToPreimageAfterEveryJournalFinalizationMarkerPreservesHistoricalCommitProof() throws {
        let cases: [(UUID, CanvasWorkTransactionTerminalState, CanvasProvenCommitStatus)] = [
            (UUID(uuidString: "00000000-0000-0000-0000-000000000676")!, .journalFinalizationFailedCommittedAndCurrentlySatisfied, .committedAndCurrentlySatisfied),
            (UUID(uuidString: "00000000-0000-0000-0000-000000000776")!, .journalFinalizationFailedHistoricallyCommittedAndSuperseded, .historicallyCommittedAndSuperseded),
            (UUID(uuidString: "00000000-0000-0000-0000-000000000876")!, .journalFinalizationFailedHistoricallyCommittedWithCurrentStateUncertain, .historicallyCommittedWithCurrentStateUncertain)
        ]

        for (operationID, terminalState, classification) in cases {
            let fixture = try SyntheticProductionsFixture()
            fixture.replaceCanvas(emptyCanvas)
            let journal = CommandJournal(
                failTerminalStates: [.committed],
                onFailedTerminalUpdate: { failedState in
                    guard failedState == .committed else { return }
                    switch classification {
                    case .committedAndCurrentlySatisfied:
                        break
                    case .historicallyCommittedAndSuperseded:
                        guard let data = try? fixture.data(at: ProductionsPath.canvas.rawValue) else { return }
                        var superseded = String(decoding: data, as: UTF8.self)
                        if !superseded.hasSuffix("\n") { superseded += "\n" }
                        superseded += "| 2026-08-27T18:00:01Z | TASK-000001 | Cleared | Later action. | Supersede the completed Focus. |\n"
                        fixture.replaceCanvas(superseded)
                    case .historicallyCommittedWithCurrentStateUncertain:
                        fixture.replaceCanvas("| malformed |")
                    }
                }
            )
            let attention = CanvasAttentionOperationService(
                canvas: CanvasWorkTransactionService(journalStore: journal, now: { self.date }),
                retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
            )
            let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
            var output: [String] = []

            XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
            assertJournalFinalizationDiagnostic(output.joined(), operationID: operationID, classification: classification)
            XCTAssertEqual(journal.journals.last?.terminalState, terminalState)
            XCTAssertTrue(terminalState.provesHistoricalCommit)

            fixture.replaceCanvas(emptyCanvas)
            let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
            XCTAssertEqual(diagnostic.reconciliation, "historically-committed-with-current-state-uncertain")
            XCTAssertTrue(diagnostic.historicalCommitProven)
            XCTAssertFalse(diagnostic.currentRequestedBoundaryProven)
            XCTAssertNotEqual(diagnostic.reconciliation, "not-committed")
            let inspectionMessage = try XCTUnwrap(diagnostic.diagnostic)
            XCTAssertTrue(inspectionMessage.contains("Append-only history is inconsistent"), inspectionMessage)
            XCTAssertTrue(inspectionMessage.contains("must not be retried"), inspectionMessage)
            fixture.remove()
        }
    }

    func testFallbackMarkerWriteFailureReportsIncompleteJournalWithoutLosingCommitClassification() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000000976")!
        let journal = CommandJournal(failTerminalStates: [.committed, .journalFinalizationFailedCommittedAndCurrentlySatisfied])
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, now: { self.date }),
            retryPolicy: .init(maximumAttempts: 1, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        let message = output.joined()
        assertJournalFinalizationDiagnostic(message, operationID: operationID, classification: .committedAndCurrentlySatisfied)
        XCTAssertTrue(message.contains("journal may still appear incomplete in startup recovery"), message)
        XCTAssertNil(journal.journals.last?.terminalState)
        XCTAssertEqual(attention.canvas.startupRecovery().map(\.transactionID), [operationID])
        let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
        XCTAssertEqual(diagnostic.reconciliation, "committed-and-currently-satisfied")
        XCTAssertTrue(diagnostic.historicalCommitProven)
        XCTAssertTrue(try XCTUnwrap(diagnostic.diagnostic).contains("must not be retried"))
    }

    func testDefiniteNoCommitTerminalFinalizationFailureIsExitTwoAndInspectable() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000001076")!
        let journal = CommandJournal(failTerminalStates: [.definiteNoCommit])
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, replacer: CommandFailingReplacer(), now: { self.date }),
            retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 2)
        let message = output.joined()
        XCTAssertTrue(message.contains(operationID.uuidString), message)
        XCTAssertTrue(message.contains("definitely did not commit"), message)
        XCTAssertTrue(message.contains("journal could not be finalized"), message)
        XCTAssertTrue(message.contains("Do not retry until `canvas inspect`"), message)
        XCTAssertNil(journal.journals.last?.terminalState)
        XCTAssertEqual(attention.canvas.startupRecovery().map(\.transactionID), [operationID])
        let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
        XCTAssertEqual(diagnostic.reconciliation, "not-committed")
        XCTAssertFalse(diagnostic.historicalCommitProven)
        XCTAssertTrue(try XCTUnwrap(diagnostic.diagnostic).contains("Do not retry"))
    }

    func testReplacementFailureJournalReadFailureIsOperationAwareExitThree() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000001176")!
        let journal = CommandJournal(throwOnJournalRead: true)
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, replacer: CommandFailingReplacer(), now: { self.date }),
            retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        let message = output.joined()
        XCTAssertTrue(message.contains(operationID.uuidString), message)
        XCTAssertTrue(message.contains("Classification: possible commit"), message)
        XCTAssertTrue(message.contains("current Canvas and journal state are uncertain"), message)
        XCTAssertTrue(message.contains("recovery journal could not be read"), message)
        XCTAssertTrue(message.contains("canvas inspect"), message)
        XCTAssertTrue(message.contains("must not be retried"), message)
    }

    func testReloadFailureJournalReadFailurePreservesProvenCommitAsExitThree() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000001276")!
        let reader = CommandCanvasReloadFailingReader()
        let journal = CommandJournal(throwOnJournalRead: true)
        let canvas = CanvasWorkTransactionService(
            journalStore: journal,
            replacer: CommandCanvasReloadFailingReplacer(reader: reader),
            now: { self.date }
        )
        let attention = CanvasAttentionOperationService(
            canvas: canvas,
            retryPolicy: .init(maximumAttempts: 4, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention, reader: reader)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        let message = output.joined()
        XCTAssertTrue(message.contains(operationID.uuidString), message)
        XCTAssertTrue(message.contains("Classification: historically committed with current state uncertain"), message)
        XCTAssertTrue(message.contains("Reload failure proves the commit"), message)
        XCTAssertTrue(message.contains("current Canvas and journal state are uncertain"), message)
        XCTAssertTrue(message.contains("recovery journal could not be read"), message)
        XCTAssertTrue(message.contains("canvas inspect"), message)
        XCTAssertTrue(message.contains("must not be retried"), message)
    }

    func testDurableDefiniteNoCommitInspectionPrecedesMalformedCanvas() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000001376")!
        let (journal, attentionAdapter) = try durableDefiniteNoCommit(operationID: operationID, fixture: fixture)
        fixture.replaceCanvas("| malformed |")
        XCTAssertFalse(fixture.load().issues.isEmpty)

        let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)

        assertDurableDefiniteNoCommitInspection(diagnostic, operationID: operationID)
        XCTAssertEqual(journal.journals.last?.terminalState, .definiteNoCommit)
    }

    func testDurableDefiniteNoCommitInspectionPrecedesUnavailableRemovedAndAmbiguousTargetResolution() throws {
        for scenario in 0..<3 {
            let fixture = try SyntheticProductionsFixture()
            let operationID = UUID(uuidString: "00000000-0000-0000-0000-0000000014\(scenario)6")!
            let (_, attentionAdapter) = try durableDefiniteNoCommit(operationID: operationID, fixture: fixture)

            switch scenario {
            case 0:
                try FileManager.default.removeItem(at: fixture.url(at: "Workspace/TASK-000001/TASK-000001.md"))
                XCTAssertNil(fixture.load().work.first?.workspace)
            case 1:
                try fixture.add("| Task ID | Title | State | Priority | Current lead | Initiative | Project | Depends on | Short description | Workspace |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |", at: ProductionsPath.tasks.rawValue)
                XCTAssertTrue(fixture.load().work.isEmpty)
            default:
                var tasks = String(decoding: try fixture.data(at: ProductionsPath.tasks.rawValue), as: UTF8.self)
                tasks += "\n| TASK-000001 | Duplicate task | Active / Current | High | Office | — | — | — | ambiguous | [task](../../Workspace/TASK-000001/TASK-000001.md) |"
                try fixture.add(tasks, at: ProductionsPath.tasks.rawValue)
                XCTAssertTrue(fixture.load().issues.contains { if case .duplicate = $0 { true } else { false } })
            }

            let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
            assertDurableDefiniteNoCommitInspection(diagnostic, operationID: operationID)
            fixture.remove()
        }
    }

    func testCommittedReloadFailedCanonicalInspectionFailureRetainsHistoricalProof() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000001576")!
        let reader = CommandCanvasReloadFailingReader()
        let journal = CommandJournal()
        let canvas = CanvasWorkTransactionService(
            journalStore: journal,
            replacer: CommandCanvasReloadFailingReplacer(reader: reader),
            now: { self.date }
        )
        let attention = CanvasAttentionOperationService(
            canvas: canvas,
            retryPolicy: .init(maximumAttempts: 1, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention, reader: reader)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        assertHistoricalUncertaintyOutput(output.joined(), operationID: operationID)
        XCTAssertEqual(journal.journals.last?.terminalState, .committedReloadFailed)
        XCTAssertTrue(try XCTUnwrap(journal.journals.last?.terminalState).provesHistoricalCommit)

        let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
        assertHistoricalUncertaintyInspection(diagnostic, operationID: operationID, terminalState: .committedReloadFailed)
    }

    func testCommittedReloadFailedTargetMismatchAndUnavailableTargetRetainHistoricalProof() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000001676")!
        let journal = CommandJournal()
        let replacer = CommandWriteThenMutateReplacer {
            try? fixture.add(fixture.workspaceRecord + "\n\nChanged after Canvas replacement.", at: "Workspace/TASK-000001/TASK-000001.md")
        }
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, replacer: replacer, now: { self.date }),
            retryPolicy: .init(maximumAttempts: 1, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        assertHistoricalUncertaintyOutput(output.joined(), operationID: operationID)
        XCTAssertEqual(journal.journals.last?.terminalState, .committedReloadFailed)
        XCTAssertTrue(try XCTUnwrap(journal.journals.last?.terminalState).provesHistoricalCommit)
        assertHistoricalUncertaintyInspection(
            try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter),
            operationID: operationID,
            terminalState: .committedReloadFailed
        )

        try FileManager.default.removeItem(at: fixture.url(at: "Workspace/TASK-000001/TASK-000001.md"))
        assertHistoricalUncertaintyInspection(
            try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter),
            operationID: operationID,
            terminalState: .committedReloadFailed
        )
        XCTAssertEqual(journal.journals.last?.terminalState, .committedReloadFailed)
    }

    func testCommittedReloadFailedReturnToPreimageReportsAppendOnlyInconsistencyWithoutDowngrade() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        fixture.replaceCanvas(emptyCanvas)
        let operationID = UUID(uuidString: "00000000-0000-0000-0000-000000001776")!
        let journal = CommandJournal(
            onTerminalUpdate: { terminalState in
                guard terminalState == .committed,
                      let data = try? fixture.data(at: ProductionsPath.canvas.rawValue) else { return }
                var invalid = String(decoding: data, as: UTF8.self)
                if !invalid.hasSuffix("\n") { invalid += "\n" }
                invalid += "| 2026-08-27T18:00:01Z | TASK-999999 | Placed | External defect. | Force reload failure. |\n"
                fixture.replaceCanvas(invalid)
            },
            onJournalRead: { fixture.replaceCanvas(self.emptyCanvas) }
        )
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, now: { self.date }),
            retryPolicy: .init(maximumAttempts: 1, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []

        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 3)
        let message = output.joined()
        assertHistoricalUncertaintyOutput(message, operationID: operationID)
        XCTAssertTrue(message.contains("Append-only history is inconsistent"), message)
        XCTAssertEqual(journal.journals.last?.terminalState, .committedReloadFailed)
        XCTAssertTrue(try XCTUnwrap(journal.journals.last?.terminalState).provesHistoricalCommit)

        let diagnostic = try inspect(operationID: operationID, fixture: fixture, adapter: attentionAdapter)
        assertHistoricalUncertaintyInspection(diagnostic, operationID: operationID, terminalState: .committedReloadFailed)
        XCTAssertTrue(try XCTUnwrap(diagnostic.diagnostic).contains("Append-only history is inconsistent"))
        XCTAssertNotEqual(diagnostic.reconciliation, "not-committed")
    }

    func testPreviewConfirmedStartAndStopCompatibilitySurfaceRemainsUnchanged() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        var output: [String] = []
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: ["OperationsDashboard", "canvas", "preview", "start", "--productions-root", fixture.root.path, "--work", "TASK-000001", "--reason", "Approved action.", "--context", "Command test."], write: { output.append($0) }), 0)
        XCTAssertTrue(output.joined().contains("confirmationToken"))
        XCTAssertTrue(output.joined().contains("canvasSHA256"))
    }

    func testPreviewOutputIncludesConfirmationTokenAndNoArgumentLaunchIsUntouched() throws {
        XCTAssertNil(HeadlessCanvasCommandLine.runIfRequested(arguments: ["OperationsDashboard"]))
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        var output: [String] = []
        let arguments = ["OperationsDashboard", "canvas", "preview", "start", "--productions-root", fixture.root.path, "--work", "TASK-000001", "--reason", "Approved action.", "--context", "Command test."]
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: arguments, write: { output.append($0) }), 0)
        XCTAssertTrue(output.joined().contains("confirmationToken")); XCTAssertTrue(output.joined().contains("canvasSHA256"))
    }

    private var emptyCanvas: String { "| Occurred | Work ID | Event | Reason | Context |\n| --- | --- | --- | --- | --- |" }
    private func configuration(_ fixture: SyntheticProductionsFixture) -> ProductionsConfiguration { ProductionsConfiguration(schemaVersion: 2, productionsRootPath: fixture.root.path) }
    private func command(_ action: CanvasWorkAction) -> HeadlessCanvasCommand { HeadlessCanvasCommand(action: action, workID: "TASK-000001", reason: "Approved action.", context: "Command test.") }
    private func confirmedCommand(_ action: CanvasWorkAction, fixture: SyntheticProductionsFixture) throws -> HeadlessCanvasCommand { let draft = command(action); let preview = try adapter().preview(for: draft, configuration: configuration(fixture)); return HeadlessCanvasCommand(action: draft.action, workID: draft.workID, reason: draft.reason, context: draft.context, confirmation: ConfirmedCommand(confirmation: try ConfirmedCommand.token(preview: preview))) }
    private func arguments(for command: HeadlessCanvasCommand, root: String, confirmation: String) -> [String] { ["OperationsDashboard", "canvas", command.action.rawValue, "--productions-root", root, "--work", command.workID, "--reason", command.reason, "--context", command.context, "--confirm", confirmation] }
    private func attentionArguments(_ action: String, root: String) -> [String] { ["OperationsDashboard", "canvas", action, "--productions-root", root, "--work", "TASK-000001", "--reason", "Approved action.", "--context", "Command test."] }
    private func inspect(operationID: UUID, fixture: SyntheticProductionsFixture, adapter: HeadlessCanvasAttentionCommandAdapter) throws -> CanvasAttentionOperationDiagnostic {
        var output: [String] = []
        let arguments = ["OperationsDashboard", "canvas", "inspect", "--productions-root", fixture.root.path, "--operation", operationID.uuidString]
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: arguments, attentionAdapter: adapter, write: { output.append($0) }), 0)
        return try JSONDecoder().decode(CanvasAttentionOperationDiagnostic.self, from: try XCTUnwrap(output.first?.data(using: .utf8)))
    }
    private func durableDefiniteNoCommit(operationID: UUID, fixture: SyntheticProductionsFixture) throws -> (CommandJournal, HeadlessCanvasAttentionCommandAdapter) {
        fixture.replaceCanvas(emptyCanvas)
        let journal = CommandJournal()
        let attention = CanvasAttentionOperationService(
            canvas: CanvasWorkTransactionService(journalStore: journal, replacer: CommandFailingReplacer(), now: { self.date }),
            retryPolicy: .init(maximumAttempts: 1, delay: 0), sleep: { _ in }, makeOperationID: { operationID }
        )
        let attentionAdapter = HeadlessCanvasAttentionCommandAdapter(attention: attention)
        var output: [String] = []
        XCTAssertEqual(HeadlessCanvasCommandLine.runIfRequested(arguments: attentionArguments("focus", root: fixture.root.path), attentionAdapter: attentionAdapter, write: { output.append($0) }), 2)
        XCTAssertEqual(journal.journals.last?.terminalState, .definiteNoCommit)
        return (journal, attentionAdapter)
    }
    private func assertDurableDefiniteNoCommitInspection(_ diagnostic: CanvasAttentionOperationDiagnostic, operationID: UUID, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(diagnostic.operationID, operationID, file: file, line: line)
        XCTAssertEqual(diagnostic.terminalState, .definiteNoCommit, file: file, line: line)
        XCTAssertEqual(diagnostic.reconciliation, "not-committed", file: file, line: line)
        XCTAssertFalse(diagnostic.historicalCommitProven, file: file, line: line)
        XCTAssertFalse(diagnostic.currentRequestedBoundaryProven, file: file, line: line)
        XCTAssertTrue(diagnostic.diagnostic?.contains("durable journal proves definite no-commit") == true, file: file, line: line)
        XCTAssertTrue(diagnostic.diagnostic?.contains("mutable Canvas and target state were not inspected") == true, file: file, line: line)
    }
    private func assertHistoricalUncertaintyOutput(_ message: String, operationID: UUID, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(message.contains(operationID.uuidString), message, file: file, line: line)
        XCTAssertTrue(message.contains("proven historically committed"), message, file: file, line: line)
        XCTAssertTrue(message.contains("current state is uncertain"), message, file: file, line: line)
        XCTAssertTrue(message.contains("must not be retried"), message, file: file, line: line)
    }
    private func assertHistoricalUncertaintyInspection(_ diagnostic: CanvasAttentionOperationDiagnostic, operationID: UUID, terminalState: CanvasWorkTransactionTerminalState, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(diagnostic.operationID, operationID, file: file, line: line)
        XCTAssertEqual(diagnostic.terminalState, terminalState, file: file, line: line)
        XCTAssertTrue(terminalState.provesHistoricalCommit, file: file, line: line)
        XCTAssertEqual(diagnostic.reconciliation, "historically-committed-with-current-state-uncertain", file: file, line: line)
        XCTAssertTrue(diagnostic.historicalCommitProven, file: file, line: line)
        XCTAssertFalse(diagnostic.currentRequestedBoundaryProven, file: file, line: line)
        XCTAssertTrue(diagnostic.diagnostic?.contains("must not be retried") == true, file: file, line: line)
    }
    private func assertJournalFinalizationDiagnostic(_ message: String, operationID: UUID, classification: CanvasProvenCommitStatus, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(message.contains(operationID.uuidString), message, file: file, line: line)
        XCTAssertTrue(message.contains(classification.diagnostic), message, file: file, line: line)
        XCTAssertTrue(message.contains("journal failed to reach its correct terminal state"), message, file: file, line: line)
        XCTAssertTrue(message.contains("operation must not be retried"), message, file: file, line: line)
        XCTAssertTrue(message.contains("canvas inspect"), message, file: file, line: line)
    }
    private func adapter(journal: CommandJournal = CommandJournal()) -> HeadlessCanvasCommandAdapter { adapter(service: CanvasWorkTransactionService(journalStore: journal, now: { self.date })) }
    private func adapter(service: CanvasWorkTransactionService) -> HeadlessCanvasCommandAdapter { HeadlessCanvasCommandAdapter(canvas: service) }
}

private final class CommandJournal: CanvasWorkTransactionJournalStore {
    var journals: [CanvasWorkTransactionJournal] = []
    let afterPersist: (() -> Void)?
    let failPersist: Bool
    let failTerminalStates: [CanvasWorkTransactionTerminalState]
    let onFailedTerminalUpdate: ((CanvasWorkTransactionTerminalState) -> Void)?
    let throwOnJournalRead: Bool
    let onTerminalUpdate: ((CanvasWorkTransactionTerminalState) -> Void)?
    let onJournalRead: (() -> Void)?
    init(afterPersist: (() -> Void)? = nil, failPersist: Bool = false, failTerminalStates: [CanvasWorkTransactionTerminalState] = [], onFailedTerminalUpdate: ((CanvasWorkTransactionTerminalState) -> Void)? = nil, throwOnJournalRead: Bool = false, onTerminalUpdate: ((CanvasWorkTransactionTerminalState) -> Void)? = nil, onJournalRead: (() -> Void)? = nil) {
        self.afterPersist = afterPersist
        self.failPersist = failPersist
        self.failTerminalStates = failTerminalStates
        self.onFailedTerminalUpdate = onFailedTerminalUpdate
        self.throwOnJournalRead = throwOnJournalRead
        self.onTerminalUpdate = onTerminalUpdate
        self.onJournalRead = onJournalRead
    }
    func persist(_ journal: CanvasWorkTransactionJournal) throws { if failPersist { throw NSError(domain: "HeadlessCanvasCommandsTests", code: 1) }; journals.append(journal); afterPersist?() }
    func update(_ journal: CanvasWorkTransactionJournal) throws {
        if let terminalState = journal.terminalState, failTerminalStates.contains(terminalState) {
            onFailedTerminalUpdate?(terminalState)
            throw NSError(domain: "HeadlessCanvasCommandsTests", code: 3)
        }
        guard let index = journals.firstIndex(where: { $0.transactionID == journal.transactionID }) else { throw NSError(domain: "HeadlessCanvasCommandsTests", code: 1) }
        journals[index] = journal
        if let terminalState = journal.terminalState { onTerminalUpdate?(terminalState) }
    }
    func incomplete() throws -> [CanvasWorkTransactionJournal] { journals.filter { $0.terminalState?.isIncomplete ?? true } }
    func journal(transactionID: UUID) throws -> CanvasWorkTransactionJournal? {
        if throwOnJournalRead { throw NSError(domain: "HeadlessCanvasCommandsTests", code: 6) }
        onJournalRead?()
        return journals.first { $0.transactionID == transactionID }
    }
}
private struct CommandDeniedLock: CanvasWorkTransactionLocking { func acquire(canvasURL: URL) -> AnyObject? { nil } }
private struct CommandFailingReplacer: AtomicFileReplacing { func replace(data: Data, at target: URL) throws { throw NSError(domain: "HeadlessCanvasCommandsTests", code: 2) } }
private struct CommandWriteThenThrowReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { try DurableReplacement().replace(data: data, at: target); throw NSError(domain: "HeadlessCanvasCommandsTests", code: 4) }
}
private struct CommandWriteThenMutateReplacer: AtomicFileReplacing {
    let afterWrite: () -> Void
    func replace(data: Data, at target: URL) throws {
        try DurableReplacement().replace(data: data, at: target)
        afterWrite()
    }
}
private struct CommandWriteThenSupersedeReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws {
        var superseded = String(decoding: data, as: UTF8.self)
        if !superseded.hasSuffix("\n") { superseded += "\n" }
        superseded += "| 2026-08-27T18:00:01Z | TASK-000001 | Cleared | Later action. | Supersede the interrupted Focus. |\n"
        try DurableReplacement().replace(data: Data(superseded.utf8), at: target)
        throw NSError(domain: "HeadlessCanvasCommandsTests", code: 5)
    }
}
private final class CommandCanvasReloadFailingReader: ProductionsReading {
    var failCanvas = false
    private let local = LocalFileSystem()
    func exists(at url: URL) -> Bool { local.exists(at: url) }
    func isReadable(at url: URL) -> Bool { local.isReadable(at: url) }
    func isSymbolicLink(at url: URL) throws -> Bool { try local.isSymbolicLink(at: url) }
    func isDirectory(at url: URL) throws -> Bool { try local.isDirectory(at: url) }
    func directoryEntries(at url: URL) throws -> [FileSystemEntry] { try local.directoryEntries(at: url) }
    func readData(at url: URL) throws -> Data {
        failCanvas && url.path.hasSuffix("/Office/Threads/Canvas.md") ? Data("| malformed |".utf8) : try local.readData(at: url)
    }
}
private final class CommandCanvasReloadFailingReplacer: AtomicFileReplacing {
    private let durable = DurableReplacement()
    private let reader: CommandCanvasReloadFailingReader
    init(reader: CommandCanvasReloadFailingReader) { self.reader = reader }
    func replace(data: Data, at target: URL) throws {
        try durable.replace(data: data, at: target)
        reader.failCanvas = true
    }
}
