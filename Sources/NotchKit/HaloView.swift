import SwiftUI
import NotchFlowCore

// MARK: - Attention ping halo

/// A single soft ring that blooms and fades in 0.6s the moment the model asks
/// for attention. It lives behind the pill and outside the clip so it can
/// spill past the edge like a pulse rather than a contained outline.
struct HaloView: View {
    let pingAt: Date?
    let status: SessionStatus?
    let shape: NotchShape

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = pingAt.map { timeline.date.timeIntervalSince($0) } ?? .infinity
            let alive = elapsed >= 0 && elapsed < 0.6
            let decay = max(0, 1 - elapsed / 0.6)
            shape
                .stroke(statusColor(for: status), lineWidth: 3)
                .blur(radius: 4)
                .scaleEffect(CGFloat(1 + 0.6 * decay))
                .opacity(alive ? decay : 0)
        }
        .allowsHitTesting(false)
    }
}
