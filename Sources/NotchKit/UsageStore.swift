import Foundation
import NotchFlowCore
import os

/// Scans local Claude transcripts and Codex rollouts into usage events.
/// Unchanged files are served from a per-file cache, so a refresh only
/// pays for what actually changed since the last one.
@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var events: [UsageEvent] = []
    @Published private(set) var lastRefresh: Date?

    private static let logger = Logger(subsystem: "app.notchflow", category: "usage")
    /// Bump whenever parsing or pricing changes so cached per-file events
    /// (which bake in cost) are discarded instead of served stale.
    private static let cacheVersion = 2
    private var fileCache: [String: FileEntry] = [:]
    private var refreshing = false
    /// When the demo director seeds synthetic usage, the real transcript scan
    /// must never overwrite it: both refresh paths bail out while locked.
    private var demoLocked = false

    struct FileEntry: Codable {
        let size: Int
        let mtime: TimeInterval
        let events: [UsageEvent]
    }

    private struct CacheFile: Codable {
        var version: Int
        var files: [String: FileEntry]
    }

    init() {
        loadCache()
        events = fileCache.values.flatMap(\.events)
    }

    /// Replaces the corpus with a fixed demo set and locks out the live scan,
    /// so a hands-free cinematic shows stable, hand-picked numbers.
    func loadDemo(_ demoEvents: [UsageEvent]) {
        events = demoEvents
        lastRefresh = Date()
        demoLocked = true
    }

    public func refreshIfStale(maxAge: TimeInterval = 30) {
        if demoLocked { return }
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < maxAge { return }
        refresh()
    }

    func refresh() {
        if demoLocked { return }
        guard !refreshing else { return }
        refreshing = true
        let cache = fileCache
        Task.detached(priority: .utility) {
            let started = Date()
            let result = Self.scan(previous: cache)
            let elapsed = Date().timeIntervalSince(started)
            await MainActor.run {
                self.fileCache = result
                self.events = result.values.flatMap(\.events)
                self.lastRefresh = Date()
                self.refreshing = false
                self.saveCache()
                Self.logger.info("usage scan finished: \(result.count) files, \(self.events.count) events, \(String(format: "%.1f", elapsed))s")
            }
        }
    }

    // MARK: - Scanning

    private struct PendingFile {
        let url: URL
        let size: Int
        let mtime: TimeInterval
        let isCodex: Bool
    }

    private final class ScanResults: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: FileEntry] = [:]
    }

    /// Files untouched for 60 days can no longer contribute to any visible
    /// range; skipping them keeps the corpus bounded. Changed files parse in
    /// parallel across cores, so even a cold first scan takes seconds.
    nonisolated private static func scan(previous: [String: FileEntry]) -> [String: FileEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pricing = ClaudePricing.load()
        let openAIPricing = OpenAIPricing.load()
        let cutoff = Date().addingTimeInterval(-60 * 86_400).timeIntervalSince1970
        let results = ScanResults()
        var work: [PendingFile] = []

        func triage(url: URL, isCodex: Bool) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (attributes[.size] as? NSNumber)?.intValue,
                  let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970,
                  mtime >= cutoff else { return }
            if let cached = previous[url.path], cached.size == size, cached.mtime == mtime {
                results.entries[url.path] = cached
            } else if size < 128 * 1_024 * 1_024 {
                work.append(PendingFile(url: url, size: size, mtime: mtime, isCodex: isCodex))
            }
        }

        for url in jsonlFiles(under: home.appendingPathComponent(".claude/projects")) {
            triage(url: url, isCodex: false)
        }
        for url in jsonlFiles(under: home.appendingPathComponent(".codex/sessions"))
        where url.lastPathComponent.hasPrefix("rollout-") {
            triage(url: url, isCodex: true)
        }

        DispatchQueue.concurrentPerform(iterations: work.count) { index in
            let file = work[index]
            guard let handle = try? FileHandle(forReadingFrom: file.url),
                  let data = try? handle.readToEnd() else { return }
            try? handle.close()
            let events: [UsageEvent]
            if file.isCodex {
                events = coalesce(UsageAggregator.codexEvents(rollout: data, pricing: openAIPricing))
            } else {
                let fallback = file.url.deletingLastPathComponent().lastPathComponent
                events = coalesce(UsageAggregator.claudeEvents(
                    transcript: data,
                    fallbackProject: fallback,
                    pricing: pricing
                ))
            }
            let entry = FileEntry(size: file.size, mtime: file.mtime, events: events)
            results.lock.lock()
            results.entries[file.url.path] = entry
            results.lock.unlock()
        }
        return results.entries
    }

    nonisolated private static func jsonlFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
            return url
        }
    }

    /// Per-file events collapse to one per (day, model, project); the Stats
    /// screen never needs finer granularity and the cache stays tiny.
    nonisolated private static func coalesce(_ events: [UsageEvent]) -> [UsageEvent] {
        var merged: [String: UsageEvent] = [:]
        let calendar = Calendar.current
        for event in events {
            let day = calendar.startOfDay(for: event.date)
            let key = "\(day.timeIntervalSince1970)|\(event.model)|\(event.project)|\(event.provider.rawValue)"
            if let existing = merged[key] {
                merged[key] = UsageEvent(
                    date: day,
                    provider: event.provider,
                    model: event.model,
                    project: event.project,
                    input: existing.input + event.input,
                    output: existing.output + event.output,
                    cacheRead: existing.cacheRead + event.cacheRead,
                    cacheWrite: existing.cacheWrite + event.cacheWrite,
                    costUSD: existing.costUSD + event.costUSD
                )
            } else {
                merged[key] = UsageEvent(
                    date: day,
                    provider: event.provider,
                    model: event.model,
                    project: event.project,
                    input: event.input,
                    output: event.output,
                    cacheRead: event.cacheRead,
                    cacheWrite: event.cacheWrite,
                    costUSD: event.costUSD
                )
            }
        }
        return Array(merged.values)
    }

    // MARK: - Cache persistence

    private var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NotchFlow", isDirectory: true)
            .appendingPathComponent("usage-cache.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              cache.version == Self.cacheVersion else {
            return
        }
        fileCache = cache.files
    }

    private func saveCache() {
        let directory = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cache = CacheFile(version: Self.cacheVersion, files: fileCache)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: cacheURL.path
        )
    }
}
