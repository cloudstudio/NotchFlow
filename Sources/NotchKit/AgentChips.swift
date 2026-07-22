import SwiftUI
import NotchFlowCore

struct AgentChip: View {
    let agent: AgentKind

    var body: some View {
        Text(agent.displayName)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(agentColor(agent).opacity(0.9)))
            .foregroundStyle(.white)
    }
}
struct ModelChip: View {
    let model: String

    var body: some View {
        Text(UsageAggregator.shortModel(model))
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(.white.opacity(0.08)))
            .foregroundStyle(.white.opacity(0.65))
    }
}
/// A glanceable identity for the host terminal: a short name, a muted color
/// that lives ONLY here (its own channel — never the status or agent hue), and
/// an SF Symbol. Headless sessions read as a cloud. This is the "which terminal
/// am I in" answer, promoted out of the old dim location text.
struct TerminalIdentity {
    let label: String
    let color: Color
    let symbol: String

    private init(_ label: String, _ color: Color, _ symbol: String) {
        self.label = label
        self.color = color
        self.symbol = symbol
    }

    init(program: String?, isHeadless: Bool) {
        if isHeadless {
            self = .init("headless", Color(white: 0.50), "cloud")
            return
        }
        switch program {
        case "iTerm.app":      self = .init("iTerm", Color(red: 0.42, green: 0.82, blue: 0.55), "terminal.fill")
        case "Apple_Terminal": self = .init("Terminal", Color(red: 0.60, green: 0.64, blue: 0.70), "terminal.fill")
        case "WarpTerminal":   self = .init("Warp", Color(red: 0.97, green: 0.50, blue: 0.52), "bolt.fill")
        case "Codex Desktop":  self = .init("Codex", Color(red: 0.28, green: 0.78, blue: 0.82), "sparkles")
        case "ghostty":        self = .init("Ghostty", Color(red: 0.66, green: 0.56, blue: 0.98), "moon.stars.fill")
        case "WezTerm":        self = .init("WezTerm", Color(red: 0.90, green: 0.70, blue: 0.36), "rectangle.split.2x1.fill")
        case "Hyper":          self = .init("Hyper", Color(red: 0.92, green: 0.46, blue: 0.82), "hexagon.fill")
        case "vscode":         self = .init("VS Code", Color(red: 0.30, green: 0.60, blue: 0.92), "curlybraces")
        default:               self = .init(program ?? "shell", Color(white: 0.55), "terminal")
        }
    }

    init(session: AgentSession, canJump: Bool) {
        self.init(
            program: TerminalCatalog.program(fromTerminalIdentity: session.terminal),
            isHeadless: !canJump
        )
    }
}
/// An OUTLINED tinted pill — deliberately the opposite shape of the solid
/// AgentChip so "where" (terminal) and "who" (agent) never read as the same
/// token, even when both hues sit near blue.
struct TerminalChip: View {
    let term: TerminalIdentity
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 3.5) {
            Image(systemName: term.symbol)
                .font(.system(size: 9, weight: .semibold))
            if !compact {
                Text(term.label)
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(term.color)
        .padding(.horizontal, compact ? 4 : 6)
        .padding(.vertical, 2.5)
        .background(Capsule().fill(term.color.opacity(0.14)))
        .overlay(Capsule().stroke(term.color.opacity(0.30), lineWidth: 0.75))
    }
}
