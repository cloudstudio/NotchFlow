import SwiftUI
import NotchFlowCore

public struct NotchIslandView: View {
    @ObservedObject var model: AppModel
    @State private var showAllSessions = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        island
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The pill never disappears: it is the top band of the opened surface.
    /// The expanded body enters with an identity transition at its final
    /// layout and is revealed by the growing clip shape, so the opening reads
    /// as one organic morph instead of a cross-fade.
    private var island: some View {
        VStack(spacing: 0) {
            topBar
            if model.isExpanded {
                expandedBody
                    .frame(width: 560)
                    .transition(.identity)
            }
        }
        .frame(width: islandWidth)
        .background { islandBackground }
        .overlay(islandShape.stroke(.white.opacity(0.08), lineWidth: 1))
        .clipShape(islandShape)
        .background { HaloView(pingAt: model.pingAt, status: model.pingStatus, shape: islandShape) }
        .compositingGroup()
        .shadow(color: .black.opacity(0.55), radius: 14, y: 5)
        .contentShape(islandShape)
        .onHover { inside in
            if inside {
                model.pointerEntered()
            } else {
                model.pointerExited()
            }
        }
        .onTapGesture {
            if !model.isExpanded { model.setExpanded(true) }
        }
        .contextMenu {
            Button(model.sounds.isEnabled ? "Mute sounds" : "Enable sounds") {
                model.sounds.isEnabled.toggle()
                model.objectWillChange.send()
            }
            Button(model.quietMode ? "Quiet mode ✓" : "Quiet mode") {
                model.quietMode.toggle()
            }
            Divider()
            Button("Quit NotchFlow") {
                NSApplication.shared.terminate(nil)
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.78), value: model.isExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.sessions)
    }

    private var islandShape: NotchShape {
        NotchShape(
            topFillet: model.isExpanded ? 12 : 8,
            bottomRadius: model.isExpanded ? 28 : model.geometry.collapsedSize.height / 2
        )
    }

    private var islandWidth: CGFloat {
        model.isExpanded ? 560 : model.geometry.collapsedSize.width
    }

    /// The near-black solid in every state — a crisp panel that extends the
    /// physical notch, never a translucent pane.
    private var islandBackground: some View {
        islandShape.fill(Color(red: 0.015, green: 0.015, blue: 0.018))
    }

    // MARK: - Persistent top band

    @ViewBuilder
    private var topBar: some View {
        if model.geometry.hasPhysicalNotch {
            earsBar
        } else {
            standardBar
        }
    }

    /// On a real notch the pill center is dead space; content lives in the
    /// side ears and the activity text waits for the expansion.
    private var eyesExpression: EyeExpression {
        EyeExpression(status: compactSession?.status)
    }

    private var eyesColor: Color {
        statusColor(for: compactSession?.status)
    }

