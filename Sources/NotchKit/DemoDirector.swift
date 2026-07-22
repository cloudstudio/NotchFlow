import AppKit
import Foundation
import NotchFlowCore

/// Drives the real reducer with synthetic events so a recording plays itself.
/// It is a *reel* of scenarios — the cinematic story plus the interaction
/// states that are otherwise hard to stage on cue: a multi-question ask, a plan
/// review, a failure, a swarm. Autoplay walks all of them in a loop; number
/// keys 1–5 jump straight to one; space freezes the frame; r restarts.
///
/// Everything runs on the main actor. Presenter keys are best-effort (they only
/// fire while the panel is key), and autoplay carries the reel either way.
@MainActor
public final class DemoDirector {
    private let model: AppModel

    private var loopTask: Task<Void, Never>?
    private var hotkeyMonitor: Any?
    private var isPaused = false
    /// Set when a request is answered — by a real click or the self-approve
    /// fallback — so a scenario never blocks waiting on a human.
    private var userResolved = false
    /// Where autoplay resumes from; number keys rewrite it and relaunch.
    private var startIndex = 0

    private enum Scenario: CaseIterable {
        case story        // 1: session → tools → fan-out → permission → celebration → Stats
        case question     // 2: a multi-question AskUserQuestion
        case plan         // 3: a plan review
        case failure      // 4: a session that fails
        case swarm        // 5: many concurrent agents
    }

    private let order = Scenario.allCases

    public init(model: AppModel) {
        self.model = model
    }

    // MARK: - Lifecycle

    public func start() {
        guard loopTask == nil else { return }
        installHotkeys()
        model.usage.loadDemo(demoUsage())
        seedQuotas()
        launchLoop()
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        if let hotkeyMonitor {
            NSEvent.removeMonitor(hotkeyMonitor)
            self.hotkeyMonitor = nil
        }
    }

    /// Cancelling makes the running scenario's pending sleep throw, so the old
    /// cycle bails at its next beat instead of racing the fresh one.
    private func jump(to index: Int) {
        startIndex = max(0, index) % order.count
        isPaused = false
        loopTask?.cancel()
        launchLoop()
    }

