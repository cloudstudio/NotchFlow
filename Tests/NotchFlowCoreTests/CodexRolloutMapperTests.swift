import XCTest
@testable import NotchFlowCore

final class CodexRolloutMapperTests: XCTestCase {
    private func line(_ json: String) -> Data { Data(json.utf8) }

    func testSessionIdComesFromFilename() {
        XCTAssertEqual(
            CodexRolloutMapper.sessionId(
                fromFilename: "rollout-2026-07-20T20-43-35-019f80d7-33e8-73b3-8a7b-f56268ac2ee0.jsonl"
            ),
            "019f80d7-33e8-73b3-8a7b-f56268ac2ee0"
        )
        XCTAssertNil(CodexRolloutMapper.sessionId(fromFilename: "notes.txt"))
    }

    func testSessionMetaCarriesCwdAndDesktopIdentity() {
        let events = CodexRolloutMapper.events(fromLine: line(
            #"{"timestamp":"2026-07-20T18:43:36.252Z","type":"session_meta","payload":{"session_id":"s","cwd":"/Users/toni/Sites/toni","originator":"Codex Desktop"}}"#
        ), sessionId: "s")
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.type, .sessionStarted)
        XCTAssertEqual(events.first?.cwd, "/Users/toni/Sites/toni")
        XCTAssertEqual(events.first?.terminal, "Codex Desktop")

        let tui = CodexRolloutMapper.events(fromLine: line(
            #"{"timestamp":"2026-07-20T18:43:36.252Z","type":"session_meta","payload":{"cwd":"/tmp","originator":"codex_cli_rs"}}"#
        ), sessionId: "s")
        XCTAssertNil(tui.first?.terminal, "TUI sessions have no reachable window")
    }

    func testConversationFlowMapsToPromptAndCompletion() {
        let prompt = CodexRolloutMapper.events(fromLine: line(
            #"{"timestamp":"2026-07-20T18:43:40.876Z","type":"event_msg","payload":{"type":"user_message","message":"hola\n"}}"#
        ), sessionId: "s")
        XCTAssertEqual(prompt.first?.type, .promptSubmitted)
        XCTAssertEqual(prompt.first?.detail, "hola")

        let done = CodexRolloutMapper.events(fromLine: line(
            #"{"timestamp":"2026-07-20T18:43:42.947Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"¡Hola! ¿En qué te ayudo?"}}"#
        ), sessionId: "s")
        XCTAssertEqual(done.first?.type, .turnCompleted)
        XCTAssertEqual(done.first?.detail, "¡Hola! ¿En qué te ayudo?")

        let aborted = CodexRolloutMapper.events(fromLine: line(
            #"{"timestamp":"2026-07-20T18:43:42.947Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
        ), sessionId: "s")
        XCTAssertEqual(aborted.first?.type, .turnCompleted)
    }

    func testToolCallsAndPatchesFeedActivityAndFiles() {
        let call = CodexRolloutMapper.events(fromLine: line(
            #"{"timestamp":"2026-07-20T18:43:41.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"npm test\nsecond line"}}"#
        ), sessionId: "s")
        XCTAssertEqual(call.first?.type, .toolStarted)
        XCTAssertEqual(call.first?.tool, "exec")
        XCTAssertEqual(call.first?.detail, "npm test")

        let patch = CodexRolloutMapper.events(fromLine: line(
            #"{"timestamp":"2026-07-20T18:43:41.500Z","type":"event_msg","payload":{"type":"patch_apply_end","stdout":"Success. Updated the following files:\nA /p/index.html\nM /p/app.css"}}"#
        ), sessionId: "s")
        XCTAssertEqual(
            patch.map(\.type),
            [.toolStarted, .toolStarted, .toolFinished]
        )
        XCTAssertEqual(patch.first?.tool, "Edit")
        XCTAssertEqual(patch.map(\.detail), ["/p/index.html", "/p/app.css", nil])

        var reducer = SessionReducer()
        (call + patch).forEach { reducer.apply($0) }
        XCTAssertEqual(
            reducer.sessions["s"]?.filesTouched,
            ["/p/index.html", "/p/app.css"],
            "patched files land in the assignment's file count"
        )
    }

    func testIrrelevantLinesProduceNothing() {
        XCTAssertTrue(CodexRolloutMapper.events(fromLine: line(
            #"{"timestamp":"2026-07-20T18:43:42.938Z","type":"event_msg","payload":{"type":"token_count"}}"#
        ), sessionId: "s").isEmpty)
        XCTAssertTrue(CodexRolloutMapper.events(fromLine: line("not json"), sessionId: "s").isEmpty)
    }
}
