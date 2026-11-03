import XCTest
import Foundation

// This test file tests the streaming components of AI_Connector.
//
// To run these tests, compile them together with the source files:
//   swiftc -enable-testing \
//     AI_Connector/Networking/OpenAIModels.swift \
//     AI_Connector/Networking/OpenAIClient.swift \
//     AI_Connector/Networking/RequestStats.swift \
//     AI_ConnectorTests/StreamingTests.swift \
//     -F $(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks \
//     -I $(xcrun --show-sdk-platform-path)/Developer/usr/lib \
//     -o StreamingTests
//
// Then run:
//   ./StreamingTests

// Re-declare the types under test (mirrors the app's internal types).
// This avoids the need for @testable import which requires a pre-built module.

// MARK: - UTF8IncrementalDecoder (mirrors AI_Connector/Networking/OpenAIClient.swift)

struct UTF8IncrementalDecoder: Sendable {
    enum Result: Sendable {
        case success(Character)
        case needMoreData
        case failure
    }

    private var pendingBytes: [UInt8] = []
    private var expectedLength: Int = 0

    mutating func decode(_ byte: UInt8) -> Result {
        if !pendingBytes.isEmpty {
            pendingBytes.append(byte)
            if pendingBytes.count < expectedLength {
                return .needMoreData
            }
            let completed = pendingBytes
            pendingBytes = []
            expectedLength = 0
            if let char = decodeSequence(completed) {
                return .success(char)
            }
            return .failure
        }

        if byte < 0x80 {
            return .success(Character(UnicodeScalar(byte)))
        } else if byte & 0xE0 == 0xC0 {
            pendingBytes = [byte]
            expectedLength = 2
            return .needMoreData
        } else if byte & 0xF0 == 0xE0 {
            pendingBytes = [byte]
            expectedLength = 3
            return .needMoreData
        } else if byte & 0xF8 == 0xF0 {
            pendingBytes = [byte]
            expectedLength = 4
            return .needMoreData
        } else {
            return .failure
        }
    }

    private func decodeSequence(_ bytes: [UInt8]) -> Character? {
        let data = bytes.withUnsafeBufferPointer({ Data($0) })
        guard let string = String(data: data, encoding: .utf8),
              let char = string.first else {
            return nil
        }
        return char
    }
}

// MARK: - ChatCompletionStreamDelta (mirrors AI_Connector/Networking/OpenAIModels.swift)

struct ChatCompletionStreamDelta: Codable, Hashable, Sendable {
    let role: String?
    let content: String?
}

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

struct ChatCompletionStreamChunk: Codable, Sendable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [ChatCompletionStreamChoice]
    let usage: ChatCompletionUsage?
}

// MARK: - RequestStats (mirrors AI_Connector/Networking/RequestStats.swift)

struct RequestStats: Sendable {
    let timeToFirstToken: Double?
    let totalElapsed: Double?
    let outputTokens: Int?
    let outputTokensIsServerReported: Bool
    let averageTokensPerSecond: Double?

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

// MARK: - OpenAIError (mirrors AI_Connector/Networking/OpenAIClient.swift)

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

// MARK: - UTF8IncrementalDecoder Tests

final class UTF8IncrementalDecoderTests: XCTestCase {

    func testSingleByteASCII() {
        var decoder = UTF8IncrementalDecoder()
        let result = decoder.decode(0x41)
        guard case .success(let char) = result else {
            XCTFail("Expected success, got \(result)")
            return
        }
        XCTAssertEqual(char, "A")
    }

    func testTwoByteSequence() {
        var decoder = UTF8IncrementalDecoder()
        let result1 = decoder.decode(0xC3)
        guard case .needMoreData = result1 else {
            XCTFail("Expected needMoreData, got \(result1)")
            return
        }
        let result2 = decoder.decode(0xA9)
        guard case .success(let char) = result2 else {
            XCTFail("Expected success, got \(result2)")
            return
        }
        XCTAssertEqual(char, "\u{E9}")
    }

    func testThreeByteSequence() {
        var decoder = UTF8IncrementalDecoder()
        let r1 = decoder.decode(0xE2)
        guard case .needMoreData = r1 else { XCTFail("Expected needMoreData"); return }
        let r2 = decoder.decode(0x82)
        guard case .needMoreData = r2 else { XCTFail("Expected needMoreData"); return }
        let r3 = decoder.decode(0xAC)
        guard case .success(let char) = r3 else { XCTFail("Expected success, got \(r3)"); return }
        XCTAssertEqual(char, "\u{20AC}")
    }

