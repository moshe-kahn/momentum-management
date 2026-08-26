import Foundation
import XCTest
@testable import OperationsDashboard

final class SessionPreparationTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-08-15T22:00:00Z")!

    func testResumePackageUsesMementoOverlayAndRetainsCanonicalAuthority() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        let package = try renderer().prepare(state: fixture.load(), workID: "TASK-000001", authorization: .implement, recommendedModel: "gpt-5", reasoningLevel: "high")

        XCTAssertEqual(package.schemaVersion, 1)
        XCTAssertEqual(package.brief.sessionMode, .resume)
        XCTAssertEqual(package.brief.mementoName, "Pause")
        XCTAssertEqual(package.brief.mementoID, "MEM-000001")
        XCTAssertTrue(package.brief.currentStateOrLastValidatedState.contains("Captured; revalidate"))
        XCTAssertTrue(package.context.canonicalObjectiveAndBoundaries.contains("Complete the synthetic objective."))
        XCTAssertTrue(package.context.canonicalObjectiveAndBoundaries.contains("Verify the synthetic outcome."))
        XCTAssertEqual(package.sourceSnapshot.files.count, 3)
        XCTAssertTrue(package.sourceSnapshot.files.allSatisfy { $0.sha256.count == 64 })
        XCTAssertTrue(package.briefText.contains("Authorization: implement"))
        XCTAssertTrue(package.contextText.contains("## Canonical source references"))
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testCleanAbsenceProducesStartFallbackWithoutIssuingOrWriting() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        try fixture.add(try WorkspaceSectionEditing.removeCurrentMemento(from: fixture.workspaceRecord), at: "Workspace/TASK-000001/TASK-000001.md")
        fixture.replaceMementos(emptyMementos)
        let before = try fixture.snapshot()

        let package = try renderer().prepare(state: fixture.load(), workID: "TASK-000001", authorization: .readOnly, recommendedModel: "Codex", reasoningLevel: "medium")

        XCTAssertEqual(package.brief.sessionMode, .start)
        XCTAssertNil(package.brief.mementoID)
        XCTAssertTrue(package.brief.naturalResumePointOrNextStep.contains("Resume here"))
        XCTAssertEqual(try fixture.snapshot(), before)
        XCTAssertTrue(String(decoding: try fixture.data(at: "Warehouse/Reference/Identifier Ledger.md"), as: UTF8.self).contains("MEM-000002"))
    }

    func testStartAndResumePackagesIncludeStableAdministrativeHandoffBoundary() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let resume = try renderer().prepare(state: fixture.load(), workID: "TASK-000001", recommendedModel: "Codex", reasoningLevel: "high")
        try fixture.add(try WorkspaceSectionEditing.removeCurrentMemento(from: fixture.workspaceRecord), at: "Workspace/TASK-000001/TASK-000001.md")
        fixture.replaceMementos(emptyMementos)
        let start = try renderer().prepare(state: fixture.load(), workID: "TASK-000001", recommendedModel: "Codex", reasoningLevel: "high")

        for package in [resume, start] {
            let handoff = package.context.stoppingAndHandoffRequirements
            XCTAssertTrue(handoff.contains("do not improvise canonical Productions administration"))
            XCTAssertTrue(handoff.contains("requested operation"))
            XCTAssertTrue(handoff.contains("proposed durable target"))
            XCTAssertTrue(handoff.contains("explicit statement that the thought is untargeted"))
            XCTAssertTrue(handoff.contains("concise title or summary"))
            XCTAssertTrue(handoff.contains("proposed Crumb kind and priority when applicable"))
            XCTAssertTrue(handoff.contains("current validated task and repository state"))
            XCTAssertTrue(handoff.contains("source or evidence location"))
            XCTAssertTrue(handoff.contains("exact continuation or next-action implication"))
            XCTAssertTrue(handoff.contains("explicit boundaries on what was not authorized or performed"))
            XCTAssertTrue(handoff.contains("Quick Capture into `Office/Inbox/`"))
            XCTAssertTrue(handoff.contains("capture creates an unregistered payload only"))
            XCTAssertTrue(handoff.contains("`/Users/kahntra/Productions/PRODUCTIONS_OFFICE_ADMINISTRATOR.md`"))
            XCTAssertTrue(package.contextText.contains("## Stopping and handoff requirements"))
        }
    }

    func testCopyWritesOnlyDisplayedPackageAndLeavesProductionsUnchanged() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let pasteboard = RecordingPasteboard(), service = SessionPreparationService(renderer: renderer(), pasteboard: pasteboard)
        let package = try service.renderer.prepare(state: fixture.load(), workID: "TASK-000001", authorization: .review, recommendedModel: "Codex", reasoningLevel: "high")
        let before = try fixture.snapshot()

        try service.copy(package, configuration: fixture.configuration)

        XCTAssertEqual(pasteboard.text, package.displayedText)
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testChangedSourceInvalidatesPreviewBeforePasteboardWrite() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let pasteboard = RecordingPasteboard(), service = SessionPreparationService(renderer: renderer(), pasteboard: pasteboard)
        let package = try service.renderer.prepare(state: fixture.load(), workID: "TASK-000001", authorization: .diagnose, recommendedModel: "Codex", reasoningLevel: "high")
        try fixture.add(fixture.workspaceRecord + "\n\nConcurrent canonical change.", at: "Workspace/TASK-000001/TASK-000001.md")

        XCTAssertThrowsError(try service.copy(package, configuration: fixture.configuration)) { error in
            guard case .stalePreview = error as? SessionPreparationError else { return XCTFail("Expected stale preview, got \(error)") }
        }
        XCTAssertNil(pasteboard.text)
    }

    func testRootAmbiguityRequiresExplicitValidatedSelection() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let first = FileManager.default.temporaryDirectory.appending(path: "session-root-a-\(UUID().uuidString)", directoryHint: .isDirectory)
        let second = FileManager.default.temporaryDirectory.appending(path: "session-root-b-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true); try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let record = fixture.workspaceRecord.replacingOccurrences(of: "Relevant locations: \(fixture.root.path)", with: "Relevant locations: `\(first.path)`; `\(second.path)`")
        try fixture.add(record, at: "Workspace/TASK-000001/TASK-000001.md")
        let state = fixture.load()
        XCTAssertThrowsError(try renderer().prepare(state: state, workID: "TASK-000001", recommendedModel: "Codex", reasoningLevel: "high")) { error in
            guard case .ambiguousRoots = error as? SessionPreparationError else { return XCTFail("Expected root ambiguity, got \(error)") }
        }
        let package = try renderer().prepare(state: state, workID: "TASK-000001", recommendedModel: "Codex", reasoningLevel: "high", selectedRoot: second.path)
        XCTAssertEqual(package.brief.filesystemOrProjectRoot, second.path)
    }

    func testStartWorkCommitsCanvasOnceAndReportsSubsequentRenderingFailure() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        let beforeCount = fixture.load().canvas.count
        let coordinator = SessionPreparationCoordinator(canvas: CanvasWorkTransactionService(journalStore: MemoryCanvasJournalForSession(), now: { self.date }), renderer: renderer(), reader: LocalFileSystem())
        let work = try XCTUnwrap(fixture.load().work.first)

        let outcome = try coordinator.startWorkAndPrepare(configuration: fixture.configuration, work: work, reason: "Explicit start.", context: "Acceptance composition.", authorization: .readOnly, recommendedModel: "", reasoningLevel: "high")

        guard case let .canvasCommittedPackageFailed(message) = outcome else { return XCTFail("Expected a committed partial outcome") }
        XCTAssertTrue(message.contains("Canvas committed"))
        XCTAssertEqual(fixture.load().canvas.count, beforeCount + 1, "Current work appends exactly one Engaged event and is never retried.")
        XCTAssertEqual(fixture.load().mementos.map(\.id), ["MEM-000001"], "Starting work must not resolve the Memento.")
    }

    func testProcessingBundleRequiresMementoAndUsesFlowAsRoutingSnapshot() throws {
        let fixture = try SyntheticProductionsFixture(); defer { fixture.remove() }
        XCTAssertThrowsError(try renderer().prepare(state: fixture.load(), workID: "BND-000001", recommendedModel: "Codex", reasoningLevel: "high")) { error in
            guard case .contractConflict = error as? SessionPreparationError else { return XCTFail("Expected Registry-only fallback boundary, got \(error)") }
        }
        let bundle = "## Bundle Record\nLabel: Bundle\nObjective or question: Finish routing the bundle.\nNext step: Continue bundle review.\nCompletion or resolution criterion: Resolve every content row.\n\n## Processing State\nOpen\n\n## Contents\n| Item | Disposition | Destination |\n| --- | --- | --- |\n| source | — | — |\n\n## Current Memento\n\nMemento ID: MEM-000002\nCreated: 2026-08-15T21:00:00Z\nCurrent state: Bundle evidence file was reviewed.\nNatural resume point: Continue bundle review\nOpen Crumbs: —\nExtended payload: —"
        try fixture.add(bundle, at: "Office/Processing/BND-000001 - Bundle/BND-000001.md")
        fixture.replaceMementos(fixture.mementoLedger(location: "[task](../../Workspace/TASK-000001/TASK-000001.md)") + "\n| MEM-000002 | BND-000001 | Bundle pause | Continue bundle review | 2026-08-15T21:00:00Z | `Office/Processing/BND-000001 - Bundle/BND-000001.md#current-memento` |")

        let package = try renderer().prepare(state: fixture.load(), workID: "BND-000001", recommendedModel: "Codex", reasoningLevel: "high")
        XCTAssertEqual(package.brief.sessionMode, .resume)
        XCTAssertEqual(package.brief.workKind, "Processing bundle")
        XCTAssertEqual(package.sourceSnapshot.registry.path, "Office/Flow.md")
        XCTAssertEqual(package.sourceSnapshot.workspace.path, "Office/Processing/BND-000001 - Bundle/BND-000001.md")
    }

    private func renderer() -> SessionPackageRenderer { SessionPackageRenderer(now: { self.date }) }
    private var emptyMementos: String { "| Memento ID | Target | Summary | Resume point | Created | Location |\n| --- | --- | --- | --- | --- | --- |" }
}

private final class RecordingPasteboard: SessionPasteboardWriting {
    var text: String?
    func write(_ text: String) throws { self.text = text }
}

private final class MemoryCanvasJournalForSession: CanvasWorkTransactionJournalStore {
    var journals: [CanvasWorkTransactionJournal] = []
    func persist(_ journal: CanvasWorkTransactionJournal) throws { journals.append(journal) }
    func update(_ journal: CanvasWorkTransactionJournal) throws { if let index = journals.firstIndex(where: { $0.transactionID == journal.transactionID }) { journals[index] = journal } }
    func incomplete() throws -> [CanvasWorkTransactionJournal] { journals.filter { $0.terminalState == nil || $0.terminalState == .preCommitFailure } }
}
