import XCTest
@testable import LokalBot

final class MeetingNotesGeneratorTests: XCTestCase {
    private actor Script {
        enum Reply {
            case text(String)
            case truncated(String)
            case error(TextEngineError)
            case wait
        }
        struct Call {
            var prompt: String
            var options: TextGenerationOptions
        }
        var replies: [Reply]
        var calls: [Call] = []
        var cancelled = false
        var tokenizations = 0

        init(_ replies: [Reply]) { self.replies = replies }
        func next(prompt: String, options: TextGenerationOptions) async throws -> String {
            calls.append(Call(prompt: prompt, options: options))
            guard !replies.isEmpty else { throw TextEngineError.badResponse("script exhausted") }
            switch replies.removeFirst() {
            case .text(let text): return text
            case .truncated(let text): throw TruncatedStructuredResponse(content: text)
            case .error(let error): throw error
            case .wait:
                do { try await Task.sleep(for: .seconds(30)); return "" } catch { cancelled = true; throw error }
            }
        }
        func count(_ text: String) -> Int { tokenizations += 1; return max(1, text.utf8.count / 4) }
        func recorded() -> [Call] { calls }
    }

    private struct Engine: TextEngine {
        var script: Script
        var displayName: String { "Notes fixture" }
        func tokenCount(_ text: String) async throws -> Int? { await script.count(text) }
        func generate(system: String, prompt: String, context: [String]) async throws -> String {
            try await script.next(prompt: prompt, options: .init())
        }
        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any], options: TextGenerationOptions) async throws -> String {
            try await script.next(prompt: prompt, options: options)
        }
    }

    private var transcript: Transcript {
        Transcript(segments: [
            .init(start: 0, end: 5, speaker: "me", text: "I will ship the update on Friday."),
            .init(start: 5, end: 10, speaker: "them", text: "I will review the documentation. We agreed to keep the release date."),
            .init(start: 10, end: 15, speaker: "them", text: "What happens if the dependency is delayed?"),
        ], engine: "fixture")
    }

    private func note(_ source: String = "s1", _ text: String = "Will ship the update on Friday.",
                      section: String = "Key points") -> [String: Any] {
        ["section": section, "text": text, "source": source]
    }
    private func action(_ source: String = "s1", owner: String = "p1") -> [String: Any] {
        ["text": "Ship the update", "source": source, "context": [], "owner": owner, "basis": "commitment",
         "due": "Friday", "importance": 5]
    }
    private func response(notes: [[String: Any]] = [], actions: [[String: Any]] = [], more: Bool = false) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["notes": notes, "actions": actions, "has_more": more]), as: UTF8.self)
    }
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
    private func generate(_ script: Script, transcript: Transcript? = nil, folder: URL? = nil,
                          contextTokens: Int = 32_768,
                          budget: MeetingGenerationBudget = MeetingGenerationBudget()) async throws -> MeetingNotesGenerator.Result {
        try await MeetingNotesGenerator.generate(transcript: transcript ?? self.transcript, engine: Engine(script: script),
            template: .meeting, language: .matchTranscript, context: [], contextTokens: contextTokens,
            meetingID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, folder: try folder ?? self.folder(), budget: budget)
    }

    func testOnePassProducesSummaryActionsDecisionsAndQuestions() async throws {
        let script = Script([.text(try response(notes: [
            note(), note("s2", "Keep the release date.", section: "Decisions"),
            note("s3", "What happens if the dependency is delayed?", section: "Open questions"),
        ], actions: [action()]))])
        let result = try await generate(script)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 1, "there must be no second transcript scan or narrative synthesis")
        XCTAssertEqual(calls[0].options.reasoningBudgetTokens, 0)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
        XCTAssertEqual(result.outcomes.decisionRecords.count, 1)
        XCTAssertEqual(result.outcomes.openQuestions.count, 1)
        XCTAssertTrue(result.body.contains("**You:**"))
        XCTAssertEqual(result.claims[0].segmentID, transcript.segmentID(at: 0))
        XCTAssertEqual(result.claims[0].speakerID, "me")
        XCTAssertEqual(result.claims[0].quote, transcript.segments[0].displayText)
        XCTAssertEqual(result.outcomes.actionItems[0].citations[0].segmentID, transcript.segmentID(at: 0))
        let observed1 = await script.tokenizations
        XCTAssertGreaterThan(observed1, 0)
    }

    func testRepairKeepsValidRecordsAndOnlySendsRejectedSources() async throws {
        var transcript = transcript
        transcript.segments += (3..<12).map { index in
            .init(start: Double(index * 5), end: Double(index * 5 + 5), speaker: "them",
                  text: "Documentation update \(index).")
        }
        let script = Script([
            .text(try response(notes: [note(), note("s6", "Review docs", section: "Wrong section")], actions: [action()])),
            .text(try response(notes: [note("s6", "Documentation update.")])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].prompt.contains("s6|"))
        XCTAssertFalse(calls[1].prompt.contains("s1|"))
        XCTAssertFalse(calls[1].prompt.contains("s9|"))
        XCTAssertFalse(calls[1].prompt.contains("Wrong section"))
        XCTAssertLessThan(calls[1].options.maxTokens ?? 0, calls[0].options.maxTokens ?? 0)
        XCTAssertEqual(result.claims.count, 2)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
    }

    func testRepairFailureSavesEarlierValidRecordsWithoutReplacingFinalArtifacts() async throws {
        let output = try folder()
        try Data("Previous complete summary".utf8).write(to: output.appendingPathComponent("summary.md"))
        let script = Script([
            .text(try response(notes: [note(), note("s2", "Review docs", section: "Wrong")])),
            .error(.badResponse("repair failed")),
        ])
        do { _ = try await generate(script, folder: output); XCTFail("expected failure") } catch {}
        let artifact = try JSONDecoder().decode(SummaryClaimEvidence.Artifact.self,
            from: Data(contentsOf: output.appendingPathComponent("summary.claims.partial.json")))
        XCTAssertEqual(artifact.claims.count, 1)
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("summary.md"), encoding: .utf8), "Previous complete summary")
        XCTAssertTrue(try String(contentsOf: output.appendingPathComponent("summary.partial.md"), encoding: .utf8).contains("Partial notes"))
        let observed2 = await script.recorded().count
        XCTAssertEqual(observed2, 2)
    }

    func testTruncationSalvagesOnlyCompleteRecordsAndCannotReportSuccess() async throws {
        let complete = String(decoding: try JSONSerialization.data(withJSONObject: note()), as: UTF8.self)
        let script = Script([.truncated("{\"notes\":[" + complete + ",{\"text\":\"unfinished")])
        let output = try folder()
        do { _ = try await generate(script, folder: output); XCTFail("truncated scan must remain partial") } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
        let artifact = try JSONDecoder().decode(SummaryClaimEvidence.Artifact.self,
            from: Data(contentsOf: output.appendingPathComponent("summary.claims.partial.json")))
        XCTAssertEqual(artifact.claims.count, 1)
        let observed3 = await script.recorded().count
        XCTAssertEqual(observed3, 1, "never restart the full part after truncation")
    }

    func testRepeatedInvalidRecordIsOmittedAfterOneRepairAndValidRecordsSurvive() async throws {
        let invalid = try response(notes: [note(), note("s2", "Bad section", section: "invalid")], actions: [action()])
        let script = Script([.text(invalid), .text(try response(notes: [note("s2", "Still invalid", section: "invalid")]))])
        let result = try await generate(script)
        XCTAssertEqual(result.claims.count, 1)
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
        let observed4 = await script.recorded().count
        XCTAssertEqual(observed4, 2)
    }

    func testMissingUserCommitmentGetsOneRepairWithoutRescanningTheMeeting() async throws {
        var transcript = longTranscript()
        transcript.segments[20] = .init(start: 100, end: 105, speaker: "me", text: "I will send the draft.")
        let script = Script([
            .text(try response(notes: [note("s1", "The dependency needs review.")])),
            .text(try response(actions: [action("s21", owner: "source")])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[1].prompt.contains("missing_user_commitment"))
        XCTAssertTrue(calls[1].prompt.contains("s21|"))
        XCTAssertFalse(calls[1].prompt.contains("s1|"))
        XCTAssertFalse(calls[1].prompt.contains("s60|"))
        XCTAssertEqual(result.outcomes.userActionItems.count, 1)
    }

    func testEmptySubstantialPartCannotReportComplete() async throws {
        let script = Script([.text(try response())])
        do {
            _ = try await generate(script, transcript: longTranscript())
            XCTFail("empty output cannot certify substantial evidence")
        } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 1)
    }

    func testUnknownSourceCannotBeRepairedUsingUnrelatedEvidence() async throws {
        let script = Script([.text(try response(notes: [note("s999", "unsupported")], actions: [action()]))])
        do { _ = try await generate(script); XCTFail("expected partial") } catch {}
        let observed5 = await script.recorded().count
        XCTAssertEqual(observed5, 1)
    }

    func testExplicitOverflowIsPartialEvenWithWellFormedJSON() async throws {
        let script = Script([.text(try response(notes: [note()], actions: [action()], more: true))])
        do { _ = try await generate(script); XCTFail("overflow cannot silently drop coverage") } catch is MeetingNotesGenerator.Incomplete {} catch { XCTFail("unexpected error \(error)") }
    }

    func testWrongOwnerAndNegatedCommitmentRemainUnassigned() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let wrongOwner = evidence.validate(try response(actions: [action(owner: "p2")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertFalse(wrongOwner.outcomes.actionItems[0].isForUser)
        XCTAssertTrue(wrongOwner.outcomes.actionItems[0].ownershipIsUnclear)
        var negatedTranscript = transcript
        negatedTranscript.segments[0].text = "If approved, I will ship the update on Friday."
        let negated = MeetingNotesEvidence(transcript: negatedTranscript)
        let result = negated.validate(try response(actions: [action()]), units: negated.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "unsupported_commitment")
    }

    func testSpeakerCorrectionOverridesMicrophoneDefaultInUnifiedExtraction() throws {
        var transcript = transcript
        transcript.confirmSpeaker("me", isUser: false)
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(notes: [note()], actions: [action()]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertFalse(result.outcomes.actionItems[0].isForUser)
        XCTAssertEqual(result.outcomes.actionItems[0].attribution?.resolution, .other)
    }

    func testSourceMembershipAndVisibleQuoteAreCheckedWithinPart() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var unit = evidence.units[0]
        unit.text = "the update on Friday."
        let result = evidence.validate(try response(notes: [note("s2", "outside part")], actions: [action()]),
            units: [unit], template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertEqual(result.rejected.count, 2)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
    }

    func testSchemaBoundsArraysTextSectionsSourcesAndOwners() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let schema = MeetingNotesEvidence.schema(units: [evidence.units[0]], speakers: ["p1"],
                                                template: .meeting, maximumNotes: 8, maximumActions: 5)
        XCTAssertNil(OpenAIStrictSchemaValidator.validationIssue(in: schema))
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let notes = try XCTUnwrap(properties["notes"] as? [String: Any])
        XCTAssertEqual(notes["maxItems"] as? Int, 8)
        let noteProperties = try XCTUnwrap((notes["items"] as? [String: Any])?["properties"] as? [String: Any])
        XCTAssertEqual((noteProperties["source"] as? [String: Any])?["enum"] as? [String], ["s1"])
        XCTAssertEqual((noteProperties["text"] as? [String: Any])?["maxLength"] as? Int, 280)
    }

    func testProseCannotOverrideDerivedSpeakerWithAModelID() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(notes: [note("s1", "p2 will ship the update.")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertEqual(result.rejected.count, 1)
    }

    func testOnlyAMatchingLeadingSpeakerIDCanBeRemovedFromProse() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        for prefix in ["p1", "Speaker p1", "User p1"] {
            let result = evidence.validate(try response(notes: [note("s1", "\(prefix) will ship the update.")]),
                units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
            XCTAssertEqual(result.claims.first?.text, "Will ship the update.")
            XCTAssertEqual(result.claims.first?.speakerID, "me")
            XCTAssertTrue(result.rejected.isEmpty)
        }
        let wrong = evidence.validate(try response(notes: [note("s1", "Speaker p2 will ship the update.")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(wrong.claims.isEmpty)
    }

    func testAnUnknownOwnerCanResolveOnlyFromAnExplicitQuotedCommitment() throws {
        var transcript = transcript
        transcript.segments[0].text = "After this, I'm going to create the remaining tickets."
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action(owner: "unknown")
        raw["basis"] = "unclear"
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems[0].isForUser)
        XCTAssertEqual(result.outcomes.actionItems[0].attribution?.basis, .commitment)
        XCTAssertEqual(result.outcomes.actionItems[0].attribution?.speakerID, "me")
    }

    func testSeparateTaskAndAcceptanceKeepBothCitationsAndTheAcceptingSpeaker() throws {
        let transcript = Transcript(segments: [
            .init(start: 0, end: 5, speaker: "them", text: "Could you send the draft?"),
            .init(start: 5, end: 10, speaker: "me", text: "Yes, I can do that."),
        ], engine: "fixture")
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action("s2", owner: "source")
        raw["context"] = ["s1"]
        raw["text"] = "Send the draft"
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems[0].isForUser)
        XCTAssertEqual(result.outcomes.actionItems[0].citations.count, 2)
        raw["context"] = [String]()
        let missing = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(missing.outcomes.actionItems.isEmpty)
        XCTAssertEqual(missing.rejected.first?.reason, "missing_task_context")
    }

    func testUnknownOwnershipStillRequiresAKnownPrimarySource() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(actions: [action("s999", owner: "unknown")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "unknown_source")
    }

    func testFreeformRetainsBoundedTopicHeadings() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(notes: [note(section: "Release preparation")]),
            units: evidence.units, template: .freeform, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertEqual(result.claims.first?.section, "Release preparation")
        XCTAssertTrue(result.rejected.isEmpty)
    }

    func testNoDecisionPlaceholderDoesNotBecomeACitedDecision() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let result = evidence.validate(try response(notes: [note("s2", "None explicitly settled in this segment.", section: "Decisions")]),
            units: evidence.units, template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.claims.isEmpty)
        XCTAssertTrue(result.outcomes.decisionRecords.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "empty_outcome")
    }

    func testConversationManagementCannotBecomeAUserTask() throws {
        var transcript = transcript
        transcript.segments[0].text = "So, I'm going to be a little bit more specific."
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action()
        raw["basis"] = "unclear"
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "conversation_management")
        XCTAssertFalse(evidence.units[0].isUserCommitment)
    }

    func testStatusReportCannotBecomeAnUnassignedTask() throws {
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action()
        raw["basis"] = "unclear"
        raw["text"] = "Reported a planning meeting with no updates."
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "status_not_task")
    }

    func testAcceptanceCannotBeLinkedToADistantUnrelatedTask() throws {
        let transcript = longTranscript()
        let evidence = MeetingNotesEvidence(transcript: transcript)
        var raw = action("s20")
        raw["context"] = ["s1"]
        let result = evidence.validate(try response(actions: [raw]), units: evidence.units,
            template: .meeting, meetingID: UUID(), maximumNotes: 12, maximumActions: 10)
        XCTAssertTrue(result.outcomes.actionItems.isEmpty)
        XCTAssertEqual(result.rejected.first?.reason, "distant_action_context")
        XCTAssertEqual(result.rejected.first?.sources, ["s20"])
    }

    func testDistantTaskReferenceCannotContaminateTheAcceptanceRepair() async throws {
        var transcript = longTranscript()
        transcript.segments[0].text = "Could you review the older policy?"
        transcript.segments[18].text = "Could you stack the storage PR ahead of this one?"
        transcript.segments[20] = .init(start: 100, end: 105, speaker: "me", text: "Yeah, I can do that.")
        var rejected = action("s21", owner: "source")
        rejected["context"] = ["s1"]
        var repaired = action("s21", owner: "source")
        repaired["context"] = ["s19"]
        repaired["text"] = "Stack the storage PR ahead of the current PR."
        let script = Script([
            .text(try response(notes: [note("s1", "The older policy needs review.")], actions: [rejected])),
            .text(try response(actions: [repaired])),
        ])
        let result = try await generate(script, transcript: transcript)
        let calls = await script.recorded()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls[1].prompt.contains("s1|"))
        XCTAssertFalse(calls[1].prompt.contains("older policy"))
        XCTAssertTrue(calls[1].prompt.contains("s19|"))
        XCTAssertEqual(result.outcomes.userActionItems.first?.text, "Stack the storage PR ahead of the current PR.")
    }

    func testChunkingIncludesEverySourceAndTailUsingTokenizer() async throws {
        let transcript = longTranscript()
        let evidence = MeetingNotesEvidence(transcript: transcript)
        let engine = Engine(script: Script([]))
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        let chunks = try await MeetingNotesGenerator.makeChunks(evidence: evidence, engine: engine,
            system: system, context: [], contextTokens: 8_192)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(Set(chunks.flatMap { $0.map(\.source) }), Set(evidence.units.map(\.source)))
        XCTAssertEqual(chunks.last?.last?.source, evidence.units.last?.source)
        for chunk in chunks {
            let actual = try await MeetingNotesGenerator.tokenCount(system + "\n\n"
                + MeetingNotesGenerator.prompt(units: chunk, roster: evidence.roster), engine: engine)
            XCTAssertLessThanOrEqual(actual + 4_096 + 1_536, 8_192)
        }
    }

    func testCompletedPartsResumeAndTranscriptChangesInvalidateCheckpoint() async throws {
        let transcript = longTranscript()
        let output = try folder()
        let system = MeetingNotesGenerator.systemPrompt(template: .meeting, language: .matchTranscript)
        let chunks = try await MeetingNotesGenerator.makeChunks(evidence: MeetingNotesEvidence(transcript: transcript),
            engine: Engine(script: Script([])), system: system, context: [], contextTokens: 8_192)
        let first = Script([.text(try response(notes: [note()])), .error(.badResponse("offline"))])
        do { _ = try await generate(first, transcript: transcript, folder: output, contextTokens: 8_192); XCTFail("expected interruption") } catch {}
        let resumed = Script(try chunks.dropFirst().map { .text(try response(notes: [note($0.last!.source)])) })
        let result = try await generate(resumed, transcript: transcript, folder: output, contextTokens: 8_192)
        let observed6 = await resumed.recorded().count
        XCTAssertEqual(observed6, chunks.count - 1)
        XCTAssertEqual(result.claims.first?.segmentID, transcript.segmentID(at: 0))
        var changed = transcript
        changed.segments[0].text = "New evidence invalidates the saved parts."
        let fresh = Script([.error(.badResponse("new request"))])
        do { _ = try await generate(fresh, transcript: changed, folder: output, contextTokens: 8_192); XCTFail("expected new request") } catch {}
        let observed7 = await fresh.recorded().count
        XCTAssertEqual(observed7, 1)
    }

    func testDeadlineCancelsInFlightGenerationAndRecordsIncompleteOutcome() async throws {
        let script = Script([.wait])
        let output = try folder()
        let budget = MeetingGenerationBudget(limits: .init(seconds: 0.05))
        do { _ = try await generate(script, folder: output, budget: budget); XCTFail("expected deadline") } catch is MeetingGenerationBudget.Exhausted {} catch { XCTFail("unexpected error \(error)") }
        // A short deadline may run out during planning, before an HTTP request.
        let observed8 = await script.recorded().count
        XCTAssertLessThanOrEqual(observed8, 1)
        let metric = try String(contentsOf: output.appendingPathComponent("notes-generation-metrics.json"), encoding: .utf8)
        XCTAssertTrue(metric.contains("incomplete"))
        XCTAssertFalse(metric.contains("I will ship"))
    }

    func testDeadlineWaitsForCancelledWorkToRelease() async throws {
        let script = Script([.wait])
        let budget = MeetingGenerationBudget(limits: .init(seconds: 0.05))
        do {
            _ = try await budget.run { try await script.next(prompt: "", options: .init()) }
            XCTFail("expected deadline")
        } catch is MeetingGenerationBudget.Exhausted {} catch { XCTFail("unexpected error \(error)") }
        let observed9 = await script.cancelled
        XCTAssertTrue(observed9)
    }

    func testRequestBudgetIncludesRepairAndPreservesProgress() async throws {
        let script = Script([.text(try response(notes: [note(), note("s2", "invalid", section: "wrong")]))])
        let output = try folder()
        do {
            _ = try await generate(script, folder: output, budget: MeetingGenerationBudget(limits: .init(requests: 1)))
            XCTFail("repair must consume the shared request allowance")
        } catch is MeetingGenerationBudget.Exhausted {} catch { XCTFail("unexpected error \(error)") }
        let observed10 = await script.recorded().count
        XCTAssertEqual(observed10, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("summary.claims.partial.json").path))
    }

    func testCompleteRecordParserHandlesEscapesAndDoesNotInventPartialObjects() throws {
        let record = ["text": "literal \" } { \\ value", "source": "s1"]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self)
        let parsed = CompleteJSONRecords.parse("{\"notes\":[" + encoded + ",{\"text\":\"partial", keys: ["notes", "actions"])
        XCTAssertFalse(parsed.complete)
        XCTAssertEqual(parsed.arrays["notes"]?.count, 1)
        XCTAssertEqual(parsed.arrays["notes"]?.first?["text"] as? String, record["text"])
        XCTAssertTrue(CompleteJSONRecords.parse("prose {\"notes\":[{}", keys: ["notes"]).arrays.isEmpty)
    }

    func testMissingUsageIsUnavailableAndTruncationRetainsUsageAndTimings() throws {
        let payload = #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}],"usage":{"completion_tokens":512},"timings":{"prompt_ms":123,"predicted_ms":456}}"#
        let parsed = try OpenAICompatibleEngine.parseChatCompletion(Data(payload.utf8), allowTruncation: true)
        XCTAssertTrue(parsed.truncated)
        XCTAssertEqual(parsed.content, "partial")
        XCTAssertEqual(parsed.usage?.outputTokens, 512)
        XCTAssertNil(parsed.usage?.inputTokens)
        XCTAssertNil(parsed.usage?.cachedInputTokens)
        XCTAssertNil(parsed.usage?.reasoningOutputTokens)
        XCTAssertEqual(parsed.prefillSeconds, 0.123)
        XCTAssertEqual(parsed.generationSeconds, 0.456)
    }

    private func longTranscript() -> Transcript {
        Transcript(segments: (0..<60).map { index in
            .init(start: Double(index * 5), end: Double(index * 5 + 5), speaker: "them",
                  text: "I will finish task \(index). " + String(repeating: "The dependency needs review. ", count: 6))
        }, engine: "fixture")
    }
}
