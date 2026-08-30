import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import OperationsDashboard

final class AcceptedHandoffTransactionsTests: XCTestCase {
    private let operationID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    func testProductionServiceCommitsOneImmutableRowAndPreservesGuards() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let journal = HandoffMemoryJournal()
        let registryBefore = try fixture.read(fixture.registryURL)
        let dependentBefore = try fixture.read(fixture.dependentURL)
        let unrelatedBefore = fixture.unrelatedManifest()

        let result = try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration)

        XCTAssertEqual(result.outcome, "committed")
        XCTAssertEqual(result.classification, "committed-and-current")
        XCTAssertEqual(result.operationUUID, operationID)
        XCTAssertEqual(result.sourceID, "TASK-0066")
        XCTAssertEqual(result.dependentID, "TASK-0064")
        XCTAssertEqual(result.marker, "picker-v1")
        XCTAssertTrue(result.historicalCommitProven)
        XCTAssertTrue(result.journalFinalized)
        XCTAssertFalse(result.fallbackRecorded)
        XCTAssertEqual(result.discoveryOutcome, "complete")
        XCTAssertEqual(result.newlyEligibleHooks, [])
        XCTAssertEqual(try fixture.read(fixture.registryURL), registryBefore)
        XCTAssertEqual(try fixture.read(fixture.dependentURL), dependentBefore)
        XCTAssertEqual(fixture.unrelatedManifest(), unrelatedBefore)
        let text = String(decoding: try fixture.read(fixture.sourceURL), as: UTF8.self)
        XCTAssertTrue(text.contains("| picker-v1 | 2026-08-29T20:00:00Z | `Warehouse/Evidence/source.md#accepted-build` |"))
        XCTAssertEqual(text.components(separatedBy: "| picker-v1 |").count, 2)
        XCTAssertEqual(journal.values.count, 1)
    }

    func testExistingAcceptedHandoffsAppendsBeforeLaterSectionWithoutChangingSuffix() throws {
        let fixture = try HandoffFixture(existingMarker: true, laterSection: true); defer { fixture.remove() }
        let before = String(decoding: try fixture.read(fixture.sourceURL), as: UTF8.self)
        let suffix = try XCTUnwrap(before.range(of: "## Later Unknown Section")).lowerBound
        let expectedSuffix = String(before[suffix...])

        _ = try service().perform(request: fixture.request(), configuration: fixture.configuration)
        let after = String(decoding: try fixture.read(fixture.sourceURL), as: UTF8.self)

        XCTAssertTrue(after.contains("| prior-v1 | 2026-08-28T20:00:00Z | `Warehouse/Evidence/prior.md` |"))
        XCTAssertTrue(after.contains("| picker-v1 | 2026-08-29T20:00:00Z | `Warehouse/Evidence/source.md#accepted-build` |"))
        XCTAssertTrue(after.hasSuffix(expectedSuffix))
    }

    func testMalformedOrFragmentedHistoricalAcceptedHandoffTablesRejectBeforeJournal() throws {
        let mutations: [(HandoffFixture) throws -> Void] = [
            { try $0.append("| Upper-Marker | 2026-08-27T20:00:00Z | `Warehouse/Evidence/prior.md` |\n", to: $0.sourceURL) },
            { try $0.append("\n| Upper-Marker | 2026-08-27T20:00:00Z | `Warehouse/Evidence/prior.md` |\n", to: $0.sourceURL) },
            { try $0.append("\n| malformed | row |\n", to: $0.sourceURL) },
            { try $0.append("\n  | hidden | 2026-08-27T20:00:00Z | evidence |\n", to: $0.sourceURL) },
            { try $0.append("\n| --- | --- | --- |\n", to: $0.sourceURL) },
            {
                try $0.replace(
                    in: $0.sourceURL,
                    "## Accepted Handoffs\n\n| Marker |",
                    with: "## Accepted Handoffs\nNarrative before table.\n| Marker |"
                )
            },
        ]
        for mutate in mutations {
            let fixture = try HandoffFixture(existingMarker: true); defer { fixture.remove() }
            try mutate(fixture)
            let journal = HandoffMemoryJournal()
            let failure = try captureFailure {
                try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid")
            XCTAssertTrue(journal.values.isEmpty)
            XCTAssertNil(failure.result.inspectCommand)
        }

        let permitted = try HandoffFixture(existingMarker: true); defer { permitted.remove() }
        try permitted.append("\nHistorical context after the exact table.\n", to: permitted.sourceURL)
        let result = try service().perform(request: permitted.request(), configuration: permitted.configuration)
        XCTAssertEqual(result.outcome, "committed")
    }

    func testReverseDiscoveryReturnsExactPendingDependentHook() throws {
        let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
        let result = try service(discover: AcceptedHandoffDiscovery.newlyEligible)
            .perform(request: fixture.request(), configuration: fixture.configuration)
        XCTAssertEqual(result.newlyEligibleHooks, [
            .init(candidateID: "TASK-0064", hook: "TASK-0066@accepted-handoff:picker-v1"),
        ])
    }

    func testReverseDiscoveryValidatesEveryDispositionControlTuple() throws {
        let timestamp = "2026-08-29T21:00:00Z"
        let valid: [(String, Bool, Bool)] = [
            (HandoffFixture.reviewRow(disposition: "Pending"), true, false),
            (HandoffFixture.reviewRow(disposition: "Proceed", decidedAt: timestamp), false, false),
            (HandoffFixture.reviewRow(disposition: "Decline", decidedAt: timestamp), false, false),
            (HandoffFixture.reviewRow(
                disposition: "Defer", decidedAt: timestamp,
                reconsiderAfter: "TASK-0066@accepted-handoff:other-marker"
            ), false, false),
            (HandoffFixture.reviewRow(
                disposition: "Replace", decidedAt: timestamp,
                replacement: "IDEA-0001@TASK-0066@accepted-handoff:other-marker"
            ), false, true),
        ]
        for (row, visible, needsReplacement) in valid {
            let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
            if needsReplacement { try fixture.installReplacementIdea() }
            try fixture.setDependentReviewRow(row)
            let result = try service(discover: AcceptedHandoffDiscovery.newlyEligible)
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "committed")
            XCTAssertEqual(result.newlyEligibleHooks?.isEmpty, !visible, row)
        }

        let malformed = [
            HandoffFixture.reviewRow(disposition: "Pending", question: "—"),
            HandoffFixture.reviewRow(disposition: "Pending", decidedAt: timestamp),
            HandoffFixture.reviewRow(disposition: "Proceed"),
            HandoffFixture.reviewRow(disposition: "Proceed", decidedAt: timestamp, reconsiderAfter: "TASK-0066@accepted-handoff:other-marker"),
            HandoffFixture.reviewRow(disposition: "Decline", decidedAt: "2026-08-29"),
            HandoffFixture.reviewRow(disposition: "Decline", decidedAt: timestamp, replacement: "TASK-9999@TASK-0066@done-complete"),
            HandoffFixture.reviewRow(disposition: "Defer", decidedAt: timestamp),
            HandoffFixture.reviewRow(disposition: "Defer", decidedAt: timestamp, reconsiderAfter: HandoffFixture.primaryHook),
            HandoffFixture.reviewRow(disposition: "Defer", decidedAt: timestamp, reconsiderAfter: "narrative trigger"),
            HandoffFixture.reviewRow(disposition: "Replace", decidedAt: timestamp),
            HandoffFixture.reviewRow(disposition: "Replace", decidedAt: timestamp, reconsiderAfter: "TASK-0066@done-complete", replacement: "IDEA-0001@TASK-0066@accepted-handoff:other-marker"),
            HandoffFixture.reviewRow(disposition: "Replace", decidedAt: timestamp, replacement: "TASK-0064@TASK-0066@accepted-handoff:other-marker"),
            HandoffFixture.reviewRow(disposition: "Unknown", decidedAt: timestamp),
        ]
        for row in malformed {
            let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
            try fixture.setDependentReviewRow(row)
            let result = try service(discover: AcceptedHandoffDiscovery.newlyEligible)
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "committed-with-discovery-failure", row)
            XCTAssertTrue(result.historicalCommitProven, row)
            XCTAssertEqual(result.discoveryOutcome, "failed", row)
            XCTAssertNil(result.newlyEligibleHooks, row)
        }
    }

    func testReverseDiscoveryRejectsRegistryWorkspaceHookSetMismatchAfterProvenCommit() throws {
        do {
            let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
            try fixture.replace(
                in: fixture.dependentURL,
                HandoffFixture.primaryHook,
                with: "TASK-0066@accepted-handoff:other-marker"
            )
            let result = try service(discover: AcceptedHandoffDiscovery.newlyEligible)
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "committed-with-discovery-failure")
            XCTAssertTrue(result.historicalCommitProven)
            XCTAssertEqual(result.discoveryOutcome, "failed")
            XCTAssertNil(result.newlyEligibleHooks)
        }
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            try fixture.append("""

            ## Eligibility Reviews

            | Hook | Review question | Disposition | Decided at | Reconsider after | Replacement |
            | --- | --- | --- | --- | --- | --- |
            \(HandoffFixture.reviewRow(disposition: "Pending"))
            """ + "\n", to: fixture.dependentURL)
            let result = try service(discover: AcceptedHandoffDiscovery.newlyEligible)
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "committed-with-discovery-failure")
            XCTAssertTrue(result.historicalCommitProven)
            XCTAssertNil(result.newlyEligibleHooks)
        }
    }

    func testReverseDiscoveryRejectsReplaceUnresolvedTargetAndCycleAfterProvenCommit() throws {
        let timestamp = "2026-08-29T21:00:00Z"
        do {
            let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
            try fixture.setDependentReviewRow(HandoffFixture.reviewRow(
                disposition: "Replace", decidedAt: timestamp,
                replacement: "IDEA-9999@TASK-0066@accepted-handoff:other-marker"
            ))
            let result = try service(discover: AcceptedHandoffDiscovery.newlyEligible)
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "committed-with-discovery-failure")
            XCTAssertTrue(result.historicalCommitProven)
        }
        do {
            let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
            try fixture.setDependentReviewRow(HandoffFixture.reviewRow(
                disposition: "Replace", decidedAt: timestamp,
                replacement: "IDEA-0001@TASK-0066@accepted-handoff:other-marker"
            ))
            try fixture.installReplacementIdea(row: HandoffFixture.reviewRow(
                hook: "TASK-0066@accepted-handoff:other-marker",
                disposition: "Replace", decidedAt: timestamp,
                replacement: "TASK-0064@\(HandoffFixture.primaryHook)"
            ))
            let result = try service(discover: AcceptedHandoffDiscovery.newlyEligible)
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "committed-with-discovery-failure")
            XCTAssertTrue(result.diagnostic?.contains("cycle") == true)
        }
    }

    func testReverseDiscoveryRejectsNoncanonicalOrNonUTF8CandidateAfterProvenCommit() throws {
        let mutations: [(HandoffFixture) throws -> Void] = [
            { try $0.replace(in: $0.dependentURL, "# Dependent Task", with: "# Wrong Dependent Title") },
            { try $0.replace(in: $0.dependentURL, "Title: Dependent Task", with: "Title: Wrong Dependent Title") },
            { try $0.replace(in: $0.dependentURL, "ID: TASK-0064", with: "ID: TASK-9999") },
            { try $0.replace(in: $0.dependentURL, "Type: Task", with: "Type: Project") },
            { try $0.replace(in: $0.dependentURL, "# Dependent Task", with: "#  Dependent Task ") },
            { try $0.replace(in: $0.dependentURL, "Title: Dependent Task", with: "Title:  Dependent Task ") },
            { try $0.replace(in: $0.dependentURL, "ID: TASK-0064", with: "ID:  TASK-0064 ") },
            { try $0.replace(in: $0.dependentURL, "Type: Task", with: "Type:  Task ") },
            {
                var data = try $0.read($0.dependentURL)
                data.append(0xff)
                try data.write(to: $0.dependentURL)
            },
        ]
        for mutate in mutations {
            let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
            let accepted = service(discover: { sourceID, marker, configuration in
                try mutate(fixture)
                return try AcceptedHandoffDiscovery.newlyEligible(
                    sourceID: sourceID, marker: marker, configuration: configuration
                )
            })
            var output: [String] = []
            let exit = HeadlessOfficeCommandLine.runIfRequested(
                arguments: fixture.arguments(), acceptedHandoffService: accepted,
                write: { output.append($0) }
            )
            XCTAssertEqual(exit, 3)
            let result = try JSONDecoder().decode(
                AcceptedHandoffCommandResult.self,
                from: Data(try XCTUnwrap(output.first).utf8)
            )
            XCTAssertEqual(result.outcome, "committed-with-discovery-failure")
            XCTAssertTrue(result.historicalCommitProven)
            XCTAssertEqual(result.discoveryOutcome, "failed")
            XCTAssertNil(result.newlyEligibleHooks)
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
            let source = String(decoding: try fixture.read(fixture.sourceURL), as: UTF8.self)
            XCTAssertTrue(source.contains("| picker-v1 | 2026-08-29T20:00:00Z |"))
        }
    }

    func testWriterAndDiscoveryShareExactMarkdownAnchorNormalization() throws {
        let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
        try fixture.replace(in: fixture.evidenceURL, "# Accepted Build", with: "# Accepted  Build")
        let result = try service(discover: AcceptedHandoffDiscovery.newlyEligible)
            .perform(request: fixture.request(), configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "committed")
        XCTAssertEqual(result.discoveryOutcome, "complete")
        XCTAssertEqual(result.newlyEligibleHooks, [
            .init(candidateID: "TASK-0064", hook: HandoffFixture.primaryHook),
        ])
    }

    func testFencedOnlyEvidenceAnchorRejectsBeforeJournalOrWrite() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        try fixture.replace(
            in: fixture.evidenceURL,
            "# Accepted Build",
            with: "```markdown\n# Accepted Build\n```"
        )
        let journal = HandoffMemoryJournal()
        let sourceBefore = try fixture.read(fixture.sourceURL)
        let failure = try captureFailure {
            try service(journal: journal).perform(
                request: fixture.request(), configuration: fixture.configuration
            )
        }
        XCTAssertEqual(failure.result.classification, "targetContractInvalid")
        XCTAssertNil(failure.result.inspectCommand)
        XCTAssertTrue(journal.values.isEmpty)
        XCTAssertEqual(try fixture.read(fixture.sourceURL), sourceBefore)
    }

    func testFencedOnlyEvidenceAfterCommitPreservesProofAndFailsDiscovery() throws {
        let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
        let result = try service(discover: { sourceID, marker, configuration in
            try fixture.replace(
                in: fixture.evidenceURL,
                "# Accepted Build",
                with: "~~~markdown\n# Accepted Build\n~~~"
            )
            return try AcceptedHandoffDiscovery.newlyEligible(
                sourceID: sourceID, marker: marker, configuration: configuration
            )
        }).perform(request: fixture.request(), configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "committed-with-discovery-failure")
        XCTAssertTrue(result.historicalCommitProven)
        XCTAssertEqual(result.discoveryOutcome, "failed")
        XCTAssertNil(result.newlyEligibleHooks)
        XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
        let source = String(decoding: try fixture.read(fixture.sourceURL), as: UTF8.self)
        XCTAssertTrue(source.contains("| picker-v1 | 2026-08-29T20:00:00Z |"))
    }

    func testReverseDiscoveryValidatesAcceptedHandoffSourceIdentityAndEvidenceAfterProvenCommit() throws {
        let mutations: [(HandoffFixture) throws -> Void] = [
            { try $0.replace(in: $0.sourceURL, "# Source Task", with: "# Wrong Source Title") },
            { try FileManager.default.removeItem(at: $0.evidenceURL) },
        ]
        for mutate in mutations {
            let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
            let result = try service(discover: { sourceID, marker, configuration in
                try mutate(fixture)
                return try AcceptedHandoffDiscovery.newlyEligible(
                    sourceID: sourceID, marker: marker, configuration: configuration
                )
            }).perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "committed-with-discovery-failure")
            XCTAssertTrue(result.historicalCommitProven)
            XCTAssertEqual(result.discoveryOutcome, "failed")
            XCTAssertNil(result.newlyEligibleHooks)
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
        }
    }

    func testCLIProductionAdapterCommitsAndRendersStableJSON() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let accepted = service()
        var output: [String] = []
        let exit = HeadlessOfficeCommandLine.runIfRequested(
            arguments: fixture.arguments(), acceptedHandoffService: accepted,
            write: { output.append($0) }
        )
        XCTAssertEqual(exit, 0)
        let result = try JSONDecoder().decode(AcceptedHandoffCommandResult.self, from: Data(try XCTUnwrap(output.first).utf8))
        XCTAssertEqual(result.outcome, "committed")
        XCTAssertEqual(result.operationUUID, operationID)
        XCTAssertEqual(result.sourceCommit, HandoffFixture.commit)
        XCTAssertEqual(result.dependentWorkspaceSHA256, fixture.request().expectedDependentWorkspaceSHA256)
        XCTAssertNotNil(result.inspectCommand)
    }

    func testProductionCommandPathAcceptsAdoptedIDEA0006TerminalPeriodDuringDiscovery() throws {
        let fixture = try HandoffFixture(reviewHook: true); defer { fixture.remove() }
        try fixture.installAdoptedV112ActivationPackage()
        let journal = HandoffMemoryJournal()
        let accepted = AcceptedHandoffService(
            journalStore: journal,
            contractValidator: AdoptedOfficeV112ContractValidator(),
            makeOperationID: { self.operationID },
            discover: AcceptedHandoffDiscovery.newlyEligible
        )
        var output: [String] = []

        let exit = HeadlessOfficeCommandLine.runIfRequested(
            arguments: fixture.arguments(), acceptedHandoffService: accepted,
            write: { output.append($0) }
        )

        XCTAssertEqual(exit, 0)
        let result = try JSONDecoder().decode(
            AcceptedHandoffCommandResult.self,
            from: Data(try XCTUnwrap(output.first).utf8)
        )
        XCTAssertEqual(result.outcome, "committed")
        XCTAssertEqual(result.classification, "committed-and-current")
        XCTAssertEqual(result.discoveryOutcome, "complete")
        XCTAssertEqual(result.newlyEligibleHooks, [
            .init(candidateID: "TASK-0064", hook: HandoffFixture.primaryHook),
        ])
        XCTAssertEqual(journal.values.count, 1)
    }

    func testActivationAndInputFailuresArePrejournal() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let journal = HandoffMemoryJournal()
        var issued = false
        let rejected = AcceptedHandoffService(
            journalStore: journal, contractValidator: RejectingHandoffValidator(),
            makeOperationID: { issued = true; return self.operationID }, discover: { _, _, _ in [] }
        )
        let activation = try captureFailure { try rejected.perform(request: fixture.request(), configuration: fixture.configuration) }
        XCTAssertEqual(activation.result.classification, "contractNotAdopted")
        XCTAssertNil(activation.result.operationUUID)
        XCTAssertFalse(issued)
        XCTAssertTrue(journal.values.isEmpty)

        let invalidRequests: [AcceptedHandoffRequest] = [
            fixture.request(marker: "Invalid"),
            fixture.request(acceptedAt: "2026-08-29"),
            fixture.request(sourceCommit: "abc"),
            fixture.request(evidence: "bad|cell"),
            fixture.request(sourceID: "TASK-0064", dependentID: "TASK-0064"),
        ]
        for request in invalidRequests {
            let local = HandoffMemoryJournal()
            let failure = try captureFailure { try service(journal: local).perform(request: request, configuration: fixture.configuration) }
            XCTAssertEqual(failure.result.classification, "invalidInput")
            XCTAssertTrue(local.values.isEmpty)
            XCTAssertNil(failure.result.inspectCommand)
        }
    }

    func testLockJournalAdmissionAndSpecialTargetFailuresAreDefinitePremutation() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let before = try fixture.snapshot()
        let deniedJournal = HandoffMemoryJournal()
        let denied = service(journal: deniedJournal, locking: DeniedHandoffLock())
        let lockFailure = try captureFailure {
            try denied.perform(request: fixture.request(), configuration: fixture.configuration)
        }
        XCTAssertEqual(lockFailure.result.classification, "lockUnavailable")
        XCTAssertEqual(lockFailure.exitCode, 2)
        XCTAssertNil(lockFailure.result.inspectCommand)
        XCTAssertTrue(deniedJournal.values.isEmpty)
        XCTAssertEqual(try fixture.snapshot(), before)

        let admissionJournal = HandoffMemoryJournal()
        admissionJournal.failPersist = true
        let admissionFailure = try captureFailure {
            try service(journal: admissionJournal).perform(request: fixture.request(), configuration: fixture.configuration)
        }
        XCTAssertEqual(admissionFailure.result.classification, "journalCreateFailed")
        XCTAssertEqual(admissionFailure.exitCode, 2)
        XCTAssertNil(admissionFailure.result.inspectCommand)
        XCTAssertTrue(admissionFailure.result.diagnostic?.contains("no durable operation journal was created") == true)
        XCTAssertEqual(try fixture.snapshot(), before)

        try FileManager.default.removeItem(at: fixture.sourceURL)
        try FileManager.default.createDirectory(at: fixture.sourceURL, withIntermediateDirectories: false)
        let specialJournal = HandoffMemoryJournal()
        let specialFailure = try captureFailure {
            try service(journal: specialJournal).perform(
                request: fixture.request(workspaceHash: String(repeating: "0", count: 64)),
                configuration: fixture.configuration
            )
        }
        XCTAssertEqual(specialFailure.result.classification, "targetContractInvalid")
        XCTAssertTrue(specialJournal.values.isEmpty)
        XCTAssertNil(specialFailure.result.inspectCommand)
    }

    func testHashRelationshipMarkerAndCommitEvidenceFailuresArePrejournal() throws {
        let cases: [(HandoffFixture) throws -> AcceptedHandoffRequest] = [
            { $0.request(workspaceHash: String(repeating: "0", count: 64)) },
            { $0.request(dependentHash: String(repeating: "0", count: 64)) },
            { $0.request(registryHash: String(repeating: "0", count: 64)) },
            { $0.request(sourceCommit: String(repeating: "a", count: 40)) },
        ]
        for make in cases {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let journal = HandoffMemoryJournal(), before = try fixture.snapshot()
            let failure = try captureFailure { try service(journal: journal).perform(request: make(fixture), configuration: fixture.configuration) }
            XCTAssertTrue(["hashMismatch", "targetContractInvalid"].contains(failure.result.classification ?? ""))
            XCTAssertTrue(journal.values.isEmpty)
            XCTAssertEqual(try fixture.snapshot(), before)
        }

        let broken = try HandoffFixture(); defer { broken.remove() }
        try broken.replace(in: broken.sourceURL, "Related records: TASK-0064", with: "Related records: —")
        let relationshipFailure = try captureFailure {
            try service().perform(request: broken.request(), configuration: broken.configuration)
        }
        XCTAssertEqual(relationshipFailure.result.classification, "targetContractInvalid")

        let duplicate = try HandoffFixture(existingMarker: true); defer { duplicate.remove() }
        try duplicate.replace(in: duplicate.sourceURL, "prior-v1", with: "picker-v1")
        let duplicateFailure = try captureFailure {
            try service().perform(request: duplicate.request(), configuration: duplicate.configuration)
        }
        XCTAssertEqual(duplicateFailure.result.classification, "targetContractInvalid")
    }

    func testWorkspaceIdentityAndReciprocalRelationshipVariantsRejectPrejournal() throws {
        let mutations: [(HandoffFixture) throws -> Void] = [
            { try $0.replace(in: $0.sourceURL, "# Source Task", with: "# Wrong Source") },
            { try $0.append("\n# Duplicate Source\n", to: $0.sourceURL) },
            { try $0.replace(in: $0.sourceURL, "Related records: TASK-0064", with: "Related records: TASK-0064; TASK-0064") },
            { try $0.replace(in: $0.dependentURL, "Depends on: TASK-0066", with: "Depends on: —") },
            { try $0.replace(in: $0.registryURL, "TASK-0066 accepted handoff", with: "TASK-0066; TASK-0066") },
        ]
        for mutate in mutations {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            try mutate(fixture)
            let journal = HandoffMemoryJournal()
            let failure = try captureFailure {
                try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid")
            XCTAssertTrue(journal.values.isEmpty)
            XCTAssertNil(failure.result.inspectCommand)
        }
    }

    func testEvidenceContainmentKindsSymlinkAnchorAndCircularFailuresArePrejournal() throws {
        let badReferences = [
            "/private/tmp/outside.md", "../outside.md", "Warehouse//Evidence/source.md",
            "Workspace/TASK-0066/TASK-0066.md", "`Warehouse/Evidence/source.md#missing-anchor`",
        ]
        for reference in badReferences {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let journal = HandoffMemoryJournal()
            let failure = try captureFailure {
                try service(journal: journal).perform(request: fixture.request(evidence: reference), configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.result.classification, "targetContractInvalid", reference)
            XCTAssertTrue(journal.values.isEmpty)
        }

        let directory = try HandoffFixture(); defer { directory.remove() }
        let directoryFailure = try captureFailure {
            try service().perform(request: directory.request(evidence: "Warehouse/Evidence"), configuration: directory.configuration)
        }
        XCTAssertEqual(directoryFailure.result.classification, "targetContractInvalid")

        let symlink = try HandoffFixture(); defer { symlink.remove() }
        try FileManager.default.removeItem(at: symlink.evidenceURL)
        try FileManager.default.createSymbolicLink(at: symlink.evidenceURL, withDestinationURL: symlink.priorEvidenceURL)
        let symlinkFailure = try captureFailure {
            try service().perform(request: symlink.request(), configuration: symlink.configuration)
        }
        XCTAssertEqual(symlinkFailure.result.classification, "targetContractInvalid")
    }

    func testPreparationRaceAfterJournalIsDefiniteNoCommit() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let journal = HandoffMemoryJournal()
        journal.onPersist = { try fixture.append("\nConcurrent bytes.\n", to: fixture.dependentURL) }
        let beforeSource = try fixture.read(fixture.sourceURL)
        let result = try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "not-committed")
        XCTAssertEqual(result.classification, "definite-no-commit")
        XCTAssertEqual(try fixture.read(fixture.sourceURL), beforeSource)
        XCTAssertTrue(result.journalFinalized)
        XCTAssertNotNil(result.inspectCommand)
    }

    func testReplacementExceptionPreimageAndPostimageReconcileExactly() throws {
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let result = try service(replacer: ThrowBeforeHandoffReplacer())
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "not-committed")
            XCTAssertEqual(result.classification, "definite-no-commit")
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
        }
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let result = try service(replacer: WriteThenThrowHandoffReplacer())
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "committed")
            XCTAssertTrue(result.historicalCommitProven)
            XCTAssertEqual(result.discoveryOutcome, "complete")
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
        }
    }

    func testPartialReplacementAndReloadFailurePreserveNoRetryProof() throws {
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let result = try service(replacer: PartialThenThrowHandoffReplacer())
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "uncertain")
            XCTAssertFalse(result.historicalCommitProven)
            XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
        }
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let result = try service(replacer: CorruptAfterWriteHandoffReplacer())
                .perform(request: fixture.request(), configuration: fixture.configuration)
            XCTAssertEqual(result.outcome, "uncertain")
            XCTAssertTrue(result.historicalCommitProven)
            XCTAssertEqual(result.classification, "historically-committed-current-state-uncertain")
        }
    }

    func testJournalReadFailureAfterReplacementFreezesOutcomeAndNeverRetries() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let journal = HandoffMemoryJournal()
        journal.failRead = true
        let failure = try captureFailure {
            try service(journal: journal, replacer: WriteThenThrowHandoffReplacer())
                .perform(request: fixture.request(), configuration: fixture.configuration)
        }
        XCTAssertEqual(failure.exitCode, 3)
        XCTAssertEqual(failure.result.outcome, "uncertain")
        XCTAssertEqual(failure.result.classification, "possible-commit")
        XCTAssertFalse(failure.result.historicalCommitProven)
        XCTAssertNotNil(failure.result.inspectCommand)
        XCTAssertTrue(failure.result.diagnostic?.contains("Do not retry automatically.") == true)
    }

    func testTerminalFinalizationFallbackIsTypedAndSticky() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let journal = HandoffMemoryJournal()
        journal.failNextUpdate = true
        let failure = try captureFailure {
            try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration)
        }
        XCTAssertEqual(failure.exitCode, 3)
        XCTAssertTrue(failure.result.historicalCommitProven)
        XCTAssertFalse(failure.result.journalFinalized)
        XCTAssertTrue(failure.result.fallbackRecorded)
        XCTAssertEqual(journal.values.first?.terminalState, .journalFinalizationFailedCommittedAndCurrent)
    }

    func testTerminalFallbackFailureIsExplicitForProvenCommitAndDefiniteNoCommit() throws {
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let journal = HandoffMemoryJournal()
            journal.failNextUpdate = true
            journal.failFallback = true
            let failure: AcceptedHandoffCommandFailure
            do {
                let returned = try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration)
                XCTFail("Expected proven fallback failure, got \(returned.outcome)")
                return
            } catch let caught as AcceptedHandoffCommandFailure { failure = caught }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertTrue(failure.result.historicalCommitProven)
            XCTAssertFalse(failure.result.journalFinalized)
            XCTAssertFalse(failure.result.fallbackRecorded)
            XCTAssertTrue(failure.result.diagnostic?.contains("Do not retry automatically.") == true)
        }
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let journal = HandoffMemoryJournal()
            journal.failNextUpdate = true
            journal.failFallback = true
            let failure = try captureFailure {
                try service(journal: journal, replacer: WriteThenThrowHandoffReplacer())
                    .perform(request: fixture.request(), configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertEqual(failure.result.classification, "committed-and-current")
            XCTAssertTrue(failure.result.historicalCommitProven)
            XCTAssertFalse(failure.result.fallbackRecorded)
        }
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let journal = HandoffMemoryJournal()
            journal.onPersist = { try fixture.append("\nConcurrent bytes.\n", to: fixture.dependentURL) }
            journal.failNextUpdate = true
            journal.failFallback = true
            let failure: AcceptedHandoffCommandFailure
            do {
                let returned = try service(journal: journal).perform(request: fixture.request(), configuration: fixture.configuration)
                XCTFail("Expected definite-no-commit fallback failure, got \(returned.outcome)")
                return
            } catch let caught as AcceptedHandoffCommandFailure { failure = caught }
            XCTAssertEqual(failure.exitCode, 2)
            XCTAssertEqual(failure.result.classification, "definite-no-commit")
            XCTAssertFalse(failure.result.historicalCommitProven)
            XCTAssertFalse(failure.result.journalFinalized)
            XCTAssertFalse(failure.result.fallbackRecorded)
        }
    }

    func testDurableStoreFreshInspectionAndRootMismatchFreezeProof() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let recovery = fixture.root.appending(path: "Recovery", directoryHint: .isDirectory)
        let store = ApplicationSupportAcceptedHandoffJournalStore(directory: recovery)
        let writer = service(journal: store)
        let committed = try writer.perform(request: fixture.request(), configuration: fixture.configuration)
        let operation = try XCTUnwrap(committed.operationUUID)
        let journalURL = recovery.appending(path: "\(operation.uuidString).json")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: journalURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let fresh = service(journal: ApplicationSupportAcceptedHandoffJournalStore(directory: recovery))
        XCTAssertEqual(try fresh.inspect(operationID: operation, configuration: fixture.configuration).classification, "committed-and-current")
        let alternate = try HandoffFixture(); defer { alternate.remove() }
        let frozen = try fresh.inspect(operationID: operation, configuration: alternate.configuration)
        XCTAssertEqual(frozen.classification, "historically-committed-current-state-uncertain")
        XCTAssertTrue(frozen.historicalCommitProven)
        XCTAssertEqual(try Data(contentsOf: journalURL), try Data(contentsOf: journalURL))
    }

    func testOfficeInspectorDispatchesAcceptedHandoffJournal() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let recovery = fixture.root.appending(path: "Recovery", directoryHint: .isDirectory)
        let accepted = service(journal: ApplicationSupportAcceptedHandoffJournalStore(directory: recovery))
        let committed = try accepted.perform(request: fixture.request(), configuration: fixture.configuration)
        let inspector = ApplicationSupportOfficeWorkspaceInspector(
            directory: recovery, checkpointService: TaskCheckpointService(), acceptedHandoffService: accepted
        )
        let payload = try inspector.inspect(operationID: try XCTUnwrap(committed.operationUUID), configuration: fixture.configuration)
        guard case let .acceptedHandoff(result) = payload else { return XCTFail("Wrong journal dispatch") }
        XCTAssertEqual(result.classification, "committed-and-current")

        var output: [String] = []
        let code = HeadlessOfficeCommandLine.runIfRequested(
            arguments: [
                "OperationsDashboard", "office", "inspect", "--productions-root", fixture.root.path,
                "--operation", try XCTUnwrap(committed.operationUUID).uuidString,
            ],
            acceptedHandoffService: accepted, inspector: inspector, write: { output.append($0) }
        )
        XCTAssertEqual(code, 0)
        let decoded = try JSONDecoder().decode(
            AcceptedHandoffCommandResult.self, from: Data(try XCTUnwrap(output.first).utf8)
        )
        XCTAssertEqual(decoded.classification, "committed-and-current")
    }

    func testInspectionPostimageProofFinalizesOrUsesTypedCommittedFallback() throws {
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let journal = HandoffMemoryJournal()
            _ = try service(journal: journal, replacer: PartialThenThrowHandoffReplacer())
                .perform(request: fixture.request(), configuration: fixture.configuration)
            let expected = try XCTUnwrap(journal.values.first?.workspaceExpectedAfter)
            try expected.write(to: fixture.sourceURL)
            let inspected = try service(journal: journal).inspect(operationID: operationID, configuration: fixture.configuration)
            XCTAssertEqual(inspected.outcome, "committed")
            XCTAssertEqual(inspected.classification, "committed-and-current")
            XCTAssertTrue(inspected.historicalCommitProven)
            XCTAssertTrue(inspected.journalFinalized)
            XCTAssertEqual(journal.values.first?.terminalState, .reconciledCommittedAndCurrent)
        }
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let journal = HandoffMemoryJournal()
            _ = try service(journal: journal, replacer: PartialThenThrowHandoffReplacer())
                .perform(request: fixture.request(), configuration: fixture.configuration)
            try XCTUnwrap(journal.values.first?.workspaceExpectedAfter).write(to: fixture.sourceURL)
            journal.failNextUpdate = true
            let failure = try captureFailure {
                try service(journal: journal).inspect(operationID: operationID, configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertEqual(failure.result.classification, "committed-and-current")
            XCTAssertTrue(failure.result.historicalCommitProven)
            XCTAssertFalse(failure.result.journalFinalized)
            XCTAssertTrue(failure.result.fallbackRecorded)
            XCTAssertTrue(failure.result.diagnostic?.contains("Do not retry automatically.") == true)
            XCTAssertEqual(journal.values.first?.terminalState, .journalFinalizationFailedCommittedAndCurrent)
        }
        do {
            let fixture = try HandoffFixture(); defer { fixture.remove() }
            let journal = HandoffMemoryJournal()
            _ = try service(journal: journal, replacer: PartialThenThrowHandoffReplacer())
                .perform(request: fixture.request(), configuration: fixture.configuration)
            try XCTUnwrap(journal.values.first?.workspaceExpectedAfter).write(to: fixture.sourceURL)
            journal.failNextUpdate = true
            journal.failFallback = true
            let failure = try captureFailure {
                try service(journal: journal).inspect(operationID: operationID, configuration: fixture.configuration)
            }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertTrue(failure.result.historicalCommitProven)
            XCTAssertFalse(failure.result.journalFinalized)
            XCTAssertFalse(failure.result.fallbackRecorded)
            XCTAssertTrue(failure.result.diagnostic?.contains("Do not retry automatically.") == true)
        }
    }

    func testInspectionAcceptsLaterDoneCompleteSourceAsSupersedingHistory() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let journal = HandoffMemoryJournal()
        let accepted = service(journal: journal)
        _ = try accepted.perform(request: fixture.request(), configuration: fixture.configuration)
        try fixture.replace(in: fixture.registryURL, "Active / Current", with: "Done / Complete")
        let inspected = try accepted.inspect(operationID: operationID, configuration: fixture.configuration)
        XCTAssertEqual(inspected.outcome, "committed")
        XCTAssertEqual(inspected.classification, "historically-committed-and-superseded")
        XCTAssertTrue(inspected.historicalCommitProven)
    }

    func testDurableEnvelopeSubstitutionAndStartupFilteringNeverRewriteJournal() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let recovery = fixture.root.appending(path: "RecoveryEnvelope", directoryHint: .isDirectory)
        let store = ApplicationSupportAcceptedHandoffJournalStore(directory: recovery)
        _ = try service(journal: store).perform(request: fixture.request(), configuration: fixture.configuration)
        let durable = try XCTUnwrap(try store.journal(operationID: operationID))
        let journalURL = recovery.appending(path: "\(operationID.uuidString).json")
        let frozen = try Data(contentsOf: journalURL)

        let substituted = try mutatedHandoffJournal(durable) {
            $0["evidence"] = "`Warehouse/Evidence/substituted.md`"
        }
        XCTAssertThrowsError(try store.update(substituted))
        let substitutedFallback = try mutatedHandoffJournal(durable) {
            $0["evidence"] = "`Warehouse/Evidence/substituted.md`"
            $0["terminalState"] = OfficeWorkspaceTerminalState.journalFinalizationFailedCommittedAndCurrent.rawValue
            $0["journalFinalized"] = false
            $0["fallbackRecorded"] = true
        }
        XCTAssertThrowsError(try store.recordFallback(substitutedFallback))
        XCTAssertEqual(try Data(contentsOf: journalURL), frozen)
        XCTAssertTrue(service(journal: store).startupRecovery().isEmpty)

        let uncertain = try mutatedHandoffJournal(durable) {
            $0["terminalState"] = OfficeWorkspaceTerminalState.historicallyCommittedWithCurrentStateUncertain.rawValue
            $0["journalFinalized"] = true
            $0["fallbackRecorded"] = false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(uncertain).write(to: journalURL)
        let fresh = service(journal: ApplicationSupportAcceptedHandoffJournalStore(directory: recovery))
        XCTAssertEqual(fresh.startupRecovery().map(\.operationUUID), [operationID])
    }

    func testDiscoveryFailurePreservesProvenCommitAsFourthOutcome() throws {
        let fixture = try HandoffFixture(); defer { fixture.remove() }
        let result = try service(discover: { _, _, _ in throw HandoffTestError.synthetic })
            .perform(request: fixture.request(), configuration: fixture.configuration)
        XCTAssertEqual(result.outcome, "committed-with-discovery-failure")
        XCTAssertTrue(result.historicalCommitProven)
        XCTAssertTrue(result.journalFinalized)
        XCTAssertNil(result.newlyEligibleHooks)
        XCTAssertEqual(result.discoveryOutcome, "failed")
        XCTAssertTrue(result.diagnostic?.contains("Do not retry automatically.") == true)
    }

    private func service(
        journal: any AcceptedHandoffJournalStore = HandoffMemoryJournal(),
        replacer: any AtomicFileReplacing = DurableReplacement(),
        locking: any TaskCheckpointLocking = LocalTaskCheckpointLocking(),
        discover: @escaping (String, String, ProductionsConfiguration) throws -> [AcceptedHandoffEligibleHook] = { _, _, _ in [] }
    ) -> AcceptedHandoffService {
        AcceptedHandoffService(
            journalStore: journal, replacer: replacer, locking: locking,
            contractValidator: AcceptingHandoffValidator(),
            makeOperationID: { self.operationID }, discover: discover
        )
    }

    private func captureFailure(_ operation: () throws -> AcceptedHandoffCommandResult) throws -> AcceptedHandoffCommandFailure {
        do { _ = try operation(); XCTFail("Expected failure"); throw HandoffTestError.synthetic }
        catch let failure as AcceptedHandoffCommandFailure { return failure }
    }
}