    func testFourByteSequence() {
        var decoder = UTF8IncrementalDecoder()
        let r1 = decoder.decode(0xF0)
        guard case .needMoreData = r1 else { XCTFail("Expected needMoreData"); return }
        let r2 = decoder.decode(0x9F)
        guard case .needMoreData = r2 else { XCTFail("Expected needMoreData"); return }
        let r3 = decoder.decode(0x98)
        guard case .needMoreData = r3 else { XCTFail("Expected needMoreData"); return }
        let r4 = decoder.decode(0x80)
        guard case .success(let char) = r4 else { XCTFail("Expected success, got \(r4)"); return }
        XCTAssertEqual(char, "\u{1F600}")
    }

    func testMultiByteCharacterSplitAcrossChunks() {
        var decoder = UTF8IncrementalDecoder()
        for byte in "Hello".utf8 {
            let result = decoder.decode(byte)
            guard case .success = result else {
                XCTFail("Expected success for ASCII byte \(byte)")
                return
            }
        }
        let spaceResult = decoder.decode(0x20)
        guard case .success = spaceResult else {
            XCTFail("Expected success for space")
            return
        }
        let emojiBytes: [UInt8] = [0xF0, 0x9F, 0x98, 0x80]
        let r1 = decoder.decode(emojiBytes[0])
        guard case .needMoreData = r1 else { XCTFail("Expected needMoreData"); return }
        let r2 = decoder.decode(emojiBytes[1])
        guard case .needMoreData = r2 else { XCTFail("Expected needMoreData"); return }
        let r3 = decoder.decode(emojiBytes[2])
        guard case .needMoreData = r3 else { XCTFail("Expected needMoreData"); return }
        let r4 = decoder.decode(emojiBytes[3])
        guard case .success(let char) = r4 else { XCTFail("Expected success, got \(r4)"); return }
        XCTAssertEqual(char, "\u{1F600}")
    }

    func testInvalidLeadingByte() {
        var decoder = UTF8IncrementalDecoder()
        let result = decoder.decode(0x80)
        guard case .failure = result else {
            XCTFail("Expected failure for invalid leading byte 0x80")
            return
        }
    }

    func testInvalidByte0xFF() {
        var decoder = UTF8IncrementalDecoder()
        let result = decoder.decode(0xFF)
        guard case .failure = result else {
            XCTFail("Expected failure for byte 0xFF")
            return
        }
    }

    func testMixedContent() {
        var decoder = UTF8IncrementalDecoder()
        let text = "Hello, wörld! €100 😀"
        var decoded = ""
        for byte in text.utf8 {
            let result = decoder.decode(byte)
            guard case .success(let char) = result else {
                XCTFail("Expected success for byte \(byte), got \(result)")
                return
            }
            decoded.append(char)
        }
        XCTAssertEqual(decoded, text)
    }
}

// MARK: - ChatCompletionStreamDelta Tests

final class ChatCompletionStreamDeltaTests: XCTestCase {

