import Foundation

// MARK: - Conversation History

/// The status of a single conversation entry.
///
/// - `completed`: The request finished normally (stream or non-streaming).
/// - `interrupted`: The request was canceled or the stream was cut off before
///   completion. The partial assistant response (if any) is preserved.
/// - `failed`: The request failed before any content was received, or the
///   backend rejected the request.
enum ConversationStatus: String, Codable, Sendable {
    case completed
    case interrupted
    case failed
}

/// A single user prompt / assistant response pair in the conversation.
///
/// The user prompt is captured as an immutable value at submission time, so
/// it is preserved even after the prompt editor is cleared.
struct ConversationEntry: Identifiable, Sendable {
    /// A unique identifier for this entry.
    let id: UUID
    /// The user's prompt, captured at submission time.
    let userPrompt: String
    /// The assistant's response. May be empty if the request failed before
    /// any content was received. Partial responses from interrupted streams
    /// are preserved.
    var assistantResponse: String
    /// The status of this exchange.
    var status: ConversationStatus
    /// The model identifier used for this exchange.
    let modelID: String
    /// The timestamp at which the user prompt was submitted.
    let submittedAt: Date

    init(
        id: UUID = UUID(),
        userPrompt: String,
        assistantResponse: String = "",
        status: ConversationStatus = .completed,
        modelID: String,
        submittedAt: Date = Date()
    ) {
        self.id = id
        self.userPrompt = userPrompt
        self.assistantResponse = assistantResponse
        self.status = status
        self.modelID = modelID
        self.submittedAt = submittedAt
    }
}

/// A lightweight in-memory conversation model.
///
/// Records submitted user prompts and their corresponding assistant responses
/// in chronological order. This is a pure data type with no dependency on
/// networking or UI presentation code.
///
/// For this phase, the conversation is in-memory only and is not persisted
/// across application launches.
struct ConversationHistory: Sendable {
    /// The entries in chronological order (oldest first).
    private(set) var entries: [ConversationEntry] = []

    /// Creates an empty conversation history.
    init() {}

    /// Creates a conversation history with the given entries.
    init(entries: [ConversationEntry]) {
        self.entries = entries
    }

    /// The number of entries in the conversation.
    var count: Int { entries.count }

    /// Whether the conversation is empty.
    var isEmpty: Bool { entries.isEmpty }

    /// Appends a new entry to the conversation.
    ///
    /// Existing entries are never modified or removed.
    mutating func append(_ entry: ConversationEntry) {
        entries.append(entry)
    }

    /// Updates the assistant response and status of the entry with the given
    /// identifier.
    ///
    /// - Returns: `true` if an entry with the given identifier was found and
    ///   updated, `false` otherwise.
    @discardableResult
    mutating func updateResponse(
        for entryID: UUID,
        response: String,
        status: ConversationStatus
    ) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else {
            return false
        }
        entries[index].assistantResponse = response
        entries[index].status = status
        return true
    }

    /// Removes all entries from the conversation.
    mutating func clear() {
        entries.removeAll()
    }
}
