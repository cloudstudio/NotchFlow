import AppKit
import CryptoKit
import Foundation
import NotchFlowCore

/// The notch finding its voice: speaks short lines through a local Piper install
/// (binary + a voice model — see `PiperLocator`). Fully local, no account, no
/// network. Silent unless the "voice" plugin is on and Piper is available, so it
/// costs nothing when off.
///
/// Piper *synthesizes* speech (≈1–3s: model load + inference), so lines are
/// rendered to a WAV once and cached on disk keyed by (voice, text). The first
/// utterance of a phrase pays that cost; every one after — and after a
/// relaunch — is an instant `afplay`. `prewarm` pays it up front, at launch.
@MainActor
final class Voice {
    private let queue = DispatchQueue(label: "app.notchflow.voice", qos: .userInitiated)
    private var speaking = false

    /// Renders fixed lines into the cache ahead of time so the first real
    /// utterance is instant instead of a synthesis wait. Cheap after the first
    /// ever launch — the WAVs already exist on disk.
    func prewarm(_ lines: [String]) {
        guard let piper = PiperLocator.locate() else { return }
        let binary = piper.binaryPath
        let voice = piper.voicePath
        queue.async {
            for line in lines { _ = Voice.cachedWave(line, binary: binary, voice: voice) }
        }
    }

    /// Says a line, if the voice plugin is enabled and Piper is present. A new
    /// line is dropped while one is playing, so a fleet of agents never turns
    /// the notch into a chatterbox. Synthesis + playback run off the main thread.
    func say(_ line: String) {
        guard PluginManager.shared.isOn("voice"),
              !speaking,
              let piper = PiperLocator.locate() else { return }
        speaking = true
        let binary = piper.binaryPath
        let voice = piper.voicePath
        queue.async { [weak self] in
            if let wav = Voice.cachedWave(line, binary: binary, voice: voice) {
                Voice.play(wav)
            }
            DispatchQueue.main.async { self?.speaking = false }
        }
    }

    // MARK: - Cache

    nonisolated private static let cacheDirectory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchFlow/voice-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Stable on-disk cache key for a line in a given voice. Folds in the voice
    /// model's filename (not its full path), so the same model in a different
    /// directory reuses the cache. Pure, so it can be tested.
    nonisolated static func cacheKey(voice: String, line: String) -> String {
        let model = URL(fileURLWithPath: voice).lastPathComponent
        return SHA256.hash(data: Data("\(model)|\(line)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Returns a playable WAV for `line`, synthesizing it with Piper only on a
    /// cache miss. The key folds in the voice model, so switching voices
    /// re-renders. `nonisolated` because it touches no actor state.
    private nonisolated static func cachedWave(_ line: String, binary: String, voice: String) -> URL? {
        let wav = cacheDirectory.appendingPathComponent("\(cacheKey(voice: voice, line: line)).wav")
        if FileManager.default.fileExists(atPath: wav.path) { return wav }

        let synth = Process()
        synth.executableURL = URL(fileURLWithPath: binary)
        synth.arguments = ["--model", voice, "--output_file", wav.path]
        let input = Pipe()
        synth.standardInput = input
        synth.standardOutput = Pipe()
        synth.standardError = Pipe()
        do {
            try synth.run()
            input.fileHandleForWriting.write(Data((line + "\n").utf8))
            input.fileHandleForWriting.closeFile()
            synth.waitUntilExit()
        } catch {
            return nil
        }
        guard synth.terminationStatus == 0,
              FileManager.default.fileExists(atPath: wav.path) else { return nil }
        return wav
    }

    private nonisolated static func play(_ wav: URL) {
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = [wav.path]
        try? player.run()
        player.waitUntilExit()
    }
}
