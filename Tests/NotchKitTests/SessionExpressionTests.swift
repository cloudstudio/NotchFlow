import XCTest
import NotchFlowCore
@testable import NotchKit

/// The eyes are the app's at-a-glance state. Two invariants: each status maps to
/// exactly one expression, and "stuck outranks working" — a wedged agent must
/// read as needing attention even while its status says it is busy.
final class SessionExpressionTests: XCTestCase {
    private func session(_ status: SessionStatus, stuck: String? = nil) -> AgentSession {
        AgentSession(id: "s", agent: .claude, status: status, stuckReason: stuck)
    }

    func testEyeExpressionMapsEachStatus() {
        XCTAssertEqual(EyeExpression(status: .working), .awake)
        XCTAssertEqual(EyeExpression(status: .runningTool), .focused)
        XCTAssertEqual(EyeExpression(status: .waitingPermission), .alert)
        XCTAssertEqual(EyeExpression(status: .idle), .sleepy)
        XCTAssertEqual(EyeExpression(status: .completed), .happy)
        XCTAssertEqual(EyeExpression(status: .failed), .dead)
        XCTAssertEqual(EyeExpression(status: nil), .sleepy)
    }

    func testStuckOutranksWorking() {
        XCTAssertEqual(sessionEyes(session(.working, stuck: "repeating a failing command")), .alert)
        XCTAssertEqual(sessionEyes(session(.runningTool, stuck: "stuck")), .alert)
    }

    func testHealthyWorkingReadsAsAwake() {
        XCTAssertEqual(sessionEyes(session(.working)), .awake)
    }
}