private struct AcceptingHandoffValidator: OfficeV112ContractValidating {
    func validate(configuration: ProductionsConfiguration) throws {}
}

private struct RejectingHandoffValidator: OfficeV112ContractValidating {
    func validate(configuration: ProductionsConfiguration) throws {
        throw OfficeContractValidationError.contractNotAdopted("Synthetic rejection.")
    }
}

private enum HandoffTestError: Error { case synthetic }

private final class HandoffMemoryJournal: AcceptedHandoffJournalStore {
    var values: [AcceptedHandoffJournal] = []
    var failPersist = false
    var failNextUpdate = false
    var failFallback = false
    var failRead = false
    var onPersist: (() throws -> Void)?

    func persist(_ journal: AcceptedHandoffJournal) throws {
        if failPersist { throw HandoffTestError.synthetic }
        values.append(journal)
        try onPersist?()
    }

    func update(_ journal: AcceptedHandoffJournal) throws {
        if failNextUpdate { failNextUpdate = false; throw HandoffTestError.synthetic }
        guard let index = values.firstIndex(where: { $0.operationUUID == journal.operationUUID }) else { throw HandoffTestError.synthetic }
        values[index] = journal
    }

    func recordFallback(_ journal: AcceptedHandoffJournal) throws {
        if failFallback { throw HandoffTestError.synthetic }
        guard let index = values.firstIndex(where: { $0.operationUUID == journal.operationUUID }) else { throw HandoffTestError.synthetic }
        values[index] = journal
    }