    private func launchLoop() {
        loopTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // One full pass through every scenario, then STOP (no loop).
            // Press r to replay from the start, or 1–5 to jump to one.
            for step in 0..<self.order.count {
                if Task.isCancelled { return }
                let index = (self.startIndex + step) % self.order.count
                let ok = await self.play(self.order[index])
                if !ok { return }
            }
            self.model.setExpanded(false)
        }
    }

    // MARK: - Presenter keys

    private func installHotkeys() {
        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let keys = event.charactersIgnoringModifiers else { return event }
            switch keys {
            case "1", "2", "3", "4", "5":
                self.jump(to: (Int(keys) ?? 1) - 1)
                return nil
            case "r", "R":
                self.jump(to: 0)
                return nil
            case " ":
                self.isPaused.toggle()
                return nil
            default:
                return event
            }
        }
    }

    private func play(_ scenario: Scenario) async -> Bool {
        switch scenario {
        case .story: return await scenarioStory()
        case .question: return await scenarioQuestion()
        case .plan: return await scenarioPlan()
        case .failure: return await scenarioFailure()
        case .swarm: return await scenarioSwarm()
        }
    }

    // MARK: - Scenario 1 · the story

    private let rootId = "demo-root"
    private let storyCwd = "/Users/you/checkout-web"
    private let terminal = "iTerm.app"

    private func scenarioStory() async -> Bool {
        reset()
        guard await beat(1.0) else { return false }

        // A session wakes up. agentPid stays nil so the liveness check never
        // culls it; a real terminal keeps it visible and jumpable.
        started(rootId, cwd: storyCwd, terminal: terminal)
        guard await beat(2.0) else { return false }

        model.apply(AgentEvent(
            type: .promptSubmitted, agent: .claude, sessionId: rootId,
            detail: "Refactor the checkout to a single-page flow"
        ))
        guard await beat(2.4) else { return false }

        model.apply(AgentEvent(
            type: .toolStarted, agent: .claude, sessionId: rootId,
            tool: "Bash", detail: "npm test"
        ))
        guard await beat(2.4) else { return false }
        model.apply(AgentEvent(type: .toolFinished, agent: .claude, sessionId: rootId))
        guard await beat(1.2) else { return false }

        // Three subagents fan out. Each Task queues a human name the following
        // subagentStarted claims; a tool apiece keeps their cards reading live.
        let subs: [(id: String, name: String, tool: String, detail: String)] = [
            ("demo-sub-1", "Audit payment module", "Grep", "isPaymentAuthorized("),
            ("demo-sub-2", "Migrate the orders table", "Edit", "db/schema/orders.sql"),
            ("demo-sub-3", "Update integration tests", "Grep", "checkout.spec.ts")
        ]
        for sub in subs {
            model.apply(AgentEvent(
                type: .toolStarted, agent: .claude, sessionId: rootId,
                tool: "Task", detail: sub.name
            ))
            guard await beat(0.6) else { return false }
            model.apply(AgentEvent(
                type: .subagentStarted, agent: .claude, sessionId: sub.id,
                parentSessionId: rootId, cwd: storyCwd, terminal: terminal
            ))
            guard await beat(0.5) else { return false }
            model.apply(AgentEvent(
                type: .toolStarted, agent: .claude, sessionId: sub.id,
                parentSessionId: rootId, tool: sub.tool, detail: sub.detail
            ))
            guard await beat(0.8) else { return false }
        }

        model.setExpanded(true)
        guard await beat(4.0) else { return false }

        // The permission moment. receive() auto-expands and plays the chime;
        // a live presenter has ~6s to click Allow before the reel self-approves.
        let requestId = UUID().uuidString
        userResolved = false
        model.receive(BridgeEnvelope(event: AgentEvent(
            type: .permissionRequested, agent: .claude, sessionId: rootId,
            tool: "Bash", detail: "psql < migrations/003_orders.sql"
        ), interaction: InteractionRequest(
            id: requestId, kind: .permission, providerEventName: "PermissionRequest",
            title: "Run database migration?", detail: "psql < migrations/003_orders.sql"
        )), respond: { [weak self] _ in
            Task { @MainActor in self?.userResolved = true }
        })
        guard await waitForAnswer(requestId, upTo: 6.0) else { return false }

        model.setExpanded(true)
        model.apply(AgentEvent(
            type: .toolStarted, agent: .claude, sessionId: rootId,
            tool: "Bash", detail: "psql < migrations/003_orders.sql"
        ))
        guard await beat(2.0) else { return false }

        for sub in subs {
            model.apply(AgentEvent(
                type: .subagentStopped, agent: .claude, sessionId: sub.id,
                parentSessionId: rootId
            ))
            guard await beat(0.6) else { return false }
        }

        // The root wraps the turn: done chime, celebration, running total.
        model.apply(AgentEvent(
            type: .turnCompleted, agent: .claude, sessionId: rootId,
            detail: "Shipped the single-page checkout — 7 files touched.",
            equivalentCostUSD: 3.42
        ))
        guard await beat(1.2) else { return false }

        // The money shot.
        model.setExpanded(true)
        model.expandedTab = .stats
        guard await beat(6.0) else { return false }

        model.setExpanded(false)
        model.expandedTab = .now
        return await beat(2.0)
    }

    // MARK: - Scenario 2 · a multi-question ask

    private func scenarioQuestion() async -> Bool {
        reset()
        let id = "demo-ask"
        started(id, cwd: "/Users/you/web-dashboard", terminal: "WarpTerminal")
        guard await beat(0.6) else { return false }

        let request = InteractionRequest(
            kind: .question,
            providerEventName: "AskUserQuestion",
            title: "Claude asks",
            questions: [
                AgentQuestion(
                    header: "Pagination",
                    question: "How should the new /orders endpoint paginate?",
                    options: [
                        QuestionOption(label: "Cursor-based",
                                       description: "Opaque cursor — stable under inserts, best for infinite scroll"),
                        QuestionOption(label: "Offset / limit",
                                       description: "Simple ?offset=&limit= — easy but drifts on writes"),
                        QuestionOption(label: "Page number",
                                       description: "?page=2 — familiar for a classic table UI")
                    ],
                    multiSelect: false
                ),
                AgentQuestion(
                    header: "Auth",
                    question: "Require an API key on this endpoint?",
                    options: [
                        QuestionOption(label: "Yes — API key"),
                        QuestionOption(label: "Public / no auth")
                    ],
                    multiSelect: false
                )
            ]
        )
        userResolved = false
        model.receive(BridgeEnvelope(event: AgentEvent(
            type: .permissionRequested, agent: .claude, sessionId: id
        ), interaction: request), respond: { [weak self] _ in
            Task { @MainActor in self?.userResolved = true }
        })
        model.setExpanded(true)

        // Give ~9s to click the options (radios must light up) before the reel
        // fills in the first option of each question and submits.
        guard await waitForAnswer(request.id, upTo: 9.0) else { return false }
        if !userResolved,
           let pending = model.pendingInteractions.first(where: { $0.request.id == request.id }) {
            let answers = Dictionary(uniqueKeysWithValues: request.questions.compactMap { q in
                q.options.first.map { (q.question, $0.label) }
            })
            model.resolve(pending, action: .allow, answers: answers)
        }
        return await beat(2.5)
    }

    // MARK: - Scenario 3 · a plan review

    private func scenarioPlan() async -> Bool {
        reset()
        let id = "demo-plan"
        started(id, cwd: "/Users/you/payments-service", terminal: "WarpTerminal")
        guard await beat(0.6) else { return false }

        let plan = """
        ## Plan — Rate-limit the public API

        Protect the checkout + orders endpoints with a token-bucket limiter backed by Redis.

        1. **Middleware** — `middleware/rateLimit.ts`: 100 req/min per API key, sliding window.
        2. **Store** — reuse the existing Redis client; keys `rl:<apiKey>:<window>`.
        3. **Headers** — return `X-RateLimit-Remaining` and `Retry-After` on 429.
        4. **Config** — per-tier limits in `config/limits.ts`, overridable by env:

        ```
        payments-service/
        ├── middleware/rateLimit.ts
        ├── config/limits.ts
        └── test/rateLimit.test.ts
        ```

        **Rollout** — behind `RATE_LIMIT_ENABLED`, default off in dev.
        """
        let request = InteractionRequest(
            kind: .plan, providerEventName: "ExitPlanMode",
            title: "Review plan", detail: plan
        )
        userResolved = false
        model.receive(BridgeEnvelope(event: AgentEvent(
            type: .permissionRequested, agent: .claude, sessionId: id
        ), interaction: request), respond: { [weak self] _ in
            Task { @MainActor in self?.userResolved = true }
        })
        model.setExpanded(true)

        guard await waitForAnswer(request.id, upTo: 10.0) else { return false }
        if !userResolved,
           let pending = model.pendingInteractions.first(where: { $0.request.id == request.id }) {
            model.resolve(pending, action: .allow)
        }
        return await beat(2.5)
    }

    // MARK: - Scenario 4 · a failure

    private func scenarioFailure() async -> Bool {
        reset()
        let id = "demo-fail"
        started(id, cwd: "/Users/you/orders-api", terminal: "iTerm.app")
        guard await beat(0.8) else { return false }
        model.apply(AgentEvent(
            type: .toolStarted, agent: .claude, sessionId: id,
            tool: "Bash", detail: "npm run build"
        ))
        model.setExpanded(true)
        guard await beat(1.6) else { return false }
        model.apply(AgentEvent(
            type: .sessionFailed, agent: .claude, sessionId: id,
            detail: "Build failed: type error in checkout.ts:42"
        ))
        return await beat(6.0)
    }

    // MARK: - Scenario 5 · a swarm

    private func scenarioSwarm() async -> Bool {
        reset()
        // A real fleet: each agent in its own repo, running a specific tool on a
        // real file — mixed models and terminals, the way a busy afternoon looks.
        let fleet: [(project: String, agent: AgentKind, model: String, term: String, tool: String, detail: String)] = [
            ("payments-service", .claude, "claude-opus-4-8", "iTerm.app", "Edit", "src/stripe/webhook.ts"),
            ("web-dashboard", .claude, "claude-sonnet-4-5", "WarpTerminal", "Bash", "pnpm test --filter dashboard"),
            ("orders-api", .codex, "gpt-5-codex", "iTerm.app", "Edit", "internal/orders/handler.go"),
            ("auth-gateway", .claude, "claude-sonnet-4-5", "iTerm.app", "Grep", "verifyJWT("),
            ("notification-worker", .codex, "gpt-5-codex", "WarpTerminal", "Read", "queue/consumer.py"),
            ("data-pipeline", .claude, "claude-opus-4-8", "iTerm.app", "Write", "dags/nightly_rollup.py"),
            ("billing", .codex, "gpt-5-codex", "iTerm.app", "Bash", "cargo build --release"),
            ("search-index", .claude, "claude-sonnet-4-5", "WarpTerminal", "Bash", "rg 'reindex' -l"),
            ("checkout-web", .claude, "claude-sonnet-4-5", "iTerm.app", "Edit", "components/CartSummary.tsx"),
            ("mobile-app", .claude, "claude-opus-4-8", "iTerm.app", "Bash", "xcodebuild -scheme App test")
        ]
        var events: [AgentEvent] = []
        for (index, member) in fleet.enumerated() {
            let id = "swarm-\(index)"
            events.append(AgentEvent(
                type: .sessionStarted, agent: member.agent, sessionId: id,
                cwd: "/Users/you/\(member.project)", terminal: member.term, model: member.model
            ))
            events.append(AgentEvent(
                type: .toolStarted, agent: member.agent, sessionId: id,
                tool: member.tool, detail: member.detail
            ))
        }
        model.applyBatch(events)
        model.setExpanded(true)
        guard await beat(3.5) else { return false }

        // The fleet moves: two finish, one blocks on you — so it reads live.
        model.apply(AgentEvent(type: .toolFinished, agent: .claude, sessionId: "swarm-1"))
        model.apply(AgentEvent(
            type: .turnCompleted, agent: .claude, sessionId: "swarm-1",
            detail: "Dashboard tests green — 142 passing", equivalentCostUSD: 0.61
        ))
        guard await beat(1.6) else { return false }
        model.apply(AgentEvent(type: .toolFinished, agent: .codex, sessionId: "swarm-6"))
        model.apply(AgentEvent(
            type: .turnCompleted, agent: .codex, sessionId: "swarm-6",
            detail: "cargo build finished — release ok", equivalentCostUSD: 0.19
        ))
        guard await beat(1.4) else { return false }
        model.apply(AgentEvent(
            type: .permissionRequested, agent: .claude, sessionId: "swarm-0",
            tool: "Bash", detail: "stripe trigger payment_intent.succeeded"
        ))
        guard await beat(4.0) else { return false }
        return await beat(2.0)
    }

    // MARK: - Helpers

    private func reset() {
        model.demoReset()
        seedQuotas()
    }

    private func started(
        _ id: String, cwd: String, model modelName: String? = "claude-opus-4-8",
        agent: AgentKind = .claude, terminal: String
    ) {
        model.apply(AgentEvent(
            type: .sessionStarted, agent: agent, sessionId: id,
            cwd: cwd, terminal: terminal, model: modelName
        ))
    }

    /// Holds until the request is answered (by a click or by the caller's
    /// self-approve), up to `seconds`. Returns false only if the reel was
    /// cancelled, so the caller can bail.
    private func waitForAnswer(_ requestId: String, upTo seconds: Double) async -> Bool {
        var waited = 0.0
        while waited < seconds, !userResolved, !Task.isCancelled {
            if isPaused {
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }
            try? await Task.sleep(for: .milliseconds(200))
            waited += 0.2
        }
        return !Task.isCancelled
    }

    /// Sleeps one beat, holding the frame while paused. Returns false once the
    /// cycle is cancelled so the caller stops firing the rest of the script.
    private func beat(_ seconds: Double) async -> Bool {
        while isPaused, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(120))
        }
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled
    }

    private func seedQuotas() {
        model.injectQuota(QuotaState(
            provider: .claude,
            primary: QuotaWindow(
                usedFraction: 0.47, durationMinutes: 300,
                resetsAt: Date().addingTimeInterval(2 * 3600 + 13 * 60)
            ),
            secondary: QuotaWindow(
                usedFraction: 0.31, durationMinutes: 10080,
                resetsAt: Date().addingTimeInterval(5 * 86400)
            ),
            planName: "max"
        ))
        model.injectQuota(QuotaState(
            provider: .codex,
            primary: QuotaWindow(
                usedFraction: 0.82, durationMinutes: 300,
                resetsAt: Date().addingTimeInterval(48 * 60)
            ),
            secondary: QuotaWindow(
                usedFraction: 0.55, durationMinutes: 10080,
                resetsAt: Date().addingTimeInterval(4 * 86400)
            ),
            planName: "plus"
        ))
    }

    /// Seven days across three projects and three models. Costs are picked so
    /// the 7-day total reads about $187 and today about $40; token counts scale
    /// off the cost so the "where it goes" breakdown stays plausible.
    private func demoUsage() -> [UsageEvent] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        func day(_ back: Int) -> Date {
            calendar.date(byAdding: .day, value: -back, to: today) ?? today
        }

        let rows: [(Int, String, String, AgentKind, Double)] = [
            (0, "checkout-web", "claude-opus-4-8", .claude, 22.50),
            (0, "notchflow", "claude-sonnet-4-5", .claude, 9.20),
            (0, "orders-api", "gpt-5-codex", .codex, 8.30),
            (1, "checkout-web", "claude-opus-4-8", .claude, 18.00),
            (1, "notchflow", "claude-sonnet-4-5", .claude, 7.00),
            (1, "orders-api", "gpt-5-codex", .codex, 6.00),
            (2, "checkout-web", "claude-opus-4-8", .claude, 8.00),
            (2, "notchflow", "claude-sonnet-4-5", .claude, 4.00),
            (3, "checkout-web", "claude-opus-4-8", .claude, 15.00),
            (3, "orders-api", "gpt-5-codex", .codex, 9.00),
            (3, "notchflow", "claude-sonnet-4-5", .claude, 4.00),
            (4, "checkout-web", "claude-opus-4-8", .claude, 11.00),
            (4, "notchflow", "claude-sonnet-4-5", .claude, 5.00),
            (4, "orders-api", "gpt-5-codex", .codex, 3.00),
            (5, "checkout-web", "claude-opus-4-8", .claude, 20.00),
            (5, "notchflow", "claude-sonnet-4-5", .claude, 8.00),
            (5, "orders-api", "gpt-5-codex", .codex, 6.00),
            (6, "checkout-web", "claude-opus-4-8", .claude, 13.00),
            (6, "notchflow", "claude-sonnet-4-5", .claude, 6.00),
            (6, "orders-api", "gpt-5-codex", .codex, 4.00)
        ]

        return rows.map { offset, project, model, provider, cost in
            UsageEvent(
                date: day(offset),
                provider: provider,
                model: model,
                project: project,
                input: cost * 2_600,
                output: cost * 850,
                cacheRead: cost * 14_000,
                cacheWrite: cost * 1_800,
                costUSD: cost
            )
        }
    }
}
