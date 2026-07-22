import AppKit
import SwiftUI
import NotchFlowCore

/// The provider's bundled PNG logo (Resources/providers/<name>.png), or nil so
/// callers fall back to the name. Drop claude.png / codex.png there to enable.
func providerLogo(_ provider: AgentKind) -> Image? {
    let name: String
    switch provider {
    case .claude: name = "claude"
    case .codex: name = "codex"
    default: return nil
    }
    guard let url = Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Resources/providers"),
          let image = NSImage(contentsOf: url) else { return nil }
    return Image(nsImage: image)
}
public func statusColor(for status: SessionStatus?) -> Color {
    switch status {
    case .working, .runningTool: return Color(red: 0.35, green: 0.95, blue: 0.64)
    case .waitingPermission: return Color(red: 1, green: 0.58, blue: 0.24)
    case .idle: return Color(red: 0.55, green: 0.78, blue: 0.95)
    case .failed: return Color(red: 1, green: 0.28, blue: 0.28)
    case .completed, nil: return Color(white: 0.55)
    }
}
/// Amber verdict overrides the status color: stuck outranks "working".
func sessionAccent(_ session: AgentSession) -> Color {
    session.stuckReason != nil
        ? Color(red: 1, green: 0.62, blue: 0.28)
        : statusColor(for: session.status)
}
func sessionEyes(_ session: AgentSession) -> EyeExpression {
    session.stuckReason != nil ? .alert : EyeExpression(status: session.status)
}
/// Brand-ish identity color per agent, used for chips and tool accents.
public func agentColor(_ agent: AgentKind) -> Color {
    switch agent {
    case .claude: return Color(red: 0.87, green: 0.44, blue: 0.27)
    case .codex: return Color(red: 0.33, green: 0.55, blue: 0.95)
    case .cursor: return Color(white: 0.75)
    case .gemini: return Color(red: 0.45, green: 0.62, blue: 1)
    case .openCode: return Color(red: 0.72, green: 0.52, blue: 0.98)
    case .unknown: return Color(white: 0.55)
    }
}
/// Green while comfortable, amber approaching the limit, red past 80%.
public func usageColor(_ fraction: Double) -> Color {
    if fraction < 0.5 { return Color(red: 0.4, green: 0.88, blue: 0.55) }
    if fraction < 0.8 { return Color(red: 1, green: 0.75, blue: 0.35) }
    return Color(red: 1, green: 0.42, blue: 0.35)
}