    func journal(operationID: UUID) throws -> AcceptedHandoffJournal? {
        if failRead { throw HandoffTestError.synthetic }
        return values.first(where: { $0.operationUUID == operationID })
    }

    func incomplete() throws -> [AcceptedHandoffJournal] {
        values.filter { $0.terminalState == nil || $0.terminalState?.isStartupIncomplete == true }
    }
}

private struct DeniedHandoffLock: TaskCheckpointLocking {
    func acquire(registryURL: URL) -> AnyObject? { nil }
}

private struct ThrowBeforeHandoffReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { throw HandoffTestError.synthetic }
}

private struct WriteThenThrowHandoffReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { try data.write(to: target); throw HandoffTestError.synthetic }
}

private struct PartialThenThrowHandoffReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { try Data(data.prefix(data.count / 2)).write(to: target); throw HandoffTestError.synthetic }
}

private struct CorruptAfterWriteHandoffReplacer: AtomicFileReplacing {
    func replace(data: Data, at target: URL) throws { try (data + Data("foreign".utf8)).write(to: target) }
}

private final class HandoffFixture {
    static let commit = "1234567890abcdef1234567890abcdef12345678"
    static let primaryHook = "TASK-0066@accepted-handoff:picker-v1"
    let root: URL
    private let manager = FileManager.default
    let reviewHook: Bool

