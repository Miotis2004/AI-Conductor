import Foundation

// MARK: - OpenAI API Errors

/// Errors that can occur when communicating with the OpenAI-compatible API.
enum OpenAIError: LocalizedError {
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case decodingError(underlying: Error)
    case networkError(underlying: Error)
    case emptyModelList
    case noChoices

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL."
        case .httpError(let statusCode, let message):
            return "HTTP \(statusCode): \(message)"
        case .decodingError:
            return "Failed to decode the server response."
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .emptyModelList:
            return "The server returned no models."
        case .noChoices:
            return "The server returned no completion choices."
        }
    }
}

// MARK: - OpenAI Client

/// A client for an OpenAI-compatible API endpoint (e.g. a local oMLX server).
///
/// All methods are `async` and use `URLSession` with async/await.
/// The client is a value type; create one per endpoint.
struct OpenAIClient: Sendable {
    /// The base URL of the OpenAI-compatible API, e.g. `http://127.0.0.1:8000/v1`.
    let baseURL: URL
    /// The API key used for `Authorization: Bearer` authentication.
    let apiKey: String
    /// The shared `URLSession` used for all requests.
    let session: URLSession

    init(
        baseURL: URL,
        apiKey: String,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Models

    /// Fetches the list of available models from `GET /v1/models`.
    ///
    /// - Returns: A non-empty array of available models.
    /// - Throws: `OpenAIError` if the request fails or no models are returned.
    func fetchModels() async throws -> [OpenAIModel] {
        let url = baseURL.appendingPathComponent("models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyAuth(to: &request)

        let (data, response) = try await perform(request: request)
        try validate(response: response, data: data)

        let decoded: OpenAIModelsResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        } catch {
            throw OpenAIError.decodingError(underlying: error)
        }

        guard !decoded.data.isEmpty else {
            throw OpenAIError.emptyModelList
        }
        return decoded.data
    }

    // MARK: - Chat Completions

    /// Sends a chat completion request to `POST /v1/chat/completions` (non-streaming).
    ///
    /// - Parameters:
    ///   - model: The model identifier to use.
    ///   - prompt: The user's prompt text.
    /// - Returns: The full `ChatCompletionResponse`.
    /// - Throws: `OpenAIError` if the request fails or the response contains no choices.
    func sendChatCompletion(model: String, prompt: String) async throws -> ChatCompletionResponse {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(to: &request)

        let body = ChatCompletionRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: prompt)],
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await perform(request: request)
        try validate(response: response, data: data)

        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw OpenAIError.decodingError(underlying: error)
        }

        guard !decoded.choices.isEmpty else {
            throw OpenAIError.noChoices
        }
        return decoded
    }

    // MARK: - Streaming Chat Completions

    /// Sends a streaming chat completion request to `POST /v1/chat/completions` with `stream: true`.
    ///
    /// Parses Server-Sent Events incrementally and yields each `ChatCompletionStreamChunk`
    /// as it arrives. The caller is responsible for cancellation via the returned `Task`.
    ///
    /// - Parameters:
    ///   - model: The model identifier to use.
    ///   - prompt: The user's prompt text.
    /// - Returns: An `AsyncThrowingStream` of `ChatCompletionStreamChunk` values.
    /// - Throws: `OpenAIError` if the request fails or the response is not a valid SSE stream.
    func streamChatCompletion(
        model: String,
        prompt: String
    ) -> AsyncThrowingStream<ChatCompletionStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let url = self.baseURL.appendingPathComponent("chat/completions")
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                self.applyAuth(to: &request)

                let body = ChatCompletionRequest(
                    model: model,
                    messages: [ChatMessage(role: "user", content: prompt)],
                    stream: true
                )
                request.httpBody = try JSONEncoder().encode(body)

                // Use bytes(for:) for incremental streaming.
                let (bytes, response) = try await self.session.bytes(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw OpenAIError.networkError(
                        underlying: NSError(
                            domain: "OpenAIClient",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid response type"]
                        )
                    )
                }

                guard (200..<300).contains(httpResponse.statusCode) else {
                    // Read the error body for a useful message.
                    var errorData = Data()
                    for try await byte in bytes {
                        errorData.append(byte)
                        if errorData.count > 4096 { break }
                    }
                    let message = Self.extractErrorMessage(from: errorData)
                    throw OpenAIError.httpError(
                        statusCode: httpResponse.statusCode,
                        message: message
                    )
                }

                // Parse SSE lines incrementally.
                var buffer = ""
                for try await byte in bytes {
                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    buffer.append(Character(UnicodeScalar(byte)))

                    // SSE events are separated by newlines.
                    while let newlineRange = buffer.range(of: "\n") {
                        let line = String(buffer[..<newlineRange.lowerBound])
                        buffer = String(buffer[newlineRange.upperBound...])

                        let trimmed = line.trimmingCharacters(in: .whitespaces)

                        // Skip empty lines (event separators) and comments.
                        guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { continue }

                        // SSE data lines start with "data: ".
                        guard trimmed.hasPrefix("data:") else { continue }

                        let dataString = trimmed
                            .dropFirst(5) // Remove "data:"
                            .trimmingCharacters(in: .whitespaces)

                        // "[DONE]" signals the end of the stream.
                        if dataString == "[DONE]" {
                            continuation.finish()
                            return
                        }

                        // Decode the JSON chunk.
                        guard let data = dataString.data(using: .utf8) else {
                            continue
                        }

                        do {
                            let chunk = try JSONDecoder().decode(
                                ChatCompletionStreamChunk.self,
                                from: data
                            )
                            continuation.yield(chunk)
                        } catch {
                            // Malformed chunk — skip it but continue the stream.
                            // The caller can decide how to handle decode failures.
                            NSLog("OpenAIClient: Failed to decode SSE chunk: \(error.localizedDescription)")
                        }
                    }
                }

                // Stream ended normally.
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Private Helpers

    private func applyAuth(to request: inout URLRequest) {
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func perform(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw OpenAIError.networkError(underlying: NSError(domain: "OpenAIClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response type"]))
            }
            return (data, httpResponse)
        } catch {
            throw OpenAIError.networkError(underlying: error)
        }
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = Self.extractErrorMessage(from: data)
            throw OpenAIError.httpError(
                statusCode: response.statusCode,
                message: message
            )
        }
    }

    /// Attempts to extract a human-readable error message from an API error body.
    private static func extractErrorMessage(from data: Data) -> String {
        if let errorResponse = try? JSONDecoder().decode(OpenAIErrorResponse.self, from: data) {
            return errorResponse.error.message
        }
        if let string = String(data: data, encoding: .utf8), !string.isEmpty {
            return String(string.prefix(500))
        }
        return "Unknown error"
    }
}
