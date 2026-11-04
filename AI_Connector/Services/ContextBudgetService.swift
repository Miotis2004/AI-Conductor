import Foundation
import Observation

// MARK: - Context Budget

/// A description of the estimated context usage for a model request.
struct ContextBudget: Sendable {
    /// The model's maximum context length in tokens (from `max_model_len`).
    let maxModelLen: Int?
    /// The number of tokens reserved for the model's output.
    let outputReserve: Int
    /// The estimated number of tokens for the prompt (user text + attachments).
    let estimatedPromptTokens: Int
    /// The estimated number of tokens for system/prompt overhead.
    let overheadTokens: Int
    /// The total estimated tokens (prompt + overhead).
    var totalEstimatedTokens: Int {
        estimatedPromptTokens + overheadTokens
    }
    /// The usable context budget (max - output reserve).
    var usableContext: Int? {
        guard let maxLen = maxModelLen else { return nil }
        return max(0, maxLen - outputReserve)
    }
    /// Whether the estimated usage exceeds the usable context budget.
    var exceedsBudget: Bool {
        guard let usable = usableContext else { return false }
        return totalEstimatedTokens > usable
    }
    /// The amount by which the estimated usage exceeds the budget (0 if within budget).
    var overage: Int {
        guard let usable = usableContext else { return 0 }
        return max(0, totalEstimatedTokens - usable)
    }
    /// Whether the model's context metadata is available and reliable.
    var hasReliableMetadata: Bool {
        maxModelLen != nil && maxModelLen! > 0
    }

    init(
        maxModelLen: Int?,
        outputReserve: Int,
        estimatedPromptTokens: Int,
        overheadTokens: Int
    ) {
        self.maxModelLen = maxModelLen
        self.outputReserve = outputReserve
        self.estimatedPromptTokens = estimatedPromptTokens
        self.overheadTokens = overheadTokens
    }
}

// MARK: - Context Budget Service

/// A lightweight service for estimating context usage and checking whether
/// a request will fit within the selected model's context window.
///
/// Token estimation is character-based (~4 characters per token for English
/// text) and is clearly labeled as an estimate. The service uses the
/// model's reported `max_model_len` when available, includes a configurable
/// output-token reserve, and accounts for prompt overhead.
///
/// When the model's context metadata is missing or unreliable, the service
/// handles it conservatively: it does not assume a budget and does not
/// block submission, but it does warn the user that the budget is unknown.
///
/// The service is a pure value type with no dependency on UI or networking,
/// making it straightforward to unit test.
struct ContextBudgetService: Sendable {

    // MARK: - Configuration

    /// The number of tokens reserved for the model's output.
    var outputReserve: Int = 1024

    /// The estimated number of tokens for system/prompt overhead
    /// (role markers, formatting, etc.).
    var overheadTokens: Int = 50

    /// The characters-per-token ratio used for estimation.
    /// ~4 characters per token is a reasonable estimate for English text.
    var charactersPerToken: Double = 4.0

    // MARK: - Token Estimation

    /// Estimates the number of tokens for a given string.
    ///
    /// Uses a character-based heuristic (~4 characters per token). This is
    /// an estimate, not an exact count.
    ///
    /// - Parameter text: The text to estimate.
    /// - Returns: The estimated token count (minimum 1 for non-empty text).
    func estimateTokens(for text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return max(1, Int(ceil(Double(text.count) / charactersPerToken)))
    }

    // MARK: - Budget Calculation

    /// Calculates the context budget for a request.
    ///
    /// - Parameters:
    ///   - maxModelLen: The model's maximum context length in tokens, if known.
    ///   - promptText: The user's prompt text.
    ///   - attachmentContents: The contents of attached files.
    /// - Returns: A `ContextBudget` describing the estimated usage.
    func calculateBudget(
        maxModelLen: Int?,
        promptText: String,
        attachmentContents: [String]
    ) -> ContextBudget {
        // Estimate tokens for the prompt.
        let promptTokens = estimateTokens(for: promptText)

        // Estimate tokens for attachments.
        let attachmentTokens = attachmentContents.reduce(0) { $0 + estimateTokens(for: $1) }

        let totalPromptTokens = promptTokens + attachmentTokens

        return ContextBudget(
            maxModelLen: maxModelLen,
            outputReserve: outputReserve,
            estimatedPromptTokens: totalPromptTokens,
            overheadTokens: overheadTokens
        )
    }

    /// Calculates the context budget for a request with attachments that
    /// have pre-computed token estimates.
    ///
    /// - Parameters:
    ///   - maxModelLen: The model's maximum context length in tokens, if known.
    ///   - promptText: The user's prompt text.
    ///   - attachmentTokenEstimates: Pre-computed token estimates for each attachment.
    /// - Returns: A `ContextBudget` describing the estimated usage.
    func calculateBudget(
        maxModelLen: Int?,
        promptText: String,
        attachmentTokenEstimates: [Int]
    ) -> ContextBudget {
        let promptTokens = estimateTokens(for: promptText)
        let attachmentTokens = attachmentTokenEstimates.reduce(0, +)
        let totalPromptTokens = promptTokens + attachmentTokens

        return ContextBudget(
            maxModelLen: maxModelLen,
            outputReserve: outputReserve,
            estimatedPromptTokens: totalPromptTokens,
            overheadTokens: overheadTokens
        )
    }

    // MARK: - Warning Messages

    /// Generates a warning message if the request exceeds the estimated budget.
    ///
    /// - Parameter budget: The context budget to check.
    /// - Returns: A warning message, or `nil` if the request is within budget.
    func warningMessage(for budget: ContextBudget) -> String? {
        if !budget.hasReliableMetadata {
            return "Model context size is unknown. The request may exceed the model's context window."
        }

        if budget.exceedsBudget {
            let usable = budget.usableContext ?? 0
            return "Estimated context usage (\(budget.totalEstimatedTokens) tokens) exceeds the model's usable context (\(usable) tokens) by \(budget.overage) tokens. Remove some attachments or shorten the prompt."
        }

        // Warn if close to the limit (>80% usage).
        if let usable = budget.usableContext, usable > 0 {
            let usageRatio = Double(budget.totalEstimatedTokens) / Double(usable)
            if usageRatio > 0.8 {
                return "Estimated context usage is \(Int(usageRatio * 100))% of the model's context window. Consider removing attachments if the response is truncated."
            }
        }

        return nil
    }
}
