import Foundation
import XCTest
@testable import OperationsDashboard

final class ProductionsReadOnlyTests: XCTestCase {
    func testCompleteSyntheticContractLoadsWithoutMutatingProductions() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        let before = try fixture.snapshot()
        let state = ProductionsLoader(reader: LocalFileSystem()).load(configuration: ProductionsConfiguration(schemaVersion: 2, productionsRootPath: fixture.root.path))
        XCTAssertTrue(state.issues.isEmpty, state.issues.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(state.inbox.compactMap(\.flowID), ["FLOW-000001"])
        XCTAssertEqual(state.processing.compactMap(\.flowID), ["BND-000001"])
        XCTAssertEqual(state.work.map(\.id), ["TASK-000001"])
        XCTAssertEqual(state.canvasCurrentIDs, ["TASK-000001"])
        XCTAssertEqual(state.crumbs.first?.target, "TASK-000001")
        XCTAssertEqual(state.mementos.first?.target, "TASK-000001")
        XCTAssertEqual(try fixture.snapshot(), before, "Read-only load must not write anywhere under Productions.")
    }

    func testMalformedAndDuplicateMementoAreVisibleErrors() throws {
        let fixture = try SyntheticProductionsFixture(duplicateMemento: true)
        defer { fixture.remove() }
        let state = ProductionsLoader(reader: LocalFileSystem()).load(configuration: ProductionsConfiguration(schemaVersion: 2, productionsRootPath: fixture.root.path))
        XCTAssertTrue(state.issues.contains { if case .duplicate = $0 { true } else { false } })
    }

    func testRootRelativeCodeMementoLocationResolvesWithoutAnchor() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        fixture.replaceMementos(fixture.mementoLedger(location: "`Workspace/TASK-000001/TASK-000001.md`"))

        let state = fixture.load()

        XCTAssertEqual(state.mementos.first?.location, "Workspace/TASK-000001/TASK-000001.md")
        XCTAssertFalse(state.issues.contains { if case .malformed("Memento MEM-000001") = $0 { true } else { false } })
    }

    func testRootRelativeCodeMementoLocationResolvesCurrentMementoAnchor() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        try fixture.add("# TASK-000001\n\n## Current Memento\n\nMemento ID: MEM-000001", at: "Workspace/TASK-000001/TASK-000001.md")
        fixture.replaceMementos(fixture.mementoLedger(location: "`Workspace/TASK-000001/TASK-000001.md#current-memento`"))

        let state = fixture.load()

        XCTAssertEqual(state.mementos.first?.location, "Workspace/TASK-000001/TASK-000001.md#current-memento")
        XCTAssertFalse(state.issues.contains { if case .malformed("Memento MEM-000001") = $0 { true } else { false } })
    }

    func testExistingMementoFileWithMismatchedAnchorIsRejected() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        try fixture.add("# TASK-000001\n\n## Current Memento", at: "Workspace/TASK-000001/TASK-000001.md")
        fixture.replaceMementos(fixture.mementoLedger(location: "`Workspace/TASK-000001/TASK-000001.md#different-memento`"))

        let state = fixture.load()

        XCTAssertTrue(state.mementos.isEmpty)
        XCTAssertTrue(state.issues.contains(.malformed("Memento MEM-000001")))
    }

    func testMementoAnchorIsExcludedFromFilesystemExistenceCheck() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        try fixture.add("# TASK-000001\n\n## Current Memento", at: "Workspace/TASK-000001/TASK-000001.md")
        fixture.replaceMementos(fixture.mementoLedger(location: "`Workspace/TASK-000001/TASK-000001.md#current-memento`"))
        let reader = RecordingProductionsReader()

        let state = ProductionsLoader(reader: reader).load(configuration: fixture.configuration)

        XCTAssertEqual(state.mementos.map(\.id), ["MEM-000001"])
        XCTAssertTrue(reader.existenceChecks.contains { $0.hasSuffix("Workspace/TASK-000001/TASK-000001.md") })
        XCTAssertFalse(reader.existenceChecks.contains { $0.contains("#current-memento") })
    }

    func testRootRelativeMementoLocationCannotEscapeProductionsRoot() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        let name = "escaped-memento-\(UUID().uuidString).md"
        try fixture.addOutsideRoot("outside", named: name)
        fixture.replaceMementos(fixture.mementoLedger(location: "`../\(name)`"))

        let state = fixture.load()

        XCTAssertTrue(state.mementos.isEmpty)
        XCTAssertTrue(state.issues.contains(.malformed("Memento MEM-000001")))
    }

    func testMissingAndSymbolicLinkMementoTargetsRemainRejected() throws {
        let missingFixture = try SyntheticProductionsFixture()
        defer { missingFixture.remove() }
        missingFixture.replaceMementos(missingFixture.mementoLedger(location: "`Workspace/TASK-000001/missing.md`"))
        let missingState = missingFixture.load()
        XCTAssertTrue(missingState.mementos.isEmpty)
        XCTAssertTrue(missingState.issues.contains(.malformed("Memento MEM-000001")))

        let symlinkFixture = try SyntheticProductionsFixture()
        defer { symlinkFixture.remove() }
        try symlinkFixture.addMementoSymlink(at: "Workspace/TASK-000001/memento-link.md")
        symlinkFixture.replaceMementos(symlinkFixture.mementoLedger(location: "`Workspace/TASK-000001/memento-link.md`"))
        let symlinkState = symlinkFixture.load()
        XCTAssertTrue(symlinkState.mementos.isEmpty)
        XCTAssertTrue(symlinkState.issues.contains(.malformed("Memento MEM-000001")))
    }

    func testUnreferencedInboxFileAppearsAsOneUnregisteredItemWithoutWrites() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        try fixture.add("test payload", at: "Office/Inbox/drop-me.txt")
        let before = try fixture.snapshot()
        let state = fixture.load()
        let item = try XCTUnwrap(state.inbox.first { $0.label == "drop-me.txt" })
        XCTAssertTrue(item.isUnregistered)
        XCTAssertNil(item.flowID)
        XCTAssertEqual(item.priority, "")
        XCTAssertEqual(try fixture.snapshot(), before)
    }

    func testUnreferencedInboxFolderAppearsOnceAndIgnoresDescendantsAndHiddenChildren() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        try fixture.add("nested", at: "Office/Inbox/Research/notes.md")
        try fixture.add("hidden", at: "Office/Inbox/.ignored.md")
        let state = fixture.load()
        XCTAssertEqual(state.inbox.filter { $0.label == "Research" }.count, 1)
        XCTAssertFalse(state.inbox.contains { $0.label == "notes.md" || $0.label == ".ignored.md" })
    }

    func testRegisteredInboxPayloadAppearsNormally() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        let item = try XCTUnwrap(fixture.load().inbox.first { $0.label == "Inbox item" })
        XCTAssertEqual(item.flowID, "FLOW-000001")
        XCTAssertFalse(item.isUnregistered)
        XCTAssertEqual(item.priority, "High")
    }

    func testMissingAndDuplicateInboxFlowReferencesRemainErrors() throws {
        let fixture = try SyntheticProductionsFixture()
        defer { fixture.remove() }
        fixture.replaceFlow(fixture.flow + "\n| FLOW-000002 | Missing | Note | Inbox | Low | Office | Office | — | test | — | `Office/Inbox/missing.md` | Missing | Review | 2026-08-11 | 2026-08-11 |\n| FLOW-000003 | Duplicate | Note | Inbox | Low | Office | Office | — | test | — | `Office/Inbox/FLOW-000001.md` | Duplicate | Review | 2026-08-11 | 2026-08-11 |")
        let state = fixture.load()
        XCTAssertTrue(state.issues.contains { if case .unresolved = $0 { true } else { false } })
        XCTAssertTrue(state.issues.contains { if case .duplicate = $0 { true } else { false } })
    }
}

