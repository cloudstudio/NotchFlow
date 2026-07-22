import SwiftUI
import NotchFlowCore

// MARK: - Primary session card

/// The session that matters most right now, with enough context to skip the
/// terminal: original prompt, current action and the last few tools it ran.
struct PrimarySessionCard: View {
    let session: AgentSession
    let now: Date
    var childSummary: String?
    var canJump: Bool = true
    let onJump: () -> Void
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if canJump {
            Button(action: onJump) { cardContent }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("Jump to \(TerminalCatalog.program(fromTerminalIdentity: session.terminal) ?? "terminal")")
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    TerminalChip(term: TerminalIdentity(session: session, canJump: canJump))
                    Text(titleLine)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if session.parentId != nil {
                        Text("SUBAGENT")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.white.opacity(0.1)))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer(minLength: 8)
                    AgentChip(agent: session.agent)
                    Text(elapsedLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }

                if let reason = session.stuckReason {
                    Label(reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.28))
                }

                HStack(alignment: .center, spacing: 8) {
                    MoriEyesView(expression: sessionEyes(session), color: color)
                        .frame(width: 24, height: 14)
                    if let tool = session.tool {
                        Text(tool)
                            .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Text(actionDetail)
                        .font(.system(
                            size: 12.5,
                            weight: .medium,
                            design: session.tool == nil ? .rounded : .monospaced
                        ))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text(statusLabel)
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                    Spacer()
                    if let cost = session.equivalentCostUSD {
                        Text("API eq. \(session.costIncomplete == true ? "≥ " : "")\(cost, format: .currency(code: "USD"))")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.32))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(isHovered && canJump ? 0.085 : 0.055))
            )
    }

    private var titleLine: String {
        let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? session.agent.displayName
        if let headline = session.prompt?
            .split(separator: "\n").first.map(String.init), !headline.isEmpty {
            return "\(project) · \(headline)"
        }
        return project
    }

    /// One readable line: a command's first line, trimmed, never a wall of
    /// pasted script. Idle sessions read the agent's closing message instead.
    private var actionDetail: String {
        guard let detail = session.detail else {
            switch session.status {
            case .idle: return "Waiting for your next prompt"
            case .completed: return "Finished"
            case .failed: return "Failed"
            default: return "Thinking…"
            }
        }
        let firstLine = detail.split(whereSeparator: \.isNewline).first.map(String.init) ?? detail
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        let limit = session.tool == nil ? 160 : 72
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    private var elapsedLabel: String {
        let seconds = max(0, Int(now.timeIntervalSince(session.startedAt)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 { return "\(hours)h\(String(format: "%02d", minutes))" }
        if minutes > 0 { return "\(minutes)m" }
        return "now"
    }

    private var statusLabel: String {
        if session.stuckReason != nil { return "STUCK" }
        switch session.status {
        case .working: return "WORKING"
        case .runningTool: return "RUNNING"
        case .waitingPermission: return "ALLOW?"
        case .idle: return "READY"
        case .completed: return "DONE"
        case .failed: return "FAILED"
        }
    }

    private var color: Color {
        sessionAccent(session)
    }
}
// MARK: - Swarm rows

/// One line per agent: at fifty concurrent sessions this is the only
/// density that stays readable.
struct SwarmRow: View {
    let session: AgentSession
    let now: Date
    var childSummary: String?
    var canJump: Bool = true
    let onJump: () -> Void
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if canJump {
            Button(action: onJump) { rowContent }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
            HStack(spacing: 8) {
                MoriEyesView(
                    expression: sessionEyes(session),
                    color: sessionAccent(session)
                )
                .frame(width: 20, height: 11)
                TerminalChip(term: TerminalIdentity(session: session, canJump: canJump))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                if let tool = session.tool {
                    Text(tool)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let childSummary {
                    Text(childSummary)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
                AgentChip(agent: session.agent)
                Text(elapsed)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(.white.opacity(rowOpacity))
            )
    }

    private var rowOpacity: Double {
        if isHovered, canJump { return 0.1 }
        return session.status == .waitingPermission ? 0.09 : 0.04
    }

    private var title: String {
        let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? session.agent.displayName
        if let headline = session.prompt?.split(separator: "\n").first.map(String.init) {
            return "\(project) · \(headline)"
        }
        return project
    }

    private var elapsed: String {
        let seconds = max(0, Int(now.timeIntervalSince(session.startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
    }
}
/// The competitor's pattern, done natively: a quiet box inside the parent
/// listing running subagents by name with their live command under a tree
/// connector, finished ones as "Done | duration", the rest as an overflow
/// count.
struct SubagentSection: View {
    let children: [AgentSession]
    let now: Date

    @ViewBuilder
    var body: some View {
        let live: Set<SessionStatus> = [.working, .runningTool, .waitingPermission, .idle]
        let running = children.filter { live.contains($0.status) }
        let done = children.filter { $0.status == .completed || $0.status == .failed }
        if !running.isEmpty {
            content(running: running, doneCount: done.count)
        }
    }

    private func content(running: [AgentSession], doneCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Subagents · \(running.count) running\(doneCount > 0 ? " · \(doneCount) done" : "")")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            ForEach(Array(running.prefix(4))) { child in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor(for: child.status))
                            .frame(width: 5, height: 5)
                        Text(name(of: child))
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Text(elapsed(child))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.35))
                        Spacer(minLength: 0)
                    }
                    if let line = commandLine(of: child) {
                        HStack(spacing: 4) {
                            Text("\u{2514}")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.25))
                            Text(line)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        .padding(.leading, 11)
                    }
                }
            }
            if running.count > 4 {
                Text("+\(running.count - 4) running")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.leading, 11)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.03))
        )
    }

    private func name(of child: AgentSession) -> String {
        child.prompt ?? child.detail ?? "subagent"
    }

    private func commandLine(of child: AgentSession) -> String? {
        guard child.status == .runningTool || child.status == .working else { return nil }
        if let tool = child.tool, let detail = child.detail {
            return "\(tool) \u{00B7} \(detail)"
        }
        return child.detail
    }

    private func elapsed(_ child: AgentSession) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(child.startedAt)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }

    private func duration(_ child: AgentSession) -> String {
        let seconds = max(0, Int(child.updatedAt.timeIntervalSince(child.startedAt)))
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }
}
// MARK: - Session row

