import AppKit
import Foundation
import NotchFlowCore
import os

public struct NotchGeometry: Equatable {
    public var collapsedSize: CGSize
    public var hasPhysicalNotch: Bool
    public var notchWidth: CGFloat?

    public init(collapsedSize: CGSize, hasPhysicalNotch: Bool, notchWidth: CGFloat?) {
        self.collapsedSize = collapsedSize
        self.hasPhysicalNotch = hasPhysicalNotch
        self.notchWidth = notchWidth
    }

    public static let fallback = NotchGeometry(
        collapsedSize: CGSize(width: 344, height: 33),
        hasPhysicalNotch: false,
        notchWidth: nil
    )
}

@MainActor
public final class AppModel: ObservableObject {
    @Published public private(set) var sessions: [AgentSession] = []
    @Published public private(set) var quotas: [QuotaState] = []
    @Published private(set) var hottestQuota: QuotaState?
    @Published private(set) var isExpanded = false
    @Published public private(set) var pendingInteractions: [PendingInteraction] = []
    @Published private(set) var hooksInstalled = true
    @Published public var geometry = NotchGeometry.fallback {
        didSet { hitTestState = (isExpanded, geometry.collapsedSize) }
    }
    /// Mirror of (isExpanded, collapsed size) read synchronously by the
    /// panel's hitTest on the main thread for click passthrough. Kept
    /// deterministic on purpose: a stale SwiftUI-reported frame once made
    /// every click fall through.
    nonisolated(unsafe) public private(set) var hitTestState: (expanded: Bool, collapsedSize: CGSize) = (false, .zero)
    /// Island top-center in global screen coordinates, for pointer gaze.
    public var islandAnchor: CGPoint = .zero
    @Published private(set) var pointerBias: CGPoint = .zero
    /// Bumped when a real turn finishes, so the pill eyes celebrate.
    @Published private(set) var celebrationAt: Date?
    @Published private(set) var pingAt: Date?
    @Published private(set) var pingStatus: SessionStatus?
    @Published private(set) var resolvedFlashAt: Date?
    @Published private(set) var winkAt: Date?
    @Published var expandedTab: ExpandedTab = .now
    @Published var quietMode = UserDefaults.standard.bool(forKey: "quiet.enabled") {
        didSet { UserDefaults.standard.set(quietMode, forKey: "quiet.enabled") }
    }
    public let usage = UsageStore()
    let sounds = ChipTune()
    private let notifier = Notifier()
    private let voice = Voice()

    /// What the notch says for each interaction that opens it — the only
    /// moments it speaks. Kept in one place so it can be pre-rendered on launch.
    static let voiceLines: [InteractionKind: String] = [
        .question: "Hey, I have a question for you.",
        .plan: "I've got a plan for you to look at.",
        .permission: "Can I get your go-ahead on something?"
    ]

    enum ExpandedTab {
        case now
        case stats
    }

    var doneToday: [AgentSession] {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return sessions.filter {
            ($0.status == .completed || $0.status == .failed) && $0.updatedAt >= startOfDay
        }
    }

    public var onLayoutChanged: ((Bool) -> Void)?
    private static let logger = Logger(subsystem: "app.notchflow", category: "model")
    private var reducer = SessionReducer()
    private let codexMonitor = CodexQuotaMonitor()
    private let codexRollouts = CodexRolloutMonitor()
    private let claudeTranscripts = ClaudeTranscriptMonitor()
    private let claudeMonitor = ClaudeQuotaMonitor()
    private var saveTask: Task<Void, Never>?
    private var hoverExpandTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var maintenanceTimer: Timer?
    private var pointerMonitors: [Any] = []
    private var lastPointerUpdate = Date.distantPast
    private var livenessTimer: Timer?
    private var livenessMisses: [String: Int] = [:]
    private var liveCostTimer: Timer?
    private var lastWatchdogAlert: [String: Date] = [:]
    private var liveCostRunning = false

    public init() {
        hitTestState = (false, NotchGeometry.fallback.collapsedSize)
        loadSnapshot()
        refreshHooksInstalled()
        // Render the fixed lines to the on-disk cache now, so the first time the
        // notch needs to speak there is no synthesis wait. One-time cost across
        // all launches — the WAVs persist.
        if PluginManager.shared.isOn("voice") {
            voice.prewarm(Array(Self.voiceLines.values))
        }
    }

    // MARK: - Live services

