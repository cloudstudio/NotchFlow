import SwiftUI
import NotchFlowCore

public enum EyeExpression: Equatable {
    case awake
    case focused
    case alert
    case sleepy
    case happy
    case dead
    case listening
    case speaking

    public init(status: SessionStatus?) {
        switch status {
        case .working: self = .awake
        case .runningTool: self = .focused
        case .waitingPermission: self = .alert
        case .idle: self = .sleepy
        case .completed: self = .happy
        case .failed: self = .dead
        case nil: self = .sleepy
        }
    }
}

/// The continuous shape of an eye, so any two expressions can be blended into
/// one another instead of snapping: `openness` is the resting lid height,
/// `smile` morphs the lens into a happy arc, `cross` into a dead X.
private struct EyePose {
    var openness: CGFloat
    var smile: CGFloat
    var cross: CGFloat

    static func lerp(_ a: EyePose, _ b: EyePose, _ t: CGFloat) -> EyePose {
        EyePose(
            openness: a.openness + (b.openness - a.openness) * t,
            smile: a.smile + (b.smile - a.smile) * t,
            cross: a.cross + (b.cross - a.cross) * t
        )
    }
}

/// Two soft, glossy eyes that are always subtly alive: they breathe, glance
/// around, blink asymmetrically, follow the pointer — and *morph* smoothly from
/// one expression to the next rather than cutting. The per-frame look is derived
/// deterministically from the timeline clock; only the expression cross-fade
/// keeps a little state (when the last change happened).
public struct MoriEyesView: View {
    let expression: EyeExpression
    let color: Color
    var pointerBias: CGPoint = .zero
    /// When set, the eyes bob and throw a burst of sparkles for ~1s after
    /// this instant: the "a task just landed" celebration, used on the pill.
    var celebrateAt: Date?
    /// When set, the right eye throws a quick wink ~0.36s after this instant:
    /// a friendly acknowledgement when the user approves from the notch.
    var winkAt: Date?

    /// The expression we are morphing away from, and when the morph began.
    @State private var previousExpression: EyeExpression?
    @State private var transitionStart: Date = .distantPast

    private static let morphDuration: TimeInterval = 0.34

    public init(status: SessionStatus?, color: Color, pointerBias: CGPoint = .zero, celebrateAt: Date? = nil, winkAt: Date? = nil) {
        self.expression = EyeExpression(status: status)
        self.color = color
        self.pointerBias = pointerBias
        self.celebrateAt = celebrateAt
        self.winkAt = winkAt
    }

