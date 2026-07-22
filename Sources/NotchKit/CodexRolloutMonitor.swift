import Foundation
import NotchFlowCore

/// Tails Codex rollout files under ~/.codex/sessions and turns their lines
/// into bridge events. This is the only monitoring channel that covers
/// Codex Desktop: the `notify` hook never fires there, and its config slot
/// tends to belong to other tools anyway. Zero configuration, nothing to
/// install, nothing to break.
final class CodexRolloutMonitor {
    private let queue = DispatchQueue(label: "app.notchflow.codex-rollouts", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    private var partials: [String: Data] = [:]
    private var resyncPaths: Set<String> = []
    private var onEvents: (([AgentEvent]) -> Void)?

    /// Only files freshly written matter; anything older was over before
    /// the app looked. Files already being tracked keep flowing regardless.
    private let freshness: TimeInterval = 20 * 60
    /// Oversized histories are sampled: head (the session_meta line) plus
    /// a recent tail, instead of replaying megabytes of tool output.
    private let headLimit = 64 * 1_024
    private let tailLimit = 2 * 1_024 * 1_024

    func start(onEvents: @escaping ([AgentEvent]) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.onEvents = onEvents
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 3)
            timer.setEventHandler { [weak self] in self?.scan() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
            self?.onEvents = nil
        }
    }

    private var sessionsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
    }

    private func scan() {
        let now = Date()
        var collected: [AgentEvent] = []
        for directory in dayDirectories(now: now) {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? []
            for file in files where file.lastPathComponent.hasPrefix("rollout-") {
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                ), let modified = values.contentModificationDate,
                   let size = values.fileSize else { continue }
                if offsets[file.path] == nil,
                   now.timeIntervalSince(modified) > freshness { continue }
                collected.append(contentsOf: tail(file: file, size: UInt64(size)))
            }
        }
        if !collected.isEmpty { onEvents?(collected) }
    }

    /// Today's directory, plus yesterday's for a few hours past midnight
    /// while its sessions may still be alive.
    private func dayDirectories(now: Date) -> [URL] {
        var directories: [URL] = []
        for day in [now, now.addingTimeInterval(-3 * 3_600)] {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day else {
                continue
            }
            let directory = sessionsRoot.appendingPathComponent(
                String(format: "%04d/%02d/%02d", year, month, dayOfMonth)
            )
            if !directories.contains(directory) { directories.append(directory) }
        }
        return directories
    }

    private func tail(file: URL, size: UInt64) -> [AgentEvent] {
        guard size > 0,
              let sessionId = CodexRolloutMapper.sessionId(fromFilename: file.lastPathComponent)
        else { return [] }
        let path = file.path
        var events: [AgentEvent] = []
        var offset: UInt64
        var carry: Data

        if let known = offsets[path] {
            guard size > known else {
                offsets[path] = min(known, size)
                return []
            }
            offset = known
            carry = partials[path] ?? Data()
        } else if size > UInt64(headLimit + tailLimit) {
            if let handle = try? FileHandle(forReadingFrom: file) {
                let head = (try? handle.read(upToCount: headLimit)) ?? Data()
                try? handle.close()
                for line in head.split(separator: 0x0A).dropLast() {
                    events.append(contentsOf: CodexRolloutMapper
                        .events(fromLine: Data(line), sessionId: sessionId)
                        .filter { $0.type == .sessionStarted })
                }
            }
            offset = size - UInt64(tailLimit)
            carry = Data()
            resyncPaths.insert(path)
        } else {
            offset = 0
            carry = Data()
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else { return events }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              var data = try? handle.readToEnd() else { return events }
        offset += UInt64(data.count)
        if resyncPaths.contains(path) {
            // The seek landed mid-line; everything before the first
            // newline belongs to a line we cannot parse.
            if let newline = data.firstIndex(of: 0x0A) {
                data = Data(data[data.index(after: newline)...])
                resyncPaths.remove(path)
            } else {
                data = Data()
            }
        }

        var buffer = carry + data
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            if !line.isEmpty {
                events.append(contentsOf: CodexRolloutMapper.events(
                    fromLine: Data(line),
                    sessionId: sessionId
                ))
            }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        offsets[path] = offset
        partials[path] = buffer
        return events
    }
}
