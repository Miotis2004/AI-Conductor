import Foundation

// MARK: - OpenAI API Models

/// A single model returned by `GET /v1/models`.
struct OpenAIModel: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let object: String
    let created: Int
    let ownedBy: String
    /// The model's maximum context length in tokens, if reported by the server.
    /// This is optional because not all OpenAI-compatible servers report it.
    let maxModelLen: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case object
        case created
        case ownedBy = "owned_by"
        case maxModelLen = "max_model_len"
    }
}

/// The envelope returned by `GET /v1/models`.
struct OpenAIModelsResponse: Codable, Sendable {
    let object: String
    let data: [OpenAIModel]
}

/// A single chat message.
///
/// `content` is optional because streaming deltas may contain only a role
/// (e.g. the first chunk) without any text content.
struct ChatMessage: Codable, Hashable, Sendable {
    let role: String
    let content: String?
}

/// The request body for `POST /v1/chat/completions`.
struct ChatCompletionRequest: Codable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}

/// A single choice in a chat completion response.
struct ChatCompletionChoice: Codable, Sendable {
    let index: Int
    let message: ChatMessage
    let finishReason: String

    enum CodingKeys: String, CodingKey {
        case index
        case message
        case finishReason = "finish_reason"
    }
}

/// Usage statistics from a chat completion response.
struct ChatCompletionUsage: Codable, Sendable {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
    }
}

/// The full response from `POST /v1/chat/completions` (non-streaming).
struct ChatCompletionResponse: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [ChatCompletionChoice]
    let usage: ChatCompletionUsage?
}

/// An error object returned by the OpenAI-compatible API.
struct OpenAIErrorResponse: Codable, Sendable {
    let error: OpenAIErrorDetail
}

struct OpenAIErrorDetail: Codable, Sendable {
    let message: String
    let type: String?
    let code: String?
}

// MARK: - Streaming Models

/// An incremental delta in a streaming chat completion chunk.
///
/// Both `role` and `content` are optional because streaming deltas
/// frequently contain only one or the other:
/// - The first chunk typically contains only `role` (e.g. `"assistant"`).
/// - Subsequent chunks typically contain only `content` (incremental text).
/// - The final chunk may contain only `finish_reason` with an empty delta.
struct ChatCompletionStreamDelta: Codable, Hashable, Sendable {
    let role: String?
    let content: String?
}

/// A single choice in a streaming chat completion chunk.
///
/// In streaming mode, `delta` contains incremental content rather than a full `message`.
struct ChatCompletionStreamChoice: Codable, Sendable {
    let index: Int
    let delta: ChatCompletionStreamDelta
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index
        case delta
        case finishReason = "finish_reason"
    }
}

/// A single SSE chunk from `POST /v1/chat/completions` with `stream: true`.
struct ChatCompletionStreamChunk: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [ChatCompletionStreamChoice]
    let usage: ChatCompletionUsage?
}
