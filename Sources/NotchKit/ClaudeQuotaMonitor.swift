import Foundation
import NotchFlowCore
import os

/// Reads the same rate-limit windows Claude Code shows in /usage, using the
/// locally stored OAuth credential. The token is read from the user's own
/// Keychain item (or ~/.claude/.credentials.json) and sent exclusively to
/// Anthropic's usage endpoint; it is never logged or persisted by NotchFlow.
final class ClaudeQuotaMonitor {
    private static let logger = Logger(subsystem: "app.notchflow", category: "claude-quota")
    private var timer: Timer?

    func start(onUpdate: @escaping (QuotaState?) -> Void) {
        poll(onUpdate: onUpdate)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.poll(onUpdate: onUpdate)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll(onUpdate: @escaping (QuotaState?) -> Void) {
        Task.detached(priority: .utility) {
            let quota = await Self.readQuota()
            await MainActor.run { onUpdate(quota) }
        }
    }

    private static func readQuota() async -> QuotaState? {
        guard let token = accessToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        guard http.statusCode == 200 else {
            logger.info("usage endpoint returned \(http.statusCode)")
            // An expired credential must surface, not vanish: a missing
            // quota reads as "plenty left". Clears itself once Claude Code
            // refreshes the token and a later poll succeeds.
            if http.statusCode == 401 || http.statusCode == 403 {
                return QuotaState(provider: .claude, authProblem: true, updatedAt: Date())
            }
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let session = window(object["five_hour"], durationMinutes: 300)
        let week = window(object["seven_day"], durationMinutes: 10_080)
        guard session != nil || week != nil else { return nil }
        return QuotaState(
            provider: .claude,
            primary: session,
            secondary: week,
            updatedAt: Date()
        )
    }

    private static func window(_ value: Any?, durationMinutes: Int) -> QuotaWindow? {
        guard let raw = value as? [String: Any],
              let utilization = raw["utilization"] as? NSNumber else { return nil }
        let resetsAt = (raw["resets_at"] as? String).flatMap { text -> Date? in
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        return QuotaWindow(
            usedFraction: utilization.doubleValue / 100,
            durationMinutes: durationMinutes,
            resetsAt: resetsAt
        )
    }

    private static func accessToken() -> String? {
        if let keychain = keychainCredentials(),
           let token = oauthAccessToken(from: keychain) {
            return token
        }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: fallback) else { return nil }
        return oauthAccessToken(from: data)
    }

    private static func keychainCredentials() -> Data? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    private static func oauthAccessToken(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any] else { return nil }
        return oauth["accessToken"] as? String
    }
}
