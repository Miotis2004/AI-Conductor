import Foundation
import SwiftUI
import Observation

// MARK: - Connection State

/// Represents the current connection state to the oMLX endpoint.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

// MARK: - Chat ViewModel

/// The view model that drives the chat interface.
///
/// It is `@MainActor`-isolated (matching the project's `SWIFT_DEFAULT_ACTOR_ISOLATION`)
/// and uses `@Observable` for SwiftUI integration.
@Observable
@MainActor
final class ChatViewModel {
    // MARK: - Published State

    /// The current connection state.
    var connectionState: ConnectionState = .disconnected
    /// The list of models fetched from the server.
    var models: [OpenAIModel] = []
    /// The currently selected model identifier.
    var selectedModelID: String?
    /// The user's prompt text.
    var prompt: String = ""
    /// The assistant's response text.
    var response: String = ""
    /// Whether a chat completion request is in flight.
    var isLoading: Bool = false
    /// The API key (loaded from / saved to the Keychain).
    var apiKey: String = ""
    /// The base URL of the oMLX endpoint.
    var baseURL: String = "http://127.0.0.1:8000/v1"
    /// Performance statistics for the most recent request.
    var requestStats: RequestStats?

    // MARK: - Private

    private var client: OpenAIClient?
    private var streamTask: Task<Void, Never>?

    // MARK: - Init

    init() {
        self.apiKey = KeychainStore.load() ?? ""
    }

    // MARK: - Connection

    /// Connects to the oMLX endpoint and fetches the list of available models.
    func connect() async {
        guard let url = URL(string: baseURL) else {
            connectionState = .failed("Invalid base URL: \(baseURL)")
            return
        }

        connectionState = .connecting
        models = []
        selectedModelID = nil
        response = ""
        requestStats = nil

        let client = OpenAIClient(baseURL: url, apiKey: apiKey)
        self.client = client

        do {
            let fetched = try await client.fetchModels()
            models = fetched
            selectedModelID = fetched.first?.id
            connectionState = .connected
        } catch let error as OpenAIError {
            connectionState = .failed(error.localizedDescription)
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Chat

    /// Sends the current prompt to the selected model using streaming.
    ///
    /// Falls back to non-streaming if the streaming request fails before any
    /// content has been received.
    func send() async {
        guard let modelID = selectedModelID,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Rebuild the client in case the API key or base URL changed.
        guard let url = URL(string: baseURL) else {
            connectionState = .failed("Invalid base URL: \(baseURL)")
            return
        }
        let client = OpenAIClient(baseURL: url, apiKey: apiKey)
        self.client = client

        isLoading = true
        response = ""
        requestStats = nil

        // Track timing locally.
        let startTime = Date()
        var firstTokenTime: Date?
        var receivedAnyContent = false
        var serverReportedTokens: Int?

        defer {
            isLoading = false
            streamTask = nil
        }

        let stream = client.streamChatCompletion(model: modelID, prompt: prompt)

        streamTask = Task {
            do {
                for try await chunk in stream {
                    // Check for cancellation.
                    if Task.isCancelled {
                        break
                    }

                    // Extract content from the first choice's delta.
                    if let delta = chunk.choices.first?.delta,
                       let content = delta.content,
                       !content.isEmpty {
                        if !receivedAnyContent {
                            firstTokenTime = Date()
                            receivedAnyContent = true
                        }
                        response += content
                    }

                    // Capture server-reported usage if present.
                    if let usage = chunk.usage {
                        serverReportedTokens = usage.completionTokens
                    }
                }
            } catch let error as OpenAIError {
                // Streaming failed — fall back to non-streaming if we
                // haven't received any content yet.
                if !receivedAnyContent {
                    await self.fallbackToNonStreaming(
                        client: client,
                        model: modelID,
                        startTime: startTime
                    )
                } else {
                    // We got partial content before the error.
                    self.response = "Error: \(error.localizedDescription)"
                    self.connectionState = .failed(error.localizedDescription)
                }
            } catch {
                if !receivedAnyContent {
                    await self.fallbackToNonStreaming(
                        client: client,
                        model: modelID,
                        startTime: startTime
                    )
                } else {
                    self.response = "Error: \(error.localizedDescription)"
                    self.connectionState = .failed(error.localizedDescription)
                }
            }

            // Compute final stats.
            let endTime = Date()
            let totalElapsed = endTime.timeIntervalSince(startTime)
            let ttft = firstTokenTime?.timeIntervalSince(startTime)

            // Estimate tokens if the server didn't report usage.
            // Rough estimate: ~4 characters per token for English text.
            let estimatedTokens = max(1, response.count / 4)
            let outputTokens = serverReportedTokens ?? estimatedTokens
            let isServerReported = serverReportedTokens != nil

            // Tokens per second: tokens generated / time from first token to end.
            let generationTime = firstTokenTime.map { endTime.timeIntervalSince($0) } ?? totalElapsed
            let tps = generationTime > 0 ? Double(outputTokens) / generationTime : nil

            self.requestStats = RequestStats(
                timeToFirstToken: ttft,
                totalElapsed: totalElapsed,
                outputTokens: outputTokens,
                outputTokensIsServerReported: isServerReported,
                averageTokensPerSecond: tps
            )

            if !Task.isCancelled {
                self.connectionState = .connected
            }
        }

        // Wait for the stream task to complete.
        await streamTask?.value
    }

    /// Cancels the active streaming request.
    func stopGeneration() {
        streamTask?.cancel()
        streamTask = nil
        isLoading = false
        connectionState = .connected
    }

    // MARK: - Non-Streaming Fallback

    private func fallbackToNonStreaming(
        client: OpenAIClient,
        model: String,
        startTime: Date
    ) async {
        do {
            let result = try await client.sendChatCompletion(model: model, prompt: prompt)
            let endTime = Date()
            let totalElapsed = endTime.timeIntervalSince(startTime)

            let content = result.choices.first?.message.content ?? ""
            response = content

            let serverTokens = result.usage?.completionTokens
            let estimatedTokens = max(1, content.count / 4)
            let outputTokens = serverTokens ?? estimatedTokens
            let isServerReported = serverTokens != nil

            // For non-streaming, TTFT == total elapsed (no incremental delivery).
            let tps = totalElapsed > 0 ? Double(outputTokens) / totalElapsed : nil

            requestStats = RequestStats(
                timeToFirstToken: totalElapsed,
                totalElapsed: totalElapsed,
                outputTokens: outputTokens,
                outputTokensIsServerReported: isServerReported,
                averageTokensPerSecond: tps
            )
            connectionState = .connected
        } catch let error as OpenAIError {
            response = "Error: \(error.localizedDescription)"
            connectionState = .failed(error.localizedDescription)
        } catch {
            response = "Error: \(error.localizedDescription)"
            connectionState = .failed(error.localizedDescription)
        }
    }

    // MARK: - API Key

    /// Persists the current API key to the Keychain.
    func saveAPIKey() {
        KeychainStore.save(apiKey)
    }

    /// Clears the stored API key from the Keychain and the UI.
    func clearAPIKey() {
        KeychainStore.delete()
        apiKey = ""
    }
}
