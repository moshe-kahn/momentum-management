import Foundation
import XCTest
@testable import OperationsDashboard

final class RecoveryJournalRootTests: XCTestCase {
    func testDefaultRootRemainsApplicationSupportWhenEnvOverrideIsAbsent() {
        let manager = FileManager.default
        let expected = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "Operations Dashboard/Canvas Work Transaction Recovery", directoryHint: .isDirectory)

        XCTAssertEqual(
            RecoveryJournalRoot.directory(
                named: "Canvas Work Transaction Recovery",
                manager: manager,
                environment: [:]
            ).standardizedFileURL,
            expected.standardizedFileURL
        )
    }

    func testEnvOverrideRoutesAllApplicationRecoveryStoresUnderOverrideRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "OperationsDashboardRecoveryRoot-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }

        setenv(RecoveryJournalRoot.environmentKey, root.path, 1)
        defer { unsetenv(RecoveryJournalRoot.environmentKey) }

        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

        try ApplicationSupportCanvasWorkTransactionJournalStore().persist(.init(
            transactionID: id,
            timestamp: timestamp,
            action: .start,
            workID: "TASK-000001",
            canvasHash: "canvas-before",
            canvasPreimage: Data("canvas".utf8),
            appendedEvents: ["Engaged"],
            reason: "test",
            context: nil,
            clearBasis: nil,
            targetHash: nil,
            expectedCanvasHash: nil,
            terminalState: nil,
            diagnostic: nil
        ))
        XCTAssertTrue(fileExists(root, "Canvas Work Transaction Recovery/\(id.uuidString).json"))

        try ApplicationSupportMementoTransactionJournalStore().persist(.init(
            transactionID: id,
            timestamp: timestamp,
            action: .create,
            productionsRootPath: nil,
            targetID: "TASK-000001",
            mementoID: "MEM-000001",
            targetPath: "Workspace/TASK-000001/TASK-000001.md",
            identifierHash: nil,
            mementoLedgerHash: "memento-ledger-before",
            targetHash: "target-before",
            identifierPreimage: nil,
            mementoLedgerPreimage: Data("mementos".utf8),
            targetPreimage: Data("target".utf8),
            payloadPath: nil,
            payloadPreimage: nil,
            terminalState: nil,
            diagnostic: nil
        ))
        XCTAssertTrue(fileExists(root, "Memento Transaction Recovery/\(id.uuidString).json"))

        try ApplicationSupportFlowRegistrationJournalStore().persist(.init(
            transactionID: id,
            timestamp: timestamp,
            payloadPath: "Dashboard/Inbox/item.txt",
            flowID: "FLOW-000001",
            ledgerHash: "identifier-before",
            flowHash: "flow-before",
            ledgerPreimage: Data("ledger".utf8),
            flowPreimage: Data("flow".utf8),
            terminalState: nil,
            diagnostic: nil
        ))
        XCTAssertTrue(fileExists(root, "Flow Registration Recovery/\(id.uuidString).json"))

        XCTAssertEqual(
            ApplicationSupportAcceptedHandoffJournalStore().directory.standardizedFileURL,
            root.appending(path: "Office Workspace Transaction Recovery", directoryHint: .isDirectory).standardizedFileURL
        )

        _ = try ApplicationSupportManagerRoutingLedgerStore().transact(expectedSHA256: nil) { ledger in
            ledger.continuationEnvelopes = []
        }
        XCTAssertTrue(fileExists(root, "Manager Routing Recovery"))
    }

    func testProductionsRootFallbackRoutesStoresUnderWarehouseRecoveryWhenEnvIsAbsent() throws {
        unsetenv(RecoveryJournalRoot.environmentKey)
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        let id = UUID()

        try RecoveryJournalRoot.withProductionsRoot(fixture.root.path) {
            try ApplicationSupportCanvasWorkTransactionJournalStore().persist(.init(
                transactionID: id,
                timestamp: Date(timeIntervalSince1970: 1_800_000_001),
                action: .start,
                workID: "TASK-000001",
                canvasHash: "canvas-before",
                canvasPreimage: Data("canvas".utf8),
                appendedEvents: ["Engaged"],
                reason: "test",
                context: nil,
                clearBasis: nil,
                targetHash: nil,
                expectedCanvasHash: nil,
                terminalState: nil,
                diagnostic: nil
            ))
        }

        XCTAssertTrue(fileExists(
            fixture.root,
            "Warehouse/Recovery/OperationsDashboard/Canvas Work Transaction Recovery/\(id.uuidString).json"
        ))
    }

    func testEnvOverrideTakesPrecedenceOverProductionsRootFallback() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        let override = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appending(path: "OperationsDashboardRecoveryEnvWins-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: override) }
        setenv(RecoveryJournalRoot.environmentKey, override.path, 1)
        defer { unsetenv(RecoveryJournalRoot.environmentKey) }

        let directory = RecoveryJournalRoot.withProductionsRoot(fixture.root.path) {
            RecoveryJournalRoot.directory(named: "Canvas Work Transaction Recovery")
        }

        XCTAssertEqual(
            directory.standardizedFileURL,
            override.appending(path: "Canvas Work Transaction Recovery", directoryHint: .isDirectory).standardizedFileURL
        )
    }

    func testHeadlessCanvasCommandUsesProductionsRootFallbackForDefaultJournalStore() throws {
        unsetenv(RecoveryJournalRoot.environmentKey)
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        var output: [String] = []

        let exit = HeadlessCanvasCommandLine.runIfRequested(
            arguments: [
                "OperationsDashboard", "canvas", "focus",
                "--productions-root", fixture.root.path,
                "--work", "TASK-000001",
                "--reason", "Recovery root fallback test.",
                "--context", "Verify journal placement."
            ],
            write: { output.append($0) }
        )

        XCTAssertEqual(exit, 0, output.joined(separator: "\n"))
        let recovery = fixture.root.appending(
            path: "Warehouse/Recovery/OperationsDashboard/Canvas Work Transaction Recovery",
            directoryHint: .isDirectory
        )
        let journals = try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(journals.count, 1)
    }

    private func fileExists(_ root: URL, _ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appending(path: relativePath).path)
    }
}