    public func startLiveServices() {
        codexMonitor.start { [weak self] quota in
            if let quota { self?.applyQuota(quota) }
        }
        claudeMonitor.start { [weak self] quota in
            if let quota { self?.applyQuota(quota) }
        }
        codexRollouts.start { [weak self] events in
            Task { @MainActor in self?.applyBatch(events) }
        }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.runMaintenance() }
        }
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLiveness(); self?.runWatchdog() }
        }
        notifier.onTap = { [weak self] sessionId in
            Task { @MainActor in self?.focusSession(id: sessionId) }
        }
        liveCostTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLiveCosts() }
        }
        reconcileTranscriptFloor()
    }

    /// The transcript floor is the no-hooks monitor: run it only while the
    /// hooks are absent, so an installed setup keeps its richer hook path
    /// and there is never a double source for the same session.
    private func reconcileTranscriptFloor() {
        if hooksInstalled {
            if claudeTranscripts.isRunning { claudeTranscripts.stop() }
        } else if !claudeTranscripts.isRunning {
            claudeTranscripts.start { [weak self] events in
                Task { @MainActor in self?.applyBatch(events) }
            }
        }
    }

    public func stopLiveServices() {
        codexMonitor.stop()
        codexRollouts.stop()
        claudeTranscripts.stop()
        claudeMonitor.stop()
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        livenessTimer?.invalidate()
        livenessTimer = nil
        liveCostTimer?.invalidate()
        liveCostTimer = nil
        saveTask?.cancel()
        saveSnapshotNow()
    }

    private var sdkPidCache: [Int32: Bool] = [:]

    /// SDK-embedded agents (MORI and friends) run headless: real PID, real
    /// terminal env, but an SDK binary path, and they must not pretend to be
    /// clickable. A transcript-floor session has no PID and no terminal; it
    /// is a genuine session we simply cannot jump to, not a headless robot,
    /// so it stays visible.
    func isHeadless(_ session: AgentSession) -> Bool {
        if session.terminal == "NotchFlow" { return true }
        guard let pid = session.agentPid else { return false }
        if let cached = sdkPidCache[pid] { return cached }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer).lowercased() : ""
        let sdk = path.contains("claude_agent_sdk") || path.contains("_bundled")
        sdkPidCache[pid] = sdk
        return sdk
    }

    /// Alive is not enough: macOS recycles PIDs, so the process must also
    /// still be an agent binary before we trust it as proof of life.
    private func isAgentProcessAlive(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 || errno != ESRCH else { return false }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let path = String(cString: buffer).lowercased()
        return ["claude", "codex", "cursor", "gemini", "opencode"].contains { path.contains($0) }
    }

    private func runMaintenance() {
        reducer.expireSessions()
        publish()
        refreshHooksInstalled()
        reconcileTranscriptFloor()
        scheduleSave()
    }

    /// A session whose agent process vanished is over, no matter what its
    /// last event said. Two consecutive misses avoid pid-check races.
    private func checkLiveness() {
        let live: Set<SessionStatus> = [.working, .runningTool, .waitingPermission, .idle]
        for session in reducer.sessions.values
        where live.contains(session.status) {
            guard let pid = session.agentPid else { continue }
            let gone = !isAgentProcessAlive(pid)
            if !gone {
                livenessMisses[session.id] = 0
                continue
            }
            let misses = (livenessMisses[session.id] ?? 0) + 1
            livenessMisses[session.id] = misses
            if misses >= 2 {
                livenessMisses.removeValue(forKey: session.id)
                apply(AgentEvent(
                    type: .sessionStopped,
                    agent: session.agent,
                    sessionId: session.id,
                    detail: session.detail
                ))
            }
        }
    }

    // MARK: - Pointer gaze

    /// The eyes glance toward the cursor when it wanders near the island.
    public func startPointerTracking() {
        let handle: (NSEvent) -> Void = { [weak self] _ in
            self?.updatePointerBias()
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handle) {
            pointerMonitors.append(global)
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            handle(event)
            return event
        }
        if let local { pointerMonitors.append(local) }
    }

    private func updatePointerBias() {
        let now = Date()
        guard now.timeIntervalSince(lastPointerUpdate) > 0.08 else { return }
        lastPointerUpdate = now
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - islandAnchor.x
        let dyBelow = islandAnchor.y - mouse.y
        var bias = CGPoint.zero
        if abs(dx) < 700, dyBelow > -20, dyBelow < 600 {
            bias = CGPoint(
                x: min(max(dx / 450, -1), 1),
                y: min(max(dyBelow / 450, 0), 1)
            )
        }
        if abs(bias.x - pointerBias.x) > 0.04 || abs(bias.y - pointerBias.y) > 0.04 {
            pointerBias = bias
        }
    }

    // MARK: - Expansion

    func toggleExpanded() {
        setExpanded(!isExpanded)
    }

    func setExpanded(_ expanded: Bool) {
        hoverExpandTask?.cancel()
        collapseTask?.cancel()
        if expanded { usage.refreshIfStale() }
        guard isExpanded != expanded else { return }
        isExpanded = expanded
        hitTestState = (expanded, geometry.collapsedSize)
        if !expanded { expandedTab = .now }
        onLayoutChanged?(expanded)
    }

    func pointerEntered() {
        collapseTask?.cancel()
        guard !isExpanded else { return }
        hoverExpandTask?.cancel()
        hoverExpandTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.setExpanded(true)
        }
    }

    func pointerExited() {
        hoverExpandTask?.cancel()
        guard isExpanded, pendingInteractions.isEmpty else { return }
        scheduleCollapse(after: .milliseconds(600))
    }

    private func scheduleCollapse(after delay: Duration) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.setExpanded(false)
        }
    }

    // MARK: - Events

    func apply(_ event: AgentEvent) {
        applyOne(event, announce: true)
        publish()
        scheduleSave()
    }

    /// Rollout tailing delivers history in bursts; one publish per batch
    /// and no announcements for stale events keep replays silent and cheap.
    func applyBatch(_ events: [AgentEvent]) {
        guard !events.isEmpty else { return }
        let recency = Date().addingTimeInterval(-10)
        for event in events {
            applyOne(event, announce: event.timestamp > recency)
        }
        publish()
        scheduleSave()
    }

    private func applyOne(_ event: AgentEvent, announce: Bool) {
        let previousStatus = reducer.sessions[event.sessionId]?.status
        reducer.apply(event)

        if event.type == .permissionRequested, !isExpanded {
            setExpanded(true)
        }
        // A request answered outside the notch — in the terminal, under
        // foreground suppression — never sends us a response, so its card
        // would linger until the 305s timeout. Once the same session visibly
        // moves on, the request is moot: drop its card without replying.
        if announce, !pendingInteractions.isEmpty {
            switch event.type {
            case .toolStarted, .toolFinished, .turnCompleted,
                 .promptSubmitted, .sessionStopped, .sessionFailed:
                dismissStaleInteractions(sessionId: event.sessionId)
            default:
                break
            }
        }
        if announce {
            announceTransition(event: event, from: previousStatus)
        }
        if event.type == .turnCompleted, event.agent == .claude,
           let path = event.transcriptPath ?? reducer.sessions[event.sessionId]?.transcriptPath {
            scheduleSummaryRefresh(sessionId: event.sessionId, transcriptPath: path)
        }
    }

    private var summaryTasks: [String: Task<Void, Never>] = [:]

    /// The Stop hook reads the transcript before the CLI flushes the final
    /// message, so the closing summary arrives one behind. Re-reading a
    /// moment later fixes the card without blocking the provider.
    private func scheduleSummaryRefresh(sessionId: String, transcriptPath: String) {
        summaryTasks[sessionId]?.cancel()
        summaryTasks[sessionId] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_200))
            guard !Task.isCancelled else { return }
            let summary = await Task.detached(priority: .utility) {
                TranscriptCost.claudeTranscriptSummary(transcriptPath: transcriptPath)
            }.value
            guard let self, let summary else { return }
            self.reducer.applySummary(
                sessionId: sessionId,
                detail: summary.lastAssistantText,
                model: summary.lastModel,
                costUSD: summary.costUSD,
                costIncomplete: summary.unpricedModels.isEmpty ? false : true
            )
            self.publish()
            self.scheduleSave()
        }
    }

    /// While a Claude session works, its transcript keeps growing; re-read
    /// it periodically so the card's cost climbs live instead of only
    /// landing when the turn ends.
    private func refreshLiveCosts() {
        guard !liveCostRunning else { return }
        let candidates = reducer.sessions.values.compactMap { session -> (String, String)? in
            guard session.agent == .claude,
                  session.status == .working || session.status == .runningTool,
                  let path = session.transcriptPath else { return nil }
            return (session.id, path)
        }
        guard !candidates.isEmpty else { return }
        liveCostRunning = true
        Task { [weak self] in
            defer { self?.liveCostRunning = false }
            for (sessionId, path) in candidates {
                let summary = await Task.detached(priority: .utility) {
                    TranscriptCost.claudeTranscriptSummary(transcriptPath: path)
                }.value
                guard let self, let summary else { continue }
                self.reducer.applyLiveCost(
                    sessionId: sessionId,
                    costUSD: summary.costUSD,
                    costIncomplete: summary.unpricedModels.isEmpty ? false : true
                )
            }
            self?.publish()
        }
    }

    /// Sound, voice and notifications only mark the moments that need a
    /// human: ready, permission, failure. Subagents stay quiet; their
    /// parent speaks for them. Quiet mode silences all three.
    private func announceTransition(event: AgentEvent, from previousStatus: SessionStatus?) {
        guard !quietMode,
              let session = reducer.sessions[event.sessionId],
              session.parentId == nil,
              session.status != previousStatus else { return }
        let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "project"
        switch session.status {
        case .idle where previousStatus == .working || previousStatus == .runningTool:
            let stillWorking = reducer.sessions.values.filter { [.working, .runningTool, .waitingPermission].contains($0.status) && $0.parentId == nil }.count
            sounds.play(stillWorking == 0 ? .allDone : .done)
            celebrationAt = Date()
            pingAt = Date()
            pingStatus = .idle
            if !isExpanded, PluginManager.shared.isOn("notifyfocus") {
                notifier.post(title: "\(session.agent.displayName) ready", body: project, sessionId: session.id)
            }
        case .waitingPermission:
            sounds.play(.attention)
            pingAt = Date()
            pingStatus = .waitingPermission
            if !isExpanded, PluginManager.shared.isOn("notifyfocus") {
                notifier.post(
                    title: "\(session.agent.displayName) asks permission",
                    body: session.tool ?? project,
                    sessionId: session.id
                )
            }
        case .failed:
            sounds.play(.fail)
            pingAt = Date()
            pingStatus = .failed
            if PluginManager.shared.isOn("notifyfocus") {
                notifier.post(title: "\(session.agent.displayName) failed", body: project, sessionId: session.id)
            }
        default:
            break
        }
    }

    private func applyQuota(_ newQuota: QuotaState) {
        reducer.applyQuota(newQuota)
        publish()
        scheduleSave()
    }

    private func publish() {
        sessions = reducer.orderedSessions
        quotas = reducer.orderedQuotas
        hottestQuota = reducer.hottestQuota()
    }

    /// The auto-approve contract, pure so it can be exhaustively tested: allow a
    /// request only when it is a permission (never a question or plan), the
    /// plugin is on, and the tool is on the read-only safelist. Anything that can
    /// write, edit, or run a shell must fall through to a human. Case-insensitive.
    nonisolated static func shouldAutoApprove(kind: InteractionKind, tool: String?, autoApproveOn: Bool) -> Bool {
        guard kind == .permission, autoApproveOn, let tool = tool?.lowercased() else { return false }
        return PluginManager.safeTools.contains(tool)
    }

    public func receive(
        _ envelope: BridgeEnvelope,
        respond: @escaping (InteractionDecision) -> Void
    ) {
        apply(envelope.event)
        guard let request = envelope.interaction else { return }

        // Auto-pilot plugin: silently allow read-only tools so parallel agents
        // stop making you babysit reads. Never questions or plans.
        if AppModel.shouldAutoApprove(
            kind: request.kind,
            tool: envelope.event.tool,
            autoApproveOn: PluginManager.shared.isOn("autoapprove")
        ) {
            respond(InteractionDecision(requestId: request.id, action: .allow, answers: [:], message: nil))
            return
        }

        if request.kind == .question, !quietMode {
            sounds.play(.attention)
        }
        // The notch speaks only here — the moments a human is actually needed —
        // never on the ambient per-session ready/fail transitions, so a fleet of
        // agents can't turn it into a chatterbox. The voice plugin gates it off
        // by default, and one line at a time (see Voice) throttles a burst.
        if !quietMode, let line = Self.voiceLines[request.kind] {
            voice.say(line)
        }
        pendingInteractions.removeAll { $0.request.id == request.id }
        pendingInteractions.append(PendingInteraction(
            request: request,
            sessionId: envelope.event.sessionId,
            respond: respond
        ))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(305))
            self?.expireInteraction(id: request.id)
        }
        setExpanded(true)
    }

    public func resolve(
        _ interaction: PendingInteraction,
        action: InteractionAction,
        answers: [String: String] = [:]
    ) {
        interaction.respond(InteractionDecision(
            requestId: interaction.request.id,
            action: action,
            answers: answers,
            message: action == .deny ? "Denied from NotchFlow" : nil
        ))
        if action == .allow {
            if !quietMode { NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now) }
            resolvedFlashAt = Date()
            winkAt = Date()
        }
        pendingInteractions.removeAll { $0.request.id == interaction.request.id }
        reducer.clearAttention(sessionId: interaction.sessionId)
        publish()
        scheduleSave()
        if pendingInteractions.isEmpty {
            scheduleCollapse(after: .seconds(2.6))
        }
    }

    private func expireInteraction(id: String) {
        pendingInteractions.removeAll { $0.request.id == id }
        if pendingInteractions.isEmpty, isExpanded {
            scheduleCollapse(after: .seconds(2))
        }
    }

    /// Drops any pending card for a session that already moved on, without
    /// sending a decision — the answer came from elsewhere (e.g. the terminal).
    private func dismissStaleInteractions(sessionId: String) {
        let before = pendingInteractions.count
        pendingInteractions.removeAll { $0.sessionId == sessionId }
        guard pendingInteractions.count != before else { return }
        if pendingInteractions.isEmpty, isExpanded {
            scheduleCollapse(after: .seconds(2))
        }
    }

    func focusSession(id: String) {
        if let session = reducer.sessions[id] { TerminalFocuser.focus(session: session) }
    }

    /// Idle/stuck watchdog plugin: nudge when a parent agent has been waiting on
    /// a permission too long, or is repeating a failing command.
    private func runWatchdog() {
        guard PluginManager.shared.isOn("watchdog"), !quietMode else { return }
        let now = Date()
        for session in reducer.sessions.values where session.parentId == nil {
            let recentlyAlerted = lastWatchdogAlert[session.id].map { now.timeIntervalSince($0) < 300 } ?? false
            guard !recentlyAlerted else { continue }
            var reason: String?
            if session.status == .waitingPermission, now.timeIntervalSince(session.updatedAt) > 60 {
                reason = "waiting on you"
            } else if let stuck = session.stuckReason {
                reason = stuck
            }
            guard let reason else { continue }
            lastWatchdogAlert[session.id] = now
            let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "agent"
            notifier.post(title: "\(session.agent.displayName) needs attention",
                          body: "\(project) · \(reason)", sessionId: session.id)
            sounds.play(.attention)
            pingAt = now
            pingStatus = .waitingPermission
        }
    }

    func focus(_ session: AgentSession) {
        TerminalFocuser.focus(session: session)
    }

    // MARK: - Hook health

    private func refreshHooksInstalled() {
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: settings),
              let text = String(data: data, encoding: .utf8) else {
            hooksInstalled = false
            return
        }
        hooksInstalled = text.contains("notchflow-hook")
    }

    // MARK: - Persistence

    private var snapshotURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NotchFlow", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private func loadSnapshot() {
        guard let data = try? Data(contentsOf: snapshotURL),
              var snapshot = try? JSONDecoder().decode(AppSnapshot.self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        snapshot.sessions = snapshot.sessions.filter { $0.value.updatedAt >= cutoff }
        for key in snapshot.sessions.keys {
            guard let status = snapshot.sessions[key]?.status else { continue }
            // The process is the truth across restarts, but only for root
            // sessions: a subagent records its parent's PID, so a living
            // process proves nothing about it. Subagents end with their
            // SubagentStop and stay ended.
            let isSubagent = snapshot.sessions[key]?.parentId != nil
            let alive: Bool
            if !isSubagent, let pid = snapshot.sessions[key]?.agentPid {
                alive = isAgentProcessAlive(pid)
            } else {
                alive = false
            }
            if alive, status != .failed {
                snapshot.sessions[key]?.status = .idle
            } else if status == .working || status == .runningTool
                || status == .waitingPermission || status == .idle {
                snapshot.sessions[key]?.status = .completed
            }
        }
        reducer = SessionReducer(sessions: snapshot.sessions, quotas: snapshot.quotas)
        publish()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveSnapshotNow()
        }
    }

    private func saveSnapshotNow() {
        let directory = snapshotURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = AppSnapshot(sessions: reducer.sessions, quotas: reducer.quotas)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: snapshotURL.path
        )
    }
}

private struct AppSnapshot: Codable {
    var sessions: [String: AgentSession]
    var quotas: [AgentKind: QuotaState]
}

public struct PendingInteraction: Identifiable {
    public var id: String { request.id }
    let request: InteractionRequest
    public let sessionId: String
    let respond: (InteractionDecision) -> Void
}
