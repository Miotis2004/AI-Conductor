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
    case streamEndedWithoutContent
    case invalidUTF8

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
        case .streamEndedWithoutContent:
            return "The stream ended without returning any content."
        case .invalidUTF8:
            return "The server returned invalid UTF-8 data."
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
    /// Parses Server-Sent Events incrementally with proper UTF-8 handling and
    /// yields each `ChatCompletionStreamChunk` as it arrives.
    ///
    /// - Parameters:
    ///   - model: The model identifier to use.
    ///   - prompt: The user's prompt text.
    /// - Returns: An `AsyncThrowingStream` of `ChatCompletionStreamChunk` values.
    /// - Throws: `OpenAIError` if the request fails, the stream contains invalid
    ///   UTF-8, or the stream ends without any valid content.
    func streamChatCompletion(
        model: String,
        prompt: String
    ) -> AsyncThrowingStream<ChatCompletionStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(
                        model: model,
                        prompt: prompt,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    // Cancellation is not an error — finish cleanly.
                    continuation.finish()
                } catch let error as OpenAIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: OpenAIError.networkError(underlying: error))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Sends a streaming chat completion request and reports the HTTP status
    /// code as soon as the response headers are received.
    ///
    /// This is useful for clearing the prompt editor as soon as the backend
    /// accepts the request (HTTP 2xx), without waiting for the entire
    /// response to finish.
    ///
    /// - Parameters:
    ///   - model: The model identifier to use.
    ///   - prompt: The user's prompt text.
    ///   - onAccepted: A closure called with the HTTP status code as soon as
    ///     the response headers are received. Called on the main actor.
    /// - Returns: An `AsyncThrowingStream` of `ChatCompletionStreamChunk` values.
    /// - Throws: `OpenAIError` if the request fails, the stream contains invalid
    ///   UTF-8, or the stream ends without any valid content.
    func streamChatCompletion(
        model: String,
        prompt: String,
        onAccepted: @escaping @MainActor (Int) -> Void
    ) -> AsyncThrowingStream<ChatCompletionStreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runStream(
                        model: model,
                        prompt: prompt,
                        continuation: continuation,
                        onAccepted: onAccepted
                    )
                } catch is CancellationError {
                    // Cancellation is not an error — finish cleanly.
                    continuation.finish()
                } catch let error as OpenAIError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: OpenAIError.networkError(underlying: error))
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - SSE Streaming Implementation

    /// Executes the streaming request and feeds parsed chunks into the continuation.
    ///
    /// Uses `URLSession.AsyncBytes` for incremental delivery, with a UTF-8
    /// incremental decoder to handle multi-byte characters that span chunk
    /// boundaries. All errors (network, HTTP, decoding, cancellation) are
    /// propagated to the continuation.
    private func runStream(
        model: String,
        prompt: String,
        continuation: AsyncThrowingStream<ChatCompletionStreamChunk, Error>.Continuation,
        onAccepted: (@MainActor (Int) -> Void)? = nil
    ) async throws {
        let url = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuth(to: &request)

        let body = ChatCompletionRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: prompt)],
            stream: true
        )
        request.httpBody = try JSONEncoder().encode(body)

        // Use bytes(for:) for incremental streaming.
        let (bytes, response) = try await session.bytes(for: request)

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

        // Report the HTTP status code as soon as the response is accepted.
        // This allows the caller to clear the prompt editor immediately
        // without waiting for the entire stream to finish.
        if let onAccepted = onAccepted {
            Task { @MainActor in
                onAccepted(httpResponse.statusCode)
            }
        }

        // Parse SSE events incrementally with proper UTF-8 handling.
        var utf8Decoder = UTF8IncrementalDecoder()
        var lineBuffer = ""
        var receivedAnyContent = false

        for try await byte in bytes {
            // Check for cancellation on each byte.
            if Task.isCancelled {
                throw CancellationError()
            }

            // Decode the byte into a character, handling multi-byte UTF-8
            // sequences that may span chunk boundaries.
            let decoded = utf8Decoder.decode(byte)
            switch decoded {
            case .success(let char):
                lineBuffer.append(char)
            case .needMoreData:
                // Incomplete multi-byte sequence — wait for more bytes.
                continue
            case .failure:
                throw OpenAIError.invalidUTF8
            }

            // Process complete lines.
            while let newlineRange = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[..<newlineRange.lowerBound])
                lineBuffer = String(lineBuffer[newlineRange.upperBound...])

                let trimmed = line.trimmingCharacters(in: .whitespaces)

                // Skip empty lines (event separators) and comments.
                guard !trimmed.isEmpty, !trimmed.hasPrefix(":") else { continue }

                // SSE data lines start with "data:".
                guard trimmed.hasPrefix("data:") else { continue }

                let dataString = trimmed
                    .dropFirst(5) // Remove "data:"
                    .trimmingCharacters(in: .whitespaces)

                // "[DONE]" signals the end of the stream.
                if dataString == "[DONE]" {
                    if !receivedAnyContent {
                        throw OpenAIError.streamEndedWithoutContent
                    }
                    continuation.finish()
                    return
                }

                // Decode the JSON chunk.
                guard let data = dataString.data(using: .utf8) else {
                    NSLog("OpenAIClient: Skipping SSE data line with invalid UTF-8: \(dataString.prefix(100))")
                    continue
                }

                do {
                    let chunk = try JSONDecoder().decode(
                        ChatCompletionStreamChunk.self,
                        from: data
                    )
                    // Track whether any content was received.
                    if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                        receivedAnyContent = true
                    }
                    continuation.yield(chunk)
                } catch {
                    // Malformed chunk — log with diagnostics but continue the stream.
                    NSLog("OpenAIClient: Failed to decode SSE chunk: \(error.localizedDescription). Data: \(dataString.prefix(200))")
                }
            }
        }

        // Stream ended (server closed the connection).
        // Check for any remaining data in the line buffer.
        let remaining = lineBuffer.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty, remaining.hasPrefix("data:") {
            let dataString = remaining
                .dropFirst(5)
                .trimmingCharacters(in: .whitespaces)
            if dataString != "[DONE]" {
                if let data = dataString.data(using: .utf8) {
                    do {
                        let chunk = try JSONDecoder().decode(
                            ChatCompletionStreamChunk.self,
                            from: data
                        )
                        if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                            receivedAnyContent = true
                        }
                        continuation.yield(chunk)
                    } catch {
                        NSLog("OpenAIClient: Failed to decode final SSE chunk: \(error.localizedDescription)")
                    }
                }
            }
        }

        // If the stream ended without [DONE] and without any content, that's an error.
        if !receivedAnyContent {
            throw OpenAIError.streamEndedWithoutContent
        }

        continuation.finish()
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

