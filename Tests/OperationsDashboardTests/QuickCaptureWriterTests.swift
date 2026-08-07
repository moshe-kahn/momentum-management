import XCTest
@testable import OperationsDashboard

final class QuickCaptureWriterTests: XCTestCase {
    func testCreatesExactUTF8MarkdownAndPreservesVerbatimUnicodeMultilineText() throws {
        let fixture = try QuickCaptureFixture()
        let text = "  leading text\nUnicode: café 🎬\ntrailing spaces  "
        let result = fixture.writer.create(text: text, configuration: fixture.configuration, now: fixture.date)
        let path = try successPath(result)

        XCTAssertEqual(path.lastPathComponent, "Quick Capture \(fixture.filenameDate).md")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "# Quick Capture\n\nCreated: \(fixture.metadataDate)\nSource: Operations Dashboard / Quick Capture\n\n\(text)\n")
        XCTAssertEqual(try fixture.names(in: fixture.destination), [path.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.first.appending(path: "source.txt").path))
    }

    func testRejectsEmptyAndWhitespaceOnlyTextWithoutCreatingAFile() throws {
        let fixture = try QuickCaptureFixture()

        XCTAssertEqual(fixture.writer.create(text: "", configuration: fixture.configuration, now: fixture.date), .failure(.invalidText, diagnostic: "Enter non-whitespace Quick Capture text."))
        XCTAssertEqual(fixture.writer.create(text: " \n\t ", configuration: fixture.configuration, now: fixture.date), .failure(.invalidText, diagnostic: "Enter non-whitespace Quick Capture text."))
        XCTAssertTrue(try fixture.names(in: fixture.destination).isEmpty)
    }

    func testCollisionSuffixesDoNotOverwriteExistingNotes() throws {
        let fixture = try QuickCaptureFixture()
        let base = "Quick Capture \(fixture.filenameDate).md"
        let second = "Quick Capture \(fixture.filenameDate) (2).md"
        try fixture.write("existing base", at: fixture.destination.appending(path: base))
        try fixture.write("existing second", at: fixture.destination.appending(path: second))

        let path = try successPath(fixture.writer.create(text: "new", configuration: fixture.configuration, now: fixture.date))

        XCTAssertEqual(path.lastPathComponent, "Quick Capture \(fixture.filenameDate) (3).md")
        XCTAssertEqual(try String(contentsOf: fixture.destination.appending(path: base)), "existing base")
        XCTAssertEqual(try String(contentsOf: fixture.destination.appending(path: second)), "existing second")
    }

    func testCollisionExhaustionDoesNotCreateAnAdditionalFile() throws {
        let fixture = try QuickCaptureFixture()
        for attempt in 1...QuickCaptureWriter.maximumCollisionAttempts {
            try fixture.write("existing", at: fixture.destination.appending(path: fixture.filename(attempt: attempt)))
        }

        let result = fixture.writer.create(text: "new", configuration: fixture.configuration, now: fixture.date)

        XCTAssertEqual(result, .failure(.collisionExhausted, diagnostic: "No collision-safe Quick Capture filename was available."))
        XCTAssertEqual(try fixture.names(in: fixture.destination).count, QuickCaptureWriter.maximumCollisionAttempts)
    }

    func testUnavailableDestinationAndInvalidConfigurationAreRejectedWithoutWriting() throws {
        let missingDestination = try QuickCaptureFixture(createDestination: false)
        XCTAssertEqual(missingDestination.writer.create(text: "note", configuration: missingDestination.configuration, now: missingDestination.date), .failure(.destinationUnavailable, diagnostic: "Enterprise Inbox destination is unavailable."))

        let fixture = try QuickCaptureFixture()
        let invalid = CaptureConfiguration(schemaVersion: 1, intakeSources: fixture.configuration.intakeSources, enterpriseInboxPath: "/outside/inbox")
        let result = fixture.writer.create(text: "note", configuration: invalid, now: fixture.date)
        guard case .failure(.configurationInvalid, _) = result else {
            return XCTFail("Expected configuration failure, got \(result)")
        }
        XCTAssertTrue(try fixture.names(in: fixture.destination).isEmpty)
    }

    func testInjectedWriteFailureDoesNotReportSuccessOrCreateFallback() throws {
        let fixture = try QuickCaptureFixture()
        let failingWriter = QuickCaptureWriter(fileSystem: FailingQuickCaptureFileSystem(destination: fixture.destination))

        let result = failingWriter.create(text: "note", configuration: fixture.configuration, now: fixture.date)

        guard case .failure(.writeFailed, _) = result else {
            return XCTFail("Expected write failure, got \(result)")
        }
        XCTAssertTrue(try fixture.names(in: fixture.destination).isEmpty)
    }

    private func successPath(_ result: QuickCaptureResult) throws -> URL {
        guard case let .success(path) = result else { throw NSError(domain: "QuickCaptureWriterTests", code: 1) }
        return path
    }
}

private final class QuickCaptureFixture {
    let root: URL
    let first: URL
    let destination: URL
    let configuration: CaptureConfiguration
    let writer = QuickCaptureWriter()
    let date: Date
    let filenameDate: String
    let metadataDate: String

    init(createDestination: Bool = true) throws {
        root = FileManager.default.temporaryDirectory.appending(path: "QuickCaptureWriterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        first = root.appending(path: "iCloud", directoryHint: .isDirectory)
        let second = root.appending(path: "Kahntra", directoryHint: .isDirectory)
        destination = root.appending(path: "Enterprise/Dashboard/Inbox", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        if createDestination { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        try Data("source".utf8).write(to: first.appending(path: "source.txt"))
        configuration = CaptureConfiguration(schemaVersion: 1, intakeSources: [
            IntakeSource(id: "icloud-downloads", displayName: "iCloud Drive Downloads", rootPath: first.path),
            IntakeSource(id: "kahntra-downloads", displayName: "Kahntra Downloads", rootPath: second.path)
        ], enterpriseInboxPath: destination.path)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        date = calendar.date(from: DateComponents(year: 2026, month: 8, day: 7, hour: 16, minute: 32, second: 45))!
        filenameDate = Self.filenameFormatter.string(from: date)
        metadataDate = Self.metadataFormatter.string(from: date)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func filename(attempt: Int) -> String {
        "Quick Capture \(filenameDate)\(attempt == 1 ? "" : " (\(attempt))").md"
    }

    func write(_ text: String, at url: URL) throws { try text.data(using: .utf8)!.write(to: url) }
    func names(in url: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return formatter
    }()

    private static let metadataFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssXXXXX"
        return formatter
    }()
}

private struct FailingQuickCaptureFileSystem: QuickCaptureFileSystem {
    let destination: URL
    func exists(at url: URL) -> Bool { url.standardizedFileURL.path == destination.standardizedFileURL.path }
    func isReadable(at url: URL) -> Bool { exists(at: url) }
    func isWritable(at url: URL) -> Bool { exists(at: url) }
    func isDirectory(at url: URL) throws -> Bool { exists(at: url) }
    func isSymbolicLink(at url: URL) throws -> Bool { false }
    func createNewFile(at url: URL, contents: Data) throws { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError) }
}