final class SyntheticProductionsFixture {
    let root: URL
    private let manager = FileManager.default
    private var additionalURLs: [URL] = []
    init(duplicateMemento: Bool = false) throws {
        root = manager.temporaryDirectory.appending(path: "ProductionsReadOnlyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try write("payload", "Office/Inbox/FLOW-000001.md")
        try write("# TASK-000001\n\nSynthetic record.", "Workspace/TASK-000001/TASK-000001.md")
        try write("## Bundle Record\nKey: value\n\n## Processing State\nOpen\n\n## Contents\n| Item | Disposition | Destination |\n| --- | --- | --- |\n| source | — | — |", "Office/Processing/BND-000001 - Bundle/BND-000001.md")
        try write(flow, "Office/Flow.md")
        try write(identifierLedger, "Warehouse/Reference/Identifier Ledger.md")
        try write(taskRegistry, "Office/Registry/Tasks.md")
        try write("| Idea ID | Title | Disposition | Priority | Current lead | Related records | Source artifacts | Short description | Workspace |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |", "Office/Registry/Ideas.md")
        try write("| Project ID | Title | State | Priority | Current lead | Related records | Depends on | Short description | Workspace |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |", "Office/Registry/Projects.md")
        try write("| Initiative ID | Title | State | Priority | Current lead | Related records | Depends on | Short description | Workspace |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- |", "Office/Registry/Initiatives.md")
        try write("| Product ID | Product | Lifecycle | Current lead | Related initiatives / products | Canonical workspace |\n| --- | --- | --- | --- | --- | --- |", "Office/Registry/Products.md")
        try write("| Department | Function |\n| --- | --- |\n| Office | Operations |", "Office/Registry/Departments.md")
        try write("| Occurred | Work ID | Event | Reason | Context |\n| --- | --- | --- | --- | --- |\n| 2026-08-11T12:00:00Z | TASK-000001 | Placed | focus | test |\n| 2026-08-11T12:01:00Z | TASK-000001 | Engaged | work | test |", "Office/Threads/Canvas.md")
        try write("| Crumb ID | Kind | Target | Priority | Summary | Created | Location |\n| --- | --- | --- | --- | --- | --- | --- |\n| CRMB-000001 | Action | TASK-000001 | High | Continue | 2026-08-11 | [task](../../Workspace/TASK-000001/TASK-000001.md) |", "Office/Threads/Crumbs.md")
        let mementos = "| Memento ID | Target | Summary | Resume point | Created | Location |\n| --- | --- | --- | --- | --- | --- |\n| MEM-000001 | TASK-000001 | Pause | Resume here | 2026-08-11 | [task](../../Workspace/TASK-000001/TASK-000001.md) |" + (duplicateMemento ? "\n| MEM-000002 | TASK-000001 | Duplicate | Again | 2026-08-11 | [task](../../Workspace/TASK-000001/TASK-000001.md) |" : "")
        try write(mementos, "Office/Threads/Mementos.md")
    }
    func remove() { try? manager.removeItem(at: root); additionalURLs.forEach { try? manager.removeItem(at: $0) } }
    var configuration: ProductionsConfiguration { ProductionsConfiguration(schemaVersion: 2, productionsRootPath: root.path) }
    func load() -> ProductionsState { ProductionsLoader(reader: LocalFileSystem()).load(configuration: configuration) }
    func add(_ text: String, at path: String) throws { try write(text, path) }
    func addOutsideRoot(_ text: String, named name: String) throws { let url = root.deletingLastPathComponent().appending(path: name); try Data(text.utf8).write(to: url); additionalURLs.append(url) }
    func addMementoSymlink(at path: String) throws {
        let url = root.appending(path: path)
        try manager.createSymbolicLink(at: url, withDestinationURL: root.appending(path: "Workspace/TASK-000001/TASK-000001.md"))
    }
    func replaceFlow(_ text: String) { try? write(text, "Office/Flow.md") }
    func replaceLedger(_ text: String) { try? write(text, "Warehouse/Reference/Identifier Ledger.md") }
    func replaceMementos(_ text: String) { try? write(text, "Office/Threads/Mementos.md") }
    func data(at path: String) throws -> Data { try Data(contentsOf: root.appending(path: path)) }
    func snapshot() throws -> [String: Data] { let files = try manager.subpathsOfDirectory(atPath: root.path).sorted(); return try Dictionary(uniqueKeysWithValues: files.map { path in let url = root.appending(path: path); return (path, (try? Data(contentsOf: url)) ?? Data()) }) }
    private func write(_ text: String, _ path: String) throws { let url = root.appending(path: path); try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try Data(text.utf8).write(to: url) }
    var flow: String { "| Entry ID | Label | Type | Stage | Priority | Steward | Department | Product | Source | Related work | Location | Summary | Next disposition | Created | Updated |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| FLOW-000001 | Inbox item | Note | Inbox | High | Office | Office | — | test | TASK-000001 | `Office/Inbox/FLOW-000001.md` | Incoming | Review | 2026-08-11 | 2026-08-11 |\n| BND-000001 | Bundle | Bundle | Processing | Medium | Office | Office | — | test | TASK-000001 | `Office/Processing/BND-000001 - Bundle/` | Processing | Review | 2026-08-11 | 2026-08-11 |" }
    var identifierLedger: String { "| Identifier type | Prefix | Minimum digits | Last issued | Next display |\n| --- | --- | --- | --- | --- |\n| Inbox / routing entry | FLOW | 6 | 1 | `FLOW-000002` |" }
    func mementoLedger(location: String) -> String { "| Memento ID | Target | Summary | Resume point | Created | Location |\n| --- | --- | --- | --- | --- | --- |\n| MEM-000001 | TASK-000001 | Pause | Resume here | 2026-08-11 | \(location) |" }
    private var taskRegistry: String { "| Task ID | Title | State | Priority | Current lead | Initiative | Project | Depends on | Short description | Workspace |\n| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |\n| TASK-000001 | Synthetic task | Active / Current | High | Office | — | — | — | test | [task](../../Workspace/TASK-000001/TASK-000001.md) |" }
}

private final class RecordingProductionsReader: ProductionsReading {
    private let local = LocalFileSystem()
    private(set) var existenceChecks: [String] = []
    func exists(at url: URL) -> Bool { existenceChecks.append(url.path); return local.exists(at: url) }
    func isReadable(at url: URL) -> Bool { local.isReadable(at: url) }
    func isSymbolicLink(at url: URL) throws -> Bool { try local.isSymbolicLink(at: url) }
    func isDirectory(at url: URL) throws -> Bool { try local.isDirectory(at: url) }
    func directoryEntries(at url: URL) throws -> [FileSystemEntry] { try local.directoryEntries(at: url) }
    func readData(at url: URL) throws -> Data { try local.readData(at: url) }
}