// MARK: - UTF-8 Incremental Decoder

/// A stateful decoder that converts individual bytes into Unicode characters,
/// correctly handling multi-byte UTF-8 sequences that span chunk boundaries.
///
/// This is critical for SSE parsing because `URLSession.AsyncBytes` delivers
/// data in arbitrary chunks, and a multi-byte character (e.g. an emoji or
/// CJK character) may be split across two chunks.
struct UTF8IncrementalDecoder: Sendable {
    /// The result of decoding a single byte.
    enum Result: Sendable {
        /// Successfully decoded a character.
        case success(Character)
        /// The byte is part of a multi-byte sequence; more data is needed.
        case needMoreData
        /// The byte sequence is invalid UTF-8.
        case failure
    }

    // State for tracking an in-progress multi-byte sequence.
    private var pendingBytes: [UInt8] = []
    private var expectedLength: Int = 0

    /// Decodes a single byte, returning a character when the sequence is complete.
    ///
    /// - Parameter byte: The next byte from the stream.
    /// - Returns: A `Result` indicating success, need for more data, or failure.
    mutating func decode(_ byte: UInt8) -> Result {
        // If we're in the middle of a multi-byte sequence, append the byte.
        if !pendingBytes.isEmpty {
            pendingBytes.append(byte)
            if pendingBytes.count < expectedLength {
                return .needMoreData
            }
            // Sequence complete — attempt to decode.
            let completed = pendingBytes
            pendingBytes = []
            expectedLength = 0
            if let char = decodeSequence(completed) {
                return .success(char)
            }
            return .failure
        }

        // Start of a new sequence.
        if byte < 0x80 {
            // Single-byte ASCII character.
            return .success(Character(UnicodeScalar(byte)))
        } else if byte & 0xE0 == 0xC0 {
            // 2-byte sequence.
            pendingBytes = [byte]
            expectedLength = 2
            return .needMoreData
        } else if byte & 0xF0 == 0xE0 {
            // 3-byte sequence.
            pendingBytes = [byte]
            expectedLength = 3
            return .needMoreData
        } else if byte & 0xF8 == 0xF0 {
            // 4-byte sequence.
            pendingBytes = [byte]
            expectedLength = 4
            return .needMoreData
        } else {
            // Invalid leading byte (0x80-0xBF or 0xF8-0xFF).
            return .failure
        }
    }

    /// Attempts to decode a complete multi-byte UTF-8 sequence.
    private func decodeSequence(_ bytes: [UInt8]) -> Character? {
        let data = bytes.withUnsafeBufferPointer({ Data($0) })
        guard let string = String(data: data, encoding: .utf8),
              let char = string.first else {
            return nil
        }
        return char
    }
}