    private var earsBar: some View {
        let earWidth = (model.geometry.collapsedSize.width - (model.geometry.notchWidth ?? 0)) / 2
        return HStack(spacing: 0) {
            MoriEyesView(
                expression: eyesExpression,
                color: eyesColor,
                pointerBias: model.pointerBias,
                celebrateAt: model.celebrationAt,
                winkAt: model.winkAt
            )
            .frame(width: 24, height: 14)
            .frame(width: max(earWidth, 34))
            Spacer(minLength: 0)
            Text("\(activeSessionCount)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: max(earWidth, 34))
        }
        .frame(height: model.geometry.collapsedSize.height)
    }

    private var standardBar: some View {
        HStack(spacing: 12) {
            MoriEyesView(
                expression: eyesExpression,
                color: eyesColor,
                pointerBias: model.pointerBias,
                celebrateAt: model.celebrationAt,
                winkAt: model.winkAt
            )
            .frame(width: 26, height: 15)

            Text(model.isExpanded ? headerText : activityTitle)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(liveSessions.isEmpty ? 0.45 : 0.78))
                .lineLimit(1)

            Spacer(minLength: 12)

            if !model.isExpanded {
                HStack(spacing: 12) {
                    if let pill = pillQuota {
                        Text("\(Int(pill.usedFraction * 100))%")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(
                                pill.usedFraction >= 0.8
                                    ? Color(red: 1, green: 0.45, blue: 0.3).opacity(0.9)
                                    : .white.opacity(0.45)
                            )
                    }
                    Text("\(activeSessionCount)")
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 24, height: 19)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(.white.opacity(0.08))
                        )
                }
                .transition(.opacity)
            } else if model.pendingInteractions.isEmpty {
                viewToggles
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: model.geometry.collapsedSize.height)
    }

    // MARK: - Expanded body

    private var expandedBody: some View {
        VStack(spacing: 12) {
            Button("") {
                model.setExpanded(false)
            }
            .keyboardShortcut(.escape, modifiers: [])
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            if model.geometry.hasPhysicalNotch {
                HStack {
                    Text(headerText)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer()
                    if model.pendingInteractions.isEmpty {
                        viewToggles
                    }
                }
            }
            if let interaction = model.pendingInteractions.first {
                quotaSection
                InteractionView(
                    model: model,
                    interaction: interaction,
                    queueCount: model.pendingInteractions.count
                )
                .id(interaction.id)
                sessionSection
            } else {
                quotaSection
                sessionSection
            }
            footer
        }
        .padding(.top, 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    /// Stats moved to the full Mission Control app; the notch stays a quick
    /// glance + approve surface.
    private var viewToggles: some View {
        EmptyView()
    }

    private func toggleIcon(
        _ symbol: String,
        tab: AppModel.ExpandedTab,
        active: Color,
        help: String
    ) -> some View {
        let isOn = model.expandedTab == tab
        return Button {
            model.expandedTab = isOn ? .now : tab
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? active : .white.opacity(0.45))
                .frame(width: 26, height: 19)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.white.opacity(isOn ? 0.12 : 0.06))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var quotaSection: some View {
        if !relevantQuotas.isEmpty {
            QuotaStripView(quotas: relevantQuotas)
        }
    }

    /// Top of the tree: sessions without a live parent. Orphaned subagents
    /// surface here instead of disappearing.
    private var topLevelLive: [AgentSession] {
        liveSessions.filter { session in
            session.parentId == nil
                || !liveSessions.contains { $0.id == session.parentId }
        }
    }

    private func liveChildren(of session: AgentSession) -> [AgentSession] {
        liveSessions.filter { $0.parentId == session.id }
    }

    private func allChildren(of session: AgentSession) -> [AgentSession] {
        model.sessions.filter { $0.parentId == session.id }
    }

    private func childSummary(of session: AgentSession) -> String? {
        let all = model.sessions.filter { $0.parentId == session.id }
        guard !all.isEmpty else { return nil }
        let done = all.filter { $0.status == .completed }.count
        return "\(done)/\(all.count) sub"
    }

    /// Every session is a dense single-line row — the minimal look, whether one
    /// agent runs or fifty. Attention pins to the top by sort order; subagents
    /// roll up under their parent. (Restore `liveSessions.count > 6` here to
    /// bring back the richer primary card below that count.)
    private var isSwarm: Bool { true }

    private var sessionSection: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            VStack(spacing: isSwarm ? 4 : 7) {
                if liveSessions.isEmpty {
                    recapSection
                } else if !model.pendingInteractions.isEmpty {
                    ForEach(Array(liveSessions.prefix(2))) { session in
                        SwarmRow(
                            session: session,
                            now: timeline.date,
                            childSummary: childSummary(of: session),
                            canJump: !model.isHeadless(session)
                        ) {
                            model.focus(session)
                        }
                    }
                } else if isSwarm {
                    swarmList(now: timeline.date)
                } else {
                    calmList(now: timeline.date)
                }
            }
        }
    }

    @ViewBuilder
    private func calmList(now: Date) -> some View {
        let topLevel = topLevelLive
        if let primary = topLevel.first {
            PrimarySessionCard(
                session: primary,
                now: now,
                childSummary: childSummary(of: primary),
                canJump: !model.isHeadless(primary),
                onJump: { model.focus(primary) }
            )
            subagentRows(of: primary, now: now)
        }
        ForEach(Array(topLevel.dropFirst().prefix(showAllSessions ? 12 : 4))) { session in
            SessionRow(
                session: session,
                now: now,
                childSummary: childSummary(of: session),
                canJump: !model.isHeadless(session),
                onJump: { model.focus(session) }
            )
            subagentRows(of: session, now: now)
        }
        showAllButton(total: topLevel.count, threshold: 5)
    }

    @ViewBuilder
    private func swarmList(now: Date) -> some View {
        let topLevel = topLevelLive
        ForEach(Array(topLevel.prefix(showAllSessions ? 24 : 10))) { session in
            SwarmRow(
                session: session,
                now: now,
                childSummary: childSummary(of: session),
                canJump: !model.isHeadless(session)
            ) {
                model.focus(session)
            }
            subagentRows(of: session, now: now)
        }
        showAllButton(total: topLevel.count, threshold: 10)
    }

    /// The day's recap fills the quiet moments: what got done, what it cost.
    @ViewBuilder
    private var recapSection: some View {
        let done = doneToday.sorted { $0.updatedAt > $1.updatedAt }
        if done.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                Text("Waiting for agents on the local bridge")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("TODAY")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                    Spacer()
                    Text(quietSummary)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
                ForEach(Array(done.prefix(5))) { session in
                    HStack(spacing: 7) {
                        Image(systemName: session.status == .failed ? "xmark" : "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(session.status == .failed
                                ? Color(red: 1, green: 0.28, blue: 0.28).opacity(0.8)
                                : Color(red: 0.35, green: 0.95, blue: 0.64).opacity(0.7))
                        Text(recapTitle(session))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let cost = session.equivalentCostUSD {
                            Text(cost, format: .currency(code: "USD"))
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.03))
            )
        }
    }

    private func recapTitle(_ session: AgentSession) -> String {
        let project = projectName(session)
        guard let headline = session.prompt?
            .split(separator: "\n").first.map(String.init), !headline.isEmpty else {
            return project
        }
        return "\(project) · \(headline)"
    }

    @ViewBuilder
    private func subagentRows(of session: AgentSession, now: Date) -> some View {
        let children = allChildren(of: session)
        if !children.isEmpty {
            SubagentSection(children: children, now: now)
        }
    }

    @ViewBuilder
    private func showAllButton(total: Int, threshold: Int) -> some View {
        if total > threshold {
            Button {
                showAllSessions.toggle()
            } label: {
                Text(showAllSessions ? "Show fewer" : "Show all \(total) sessions")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
        }
    }

    private var quietSummary: String {
        guard !doneToday.isEmpty else { return "Waiting for agents on the local bridge" }
        let cost = doneToday.compactMap(\.equivalentCostUSD).reduce(0, +)
        let base = doneToday.count == 1 ? "All quiet · 1 session done today" : "All quiet · \(doneToday.count) sessions done today"
        guard cost > 0 else { return base }
        return base + " · API eq. " + cost.formatted(.currency(code: "USD"))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Label("Local only", systemImage: "lock.fill")
            if !model.hooksInstalled {
                Label("hooks missing · run notchflow-install", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.28).opacity(0.85))
            }
            Spacer()
            if equivalentCost > 0 {
                let incomplete = model.sessions.contains { $0.costIncomplete == true }
                Text("API eq. \(incomplete ? "≥ " : "")\(equivalentCost, format: .currency(code: "USD"))")
                    .contentTransition(.numericText())
                    .animation(.spring(response: 0.5), value: equivalentCost)
                    .help("Equivalent API list price; not an additional subscription charge")
            }
        }
        .font(.system(size: 10, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.38))
    }

    // MARK: - Derived state

    private var equivalentCost: Double {
        model.sessions.compactMap(\.equivalentCostUSD).reduce(0, +)
    }

    /// The hover only ever shows sessions that still matter; finished work
    /// belongs to the day summary and, later, the Stats screen. An idle
    /// headless session matters to nobody: it cannot be jumped to and is
    /// doing nothing, so it only earns a row while actually working.
    private var liveSessions: [AgentSession] {
        model.sessions.filter { session in
            let live = session.status == .working || session.status == .runningTool
                || session.status == .waitingPermission || session.status == .idle
            guard live else { return false }
            if session.status == .idle, model.isHeadless(session) { return false }
            return true
        }
    }

    private var activeSessions: [AgentSession] {
        liveSessions.filter { $0.status != .idle }
    }

    private var activeSessionCount: Int { activeSessions.count }

    private var compactSession: AgentSession? {
        liveSessions.first
    }

    /// The brand color of whoever is currently in front, so the pill's border
    /// and glow carry an at-a-glance identity.
    private var activeAgentColor: Color { compactSession.map { agentColor($0.agent) } ?? .white }

    private var doneToday: [AgentSession] { model.doneToday }

    /// One quota for the pill: the provider currently working, else the
    /// hottest known window.
    private var pillQuota: QuotaState? {
        if let provider = compactSession?.agent,
           let quota = model.quotas.first(where: { $0.provider == provider }) {
            return quota
        }
        return model.hottestQuota
    }

    /// Hover shows the active provider's quota; anything else only intrudes
    /// past 80%. The full picture belongs to Stats.
    private var relevantQuotas: [QuotaState] {
        let primaryProvider = compactSession?.agent
        var rows = model.quotas.filter { quota in
            quota.provider == primaryProvider || quota.usedFraction >= 0.8
        }
        if rows.isEmpty, let hottest = model.hottestQuota {
            rows = [hottest]
        }
        return rows
    }

    /// Live activity, not the original prompt: this is what makes the
    /// collapsed island worth glancing at.
    private var activityTitle: String {
        if let wedged = liveSessions.first(where: { $0.stuckReason != nil }) {
            let project = wedged.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? wedged.agent.displayName
            return "stuck · \(project) · \(wedged.stuckReason ?? "")"
        }
        let attention = liveSessions.filter { $0.status == .waitingPermission }.count
        if activeSessionCount > 3 {
            return attention > 0
                ? "\(activeSessionCount) agents · \(attention) need you"
                : "\(activeSessionCount) agents running"
        }
        guard let session = compactSession else {
            let done = doneToday.count
            return done > 0 ? "quiet · \(done) done today" : "waiting for agents"
        }
        switch session.status {
        case .runningTool:
            let text = [session.tool, shortDetail(session)].compactMap { $0 }.joined(separator: " · ")
            return text.isEmpty ? "running a tool" : text
        case .working:
            return "thinking…"
        case .waitingPermission:
            return "needs you · \(session.tool ?? "permission")"
        case .idle:
            return "ready for you · \(projectName(session))"
        case .completed:
            return "done · \(projectName(session))"
        case .failed:
            return "failed · \(projectName(session))"
        }
    }

    /// Paths shrink to their basename and commands to their first words, so
    /// the narrow pill shows the meaningful part.
    private func shortDetail(_ session: AgentSession) -> String? {
        guard var text = session.detail else { return nil }
        if text.contains("/"), !text.contains(" ") {
            text = URL(fileURLWithPath: text).lastPathComponent
        }
        return String(text.prefix(46))
    }

    private var headerText: String {
        let attention = liveSessions.filter { $0.status == .waitingPermission }.count
        let stuck = liveSessions.filter { $0.stuckReason != nil }.count
        let active = liveSessions.filter { $0.status == .working || $0.status == .runningTool }.count
        let ready = liveSessions.filter { $0.status == .idle && $0.parentId == nil }.count
        var parts: [String] = []
        if active > 0 { parts.append("\(active) working") }
        if ready > 0 { parts.append("\(ready) ready") }
        if stuck > 0 { parts.append("\(stuck) stuck") }
        if attention > 0 { parts.append("\(attention) need you") }
        return parts.isEmpty ? "all quiet" : parts.joined(separator: " · ")
    }

    private func projectName(_ session: AgentSession) -> String {
        guard let cwd = session.cwd else { return session.agent.displayName }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

}

