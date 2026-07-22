import XCTest
import NotchFlowCore
@testable import NotchKit

/// Safety-critical: the auto-approve plugin's whole promise is "never writes,
/// edits, or shell." A typo in the safelist or a dropped `kind == .permission`
/// guard would let an agent mutate the filesystem unprompted. This locks the
/// contract as pure allow/deny.
final class AutoApproveGateTests: XCTestCase {
    func testReadOnlyToolsApproveWhenOn() {
        for tool in ["Read", "Grep", "Glob", "LS", "WebFetch", "WebSearch"] {
            XCTAssertTrue(
                AppModel.shouldAutoApprove(kind: .permission, tool: tool, autoApproveOn: true),
                "\(tool) is read-only and should auto-approve"
            )
        }
    }

    func testMutatingToolsNeverApprove() {
        for tool in ["Write", "Edit", "MultiEdit", "Bash", "NotebookEdit", "Task"] {
            XCTAssertFalse(
                AppModel.shouldAutoApprove(kind: .permission, tool: tool, autoApproveOn: true),
                "\(tool) can mutate state and must never auto-approve"
            )
        }
    }

    func testCaseInsensitive() {
        XCTAssertTrue(AppModel.shouldAutoApprove(kind: .permission, tool: "rEaD", autoApproveOn: true))
    }

    func testQuestionsAndPlansNeverAutoApprove() {
        XCTAssertFalse(AppModel.shouldAutoApprove(kind: .question, tool: "Read", autoApproveOn: true))
        XCTAssertFalse(AppModel.shouldAutoApprove(kind: .plan, tool: "Read", autoApproveOn: true))
    }

    func testPluginOffApprovesNothing() {
        XCTAssertFalse(AppModel.shouldAutoApprove(kind: .permission, tool: "Read", autoApproveOn: false))
    }

    func testNilToolDoesNotApprove() {
        XCTAssertFalse(AppModel.shouldAutoApprove(kind: .permission, tool: nil, autoApproveOn: true))
    }

    func testSafelistContainsNoMutatingTool() {
        for tool in ["write", "edit", "multiedit", "bash", "shell", "notebookedit", "task"] {
            XCTAssertFalse(
                PluginManager.safeTools.contains(tool),
                "\(tool) must not be on the read-only safelist"
            )
        }
    }
}
