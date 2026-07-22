import SwiftUI
import NotchFlowCore

// MARK: - Interaction

/// A brief green receipt stamped over the request the instant it is allowed,
/// so a decision made from the island feels acknowledged rather than silent.
private struct ApprovalReceipt: View {
    let flashAt: Date?
    @State private var visible = false

    private static let green = Color(red: 0.2, green: 0.72, blue: 0.46)
    private static let window: TimeInterval = 0.55

    var body: some View {
        ZStack {
            if visible {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Self.green.opacity(0.18))
                    .overlay(
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Self.green)
                    )
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .onAppear { trigger() }
        .onChange(of: flashAt) { _, _ in trigger() }
    }

    private func trigger() {
        guard let flashAt else { return }
        let age = Date().timeIntervalSince(flashAt)
        guard age >= 0, age < Self.window else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { visible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, Self.window - age)) {
            withAnimation(.easeOut(duration: 0.25)) { visible = false }
        }
    }
}
struct InteractionView: View {
    @ObservedObject var model: AppModel
    let interaction: PendingInteraction
    let queueCount: Int
    @State private var answers: [String: String] = [:]
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(interaction.request.title, systemImage: icon)
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(accent)
                    if let source = sourceLabel {
                        Text(source)
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer()
                if queueCount > 1 {
                    Text("1 of \(queueCount)")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(accent.opacity(0.18)))
                        .foregroundStyle(accent)
                }
            }

            if isForm {
                stepProgress
                if let detail = interaction.request.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineSpacing(2.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                questionView(currentQuestion)
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
                    .frame(maxWidth: .infinity, alignment: .leading)
                formControls
            } else {
                if isLongForm {
                    ScrollView {
                        interactionBody
                    }
                    .frame(height: 288)
                } else {
                    interactionBody
                }

                if isTapToAnswer {
                    // Clicking an option already answers; the only remaining
                    // action is declining, and it does not deserve a slab.
                    HStack {
                        Spacer()
                        Button("Deny") {
                            model.resolve(interaction, action: .deny)
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4).opacity(0.85))
                    }
                } else {
                    HStack(spacing: 10) {
                        Button("Deny") {
                            model.resolve(interaction, action: .deny)
                        }
                        .keyboardShortcut("n", modifiers: .command)
                        .buttonStyle(DecisionButtonStyle(color: .red.opacity(0.8)))

                        Button(allowTitle) {
                            model.resolve(interaction, action: .allow, answers: answers)
                        }
                        .keyboardShortcut("y", modifiers: .command)
                        .buttonStyle(DecisionButtonStyle(color: Color(red: 0.20, green: 0.72, blue: 0.46)))
                        .disabled(!canSubmit)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.045))
        )
        .overlay {
            ApprovalReceipt(flashAt: model.resolvedFlashAt)
                .allowsHitTesting(false)
        }
        .animation(stepAnimation, value: step)
    }

    private var interactionBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let detail = interaction.request.detail, !detail.isEmpty {
                if interaction.request.kind == .plan {
                    planDocument(detail)
                } else {
                    Text(detail)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineSpacing(2.5)
                        .textSelection(.enabled)
                        .lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(interaction.request.questions) { question in
                questionView(question)
            }
        }
    }

    /// The plan reads as a document, not a wall: a padded, bordered card with
    /// real line spacing and a legible rounded face instead of dense body text.
    private enum PlanBlock {
        case heading(String, level: Int)
        case bullet(String)
        case numbered(Int, String)
        case code(String)
        case paragraph(String)
        case spacer
    }

    private func planDocument(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(planBlocks(detail).enumerated()), id: \.offset) { _, block in
                planBlockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.06), lineWidth: 1)
        )
    }

    /// A tiny block-level Markdown pass: real plans (and the demo) use headings,
    /// lists and fenced code, which a single `Text` flattens into noise.
    private func planBlocks(_ text: String) -> [PlanBlock] {
        var blocks: [PlanBlock] = []
        var inCode = false
        var codeLines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inCode {
                    blocks.append(.code(codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(raw); continue }
            if trimmed.isEmpty { blocks.append(.spacer); continue }
            if trimmed.hasPrefix("### ") { blocks.append(.heading(String(trimmed.dropFirst(4)), level: 3)); continue }
            if trimmed.hasPrefix("## ") { blocks.append(.heading(String(trimmed.dropFirst(3)), level: 2)); continue }
            if trimmed.hasPrefix("# ") { blocks.append(.heading(String(trimmed.dropFirst(2)), level: 1)); continue }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { blocks.append(.bullet(String(trimmed.dropFirst(2)))); continue }
            if let r = trimmed.range(of: #"^\d+\. "#, options: .regularExpression) {
                let num = Int(trimmed[trimmed.startIndex..<trimmed.index(r.upperBound, offsetBy: -2)]) ?? 0
                blocks.append(.numbered(num, String(trimmed[r.upperBound...])))
                continue
            }
            blocks.append(.paragraph(trimmed))
        }
        if inCode { blocks.append(.code(codeLines.joined(separator: "\n"))) }
        return blocks
    }

    @ViewBuilder private func planBlockView(_ block: PlanBlock) -> some View {
        switch block {
        case .heading(let text, let level):
            Text(inlineMarkdown(text))
                .font(.system(size: level == 1 ? 14 : 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.top, 3)
        case .bullet(let text):
            HStack(alignment: .top, spacing: 7) {
                Text("•").foregroundStyle(.white.opacity(0.4))
                Text(inlineMarkdown(text)).foregroundStyle(.white.opacity(0.86))
            }
            .font(.system(size: 12, design: .rounded))
        case .numbered(let num, let text):
            HStack(alignment: .top, spacing: 7) {
                Text("\(num).").foregroundStyle(.white.opacity(0.4)).monospacedDigit()
                Text(inlineMarkdown(text)).foregroundStyle(.white.opacity(0.86))
            }
            .font(.system(size: 12, design: .rounded))
        case .code(let code):
            Text(code)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.78))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.black.opacity(0.32)))
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
                .lineSpacing(3)
        case .spacer:
            Color.clear.frame(height: 2)
        }
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// Plans and multi-question forms scroll inside a fixed viewport; short
    /// prompts lay out naturally. A bare ScrollView has no intrinsic height
    /// and collapses to zero inside the island's VStack.
    private var isLongForm: Bool {
        if interaction.request.kind == .plan { return true }
        let optionCount = interaction.request.questions.reduce(0) { $0 + max($1.options.count, 1) }
        return optionCount + interaction.request.questions.count > 7
    }

    @ViewBuilder
    private func questionView(_ question: AgentQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = question.header {
                Text(header.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
            }
            Text(question.question)
                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            if question.options.isEmpty {
                TextField("Type an answer", text: answerBinding(for: question.question))
                    .textFieldStyle(.plain)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.07)))
            } else {
                let hasShortcuts = isForm ? true : (interaction.request.questions.first?.id == question.id)
                ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
                    InteractionOptionRow(
                        option: option,
                        isMulti: question.multiSelect,
                        isSelected: isSelected(option.label, for: question),
                        shortcutHint: hasShortcuts && index < 9 ? "⌘\(index + 1)" : nil,
                        accent: accent
                    ) {
                        choose(option: option.label, for: question)
                    }
                    .modifier(OptionShortcut(enabled: hasShortcuts, index: index))
                }
            }
        }
    }

    /// One question, one choice: the tap IS the answer.
    private var isTapToAnswer: Bool {
        interaction.request.kind == .question
            && interaction.request.questions.count == 1
            && interaction.request.questions.first?.multiSelect == false
            && !(interaction.request.questions.first?.options.isEmpty ?? true)
    }

    private func choose(option: String, for question: AgentQuestion) {
        if question.multiSelect {
            toggle(option: option, for: question)
            return
        }
        answers[question.question] = option
        if isForm {
            // Single-select in a multi-question wizard: record and advance,
            // or submit everything on the last step.
            if isLastStep {
                model.resolve(interaction, action: .allow, answers: answers)
            } else {
                step += 1
            }
        } else {
            // One single-select question: the tap IS the answer.
            model.resolve(interaction, action: .allow, answers: [question.question: option])
        }
    }

    private func answerBinding(for question: String) -> Binding<String> {
        Binding(
            get: { answers[question, default: ""] },
            set: { answers[question] = $0 }
        )
    }

    private func isSelected(_ option: String, for question: AgentQuestion) -> Bool {
        if !question.multiSelect { return answers[question.question] == option }
        return selectedOptions(for: question).contains(option)
    }

    private func toggle(option: String, for question: AgentQuestion) {
        guard question.multiSelect else {
            answers[question.question] = option
            return
        }
        var selected = selectedOptions(for: question)
        if selected.contains(option) {
            selected.remove(option)
        } else {
            selected.insert(option)
        }
        answers[question.question] = question.options
            .map(\.label)
            .filter(selected.contains)
            .joined(separator: ", ")
    }

    private func selectedOptions(for question: AgentQuestion) -> Set<String> {
        Set((answers[question.question] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private var canSubmit: Bool {
        interaction.request.questions.allSatisfy {
            !(answers[$0.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Which terminal this request came from, so two questions at once are
    /// never answered blind. Project first, then the host terminal.
    private var sourceLabel: String? {
        guard let session = model.sessions.first(where: { $0.id == interaction.sessionId }) else {
            return nil
        }
        let project = session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let program = TerminalCatalog.program(fromTerminalIdentity: session.terminal)
        let parts = [project, program].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var icon: String {
        switch interaction.request.kind {
        case .permission: return "exclamationmark.shield.fill"
        case .question: return "questionmark.bubble.fill"
        case .plan: return "doc.text.fill"
        }
    }

    private var accent: Color {
        interaction.request.kind == .question
            ? Color(red: 0.45, green: 0.65, blue: 1)
            : Color(red: 1, green: 0.58, blue: 0.24)
    }

    private var allowTitle: String {
        guard interaction.request.kind == .question else { return "Allow" }
        let remaining = interaction.request.questions.filter {
            (answers[$0.question] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
        if interaction.request.questions.count > 1, remaining > 0 {
            return "Answer · \(remaining) left"
        }
        return "Answer"
    }

    // MARK: - Multi-question wizard

    /// More than one question becomes a step-by-step wizard — one question at a
    /// time, answer-and-advance — instead of a scroll of stacked questions.
    private var isForm: Bool {
        interaction.request.kind == .question && interaction.request.questions.count > 1
    }

    private var questions: [AgentQuestion] { interaction.request.questions }

    private var currentQuestion: AgentQuestion {
        questions[min(step, max(questions.count - 1, 0))]
    }

    private var isLastStep: Bool { step >= questions.count - 1 }

    private var currentAnswered: Bool {
        !(answers[currentQuestion.question] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Single-select advances on tap, so it needs no button; multi-select and
    /// free text need an explicit Next/Answer, as does a revisited answer.
    private var showAdvanceButton: Bool {
        currentQuestion.multiSelect || currentQuestion.options.isEmpty || currentAnswered
    }

    private var stepAnimation: Animation { .spring(response: 0.34, dampingFraction: 0.82) }

    private func advanceOrSubmit() {
        if isLastStep {
            if canSubmit { model.resolve(interaction, action: .allow, answers: answers) }
        } else {
            step += 1
        }
    }

    /// One dot per question, the current one elongated, so how many steps are
    /// left is always visible.
    private var stepProgress: some View {
        HStack(spacing: 7) {
            Text("Question \(step + 1) of \(questions.count)")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: 4) {
                ForEach(0..<questions.count, id: \.self) { index in
                    Capsule()
                        .fill(index == step
                            ? accent
                            : (index < step ? accent.opacity(0.5) : .white.opacity(0.15)))
                        .frame(width: index == step ? 14 : 6, height: 4)
                }
            }
            Spacer()
        }
    }

    private var formControls: some View {
        HStack(spacing: 10) {
            if step > 0 {
                Button { step -= 1 } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Button("Deny") { model.resolve(interaction, action: .deny) }
                .keyboardShortcut("n", modifiers: .command)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.4).opacity(0.85))
            if showAdvanceButton {
                Button { advanceOrSubmit() } label: {
                    Text(isLastStep ? "Answer" : "Next")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(red: 0.20, green: 0.72, blue: 0.46)
                                    .opacity(currentAnswered ? 1 : 0.35))
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(!currentAnswered)
            }
        }
    }
}
private struct InteractionOptionRow: View {
    let option: QuestionOption
    let isMulti: Bool
    let isSelected: Bool
    let shortcutHint: String?
    let accent: Color
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                // Every option shows its state: a radio for single-select, a
                // checkbox for multi. Without this a single-select tap changed
                // nothing on screen and read as a dead click.
                Image(systemName: indicatorSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? accent : .white.opacity(0.35))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                    if let description = option.description {
                        Text(description)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                Spacer()
                if let shortcutHint {
                    Text(shortcutHint)
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(hovered ? 0.45 : 0.25))
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.18) : .white.opacity(hovered ? 0.1 : 0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.75) : .white.opacity(hovered ? 0.14 : 0), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }

    private var indicatorSymbol: String {
        if isMulti { return isSelected ? "checkmark.square.fill" : "square" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }
}
private struct OptionShortcut: ViewModifier {
    let enabled: Bool
    let index: Int

    func body(content: Content) -> some View {
        if enabled, index < 9,
           let key = "\(index + 1)".first {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}
private struct DecisionButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(configuration.isPressed ? 0.65 : 1)))
            .foregroundStyle(.white)
            .opacity(isEnabled ? 1 : 0.35)
    }
}