// MARK: - Attention ping halo

/// A single soft ring that blooms and fades in 0.6s the moment the model asks
/// for attention. It lives behind the pill and outside the clip so it can
/// spill past the edge like a pulse rather than a contained outline.
private struct HaloView: View {
    let pingAt: Date?
    let status: SessionStatus?
    let shape: NotchShape

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = pingAt.map { timeline.date.timeIntervalSince($0) } ?? .infinity
            let alive = elapsed >= 0 && elapsed < 0.6
            let decay = max(0, 1 - elapsed / 0.6)
            shape
                .stroke(statusColor(for: status), lineWidth: 3)
                .blur(radius: 4)
                .scaleEffect(CGFloat(1 + 0.6 * decay))
                .opacity(alive ? decay : 0)
        }
        .allowsHitTesting(false)
    }
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

/// One dense, readable line per provider: bold window names, percentage in
/// the health color, reset time dimmed. Modeled on what actually reads well
/// at a glance instead of a boxed table.
struct QuotaStripView: View {
    let quotas: [QuotaState]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(quotas, id: \.provider) { quota in
                HStack(spacing: 7) {
                    Circle()
                        .fill(agentColor(quota.provider))
                        .frame(width: 5, height: 5)
                    if quota.authProblem == true {
                        Text("signed out · run \(quota.provider.rawValue) to re-login")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.28))
                    } else {
                        windowsView(for: quota)
                        if quota.isStale() {
                            Text("old data")
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.28).opacity(0.8))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func windowsView(for quota: QuotaState) -> some View {
        let windows: [(String, QuotaWindow)] = [
            quota.primary.map { (label(minutes: $0.durationMinutes, fallback: "5h"), $0) },
            quota.secondary.map { (label(minutes: $0.durationMinutes, fallback: "7d"), $0) }
        ].compactMap { $0 }
        HStack(spacing: 6) {
            ForEach(Array(windows.enumerated()), id: \.offset) { index, entry in
                if index > 0 {
                    Text("|")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.18))
                }
                HStack(spacing: 4) {
                    Text(entry.0)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("\(Int((entry.1.usedFraction * 100).rounded()))%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(usageColor(entry.1.usedFraction))
                    if let reset = entry.1.resetsAt {
                        Text(remaining(until: reset))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }
        }
    }

    private func label(minutes: Int?, fallback: String) -> String {
        guard let minutes else { return fallback }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return fallback
    }

    private func remaining(until reset: Date) -> String {
        let seconds = max(0, Int(reset.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 { return "\(days)d\(hours)h" }
        let minutes = (seconds % 3_600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }
}

// MARK: - Quota row

struct QuotaRow: View {
    let quota: QuotaState

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(heatColor)
                .frame(width: 5, height: 5)
            Text(quota.provider.displayName)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
            if let plan = quota.planName {
                Text(plan.capitalized)
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(.white.opacity(0.08)))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 8)
            Text(windowsLabel)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(quota.isStale() ? 0.3 : 0.66))
            if quota.isStale() {
                Text("STALE")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
    }

    private var heatColor: Color {
        let tone = QuotaTone.forUsage(quota.usedFraction)
        return Color(
            red: max(tone.red, 0.35),
            green: max(tone.green, 0.35 * (1 - quota.usedFraction)),
            blue: 0.3
        )
    }

    private var windowsLabel: String {
        let windows = [quota.primary, quota.secondary].compactMap { $0 }
        guard !windows.isEmpty else { return "--" }
        return windows.map { window in
            let duration: String
            if let minutes = window.durationMinutes, minutes % 1_440 == 0 {
                duration = "\(minutes / 1_440)d"
            } else if let minutes = window.durationMinutes, minutes % 60 == 0 {
                duration = "\(minutes / 60)h"
            } else {
                duration = "w"
            }
            let percent = "\(Int((window.usedFraction * 100).rounded()))%"
            guard let reset = window.resetsAt else { return "\(duration) \(percent)" }
            return "\(duration) \(percent) ↻\(remainingLabel(until: reset))"
        }
        .joined(separator: "  ·  ")
    }

    private func remainingLabel(until reset: Date) -> String {
        let seconds = max(0, Int(reset.timeIntervalSinceNow))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 { return "\(days)d\(hours)h" }
        let minutes = (seconds % 3_600) / 60
        return hours > 0 ? "\(hours)h\(minutes)m" : "\(minutes)m"
    }
}

// MARK: - Interaction

/// A brief green receipt stamped over the request the instant it is allowed,
/// so a decision made from the island feels acknowledged rather than silent.
private struct ApprovalReceipt: View {
    let flashAt: Date?
    @State private var visible = false

    private static let green = Color(red: 0.2, green: 0.72, blue: 0.46)
    private static let window: TimeInterval = 0.55

    var body: some View {
        ZStack {
            if visible {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Self.green.opacity(0.18))
                    .overlay(
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Self.green)
                    )
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .onAppear { trigger() }
        .onChange(of: flashAt) { _, _ in trigger() }
    }

    private func trigger() {
        guard let flashAt else { return }
        let age = Date().timeIntervalSince(flashAt)
        guard age >= 0, age < Self.window else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { visible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, Self.window - age)) {
            withAnimation(.easeOut(duration: 0.25)) { visible = false }
        }
    }
}

private struct InteractionView: View {
    @ObservedObject var model: AppModel
    let interaction: PendingInteraction
    let queueCount: Int
    @State private var answers: [String: String] = [:]
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(interaction.request.title, systemImage: icon)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                    if let source = sourceLabel {
                        Text(source)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if queueCount > 1 {
                    Text("1 of \(queueCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(accent.opacity(0.18)))
                        .foregroundStyle(accent)
                }
            }

            if isForm {
                stepProgress
                if let detail = interaction.request.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineSpacing(2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                questionView(currentQuestion)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .frame(maxWidth: .infinity, alignment: .leading)
                formControls
            } else {
                if isLongForm {
                    ScrollView {
                        interactionBody
                    }
                    .frame(height: 288)
                } else {
                    interactionBody
                }

                if isTapToAnswer {
                    // Clicking an option already answers; the only remaining
                    // action is declining, and it does not deserve a slab.
                    HStack {
                        Spacer()
                        Button("Deny") {
                            model.resolve(interaction, action: .deny)
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4).opacity(0.85))
                    }
                } else {
                    HStack(spacing: 10) {
                        Button("Deny") {
                            model.resolve(interaction, action: .deny)
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .buttonStyle(DecisionButtonStyle(color: .red.opacity(0.8)))

                        Button(allowTitle) {
                            model.resolve(interaction, action: .allow, answers: answers)
                        }
                        .keyboardShortcut("y", modifiers: .command)
                        .buttonStyle(DecisionButtonStyle(color: Color(red: 0.20, green: 0.72, blue: 0.46)))
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.045))
        )
        .overlay {
            ApprovalReceipt(flashAt: model.resolvedFlashAt)
                .allowsHitTesting(false)
        }
        .animation(stepAnimation, value: step)
    }

    private var interactionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail = interaction.request.detail, !detail.isEmpty {
                if interaction.request.kind == .plan {
                    planDocument(detail)
                } else {
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(interaction.request.questions) { question in
                questionView(question)
            }
        }
    }

    /// The plan reads as a document, not a wall: a padded, bordered card with
    /// real line spacing and a legible rounded face instead of dense body text.
    private func planDocument(_ detail: String) -> some View {
        Text(renderedMarkdown(detail))
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.86))
            .lineSpacing(4)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.black.opacity(0.22))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.06), lineWidth: 1)
            )
    }

    private func renderedMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }

    /// Plans and multi-question forms scroll inside a fixed viewport; short
    /// prompts lay out naturally. A bare ScrollView has no intrinsic height
    /// and collapses to zero inside the island's VStack.
    private var isLongForm: Bool {
        if interaction.request.kind == .plan { return true }
        let optionCount = interaction.request.questions.reduce(0) { $0 + max($1.options.count, 1) }
        return optionCount + interaction.request.questions.count > 7
    }

    @ViewBuilder
    private func questionView(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = question.header {
                Text(header.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
            }
            Text(question.question)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if question.options.isEmpty {
                TextField("Type an answer", text: answerBinding(for: question.question))
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.07)))
            } else {
                let hasShortcuts = isForm ? true : (interaction.request.questions.first?.id == question.id)
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    InteractionOptionRow(
                        option: option,
                        isMulti: question.multiSelect,
                        isSelected: isSelected(option.label, for: question),
                        shortcutHint: hasShortcuts && index < 9 ? "⌘\(index + 1)" : nil,
                        accent: accent
                    ) {
                        choose(option: option.label, for: question)
                    }
                    .modifier(OptionShortcut(enabled: hasShortcuts, index: index))
                }
            }
        }
    }

    /// One question, one choice: the tap IS the answer.
    private var isTapToAnswer: Bool {
        interaction.request.kind == .question
            && interaction.request.questions.count == 1
            && interaction.request.questions.first?.multiSelect == false
            && !(interaction.request.questions.first?.options.isEmpty ?? true)
    }

    private func choose(option: String, for question: AgentQuestion) {
        if question.multiSelect {
            toggle(option: option, for: question)
            return
        }
        answers[question.question] = option
        if isForm {
            // Single-select in a multi-question wizard: record and advance,
            // or submit everything on the last step.
            if isLastStep {
                model.resolve(interaction, action: .allow, answers: answers)
            } else {
                step += 1
            }
        } else {
            // One single-select question: the tap IS the answer.
            model.resolve(interaction, action: .allow, answers: [question.question: option])
        }
    }

    private func answerBinding(for question: String) -> Binding<String> {
        Binding(
            get: { answers[question, default: ""] },
            set: { answers[question] = $0 }
        )
    }

    private func isSelected(_ option: String, for question: AgentQuestion) -> Bool {
        if !question.multiSelect { return answers[question.question] == option }
        return selectedOptions(for: question).contains(option)
    }

    private func toggle(option: String, for question: AgentQuestion) {
        guard question.multiSelect else {
            answers[question.question] = option
            return
        }
        var selected = selectedOptions(for: question)
        if selected.contains(option) {
            selected.remove(option)
        } else {
            selected.insert(option)
        }
        answers[question.question] = question.options
            .map(\.label)
            .filter(selected.contains)
            .joined(separator: ", ")
    }

    private func selectedOptions(for question: AgentQuestion) -> Set<String> {
        Set((answers[question.question] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private var canSubmit: Bool {
        interaction.request.questions.allSatisfy {
            !(answers[$0.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Which terminal this request came from, so two questions at once are
    /// never answered blind. Project first, then the host terminal.
    private var sourceLabel: String? {
        guard let session = model.sessions.first(where: { $0.id == interaction.sessionId }) else {
            return nil
        }
        let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let program = TerminalCatalog.program(fromTerminalIdentity: session.terminal)
        let parts = [project, program].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var icon: String {
        switch interaction.request.kind {
        case .permission: return "exclamationmark.shield.fill"
        case .question: return "questionmark.bubble.fill"
        case .plan: return "doc.text.fill"
        }
    }

    private var accent: Color {
        interaction.request.kind == .question
            ? Color(red: 0.45, green: 0.65, blue: 1)
            : Color(red: 1, green: 0.58, blue: 0.24)
    }

    private var allowTitle: String {
        guard interaction.request.kind == .question else { return "Allow" }
        let remaining = interaction.request.questions.filter {
            (answers[$0.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        if interaction.request.questions.count > 1, remaining > 0 {
            return "Answer · \(remaining) left"
        }
        return "Answer"
    }

    // MARK: - Multi-question wizard

    /// More than one question becomes a step-by-step wizard — one question at a
    /// time, answer-and-advance — instead of a scroll of stacked questions.
    private var isForm: Bool {
        interaction.request.kind == .question && interaction.request.questions.count > 1
    }

    private var questions: [AgentQuestion] { interaction.request.questions }

    private var currentQuestion: AgentQuestion {
        questions[min(step, max(questions.count - 1, 0))]
    }

    private var isLastStep: Bool { step >= questions.count - 1 }

    private var currentAnswered: Bool {
        !(answers[currentQuestion.question] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Single-select advances on tap, so it needs no button; multi-select and
    /// free text need an explicit Next/Answer, as does a revisited answer.
    private var showAdvanceButton: Bool {
        currentQuestion.multiSelect || currentQuestion.options.isEmpty || currentAnswered
    }

    private var stepAnimation: Animation { .spring(response: 0.34, dampingFraction: 0.82) }

    private func advanceOrSubmit() {
        if isLastStep {
            if canSubmit { model.resolve(interaction, action: .allow, answers: answers) }
        } else {
            step += 1
        }
    }

    /// One dot per question, the current one elongated, so how many steps are
    /// left is always visible.
    private var stepProgress: some View {
        HStack(spacing: 7) {
            Text("Question \(step + 1) of \(questions.count)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 4) {
                ForEach(0..<questions.count, id: \.self) { index in
                    Capsule()
                        .fill(index == step
                            ? accent
                            : (index < step ? accent.opacity(0.5) : .white.opacity(0.15)))
                        .frame(width: index == step ? 14 : 6, height: 4)
                }
            }
            Spacer()
        }
    }

    private var formControls: some View {
        HStack(spacing: 10) {
            if step > 0 {
                Button { step -= 1 } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button("Deny") { model.resolve(interaction, action: .deny) }
                .keyboardShortcut("n", modifiers: .command)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4).opacity(0.85))
            if showAdvanceButton {
                Button { advanceOrSubmit() } label: {
                    Text(isLastStep ? "Answer" : "Next")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(red: 0.20, green: 0.72, blue: 0.46)
                                    .opacity(currentAnswered ? 1 : 0.35))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!currentAnswered)
            }
        }
    }
}

private struct InteractionOptionRow: View {
    let option: QuestionOption
    let isMulti: Bool
    let isSelected: Bool
    let shortcutHint: String?
    let accent: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                // Every option shows its state: a radio for single-select, a
                // checkbox for multi. Without this a single-select tap changed
                // nothing on screen and read as a dead click.
                Image(systemName: indicatorSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : .white.opacity(0.35))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                    if let description = option.description {
                        Text(description)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(hovered ? 0.45 : 0.25))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.18) : .white.opacity(hovered ? 0.1 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.75) : .white.opacity(hovered ? 0.14 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var indicatorSymbol: String {
        if isMulti { return isSelected ? "checkmark.square.fill" : "square" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }
}

private struct OptionShortcut: ViewModifier {
    let enabled: Bool
    let index: Int

    func body(content: Content) -> some View {
        if enabled, index < 9,
           let key = "\(index + 1)".first {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}

private struct DecisionButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(configuration.isPressed ? 0.65 : 1)))
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.35)
    }
}

// MARK: - Primary session card

/// The session that matters most right now, with enough context to skip the
/// terminal: original prompt, current action and the last few tools it ran.
private struct PrimarySessionCard: View {
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
private struct SwarmRow: View {
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
private struct SubagentSection: View {
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

private struct SessionRow: View {
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
