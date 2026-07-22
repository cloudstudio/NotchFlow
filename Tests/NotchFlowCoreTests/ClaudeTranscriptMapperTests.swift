import XCTest
@testable import NotchFlowCore

final class ClaudeTranscriptMapperTests: XCTestCase {
    private func line(_ json: String) -> Data { Data(json.utf8) }
    private func events(_ json: String) -> [AgentEvent] {
        ClaudeTranscriptMapper.events(fromLine: line(json), sessionId: "file-id", transcriptPath: "/p/x.jsonl")
    }

    func testSessionIdIsTheFilenameStem() {
        XCTAssertEqual(
            ClaudeTranscriptMapper.sessionId(fromFilename: "253e72d9-7bbd-4d67-9e88-2ec8e02e1139.jsonl"),
            "253e72d9-7bbd-4d67-9e88-2ec8e02e1139"
        )
        XCTAssertNil(ClaudeTranscriptMapper.sessionId(fromFilename: "notes.txt"))
    }

    func testUserStringIsAPrompt() {
        let events = events(
            #"{"type":"user","sessionId":"s","cwd":"/Sites/notchflow","timestamp":"2026-07-20T17:59:24.466Z","message":{"role":"user","content":"Add rate limiting"}}"#
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .promptSubmitted)
        XCTAssertEqual(events.first?.detail, "Add rate limiting")
        XCTAssertEqual(events.first?.sessionId, "s", "the line's own sessionId wins over the filename")
        XCTAssertEqual(events.first?.cwd, "/Sites/notchflow")
    }

    func testAssistantToolUseStartsToolsWithModelAndTranscript() {
        let events = events(
            #"{"type":"assistant","sessionId":"s","timestamp":"2026-07-20T18:00:00.000Z","message":{"model":"claude-fable-5","content":[{"type":"thinking","thinking":"…"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"npm test"}}]}}"#
        )
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .toolStarted)
        XCTAssertEqual(events.first?.tool, "Bash")
        XCTAssertEqual(events.first?.detail, "npm test")
        XCTAssertEqual(events.first?.model, "claude-fable-5")
        XCTAssertEqual(events.first?.transcriptPath, "/p/x.jsonl")
    }

    func testToolResultFinishesAndCarriesFailure() {
        let ok = events(
            #"{"type":"user","sessionId":"s","timestamp":"2026-07-20T18:00:01.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":false,"content":"done"}]}}"#
        )
        XCTAssertEqual(ok.first?.type, .toolFinished)
        XCTAssertNil(ok.first?.toolFailed)

        let bad = events(
            #"{"type":"user","sessionId":"s","timestamp":"2026-07-20T18:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"boom"}]}}"#
        )
        XCTAssertEqual(bad.first?.type, .toolFinished)
        XCTAssertEqual(bad.first?.toolFailed, true)
    }

    func testSidechainAndNoiseAreIgnored() {
        XCTAssertTrue(events(
            #"{"type":"assistant","isSidechain":true,"sessionId":"s","message":{"model":"m","content":[{"type":"tool_use","name":"Read","input":{"file_path":"a.swift"}}]}}"#
        ).isEmpty)
        XCTAssertTrue(events(#"{"type":"attachment","sessionId":"s"}"#).isEmpty)
        XCTAssertTrue(events(#"{"type":"summary","summary":"x"}"#).isEmpty)
        XCTAssertTrue(events("not json").isEmpty)
    }

    func testAssistantTextOnlyEmitsNothing() {
        // The final answer carries no status event; the monitor detects the
        // idle turn and closes it. This keeps the mapper stateless.
        XCTAssertTrue(events(
            #"{"type":"assistant","sessionId":"s","message":{"model":"m","content":[{"type":"text","text":"All done."}]}}"#
        ).isEmpty)
    }

    func testFullExchangeReducesToAReadyClaudeSession() {
        var reducer = SessionReducer()
        for json in [
            #"{"type":"user","sessionId":"s","cwd":"/Sites/shop","timestamp":"2026-07-20T18:00:00.000Z","message":{"content":"Fix login"}}"#,
            #"{"type":"assistant","sessionId":"s","timestamp":"2026-07-20T18:00:01.000Z","message":{"model":"claude-fable-5","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"auth.ts"}}]}}"#,
            #"{"type":"user","sessionId":"s","timestamp":"2026-07-20T18:00:02.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":false,"content":"ok"}]}}"#
        ] {
            events(json).forEach { reducer.apply($0) }
        }
        let session = reducer.sessions["s"]
        XCTAssertEqual(session?.agent, .claude)
        XCTAssertEqual(session?.cwd, "/Sites/shop")
        XCTAssertEqual(session?.filesTouched, ["auth.ts"])
        XCTAssertEqual(session?.status, .working, "closing the turn is the monitor's job, not the mapper's")
    }
}
