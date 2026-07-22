import Foundation

public enum InteractionKind: String, Codable, Sendable {
    case permission
    case question
    case plan
}

public struct QuestionOption: Codable, Equatable, Sendable, Identifiable {
    public var id: String { label }
    public let label: String
    public let description: String?

    public init(label: String, description: String? = nil) {
        self.label = label
        self.description = description
    }
}

public struct AgentQuestion: Codable, Equatable, Sendable, Identifiable {
    public var id: String { question }
    public let header: String?
    public let question: String
    public let options: [QuestionOption]
    public let multiSelect: Bool

    public init(
        header: String? = nil,
        question: String,
        options: [QuestionOption] = [],
        multiSelect: Bool = false
    ) {
        self.header = header
        self.question = question
        self.options = options
        self.multiSelect = multiSelect
    }
}

public struct InteractionRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let kind: InteractionKind
    public let providerEventName: String
    public let title: String
    public let detail: String?
    public let questions: [AgentQuestion]

    public init(
        id: String = UUID().uuidString,
        kind: InteractionKind,
        providerEventName: String,
        title: String,
        detail: String? = nil,
        questions: [AgentQuestion] = []
    ) {
        self.id = id
        self.kind = kind
        self.providerEventName = providerEventName
        self.title = title
        self.detail = detail
        self.questions = questions
    }
}

public struct BridgeEnvelope: Codable, Equatable, Sendable {
    public let version: Int
    public let event: AgentEvent
    public let interaction: InteractionRequest?

    public init(version: Int = 1, event: AgentEvent, interaction: InteractionRequest? = nil) {
        self.version = version
        self.event = event
        self.interaction = interaction
    }
}

public enum InteractionAction: String, Codable, Sendable {
    case allow
    case deny
}

public struct InteractionDecision: Codable, Equatable, Sendable {
    public let requestId: String
    public let action: InteractionAction
    public let answers: [String: String]
    public let message: String?

    public init(
        requestId: String,
        action: InteractionAction,
        answers: [String: String] = [:],
        message: String? = nil
    ) {
        self.requestId = requestId
        self.action = action
        self.answers = answers
        self.message = message
    }
}
