import Foundation
import NotchFlowCore
import os

/// Keeps one persistent `codex app-server` session alive, listening for
/// rate-limit pushes instead of spawning a fresh process on every poll.
final class CodexQuotaMonitor {
    private static let logger = Logger(subsystem: "app.notchflow", category: "codex-quota")
    private let queue = DispatchQueue(label: "app.notchflow.codex-quota")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextRequestId = 2
    private var refreshTimer: DispatchSourceTimer?
    private var stopped = false
    private var onUpdate: ((QuotaState?) -> Void)?

    func start(onUpdate: @escaping (QuotaState?) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onUpdate = onUpdate
            self.stopped = false
            self.launch()
            self.scheduleRefresh()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.refreshTimer?.cancel()
            self.refreshTimer = nil
            self.tearDownProcess()
        }
    }

    private func launch() {
        guard !stopped, process == nil else { return }
        guard let executable = Self.codexExecutable() else { return }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.queue.async { self?.consume(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.handleTermination() }
        }

        do {
            try process.run()
        } catch {
            Self.logger.error("failed to launch codex app-server: \(error.localizedDescription)")
            stdout.fileHandleForReading.readabilityHandler = nil
            return
        }

        self.process = process
        self.input = stdin.fileHandleForWriting
        sendLine(#"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"NotchFlow","title":"NotchFlow","version":"0.2.0"},"capabilities":{"experimentalApi":true}}}"#)
        sendLine(#"{"method":"initialized"}"#)
        requestRateLimits()
    }

    private func scheduleRefresh() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 300, repeating: 300)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.process == nil {
                self.launch()
            } else {
                self.requestRateLimits()
            }
        }
        timer.resume()
        refreshTimer = timer
    }

    private func requestRateLimits() {
        sendLine(#"{"id":\#(nextRequestId),"method":"account/rateLimits/read"}"#)
        nextRequestId += 1
    }

    private func sendLine(_ line: String) {
        guard let input else { return }
        try? input.write(contentsOf: Data((line + "\n").utf8))
    }

    private func handleTermination() {
        tearDownProcess()
        guard !stopped else { return }
        notify(nil)
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.launch()
        }
    }

    private func tearDownProcess() {
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? input?.close()
        process = nil
        input = nil
        buffer.removeAll()
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            let container = (object["result"] as? [String: Any])
                ?? (object["params"] as? [String: Any])
            guard let container, let quota = Self.quota(from: container) else { continue }
            notify(quota)
        }
        if buffer.count > 1_048_576 { buffer.removeAll() }
    }

    private func notify(_ quota: QuotaState?) {
        guard let onUpdate else { return }
        DispatchQueue.main.async { onUpdate(quota) }
    }

    private static func quota(from container: [String: Any]) -> QuotaState? {
        guard let rawLimits = container["rateLimits"] as? [String: Any] else { return nil }
        let limits: [String: Any]
        if let byId = container["rateLimitsByLimitId"] as? [String: Any],
           let codex = byId["codex"] as? [String: Any] {
            limits = codex
        } else {
            limits = rawLimits
        }
        let primary = window(limits["primary"])
        let secondary = window(limits["secondary"])
        guard primary != nil || secondary != nil else { return nil }
        return QuotaState(
            provider: .codex,
            primary: primary,
            secondary: secondary,
            planName: limits["planType"] as? String,
            updatedAt: Date()
        )
    }

    private static func window(_ value: Any?) -> QuotaWindow? {
        guard let raw = value as? [String: Any],
              let percent = raw["usedPercent"] as? NSNumber else { return nil }
        let duration = (raw["windowDurationMins"] as? NSNumber)?.intValue
        let resetSeconds = (raw["resetsAt"] as? NSNumber)?.doubleValue
        return QuotaWindow(
            usedFraction: percent.doubleValue / 100,
            durationMinutes: duration,
            resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func codexExecutable() -> String? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