struct SessionRow: View {
    let session: AgentSession
    let now: Date
    var childSummary: String?
    var canJump: Bool = true
    let onJump: () -> Void
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if canJump {
            Button(action: onJump) { rowContent }
                .buttonStyle(.plain)
                .onHover { isHovered = $0 }
                .help("Jump to \(TerminalCatalog.program(fromTerminalIdentity: session.terminal) ?? "terminal")")
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
            HStack(spacing: 10) {
                MoriEyesView(expression: sessionEyes(session), color: color)
                    .frame(width: 24, height: 14)

                VStack(alignment: .leading, spacing: 3.5) {
                    HStack(spacing: 6) {
                        TerminalChip(term: TerminalIdentity(session: session, canJump: canJump))
                        Text(rowTitle)
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if session.parentId != nil {
                            Text("SUBAGENT")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(.white.opacity(0.1)))
                                .foregroundStyle(.white.opacity(0.8))
                        }
                    }

                    HStack(spacing: 5) {
                        if let tool = session.tool {
                            Text(tool)
                                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        Text(summary)
                            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(statusLabel)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(color)
                        AgentChip(agent: session.agent)
                        if let model = session.model {
                            ModelChip(model: model)
                        }
                    }
                    HStack(spacing: 5) {
                        if let childSummary {
                            Text(childSummary)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        Text(elapsedLabel)
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(rowOpacity))
            )
    }

    private var rowOpacity: Double {
        if isHovered, canJump { return 0.1 }
        return session.status == .waitingPermission ? 0.075 : 0.045
    }

    private var rowTitle: String {
        let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? session.agent.displayName
        if let headline = session.prompt?
            .split(separator: "\n").first.map(String.init), !headline.isEmpty {
            return "\(project) · \(headline)"
        }
        return project
    }

    private var summary: String {
        if let reason = session.stuckReason { return reason }
        if let detail = session.detail { return detail }
        switch session.status {
        case .completed: return "Finished"
        case .idle: return "Waiting for your next prompt"
        default: return "Thinking…"
        }
    }

    private var elapsedLabel: String {
        let seconds = max(0, Int(now.timeIntervalSince(session.startedAt)))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        if hours > 0 { return "\(hours)h\(String(format: "%02d", minutes))" }
        if minutes > 0 { return "\(minutes)m" }
        return "now"
    }

    private var statusLabel: String {
        if session.stuckReason != nil { return "STUCK" }
        switch session.status {
        case .working: return "WORKING"
        case .runningTool: return "RUNNING"
        case .waitingPermission: return "ALLOW?"
        case .idle: return "READY"
        case .completed: return "DONE"
        case .failed: return "FAILED"
        }
    }

    private var color: Color {
        sessionAccent(session)
    }
}