    init(existingMarker: Bool = false, laterSection: Bool = false, reviewHook: Bool = false) throws {
        self.reviewHook = reviewHook
        root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appending(path: "AcceptedHandoffTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try write(registry, to: registryURL)
        try write(source(existingMarker: existingMarker, laterSection: laterSection), to: sourceURL)
        try write(dependent, to: dependentURL)
        try write("# Accepted Build\n\nCommit: \(Self.commit)\n", to: evidenceURL)
        try write("# Prior\n\nCommit: prior\n", to: priorEvidenceURL)
        try write(emptyRegistry(id: "Idea", headers: ["Idea ID", "Title", "Disposition", "Priority", "Current lead", "Related records", "Review after", "Source artifacts", "Short description", "Workspace"]), to: root.appending(path: "Office/Registry/Ideas.md"))
        try write(emptyRegistry(id: "Project", headers: ["Project ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"]), to: root.appending(path: "Office/Registry/Projects.md"))
        try write(emptyRegistry(id: "Initiative", headers: ["Initiative ID", "Title", "State", "Priority", "Current lead", "Related records", "Depends on", "Review after", "Short description", "Workspace"]), to: root.appending(path: "Office/Registry/Initiatives.md"))
    }

    var configuration: ProductionsConfiguration { .init(schemaVersion: 2, productionsRootPath: root.path) }
    var registryURL: URL { root.appending(path: "Office/Registry/Tasks.md") }
    var sourceURL: URL { root.appending(path: "Workspace/TASK-0066/TASK-0066.md") }
    var dependentURL: URL { root.appending(path: "Workspace/TASK-0064/TASK-0064.md") }
    var evidenceURL: URL { root.appending(path: "Warehouse/Evidence/source.md") }
    var priorEvidenceURL: URL { root.appending(path: "Warehouse/Evidence/prior.md") }

    func request(
        sourceID: String = "TASK-0066", dependentID: String = "TASK-0064",
        sourceCommit: String = commit, marker: String = "picker-v1",
        acceptedAt: String = "2026-08-29T20:00:00Z",
        evidence: String = "`Warehouse/Evidence/source.md#accepted-build`",
        workspaceHash: String? = nil, dependentHash: String? = nil, registryHash: String? = nil
    ) -> AcceptedHandoffRequest {
        .init(
            sourceID: sourceID, dependentID: dependentID, sourceCommit: sourceCommit,
            marker: marker, acceptedAt: acceptedAt, evidence: evidence,
            expectedWorkspaceSHA256: workspaceHash ?? digest(try! read(sourceURL)),
            expectedDependentWorkspaceSHA256: dependentHash ?? digest(try! read(dependentURL)),
            expectedRegistrySHA256: registryHash ?? digest(try! read(registryURL))
        )
    }

    func arguments() -> [String] {
        let value = request()
        return [
            "OperationsDashboard", "review", "accept-handoff",
            "--productions-root", root.path, "--source", value.sourceID,
            "--dependent", value.dependentID, "--source-commit", value.sourceCommit,
            "--marker", value.marker, "--accepted-at", value.acceptedAt,
            "--evidence", value.evidence,
            "--expected-workspace-sha256", value.expectedWorkspaceSHA256,
            "--expected-dependent-workspace-sha256", value.expectedDependentWorkspaceSHA256,
            "--expected-registry-sha256", value.expectedRegistrySHA256,
        ]
    }

    func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    func remove() { try? manager.removeItem(at: root) }
    func append(_ value: String, to url: URL) throws { var data = try read(url); data.append(Data(value.utf8)); try data.write(to: url) }
    func replace(in url: URL, _ old: String, with new: String) throws {
        let text = String(decoding: try read(url), as: UTF8.self).replacingOccurrences(of: old, with: new)
        try write(text, to: url)
    }
    func setDependentReviewRow(_ row: String) throws {
        try replace(
            in: dependentURL,
            Self.reviewRow(disposition: "Pending"),
            with: row
        )
    }
    func installReplacementIdea(
        row: String = HandoffFixture.reviewRow(
            hook: "TASK-0066@accepted-handoff:other-marker", disposition: "Pending"
        )
    ) throws {
        let headers = [
            "Idea ID", "Title", "Disposition", "Priority", "Current lead", "Related records",
            "Review after", "Source artifacts", "Short description", "Workspace",
        ]
        let registry = """
        # Ideas

        | \(headers.joined(separator: " | ")) |
        | \(Array(repeating: "---", count: headers.count).joined(separator: " | ")) |
        | IDEA-0001 | Replacement Idea | Open | Medium | Laboratory | TASK-0064 | TASK-0066@accepted-handoff:other-marker | — | Synthetic replacement. | [IDEA-0001](../../Workspace/IDEA-0001/IDEA-0001.md) |
        """ + "\n"
        try write(registry, to: root.appending(path: "Office/Registry/Ideas.md"))
        let workspace = """
        # Replacement Idea

        ## Idea Record

        ```text
        Idea ID: IDEA-0001
        Disposition: Open
        Priority: Medium
        Current lead: Laboratory
        Workspace: `Workspace/IDEA-0001/`.
        Source artifacts: —
        Related records: TASK-0064
        ```

        ## Eligibility Reviews

        | Hook | Review question | Disposition | Decided at | Reconsider after | Replacement |
        | --- | --- | --- | --- | --- | --- |
        \(row)
        """ + "\n"
        try write(workspace, to: root.appending(path: "Workspace/IDEA-0001/IDEA-0001.md"))
    }

    func installAdoptedV112ActivationPackage() throws {
        let liveRoot = URL(fileURLWithPath: "/Users/kahntra/Productions", isDirectory: true)
        for path in Array(AdoptedOfficeV112ContractValidator.immutableSHA256.keys) + [
            "Warehouse/Reference/Document Registry.md",
            "Workspace/IDEA-0006/IDEA-0006.md",
            "Workspace/TASK-0017/TASK-0017.md",
        ] {
            try write(try Data(contentsOf: liveRoot.appending(path: path)), to: root.appending(path: path))
        }
        try append(
            "| TASK-0017 | Decide Repository and Reference-Storage Structure | Active / Paused | Medium | Office | INIT-0001 | PROJ-0002 | Approved Git-safe migration sequence; sensitive-material handling decision | — | — | [TASK-0017](../../Workspace/TASK-0017/TASK-0017.md) |\n",
            to: registryURL
        )
        let headers = [
            "Idea ID", "Title", "Disposition", "Priority", "Current lead", "Related records",
            "Review after", "Source artifacts", "Short description", "Workspace",
        ]
        let ideas = """
        # Ideas

        | \(headers.joined(separator: " | ")) |
        | \(Array(repeating: "---", count: headers.count).joined(separator: " | ")) |
        | IDEA-0006 | Explore Product Provisioning and Repair Tool | Open | Low | Office | TASK-0017; TASK-0015 | TASK-0017@done-complete | Product Provisioning specification | — | [IDEA-0006](../../Workspace/IDEA-0006/IDEA-0006.md) |
        """ + "\n"
        try write(ideas, to: root.appending(path: "Office/Registry/Ideas.md"))
    }

    static func reviewRow(
        hook: String = primaryHook,
        disposition: String,
        question: String = "Review the accepted source handoff.",
        decidedAt: String = "—",
        reconsiderAfter: String = "—",
        replacement: String = "—"
    ) -> String {
        "| \(hook) | \(question) | \(disposition) | \(decidedAt) | \(reconsiderAfter) | \(replacement) |"
    }
    func snapshot() throws -> [String: Data] {
        Dictionary(uniqueKeysWithValues: try manager.subpathsOfDirectory(atPath: root.path).sorted().compactMap { relative in
            let url = root.appending(path: relative)
            var directory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &directory), !directory.boolValue else { return nil }
            return (relative, try Data(contentsOf: url))
        })
    }
    func unrelatedManifest() -> [String: String] {
        let excluded = "Workspace/TASK-0066/TASK-0066.md"
        return (try? snapshot().filter { $0.key != excluded }.mapValues(digest)) ?? [:]
    }

