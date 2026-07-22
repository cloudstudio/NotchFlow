import AVFoundation
import Foundation

/// Tiny synthesized square-wave blips, generated in memory: no bundled
/// assets, instant playback, unmistakably 8-bit.
@MainActor
final class ChipTune {
    private static let enabledKey = "sounds.enabled"
    private var player: AVAudioPlayer?

    enum Blip {
        case attention
        case done
        case fail
        case allDone
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func play(_ blip: Blip) {
        guard isEnabled else { return }
        let notes: [(frequency: Double, duration: Double)]
        switch blip {
        case .attention: notes = [(660, 0.07), (880, 0.1)]
        case .done: notes = [(523, 0.06), (659, 0.06), (784, 0.11)]
        case .fail: notes = [(330, 0.09), (220, 0.15)]
        case .allDone: notes = [(523, 0.07), (659, 0.07), (784, 0.07), (1047, 0.09), (1319, 0.13), (1568, 0.24)]
        }
        guard let data = Self.wav(notes: notes) else { return }
        player = try? AVAudioPlayer(data: data)
        player?.volume = 0.3
        player?.play()
    }

    private static func wav(notes: [(frequency: Double, duration: Double)]) -> Data? {
        let rate = 22_050.0
        var samples: [Int16] = []
        for note in notes {
            let count = Int(rate * note.duration)
            for index in 0..<count {
                let time = Double(index) / rate
                let square: Double = sin(2 * .pi * note.frequency * time) >= 0 ? 1 : -1
                let envelope = 1.0 - (Double(index) / Double(count)) * 0.65
                samples.append(Int16(square * envelope * 0.24 * 32_767))
            }
            samples.append(contentsOf: Array(repeating: 0, count: Int(rate * 0.018)))
        }

        var data = Data()
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: "RIFF".utf8)
        append32(UInt32(36 + byteCount))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        append32(16)
        append16(1)
        append16(1)
        append32(UInt32(rate))
        append32(UInt32(rate) * 2)
        append16(2)
        append16(16)
        data.append(contentsOf: "data".utf8)
        append32(UInt32(byteCount))
        for sample in samples {
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
