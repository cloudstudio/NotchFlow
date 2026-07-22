import XCTest
import NotchFlowCore
@testable import NotchKit

/// "Which terminal am I in" identity. A missing switch case quietly degrades a
/// known terminal to a generic "shell" pill. Asserts on label + symbol (never
/// color — SwiftUI Color has no reliable value equality).
final class TerminalIdentityTests: XCTestCase {
    func testHeadlessMapsToCloud() {
        let id = TerminalIdentity(program: "iTerm.app", isHeadless: true)
        XCTAssertEqual(id.label, "headless")
        XCTAssertEqual(id.symbol, "cloud")
    }

    func testKnownTerminals() {
        let expected: [(program: String, label: String, symbol: String)] = [
            ("iTerm.app", "iTerm", "terminal.fill"),
            ("Apple_Terminal", "Terminal", "terminal.fill"),
            ("WarpTerminal", "Warp", "bolt.fill"),
            ("Codex Desktop", "Codex", "sparkles"),
            ("ghostty", "Ghostty", "moon.stars.fill"),
            ("WezTerm", "WezTerm", "rectangle.split.2x1.fill"),
            ("Hyper", "Hyper", "hexagon.fill"),
            ("vscode", "VS Code", "curlybraces")
        ]
        for entry in expected {
            let id = TerminalIdentity(program: entry.program, isHeadless: false)
            XCTAssertEqual(id.label, entry.label, "label for \(entry.program)")
            XCTAssertEqual(id.symbol, entry.symbol, "symbol for \(entry.program)")
        }
    }

    func testUnknownProgramKeepsItsName() {
        let id = TerminalIdentity(program: "SomeNewTerm", isHeadless: false)
        XCTAssertEqual(id.label, "SomeNewTerm")
        XCTAssertEqual(id.symbol, "terminal")
    }

    func testNilProgramIsShell() {
        let id = TerminalIdentity(program: nil, isHeadless: false)
        XCTAssertEqual(id.label, "shell")
        XCTAssertEqual(id.symbol, "terminal")
    }
}
