import AppKit
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
                switch model.expandedTab {
                case .stats:
                    StatsView(usage: model.usage)
                case .now:
                    quotaSection
                    sessionSection
                }
            }
            footer
        }
        .padding(.top, 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
    }

    /// Stats hides behind one quiet icon in the top band instead of a tab bar;
    /// Now is the default.
    private var viewToggles: some View {
        toggleIcon(
            "chart.bar.xaxis",
            tab: .stats,
            active: Color(red: 0.55, green: 0.78, blue: 0.95),
            help: "Stats"
        )
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

    /// The now strip shows a quota for every provider you have running — both
    /// Claude and Codex when both are open — plus any provider past 80% even if
    /// idle, so a nearly-spent window never hides. Falls back to the hottest.
    private var relevantQuotas: [QuotaState] {
        QuotaVisibility.relevant(
            all: model.quotas,
            liveProviders: Set(liveSessions.map(\.agent)),
            hottest: model.hottestQuota
        )
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