    private var registry: String {
        let hook = reviewHook ? Self.primaryHook : "—"
        return """
        # Tasks — Canonical Registry

        | Task ID | Title | State | Priority | Current lead | Initiative | Project | Depends on | Review after | Short description | Workspace |
        | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        | TASK-0064 | Dependent Task | Pending / Deferred | High | Laboratory | — | — | TASK-0066 accepted handoff | \(hook) | Wait for handoff. | [TASK-0064](../../Workspace/TASK-0064/TASK-0064.md) |
        | TASK-0066 | Source Task | Active / Current | High | Laboratory | — | — | — | — | Produce handoff. | [TASK-0066](../../Workspace/TASK-0066/TASK-0066.md) |
        """ + "\n"
    }

    private func source(existingMarker: Bool, laterSection: Bool) -> String {
        var value = workspace(title: "Source Task", id: "TASK-0066", depends: "—", related: "TASK-0064")
        if existingMarker {
            value += """

            ## Accepted Handoffs

            | Marker | Accepted at | Evidence |
            | --- | --- | --- |
            | prior-v1 | 2026-08-28T20:00:00Z | `Warehouse/Evidence/prior.md` |
            """ + "\n"
        }
        if laterSection { value += "\n## Later Unknown Section\n\nPreserve this suffix exactly.\n" }
        return value
    }

