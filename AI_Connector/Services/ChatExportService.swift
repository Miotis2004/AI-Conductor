import Foundation

// MARK: - Chat Export Errors

/// Errors that can occur when exporting a conversation to a text file.
enum ChatExportError: LocalizedError {
    /// The user canceled the save or open dialog.
    case userCancelled
    /// The destination file could not be written.
    case writeFailed(underlying: Error)
    /// The existing file could not be read.
    case readFailed(underlying: Error)
    /// The file is not accessible (permissions, sandbox, etc.).
    case inaccessibleFile(underlying: Error)
    /// The conversation is empty; there is nothing to export.
    case emptyConversation
    /// The conversation has already been appended to the selected file.
    case duplicateExport

    var errorDescription: String? {
        switch self {
        case .userCancelled:
            return "The operation was canceled."
        case .writeFailed(let underlying):
            return "Failed to write the file: \(underlying.localizedDescription)"
        case .readFailed(let underlying):
            return "Failed to read the file: \(underlying.localizedDescription)"
        case .inaccessibleFile(let underlying):
            return "The file is not accessible: \(underlying.localizedDescription)"
        case .emptyConversation:
            return "There is no conversation to export."
        case .duplicateExport:
            return "This conversation has already been saved to the selected file."
        }
    }
}

// MARK: - Chat Export Service

/// A service that serializes a `ConversationHistory` to a human-readable
/// UTF-8 text file and manages saving and appending to files.
///
/// This service is a pure Foundation type with no dependency on AppKit,
/// SwiftUI, or the networking layer, which makes it straightforward to unit
/// test.
///
/// The service never includes API keys or other stored credentials in the
/// exported text.
struct ChatExportService: Sendable {

    // MARK: - Serialization

    /// Serializes a conversation history into a human-readable text block.
    ///
    /// The block includes a header with the export date, model identifier,
    /// and entry count, followed by each user prompt and assistant response
    /// clearly distinguished. Multiline text, Unicode, and code formatting
    /// are preserved exactly.
    ///
    /// - Parameters:
    ///   - history: The conversation history to serialize.
    ///   - modelID: The model identifier to include in the header.
    ///   - date: The export date to include in the header. Defaults to now.
    /// - Returns: The serialized text block, ending with a newline.
    /// - Throws: `ChatExportError.emptyConversation` if the history is empty.
    static func serialize(
        _ history: ConversationHistory,
        modelID: String,
        date: Date = Date()
    ) throws -> String {
        guard !history.isEmpty else {
            throw ChatExportError.emptyConversation
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let dateString = formatter.string(from: date)

        var lines: [String] = []
        lines.append("=== AI Connector Chat Export ===")
        lines.append("Exported: \(dateString)")
        lines.append("Model: \(modelID)")
        lines.append("Entries: \(history.count)")
        lines.append("")

        for entry in history.entries {
            lines.append("--- User (\(entry.submittedAt.formatted(date: .abbreviated, time: .standard))) ---")
            lines.append(entry.userPrompt)
            lines.append("")
            lines.append("--- Assistant [\(entry.status.rawValue)] ---")
            lines.append(entry.assistantResponse)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Save New

    /// Writes the serialized conversation to a new file at the given URL.
    ///
    /// If the file already exists, it is overwritten. The file is written
    /// as UTF-8.
    ///
    /// - Parameters:
    ///   - history: The conversation history to save.
    ///   - modelID: The model identifier for the header.
    ///   - url: The destination file URL.
    /// - Throws: `ChatExportError` if the write fails.
    static func saveNew(
        _ history: ConversationHistory,
        modelID: String,
        to url: URL
    ) throws {
        let text = try serialize(history, modelID: modelID)
        try writeText(text, to: url, appending: false)
    }

    // MARK: - Append Existing

    /// Appends the serialized conversation to an existing text file.
    ///
    /// The existing file content is preserved exactly. The appended block is
    /// separated from the existing content by a clear delimiter and a
    /// timestamp. The file is never truncated.
    ///
    /// - Parameters:
    ///   - history: The conversation history to append.
    ///   - modelID: The model identifier for the header.
    ///   - url: The destination file URL.
    ///   - existingContent: The current content of the file, used for
    ///     duplicate detection. Pass `nil` to skip duplicate detection.
    /// - Throws: `ChatExportError.duplicateExport` if the same conversation
    ///   has already been appended to the file, or `ChatExportError` if the
    ///   write fails.
    static func append(
        _ history: ConversationHistory,
        modelID: String,
        to url: URL,
        existingContent: String? = nil
    ) throws {
        let block = try serialize(history, modelID: modelID)

        // Duplicate detection: check whether the same conversation block is
        // already present in the file.
        if let existing = existingContent {
            if containsConversation(existing, history: history) {
                throw ChatExportError.duplicateExport
            }
        }

        // Read the existing content to preserve it exactly.
        let existingText: String
        do {
            existingText = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // If the file doesn't exist yet, start with empty content.
            if (error as? URLError)?.code == .fileDoesNotExist {
                existingText = ""
            } else {
                throw ChatExportError.readFailed(underlying: error)
            }
        }

        // Build the appended content: existing content + delimiter + block.
        // Ensure the existing content ends with a newline before the
        // delimiter so the block starts on its own line.
        var result = existingText
        if !result.isEmpty && !result.hasSuffix("\n") {
            result += "\n"
        }
        result += "\n"
        result += "=== Appended Conversation ===\n"
        result += block

        try writeText(result, to: url, appending: false)
    }

    // MARK: - Duplicate Detection

    /// Determines whether the given existing file content already contains
    /// the same conversation.
    ///
    /// The check is based on the user prompts in the conversation: if all
    /// user prompts in the history appear in the existing content, the
    /// conversation is considered a duplicate.
    static func containsConversation(
        _ existingContent: String,
        history: ConversationHistory
    ) -> Bool {
        guard !history.isEmpty else { return false }
        // Check that every user prompt in the history is present in the
        // existing content. This is a conservative check: it avoids
        // appending the same conversation twice while still allowing
        // different conversations to be appended.
        return history.entries.allSatisfy { entry in
            existingContent.contains(entry.userPrompt)
        }
    }

    // MARK: - File Writing

    /// Writes text to a file as UTF-8.
    ///
    /// - Parameters:
    ///   - text: The text to write.
    ///   - url: The destination file URL.
    ///   - appending: If `true`, appends to the file; otherwise overwrites.
    /// - Throws: `ChatExportError.writeFailed` if the write fails.
    static func writeText(
        _ text: String,
        to url: URL,
        appending: Bool
    ) throws {
        do {
            if appending {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                handle.seekToEndOfFile()
                let data = Data(text.utf8)
                try handle.write(contentsOf: data)
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            throw ChatExportError.writeFailed(underlying: error)
        }
    }
}
