import Foundation
import NotchFlowCore

/// Tails Claude Code transcripts so the monitor works with no hooks
/// installed: the zero-setup floor. It runs only while the hooks are
/// absent (AppModel reconciles it), so an installed setup keeps its richer,
/// interactive hook path untouched. A transcript has no explicit
/// turn-complete marker, so a session that stops changing for a few seconds
/// is treated as finished, mirroring what the file's mtime already says.
final class ClaudeTranscriptMonitor {
    private let queue = DispatchQueue(label: "app.notchflow.claude-transcripts", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var offsets: [String: UInt64] = [:]
    private var partials: [String: Data] = [:]
    private var resyncPaths: Set<String> = []
    /// Files with an open turn: their session id and the last time they grew.
    private var openTurns: [String: (sessionId: String, lastGrowth: Date)] = [:]
    private var onEvents: (([AgentEvent]) -> Void)?

    private let freshness: TimeInterval = 20 * 60
    private let idleAfter: TimeInterval = 20
    private let headLimit = 64 * 1_024
    private let tailLimit = 2 * 1_024 * 1_024

    func start(onEvents: @escaping ([AgentEvent]) -> Void) {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
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
            self?.openTurns.removeAll()
        }
    }

    var isRunning: Bool {
        queue.sync { timer != nil }
    }

    private var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
    }

    private func scan() {
        let now = Date()
        var collected: [AgentEvent] = []
        let projectDirs = (try? FileManager.default.contentsOfDirectory(
            at: projectsRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for directory in projectDirs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]
                ), let modified = values.contentModificationDate,
                   let size = values.fileSize else { continue }
                if offsets[file.path] == nil,
                   now.timeIntervalSince(modified) > freshness { continue }
                let events = tail(file: file, size: UInt64(size), modified: modified)
                collected.append(contentsOf: events)
            }
        }
        // A file that stopped growing has finished its turn; close it once.
        for (path, turn) in openTurns where now.timeIntervalSince(turn.lastGrowth) > idleAfter {
            collected.append(AgentEvent(
                type: .turnCompleted,
                agent: .claude,
                sessionId: turn.sessionId,
                transcriptPath: path,
                timestamp: now
            ))
            openTurns.removeValue(forKey: path)
        }
        if !collected.isEmpty { onEvents?(collected) }
    }

    private func tail(file: URL, size: UInt64, modified: Date) -> [AgentEvent] {
        guard size > 0,
              let sessionId = ClaudeTranscriptMapper.sessionId(fromFilename: file.lastPathComponent)
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
            if let newline = data.firstIndex(of: 0x0A) {
                data = Data(data[data.index(after: newline)...])
                resyncPaths.remove(path)
            } else {
                data = Data()
            }
        }

        var buffer = carry + data
        var sawActivity = false
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            if !lineData.isEmpty {
                let lineEvents = ClaudeTranscriptMapper.events(
                    fromLine: Data(lineData),
                    sessionId: sessionId,
                    transcriptPath: path
                )
                if !lineEvents.isEmpty { sawActivity = true }
                events.append(contentsOf: lineEvents)
            }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        offsets[path] = offset
        partials[path] = buffer
        if sawActivity {
            let liveSessionId = events.last(where: { !$0.sessionId.isEmpty })?.sessionId ?? sessionId
            openTurns[path] = (liveSessionId, modified)
        }
        return events
    }
}
