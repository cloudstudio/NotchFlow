import AppKit
import Foundation
import NotchFlowCore
import os

/// Jumps back to the terminal a session lives in. iTerm2 and Terminal.app
/// support exact tab/pane selection by tty; other terminals are activated
/// by application. Requires the one-time Automation consent from macOS.
enum TerminalFocuser {
    private static let logger = Logger(subsystem: "app.notchflow", category: "focus")

    static func focus(session: AgentSession) {
        let program = TerminalCatalog.program(fromTerminalIdentity: session.terminal)
        let ttyPath = session.tty.map { "/dev/\($0)" }

        switch program {
        case "iTerm.app":
            runScript(itermScript, argument: ttyPath ?? "")
        case "Apple_Terminal":
            runScript(terminalScript, argument: ttyPath ?? "")
        case "WarpTerminal":
            if let uuid = sessionToken(of: session),
               let url = URL(string: "warp://session/\(uuid)") {
                NSWorkspace.shared.open(url)
            }
            // If the tab was closed the URL silently does nothing, so the
            // click always at least surfaces Warp.
            activateApplication(program: program)
        case "tmux":
            focusTmux(paneTTY: ttyPath)
        case "Codex Desktop":
            // The session id from the rollout filename IS the conversation
            // id the desktop app deep-links by.
            if let url = URL(string: "codex://threads/\(session.id)") {
                NSWorkspace.shared.open(url)
            }
            activateApplication(program: program)
        default:
            activateApplication(program: program)
        }
    }

    private static func sessionToken(of session: AgentSession) -> String? {
        let parts = session.terminal?.components(separatedBy: " · ") ?? []
        guard parts.count > 1 else { return nil }
        return parts.last
    }

    /// Inside tmux the agent's tty belongs to a pane, not a window: resolve
    /// the pane, switch the attached client to it, then surface whichever
    /// GUI terminal hosts that client.
    private static func focusTmux(paneTTY: String?) {
        guard let paneTTY else { return }
        Task.detached(priority: .userInitiated) {
            guard let tmux = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }

            guard let panes = runCommand(tmux, ["list-panes", "-a", "-F", "#{pane_tty}|#{session_name}|#{window_index}|#{pane_id}"]) else { return }
            guard let match = panes
                .split(separator: "\n")
                .map(String.init)
                .first(where: { $0.hasPrefix(paneTTY + "|") })?
                .split(separator: "|", omittingEmptySubsequences: false)
                .map(String.init),
                match.count >= 4 else { return }
            let (sessionName, windowIndex, paneId) = (match[1], match[2], match[3])

            let client = runCommand(tmux, ["list-clients", "-F", "#{client_tty}"])?
                .split(separator: "\n")
                .first
                .map(String.init)
            if let client {
                _ = runCommand(tmux, ["switch-client", "-c", client, "-t", sessionName])
            }
            _ = runCommand(tmux, ["select-window", "-t", "\(sessionName):\(windowIndex)"])
            _ = runCommand(tmux, ["select-pane", "-t", paneId])

            if let client {
                // Quiet variants: probing both apps must not launch or
                // surface the one that does not host the tmux client.
                runScript(Self.withoutFallbackActivate(itermScript), argument: client)
                runScript(Self.withoutFallbackActivate(terminalScript), argument: client)
            }
        }
    }

    private static func withoutFallbackActivate(_ script: String) -> String {
        script.replacingOccurrences(
            of: "end repeat\n        activate\n    end tell",
            with: "end repeat\n    end tell"
        )
    }

    private static func runCommand(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func activateApplication(program: String?) {
        let candidates = program.map(TerminalCatalog.bundleIdentifiers(forProgram:)) ?? []
        let running = NSWorkspace.shared.runningApplications
        guard let app = running.first(where: { application in
            guard let bundleId = application.bundleIdentifier else { return false }
            return candidates.contains(bundleId)
        }) else { return }
        // Cooperative activation is routinely ignored on modern macOS and
        // reads as a dead click; force the switch.
        app.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }

    private static func runScript(_ script: String, argument: String) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script, argument]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    logger.info("osascript exited with \(process.terminationStatus)")
                }
            } catch {
                logger.error("failed to run osascript: \(error.localizedDescription)")
            }
        }
    }

    private static let itermScript = """
    on run argv
        set target to item 1 of argv
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is target then
                            select s
                            select t
                            select w
                            activate
                            return
                        end if
                    end repeat
                end repeat
            end repeat
            activate
        end tell
    end run
    """

    private static let terminalScript = """
    on run argv
        set target to item 1 of argv
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is target then
                        set selected tab of w to t
                        set index of w to 1
                        activate
                        return
                    end if
                end repeat
            end repeat
            activate
        end tell
    end run
    """
}
