import Foundation

// MARK: - Request Performance Statistics

/// Performance statistics for a single chat completion request.
///
/// Clearly distinguishes server-reported values from locally measured estimates.
struct RequestStats: Sendable {
    /// Time from request start to first visible response token (seconds).
    /// Measured locally — not a server-reported metric.
    let timeToFirstToken: Double?

    /// Total elapsed time from request start to completion (seconds).
    /// Measured locally — not a server-reported metric.
    let totalElapsed: Double?

    /// Output token count.
    let outputTokens: Int?

    /// Whether the output token count was reported by the server or estimated locally.
    let outputTokensIsServerReported: Bool

    /// Average output tokens per second.
    /// Computed from the output token count and the time from first token to completion.
    let averageTokensPerSecond: Double?

    /// A human-readable summary of the statistics.
    var summary: String {
        var parts: [String] = []

        if let ttft = timeToFirstToken {
            parts.append(String(format: "TTFT: %.2fs", ttft))
        }
        if let total = totalElapsed {
            parts.append(String(format: "Total: %.2fs", total))
        }
        if let tokens = outputTokens {
            let label = outputTokensIsServerReported ? "reported" : "est."
            parts.append(String(format: "Tokens: %d (%@)", tokens, label))
        }
        if let tps = averageTokensPerSecond {
            parts.append(String(format: "Speed: %.1f tok/s", tps))
        }

        return parts.isEmpty ? "No stats" : parts.joined(separator: "  ·  ")
    }
}
