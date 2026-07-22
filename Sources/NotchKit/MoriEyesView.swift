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

/// Two soft rounded eyes that are always subtly alive: they breathe, glance
/// around, blink asymmetrically and can follow the pointer. Everything is
/// derived deterministically from the timeline clock so each frame is pure.
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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                draw(context: &context, size: size, time: time)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private func draw(context: inout GraphicsContext, size: CGSize, time: TimeInterval) {
        let eyeWidth = size.height * 0.55
        let baseHeight = size.height * 0.78
        let centers = [size.width * 0.30, size.width * 0.70]
        let breathing = 1 + 0.03 * sin(time * 2 * .pi / 4.3)
        let gaze = gazeOffset(at: time, size: size)
        let gesture = gestureOffset(at: time, size: size)
        context.addFilter(.shadow(color: color.opacity(0.65), radius: eyeWidth * 0.45))

        let pop = celebrationScale(at: time)
        for (index, centerX) in centers.enumerated() {
            let center = CGPoint(
                x: centerX + gaze.x + gesture.x,
                y: size.height * 0.5 + gaze.y + gesture.y
            )
            switch expression {
            case .happy:
                drawHappy(context: &context, center: center, width: eyeWidth * pop, height: baseHeight * pop)
            case .dead:
                drawX(context: &context, center: center, width: eyeWidth, height: baseHeight)
            default:
                let openness = self.openness(at: time, eyeIndex: index)
                drawEye(
                    context: &context,
                    center: center,
                    width: eyeWidth * breathing * pop,
                    height: max(baseHeight * openness * breathing * pop, eyeWidth * 0.18)
                )
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

    // MARK: - Gestures and particles (ported from the MORI face)

    /// Physical reactions the eyes make: a decaying bob when a task lands,
    /// a nervous horizontal jitter while attention is needed, a gentle sink
    /// while asleep. Scaled to the face so it reads at pill size too.
    private func gestureOffset(at time: TimeInterval, size: CGSize) -> CGPoint {
        var offset = CGPoint.zero
        if let elapsed = celebrationElapsed(at: time) {
            // Two or three quick bobs that settle over a second, kept inside
            // the frame so it reads even at pill size.
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

    /// 1 = fully open. Blinks close fast and reopen slowly; occasionally a
    /// double blink. Expression sets the resting lid position.
    private func openness(at time: TimeInterval, eyeIndex: Int) -> CGFloat {
        // Expressions vary lid height, but within a tight range: at pill
        // scale a wide spread reads as inconsistent sizing, not as mood.
        let resting: CGFloat
        switch expression {
        case .alert, .listening: resting = 1.05
        case .focused: resting = 0.78
        case .sleepy: resting = 0.62
        case .speaking: resting = 0.9 + 0.1 * CGFloat(sin(time * 2 * .pi / 0.45))
        default: resting = 0.95
        }
        guard expression != .alert else { return resting }

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

        var closed = blinkAmount(0)
        if isDouble { closed = max(closed, blinkAmount(0.34)) }

        // A one-eyed wink on approval: the right eye (index 1) snaps shut fast
        // then reopens over ~0.36s, reusing the blink ramp so it reads as the
        // same lid motion. The left eye stays on its normal blink schedule.
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

        return resting * (1 - closed * 0.94)
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

    private func drawEye(
        context: inout GraphicsContext,
        center: CGPoint,
        width: CGFloat,
        height: CGFloat
    ) {
        let rect = CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
        let radius = min(width, height) / 2
        context.fill(
            Path(roundedRect: rect, cornerRadius: radius, style: .continuous),
            with: .color(color)
        )
    }

    private func drawHappy(
        context: inout GraphicsContext,
        center: CGPoint,
        width: CGFloat,
        height: CGFloat
    ) {
        var path = Path()
        path.addArc(
            center: CGPoint(x: center.x, y: center.y + height * 0.18),
            radius: width * 0.62,
            startAngle: .degrees(200),
            endAngle: .degrees(340),
            clockwise: false
        )
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(lineWidth: width * 0.42, lineCap: .round)
        )
    }

    private func drawX(
        context: inout GraphicsContext,
        center: CGPoint,
        width: CGFloat,
        height: CGFloat
    ) {
        let arm = width * 0.7
        var path = Path()
        path.move(to: CGPoint(x: center.x - arm, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x + arm, y: center.y + arm))
        path.move(to: CGPoint(x: center.x + arm, y: center.y - arm))
        path.addLine(to: CGPoint(x: center.x - arm, y: center.y + arm))
        context.stroke(
            path,
            with: .color(color),
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