    init(expression: EyeExpression, color: Color, pointerBias: CGPoint = .zero, celebrateAt: Date? = nil, winkAt: Date? = nil) {
        self.expression = expression
        self.color = color
        self.pointerBias = pointerBias
        self.celebrateAt = celebrateAt
        self.winkAt = winkAt
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            Canvas { context, size in
                draw(context: &context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .onChange(of: expression) { old, _ in
            previousExpression = old
            transitionStart = Date()
        }
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Frame

    private func draw(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let eyeWidth = size.height * 0.52
        let baseHeight = size.height * 0.82
        let centers = [size.width * 0.30, size.width * 0.70]
        let breathing = 1 + 0.028 * sin(time * 2 * .pi / 4.3)
        let gaze = gazeOffset(at: time, size: size)
        let gesture = gestureOffset(at: time, size: size)
        let pop = celebrationScale(at: time)
        let pose = currentPose(at: time)
        let lensAlpha = max(0, 1 - pose.smile - pose.cross)

        for (index, centerX) in centers.enumerated() {
            let center = CGPoint(
                x: centerX + gaze.x + gesture.x,
                y: size.height * 0.5 + gaze.y + gesture.y
            )
            let blink = blinkClose(at: time, eyeIndex: index)
            let openFraction = max(pose.openness * (1 - blink * 0.94), 0.05)
            let width = eyeWidth * breathing * pop
            let height = max(baseHeight * openFraction * breathing * pop, width * 0.16)
            drawEye(context: &context, center: center, width: width, height: height, alpha: lensAlpha)
            if pose.smile > 0.01 {
                drawSmile(context: &context, center: center, width: eyeWidth * pop, height: baseHeight * pop, alpha: pose.smile)
            }
            if pose.cross > 0.01 {
                drawX(context: &context, center: center, width: eyeWidth, height: baseHeight, alpha: pose.cross)
            }
        }

        if expression == .listening {
            let pulse = 0.5 + 0.5 * sin(time * 2 * .pi / 0.9)
            let ring = CGRect(
                x: size.width / 2 - eyeWidth * (1.6 + pulse * 0.4),
                y: size.height * 0.52 - eyeWidth * (1.6 + pulse * 0.4),
                width: eyeWidth * (3.2 + pulse * 0.8),
                height: eyeWidth * (3.2 + pulse * 0.8)
            )
            context.stroke(
                Path(ellipseIn: ring),
                with: .color(color.opacity(0.25 + 0.2 * pulse)),
                lineWidth: 1
            )
        }

        drawEffects(context: &context, size: size, time: time)
    }

    /// The eye shape at `time`, blended from the previous expression to the
    /// current one over `morphDuration` right after a change.
    private func currentPose(at time: TimeInterval) -> EyePose {
        let target = pose(for: expression, at: time)
        guard let previous = previousExpression else { return target }
        let elapsed = time - transitionStart.timeIntervalSinceReferenceDate
        guard elapsed >= 0, elapsed < Self.morphDuration else { return target }
        let t = CGFloat(smoothstep(elapsed / Self.morphDuration))
        return EyePose.lerp(pose(for: previous, at: time), target, t)
    }

    private func pose(for expression: EyeExpression, at time: TimeInterval) -> EyePose {
        switch expression {
        case .awake:             return EyePose(openness: 0.98, smile: 0, cross: 0)
        case .focused:           return EyePose(openness: 0.80, smile: 0, cross: 0)
        case .alert, .listening: return EyePose(openness: 1.06, smile: 0, cross: 0)
        case .sleepy:            return EyePose(openness: 0.60, smile: 0, cross: 0)
        case .speaking:          return EyePose(openness: 0.90 + 0.12 * CGFloat(sin(time * 2 * .pi / 0.42)), smile: 0, cross: 0)
        case .happy:             return EyePose(openness: 0.55, smile: 1, cross: 0)
        case .dead:              return EyePose(openness: 0.50, smile: 0, cross: 1)
        }
    }

    // MARK: - Gestures and particles (ported from the MORI face)

    /// Physical reactions the eyes make: a decaying bob when a task lands,
    /// a nervous horizontal jitter while attention is needed.
    private func gestureOffset(at time: TimeInterval, size: CGSize) -> CGPoint {
        var offset = CGPoint.zero
        if let elapsed = celebrationElapsed(at: time) {
            let decay = exp(-elapsed * 3.4)
            offset.y -= size.height * 0.22 * decay * abs(sin(elapsed * .pi * 3.2))
        }
        if expression == .alert {
            offset.x += size.width * 0.03 * sin(time * 2 * .pi * 5.5)
        }
        return offset
    }

    /// A quick scale-up pop at the start of a celebration, decaying to 1.
    private func celebrationScale(at time: TimeInterval) -> CGFloat {
        guard let elapsed = celebrationElapsed(at: time) else { return 1 }
        return 1 + 0.32 * CGFloat(exp(-elapsed * 5) * abs(sin(elapsed * .pi * 3.2 + 0.6)))
    }

    private func celebrationElapsed(at time: TimeInterval) -> Double? {
        guard let celebrateAt else { return nil }
        let elapsed = time - celebrateAt.timeIntervalSinceReferenceDate
        return (elapsed >= 0 && elapsed < 1.1) ? elapsed : nil
    }

    private func drawEffects(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        // A tight sparkle ring that stays inside the frame; it reads as a
        // twinkle up close and simply clips to nothing on the tiny pill.
        if let elapsed = celebrationElapsed(at: time) {
            let count = 5
            let spread = smoothstep(min(elapsed / 0.4, 1))
            let fade = max(0, 1 - elapsed / 0.85)
            for index in 0..<count {
                let angle = Double(index) / Double(count) * 2 * .pi - .pi / 2
                let distance = min(size.width, size.height) * (0.2 + 0.35 * spread)
                let point = CGPoint(
                    x: size.width / 2 + CGFloat(cos(angle)) * distance,
                    y: size.height * 0.5 + CGFloat(sin(angle)) * distance * 0.7
                )
                let radius = size.height * 0.08 * (1 - elapsed * 0.5)
                guard radius > 0.4 else { continue }
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: point.x - radius, y: point.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .color(color.opacity(fade * 0.9))
                )
            }
        }

        if expression == .sleepy {
            let period = 2.6
            let phase = time.truncatingRemainder(dividingBy: period) / period
            let start = CGPoint(x: size.width * 0.66, y: size.height * 0.4)
            let point = CGPoint(
                x: start.x + CGFloat(phase) * size.width * 0.26,
                y: start.y - CGFloat(phase) * size.height * 0.5
            )
            let fade = (1 - phase) * 0.6
            let glyph = context.resolve(
                Text("z")
                    .font(.system(size: size.height * (0.34 + phase * 0.28), weight: .bold, design: .rounded))
                    .foregroundColor(color.opacity(fade))
            )
            context.draw(glyph, at: point)
        }
    }

    /// How closed the lid is this frame, 0 (open) … 1 (shut): fast close, slow
    /// reopen, an occasional double-blink, and a one-eyed wink on approval.
    private func blinkClose(at time: TimeInterval, eyeIndex: Int) -> CGFloat {
        var closed: CGFloat = 0
        if expression != .alert && expression != .listening {
            let cycle = expression == .sleepy ? 7.1 : 4.6
            let cycleIndex = Int(time / cycle)
            let phase = time.truncatingRemainder(dividingBy: cycle)
            let jitter = Double(seeded(cycleIndex &+ eyeIndex &* 7, salt: 11) % 100) / 100.0
            let blinkStart = 0.4 + jitter * (cycle - 1.2)
            let isDouble = seeded(cycleIndex, salt: 23) % 5 == 0

            func blinkAmount(_ offset: TimeInterval) -> CGFloat {
                let duration = 0.26
                let t = phase - blinkStart - offset
                guard t > 0, t < duration else { return 0 }
                let progress = t / duration
                if progress < 0.38 {
                    return CGFloat(progress / 0.38)
                }
                return CGFloat(1 - (progress - 0.38) / 0.62)
            }

            closed = blinkAmount(0)
            if isDouble { closed = max(closed, blinkAmount(0.34)) }
        }

        // A one-eyed wink on approval: the right eye (index 1) snaps shut then
        // reopens over ~0.36s, reusing the blink ramp so it reads as the same
        // lid motion. The left eye stays on its normal schedule.
        if eyeIndex == 1, let winkAt {
            let duration = 0.36
            let t = time - winkAt.timeIntervalSinceReferenceDate
            if t > 0, t < duration {
                let progress = t / duration
                let winkCurve: CGFloat = progress < 0.38
                    ? CGFloat(progress / 0.38)
                    : CGFloat(1 - (progress - 0.38) / 0.62)
                closed = max(closed, winkCurve)
            }
        }

        return closed
    }

    /// Smooth saccades: a new pseudo-random gaze target every few seconds,
    /// eased quickly then held. The pointer bias pulls the gaze toward the
    /// user's cursor when it is near the island.
    private func gazeOffset(at time: TimeInterval, size: CGSize) -> CGPoint {
        guard expression != .alert else { return CGPoint(x: 0, y: -size.height * 0.05) }
        let interval: TimeInterval = expression == .focused ? 1.7 : 2.9
        let index = Int(time / interval)
        let phase = (time.truncatingRemainder(dividingBy: interval)) / interval

        func target(_ i: Int) -> CGPoint {
            let dx = Double(seeded(i, salt: 5) % 200) / 100.0 - 1
            let dy = Double(seeded(i, salt: 17) % 200) / 100.0 - 1
            return CGPoint(
                x: dx * size.width * 0.09,
                y: dy * size.height * 0.1 + (expression == .sleepy ? size.height * 0.04 : 0)
            )
        }

        let previous = target(index - 1)
        let next = target(index)
        let eased = phase < 0.18 ? smoothstep(phase / 0.18) : 1
        var gaze = CGPoint(
            x: previous.x + (next.x - previous.x) * eased,
            y: previous.y + (next.y - previous.y) * eased
        )
        gaze.x += pointerBias.x * size.width * 0.06
        gaze.y += pointerBias.y * size.height * 0.1
        return gaze
    }

    // MARK: - Eye rendering

    /// A glossy lens: a tight bloom behind, a solid body, a soft top gloss and
    /// — when big enough to carry it — a specular highlight. Deliberately not a
    /// fuzzy halo; the glow is kept close so it reads as a lit eye, not a ball.
    private func drawEye(context: inout GraphicsContext, center: CGPoint, width: CGFloat, height: CGFloat, alpha: CGFloat) {
        guard alpha > 0.01, width > 0, height > 0 else { return }
        let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let radius = min(width, height) / 2
        let lens = Path(roundedRect: rect, cornerRadius: radius, style: .continuous)

        var glow = context
        glow.addFilter(.blur(radius: width * 0.34))
        glow.fill(lens, with: .color(color.opacity(0.5 * alpha)))

        context.fill(lens, with: .color(color.opacity(alpha)))

        if height > width * 0.45 {
            var gloss = context
            gloss.clip(to: lens)
            gloss.fill(
                Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height * 0.62)),
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.30 * alpha), location: 0),
                        .init(color: .white.opacity(0), location: 1)
                    ]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.62)
                )
            )
            if width >= 14 {
                let dotRadius = width * 0.15
                let dotCenter = CGPoint(x: center.x - width * 0.17, y: rect.minY + height * 0.24)
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: dotCenter.x - dotRadius, y: dotCenter.y - dotRadius,
                        width: dotRadius * 2, height: dotRadius * 2
                    )),
                    with: .color(.white.opacity(0.55 * alpha))
                )
            }
        }
    }

    private func drawSmile(context: inout GraphicsContext, center: CGPoint, width: CGFloat, height: CGFloat, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        var path = Path()
        path.addArc(
            center: CGPoint(x: center.x, y: center.y + height * 0.16),
            radius: width * 0.6,
            startAngle: .degrees(200),
            endAngle: .degrees(340),
            clockwise: false
        )
        let style = StrokeStyle(lineWidth: width * 0.40, lineCap: .round)
        var glow = context
        glow.addFilter(.blur(radius: width * 0.28))
        glow.stroke(path, with: .color(color.opacity(0.4 * alpha)), style: style)
        context.stroke(path, with: .color(color.opacity(alpha)), style: style)
    }

    private func drawX(context: inout GraphicsContext, center: CGPoint, width: CGFloat, height: CGFloat, alpha: CGFloat) {
        guard alpha > 0.01 else { return }
        let arm = width * 0.7
        var path = Path()
        path.move(to: CGPoint(x: center.x - arm, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y + arm))
        path.move(to: CGPoint(x: center.x + arm, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x - arm, y: center.y + arm))
        context.stroke(
            path,
            with: .color(color.opacity(alpha)),
            style: StrokeStyle(lineWidth: width * 0.34, lineCap: .round)
        )
    }

    private func seeded(_ value: Int, salt: Int) -> Int {
        var hash = UInt64(bitPattern: Int64(value)) &* 0x9E3779B97F4A7C15
        hash ^= UInt64(bitPattern: Int64(salt)) &* 0xBF58476D1CE4E5B9
        hash = (hash ^ (hash >> 31)) &* 0x94D049BB133111EB
        return Int(truncatingIfNeeded: hash >> 33)
    }

    private func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private var accessibilityText: String {
        switch expression {
        case .alert: return "Agent needs attention"
        case .focused: return "Agent running a tool"
        case .awake: return "Agent working"
        case .sleepy: return "Agent ready for you"
        case .happy: return "Agent completed"
        case .dead: return "Agent failed"
        case .listening: return "Listening"
        case .speaking: return "Speaking"
        }
    }
}
