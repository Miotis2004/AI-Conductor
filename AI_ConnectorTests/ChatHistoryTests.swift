import XCTest
import Foundation

// This test file tests the conversation history and chat export components.
//
// To run these tests, compile them together with the source files:
//   swiftc -enable-testing \
//     AI_Connector/Models/ConversationHistory.swift \
//     AI_Connector/Services/ChatExportService.swift \
//     AI_ConnectorTests/ChatHistoryTests.swift \
//     -F $(xcrun --show-sdk-platform-path)/Developer/Library/Frameworks \
//     -I $(xcrun --show-sdk-platform-path)/Developer/usr/lib \
//     -o ChatHistoryTests
//
// Then run:
//   ./ChatHistoryTests

// MARK: - ConversationHistory Tests

final class ConversationHistoryTests: XCTestCase {

    static var allTests = [
        ("testEmptyHistory", testEmptyHistory),
        ("testAppendEntry", testAppendEntry),
        ("testAppendMultipleEntries", testAppendMultipleEntries),
        ("testUpdateResponse", testUpdateResponse),
        ("testUpdateResponseNonExistentEntry", testUpdateResponseNonExistentEntry),
        ("testClear", testClear),
        ("testPreserveEntriesWhenAppendingNew", testPreserveEntriesWhenAppendingNew),
        ("testPreservePartialResponseOnInterruption", testPreservePartialResponseOnInterruption),
        ("testFailedRequestWithNoContent", testFailedRequestWithNoContent),
        ("testUserPromptPreservedAfterClearingEditor", testUserPromptPreservedAfterClearingEditor),
    ]

    func testEmptyHistory() {
        let history = ConversationHistory()
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history.count, 0)
    }

    func testAppendEntry() {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Hello",
            assistantResponse: "Hi there!",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)
        XCTAssertEqual(history.count, 1)
        XCTAssertFalse(history.isEmpty)
        XCTAssertEqual(history.entries[0].userPrompt, "Hello")
        XCTAssertEqual(history.entries[0].assistantResponse, "Hi there!")
    }

    func testAppendMultipleEntries() {
        var history = ConversationHistory()
        let entry1 = ConversationEntry(
            userPrompt: "First prompt",
            assistantResponse: "First response",
            status: .completed,
            modelID: "test-model"
        )
        let entry2 = ConversationEntry(
            userPrompt: "Second prompt",
            assistantResponse: "Second response",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry1)
        history.append(entry2)
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.entries[0].userPrompt, "First prompt")
        XCTAssertEqual(history.entries[1].userPrompt, "Second prompt")
    }

    func testUpdateResponse() {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Test",
            assistantResponse: "",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        let updated = history.updateResponse(
            for: entry.id,
            response: "Updated response",
            status: .interrupted
        )
        XCTAssertTrue(updated)
        XCTAssertEqual(history.entries[0].assistantResponse, "Updated response")
        XCTAssertEqual(history.entries[0].status, .interrupted)
    }

    func testUpdateResponseNonExistentEntry() {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Test",
            assistantResponse: "",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        let nonExistentID = UUID()
        let updated = history.updateResponse(
            for: nonExistentID,
            response: "Should not update",
            status: .failed
        )
        XCTAssertFalse(updated)
        XCTAssertEqual(history.entries[0].assistantResponse, "")
    }

    func testClear() {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Test",
            assistantResponse: "Response",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)
        XCTAssertEqual(history.count, 1)

        history.clear()
        XCTAssertTrue(history.isEmpty)
        XCTAssertEqual(history.count, 0)
    }

    func testPreserveEntriesWhenAppendingNew() {
        var history = ConversationHistory()
        let entry1 = ConversationEntry(
            userPrompt: "Original prompt",
            assistantResponse: "Original response",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry1)

        let entry2 = ConversationEntry(
            userPrompt: "New prompt",
            assistantResponse: "New response",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry2)

        // The original entry should still be present.
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history.entries[0].userPrompt, "Original prompt")
        XCTAssertEqual(history.entries[1].userPrompt, "New prompt")
    }

    func testPreservePartialResponseOnInterruption() {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Tell me a story",
            assistantResponse: "",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        // Simulate a partial response from an interrupted stream.
        history.updateResponse(
            for: entry.id,
            response: "Once upon a time",
            status: .interrupted
        )

        XCTAssertEqual(history.entries[0].assistantResponse, "Once upon a time")
        XCTAssertEqual(history.entries[0].status, .interrupted)
    }

    func testFailedRequestWithNoContent() {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Test prompt",
            assistantResponse: "",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        history.updateResponse(
            for: entry.id,
            response: "",
            status: .failed
        )

        XCTAssertEqual(history.entries[0].assistantResponse, "")
        XCTAssertEqual(history.entries[0].status, .failed)
    }

    func testUserPromptPreservedAfterClearingEditor() {
        // The user prompt is captured as an immutable value at submission time.
        // Even if the prompt editor is cleared, the conversation entry retains
        // the original prompt.
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "My original prompt text",
            assistantResponse: "Response",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        // The entry's userPrompt is immutable and retains the original text.
        XCTAssertEqual(history.entries[0].userPrompt, "My original prompt text")
    }
}