    private var dependent: String {
        var value = workspace(title: "Dependent Task", id: "TASK-0064", depends: "TASK-0066", related: "TASK-0066")
        if reviewHook {
            value += """

            ## Eligibility Reviews

            | Hook | Review question | Disposition | Decided at | Reconsider after | Replacement |
            | --- | --- | --- | --- | --- | --- |
            \(Self.reviewRow(disposition: "Pending"))
            """ + "\n"
        }
        return value
    }

    private func workspace(title: String, id: String, depends: String, related: String) -> String {
        """
        # \(title)

        ## Core Record

        ```text
        Title: \(title)
        ID: \(id)
        Type: Task
        Current lead: Laboratory
        Associated product(s): PROD-0003
        Primary department: Laboratory
        Status source: Office/Registry/Tasks.md
        Project: —
        Initiative: —

        Objective or question: Synthetic accepted handoff.
        Next step: Preserve.
        Completion or resolution criterion: Exact marker.
        Last validated state: Synthetic fixture.
        Relevant locations: Fixture.
        Depends on: \(depends)
        Related records: \(related)
        ```

        ## Steps

        - [ ] **S03 — Synthetic work.**
        """ + "\n"
    }

    private func emptyRegistry(id: String, headers: [String]) -> String {
        "# \(id)s\n\n| " + headers.joined(separator: " | ") + " |\n| " + Array(repeating: "---", count: headers.count).joined(separator: " | ") + " |\n"
    }

    private func write(_ value: String, to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(value.utf8).write(to: url)
    }

    private func write(_ value: Data, to url: URL) throws {
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url)
    }
}

private func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func mutatedHandoffJournal(
    _ journal: AcceptedHandoffJournal,
    mutate: (inout [String: Any]) -> Void
) throws -> AcceptedHandoffJournal {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(journal)) as? [String: Any])
    mutate(&object)
    return try JSONDecoder().decode(
        AcceptedHandoffJournal.self,
        from: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    )
}