    func testRoleOnlyDelta() throws {
        let json = """
        {
            "id": "chatcmpl-123",
            "object": "chat.completion.chunk",
            "created": 1694268190,
            "model": "gpt-4",
            "choices": [
                {
                    "index": 0,
                    "delta": { "role": "assistant", "content": null },
                    "finish_reason": null
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data)
        XCTAssertEqual(chunk.choices.count, 1)
        XCTAssertEqual(chunk.choices[0].delta.role, "assistant")
        XCTAssertNil(chunk.choices[0].delta.content)
        XCTAssertNil(chunk.choices[0].finishReason)
    }

    func testContentOnlyDelta() throws {
        let json = """
        {
            "id": "chatcmpl-123",
            "object": "chat.completion.chunk",
            "created": 1694268190,
            "model": "gpt-4",
            "choices": [
                {
                    "index": 0,
                    "delta": { "content": "Hello" },
                    "finish_reason": null
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data)
        XCTAssertEqual(chunk.choices.count, 1)
        XCTAssertNil(chunk.choices[0].delta.role)
        XCTAssertEqual(chunk.choices[0].delta.content, "Hello")
    }

    func testRoleAndContentDelta() throws {
        let json = """
        {
            "id": "chatcmpl-123",
            "object": "chat.completion.chunk",
            "created": 1694268190,
            "model": "gpt-4",
            "choices": [
                {
                    "index": 0,
                    "delta": { "role": "assistant", "content": "Hi" },
                    "finish_reason": null
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data)
        XCTAssertEqual(chunk.choices[0].delta.role, "assistant")
        XCTAssertEqual(chunk.choices[0].delta.content, "Hi")
    }

    func testFinishReasonChunk() throws {
        let json = """
        {
            "id": "chatcmpl-123",
            "object": "chat.completion.chunk",
            "created": 1694268190,
            "model": "gpt-4",
            "choices": [
                {
                    "index": 0,
                    "delta": {},
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 5,
                "total_tokens": 15
            }
        }
        """
        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data)
        XCTAssertNil(chunk.choices[0].delta.role)
        XCTAssertNil(chunk.choices[0].delta.content)
        XCTAssertEqual(chunk.choices[0].finishReason, "stop")
        XCTAssertEqual(chunk.usage?.completionTokens, 5)
    }

    func testUnicodeContentDelta() throws {
        let json = """
        {
            "id": "chatcmpl-123",
            "object": "chat.completion.chunk",
            "created": 1694268190,
            "model": "gpt-4",
            "choices": [
                {
                    "index": 0,
                    "delta": { "content": "Héllo wörld! €100 😀" },
                    "finish_reason": null
                }
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data)
        XCTAssertEqual(chunk.choices[0].delta.content, "Héllo wörld! €100 😀")
    }

    func testMalformedJSON() {
        let json = """
        { "id": "chatcmpl-123", "object": "chat.completion.chunk",
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data)
        )
    }

    func testMissingRequiredFields() {
        let json = """
        { "choices": [] }
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(
            try JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data)
        )
    }
}

// MARK: - SSE Parsing Tests

final class SSEParsingTests: XCTestCase {

    func testSSEDataLineParsing() throws {
        let sseText = """
        data: {"id":"1","object":"chat.completion.chunk","created":1,"model":"test","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}

        data: {"id":"1","object":"chat.completion.chunk","created":1,"model":"test","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

        data: {"id":"1","object":"chat.completion.chunk","created":1,"model":"test","choices":[{"index":0,"delta":{"content":" World"},"finish_reason":null}]}

        data: [DONE]

        """
        let bytes = Array(sseText.utf8)
        var decoder = UTF8IncrementalDecoder()
        var lineBuffer = ""
        var dataLines: [String] = []

        for byte in bytes {
            let decoded = decoder.decode(byte)
            guard case .success(let char) = decoded else {
                XCTFail("Unexpected decode failure for byte \(byte)")
                return
            }
            lineBuffer.append(char)

            while let newlineRange = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[..<newlineRange.lowerBound])
                lineBuffer = String(lineBuffer[newlineRange.upperBound...])

                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix(":"), trimmed.hasPrefix("data:") else {
                    continue
                }

                let dataString = trimmed
                    .dropFirst(5)
                    .trimmingCharacters(in: .whitespaces)
                dataLines.append(dataString)
            }
        }

        XCTAssertEqual(dataLines.count, 4)
        XCTAssertEqual(dataLines[3], "[DONE]")

        for (index, line) in dataLines.prefix(3).enumerated() {
            let data = line.data(using: .utf8)!
            let chunk = try JSONDecoder().decode(ChatCompletionStreamChunk.self, from: data)
            XCTAssertEqual(chunk.id, "1")
            if index == 0 {
                XCTAssertEqual(chunk.choices[0].delta.role, "assistant")
            }
        }
    }

    func testDoneSentinel() throws {
        let sseText = "data: [DONE]\n"
        let bytes = Array(sseText.utf8)
        var decoder = UTF8IncrementalDecoder()
        var lineBuffer = ""
        var receivedDone = false

        for byte in bytes {
            let decoded = decoder.decode(byte)
            guard case .success(let char) = decoded else {
                XCTFail("Unexpected decode failure")
                return
            }
            lineBuffer.append(char)

            while let newlineRange = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[..<newlineRange.lowerBound])
                lineBuffer = String(lineBuffer[newlineRange.upperBound...])

                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("data:") else { continue }

                let dataString = trimmed
                    .dropFirst(5)
                    .trimmingCharacters(in: .whitespaces)

                if dataString == "[DONE]" {
                    receivedDone = true
                }
            }
        }

        XCTAssertTrue(receivedDone)
    }