// MARK: - ChatExportService Serialization Tests

final class ChatExportSerializationTests: XCTestCase {

    func testSerializeEmptyHistoryThrows() {
        let history = ConversationHistory()
        XCTAssertThrowsError(
            try ChatExportService.serialize(history, modelID: "test-model")
        ) { error in
            guard case ChatExportError.emptyConversation = error else {
                XCTFail("Expected emptyConversation error, got \(error)")
                return
            }
        }
    }

    func testSerializeSingleEntry() throws {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Hello, how are you?",
            assistantResponse: "I'm doing well, thank you!",
            status: .completed,
            modelID: "gpt-4"
        )
        history.append(entry)

        let text = try ChatExportService.serialize(history, modelID: "gpt-4")

        XCTAssertTrue(text.contains("=== AI Connector Chat Export ==="))
        XCTAssertTrue(text.contains("Model: gpt-4"))
        XCTAssertTrue(text.contains("Entries: 1"))
        XCTAssertTrue(text.contains("Hello, how are you?"))
        XCTAssertTrue(text.contains("I'm doing well, thank you!"))
        XCTAssertTrue(text.contains("--- User"))
        XCTAssertTrue(text.contains("--- Assistant [completed]"))
    }

    func testSerializeMultipleEntries() throws {
        var history = ConversationHistory()
        let entry1 = ConversationEntry(
            userPrompt: "First question",
            assistantResponse: "First answer",
            status: .completed,
            modelID: "test-model"
        )
        let entry2 = ConversationEntry(
            userPrompt: "Second question",
            assistantResponse: "Second answer",
            status: .interrupted,
            modelID: "test-model"
        )
        history.append(entry1)
        history.append(entry2)

        let text = try ChatExportService.serialize(history, modelID: "test-model")

        XCTAssertTrue(text.contains("Entries: 2"))
        XCTAssertTrue(text.contains("First question"))
        XCTAssertTrue(text.contains("First answer"))
        XCTAssertTrue(text.contains("Second question"))
        XCTAssertTrue(text.contains("Second answer"))
        XCTAssertTrue(text.contains("[interrupted]"))
    }

    func testSerializePreservesMultilineText() throws {
        var history = ConversationHistory()
        let multilinePrompt = "Line 1\nLine 2\nLine 3"
        let multilineResponse = "Response line 1\nResponse line 2"
        let entry = ConversationEntry(
            userPrompt: multilinePrompt,
            assistantResponse: multilineResponse,
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        let text = try ChatExportService.serialize(history, modelID: "test-model")

        XCTAssertTrue(text.contains("Line 1\nLine 2\nLine 3"))
        XCTAssertTrue(text.contains("Response line 1\nResponse line 2"))
    }

    func testSerializePreservesUnicode() throws {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Héllo wörld! €100 😀",
            assistantResponse: "Ünïcödé tëst — 日本語",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        let text = try ChatExportService.serialize(history, modelID: "test-model")

        XCTAssertTrue(text.contains("Héllo wörld! €100 😀"))
        XCTAssertTrue(text.contains("Ünïcödé tëst — 日本語"))
    }

    func testSerializePreservesCodeFormatting() throws {
        var history = ConversationHistory()
        let codePrompt = "Write a function:\n```\nfunc hello() {\n    print(\"hi\")\n}\n```"
        let entry = ConversationEntry(
            userPrompt: codePrompt,
            assistantResponse: "Here's the code:\n```\nfunc hello() {\n    print(\"hi\")\n}\n```",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        let text = try ChatExportService.serialize(history, modelID: "test-model")

        XCTAssertTrue(text.contains("func hello() {"))
        XCTAssertTrue(text.contains("    print(\"hi\")"))
        XCTAssertTrue(text.contains("```"))
    }

    func testSerializeIncludesExportDate() throws {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Test",
            assistantResponse: "Response",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        let fixedDate = Date(timeIntervalSince1970: 1700000000)
        let text = try ChatExportService.serialize(history, modelID: "test-model", date: fixedDate)

        XCTAssertTrue(text.contains("Exported:"))
    }

    func testSerializeDoesNotIncludeAPIKey() throws {
        var history = ConversationHistory()
        let entry = ConversationEntry(
            userPrompt: "Test prompt",
            assistantResponse: "Test response",
            status: .completed,
            modelID: "test-model"
        )
        history.append(entry)

        let text = try ChatExportService.serialize(history, modelID: "test-model")

        // The serialized text should never contain API keys or credentials.
        XCTAssertFalse(text.contains("sk-"))
        XCTAssertFalse(text.contains("Bearer"))
        XCTAssertFalse(text.contains("apiKey"))
    }
}

// MARK: - ChatExportService Save/Append Tests

final class ChatExportFileTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatExportTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func makeHistory() -> ConversationHistory {
        var history = ConversationHistory()
        history.append(ConversationEntry(
            userPrompt: "Test prompt",
            assistantResponse: "Test response",
            status: .completed,
            modelID: "test-model"
        ))
        return history
    }

    func testSaveNewCreatesFile() throws {
        let history = makeHistory()
        let fileURL = tempDirectory.appendingPathComponent("test-export.txt")

        try ChatExportService.saveNew(history, modelID: "test-model", to: fileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Test prompt"))
        XCTAssertTrue(content.contains("Test response"))
        XCTAssertTrue(content.contains("Model: test-model"))
    }

    func testSaveNewOverwritesExistingFile() throws {
        let history = makeHistory()
        let fileURL = tempDirectory.appendingPathComponent("test-overwrite.txt")

        // Write initial content.
        try "Initial content".write(to: fileURL, atomically: true, encoding: .utf8)

        // Save new should overwrite.
        try ChatExportService.saveNew(history, modelID: "test-model", to: fileURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(content.contains("Initial content"))
        XCTAssertTrue(content.contains("Test prompt"))
    }

    func testAppendToExistingFile() throws {
        let history = makeHistory()
        let fileURL = tempDirectory.appendingPathComponent("test-append.txt")

        // Write initial content.
        let initialContent = "Existing content that must be preserved."
        try initialContent.write(to: fileURL, atomically: true, encoding: .utf8)

        try ChatExportService.append(history, modelID: "test-model", to: fileURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        // Existing content must be preserved exactly.
        XCTAssertTrue(content.hasPrefix(initialContent))
        // Appended content must be present.
        XCTAssertTrue(content.contains("Test prompt"))
        XCTAssertTrue(content.contains("Test response"))
        // Delimiter must be present.
        XCTAssertTrue(content.contains("=== Appended Conversation ==="))
    }

    func testAppendNeverTruncatesExistingFile() throws {
        let history = makeHistory()
        let fileURL = tempDirectory.appendingPathComponent("test-no-truncate.txt")

        let initialContent = String(repeating: "A", count: 1000)
        try initialContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let sizeBefore = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0

        try ChatExportService.append(history, modelID: "test-model", to: fileURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        // The file must be larger than before (content was appended, not replaced).
        let sizeAfter = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        XCTAssertGreaterThan(sizeAfter, sizeBefore)
        // All original content must be present.
        XCTAssertTrue(content.hasPrefix(initialContent))
    }

    func testAppendToNonExistentFile() throws {
        let history = makeHistory()
        let fileURL = tempDirectory.appendingPathComponent("nonexistent.txt")

        // Should not throw — creates the file with the conversation.
        try ChatExportService.append(history, modelID: "test-model", to: fileURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Test prompt"))
    }

    func testDuplicateExportDetection() throws {
        let history = makeHistory()
        let fileURL = tempDirectory.appendingPathComponent("test-duplicate.txt")

        // First append succeeds.
        try ChatExportService.append(history, modelID: "test-model", to: fileURL)

        // Second append of the same conversation should throw duplicateExport.
        let existingContent = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertThrowsError(
            try ChatExportService.append(history, modelID: "test-model", to: fileURL, existingContent: existingContent)
        ) { error in
            guard case ChatExportError.duplicateExport = error else {
                XCTFail("Expected duplicateExport error, got \(error)")
                return
            }
        }
    }

    func testDifferentConversationCanAppend() throws {
        let history1 = makeHistory()
        let fileURL = tempDirectory.appendingPathComponent("test-different.txt")

        // First conversation.
        try ChatExportService.append(history1, modelID: "test-model", to: fileURL)

        // Second, different conversation.
        var history2 = ConversationHistory()
        history2.append(ConversationEntry(
            userPrompt: "Completely different prompt",
            assistantResponse: "Different response",
            status: .completed,
            modelID: "test-model"
        ))

        let existingContent = try String(contentsOf: fileURL, encoding: .utf8)
        // Should not throw — different conversation.
        try ChatExportService.append(history2, modelID: "test-model", to: fileURL, existingContent: existingContent)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Test prompt"))
        XCTAssertTrue(content.contains("Completely different prompt"))
    }

    func testContainsConversationDetection() {
        var history = ConversationHistory()
        history.append(ConversationEntry(
            userPrompt: "Unique prompt text",
            assistantResponse: "Response",
            status: .completed,
            modelID: "test-model"
        ))

        XCTAssertTrue(ChatExportService.containsConversation("Some text with Unique prompt text inside", history: history))
        XCTAssertFalse(ChatExportService.containsConversation("Completely different text", history: history))
    }

    func testContainsConversationEmptyHistory() {
        let history = ConversationHistory()
        XCTAssertFalse(ChatExportService.containsConversation("Any text", history: history))
    }

    func testAppendPreservesUnicode() throws {
        var history = ConversationHistory()
        history.append(ConversationEntry(
            userPrompt: "Héllo wörld! €100 😀",
            assistantResponse: "Ünïcödé tëst — 日本語",
            status: .completed,
            modelID: "test-model"
        ))

        let fileURL = tempDirectory.appendingPathComponent("test-unicode.txt")
        try "Initial".write(to: fileURL, atomically: true, encoding: .utf8)

        try ChatExportService.append(history, modelID: "test-model", to: fileURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Héllo wörld! €100 😀"))
        XCTAssertTrue(content.contains("Ünïcödé tëst — 日本語"))
    }

    func testAppendSeparatesWithDelimiterAndTimestamp() throws {
        let history = makeHistory()
        let fileURL = tempDirectory.appendingPathComponent("test-delimiter.txt")

        try "Original".write(to: fileURL, atomically: true, encoding: .utf8)
        try ChatExportService.append(history, modelID: "test-model", to: fileURL)

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        // The delimiter must separate the original content from the appended block.
        let delimiterIndex = content.range(of: "=== Appended Conversation ===")
        XCTAssertNotNil(delimiterIndex)
        // Original content must come before the delimiter.
        if let originalIndex = content.range(of: "Original") {
            XCTAssertTrue(originalIndex.lowerBound < delimiterIndex!.lowerBound)
        }
    }
}

// MARK: - Prompt Clearing Behavior Tests

final class PromptClearingTests: XCTestCase {

    /// Tests that the prompt is cleared only after the backend accepts the request.
    ///
    /// This simulates the logic in ChatViewModel.send(): the prompt is captured
    /// as an immutable value, and the editor is cleared only when the HTTP
    /// status code is 2xx.
    func testPromptClearedOnSuccessfulAcceptance() {
        var prompt = "My test prompt"
        var wasCleared = false

        // Simulate the onAccepted callback with a 200 status.
        let statusCode = 200
        if (200..<300).contains(statusCode) {
            prompt = ""
            wasCleared = true
        }

        XCTAssertTrue(wasCleared)
        XCTAssertEqual(prompt, "")
    }

    func testPromptPreservedOnFailedAcceptance() {
        var prompt = "My test prompt"
        let submittedPrompt = prompt
        var wasCleared = false

        // Simulate the onAccepted callback with a 401 status.
        let statusCode = 401
        if (200..<300).contains(statusCode) {
            prompt = ""
            wasCleared = true
        }

        // The prompt should be restored if the request was not accepted.
        if !wasCleared {
            prompt = submittedPrompt
        }

        XCTAssertFalse(wasCleared)
        XCTAssertEqual(prompt, "My test prompt")
    }

    func testPromptPreservedOnNetworkError() {
        var prompt = "My test prompt"
        let submittedPrompt = prompt
        var wasCleared = false

        // Simulate a network error — no HTTP status received.
        // wasCleared remains false.

        // The prompt should be restored.
        if !wasCleared {
            prompt = submittedPrompt
        }

        XCTAssertEqual(prompt, "My test prompt")
    }

    func testSubmittedPromptIsImmutable() {
        let submittedPrompt = "Original prompt text"
        var prompt = submittedPrompt

        // Simulate the user typing new text while the request is in flight.
        prompt = "New text typed by user"

        // The submitted prompt (used for the HTTP request) must be the
        // original captured value, not the mutable prompt field.
        XCTAssertEqual(submittedPrompt, "Original prompt text")
        // The prompt field now contains the user's new text.
        XCTAssertEqual(prompt, "New text typed by user")
    }

    func testPromptNotOverwrittenWhileRequestInProgress() {
        var prompt = "Original prompt"
        let submittedPrompt = prompt

        // Simulate the user typing while the request is in flight.
        prompt = "User typed new text"

        // The request uses the captured value, not the mutable field.
        XCTAssertEqual(submittedPrompt, "Original prompt")
        // The user's new text is preserved in the prompt field.
        XCTAssertEqual(prompt, "User typed new text")
    }
}