    func testCommentsAndEmptyLines() throws {
        let sseText = """
        : This is a comment

        data: {"id":"1","object":"chat.completion.chunk","created":1,"model":"test","choices":[{"index":0,"delta":{"content":"test"},"finish_reason":null}]}


        : Another comment

        """
        let bytes = Array(sseText.utf8)
        var decoder = UTF8IncrementalDecoder()
        var lineBuffer = ""
        var dataLines: [String] = []

        for byte in bytes {
            let decoded = decoder.decode(byte)
            guard case .success(let char) = decoded else {
                XCTFail("Unexpected decode failure")
                return
            }
            lineBuffer.append(char)

            while let newlineRange = lineBuffer.range(of: "\n") {
                let line = String(lineBuffer[..<newlineRange.lowerBound])
                lineBuffer = String(lineBuffer[newlineRange.upperBound...])

                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix(":"), trimmed.hasPrefix("data:") else {
                    continue
                }

                let dataString = trimmed
                    .dropFirst(5)
                    .trimmingCharacters(in: .whitespaces)
                dataLines.append(dataString)
            }
        }

        XCTAssertEqual(dataLines.count, 1)
    }

    func testMultiByteCharacterAtLineBoundary() throws {
        let text = "Héllo"
        let bytes = Array(text.utf8)
        var decoder = UTF8IncrementalDecoder()
        var decodedText = ""

        for byte in bytes {
            let decoded = decoder.decode(byte)
            guard case .success(let char) = decoded else {
                XCTFail("Unexpected decode failure for byte \(byte)")
                return
            }
            decodedText.append(char)
        }

        XCTAssertEqual(decodedText, "Héllo")
    }
}

// MARK: - RequestStats Tests

final class RequestStatsTests: XCTestCase {

    func testZeroTokenResponse() {
        let stats = RequestStats(
            timeToFirstToken: nil,
            totalElapsed: 1.5,
            outputTokens: 0,
            outputTokensIsServerReported: false,
            averageTokensPerSecond: nil
        )
        XCTAssertEqual(stats.outputTokens, 0)
        XCTAssertFalse(stats.outputTokensIsServerReported)
        XCTAssertNil(stats.averageTokensPerSecond)
        XCTAssertFalse(stats.summary.contains("Tokens: 1"))
    }

    func testEstimatedTokens() {
        let stats = RequestStats(
            timeToFirstToken: 0.5,
            totalElapsed: 2.0,
            outputTokens: 100,
            outputTokensIsServerReported: false,
            averageTokensPerSecond: 66.7
        )
        XCTAssertEqual(stats.outputTokens, 100)
        XCTAssertFalse(stats.outputTokensIsServerReported)
        XCTAssertTrue(stats.summary.contains("est."))
    }

    func testServerReportedTokens() {
        let stats = RequestStats(
            timeToFirstToken: 0.3,
            totalElapsed: 1.0,
            outputTokens: 50,
            outputTokensIsServerReported: true,
            averageTokensPerSecond: 71.4
        )
        XCTAssertEqual(stats.outputTokens, 50)
        XCTAssertTrue(stats.outputTokensIsServerReported)
        XCTAssertFalse(stats.summary.contains("est."))
    }

    func testNoStats() {
        let stats = RequestStats(
            timeToFirstToken: nil,
            totalElapsed: nil,
            outputTokens: nil,
            outputTokensIsServerReported: false,
            averageTokensPerSecond: nil
        )
        XCTAssertEqual(stats.summary, "No stats")
    }
}

// MARK: - OpenAIError Tests

final class OpenAIErrorTests: XCTestCase {

    func testStreamEndedWithoutContentDescription() {
        let error = OpenAIError.streamEndedWithoutContent
        XCTAssertEqual(error.errorDescription, "The stream ended without returning any content.")
    }

    func testInvalidUTF8Description() {
        let error = OpenAIError.invalidUTF8
        XCTAssertEqual(error.errorDescription, "The server returned invalid UTF-8 data.")
    }

    func testHTTPErrorDescription() {
        let error = OpenAIError.httpError(statusCode: 401, message: "Invalid API key")
        XCTAssertEqual(error.errorDescription, "HTTP 401: Invalid API key")
    }

    func testNetworkErrorDescription() {
        let underlying = NSError(domain: "NSURLErrorDomain", code: -1009, userInfo: [NSLocalizedDescriptionKey: "Not connected to internet"])
        let error = OpenAIError.networkError(underlying: underlying)
        XCTAssertTrue(error.errorDescription!.contains("Network error"))
    }
}
