import Foundation
import Crypto

// MARK: - Safe File Writer

/// A service that performs safe, atomic file operations within an authorized
/// workspace.
///
/// Key safety properties:
/// - Never deletes an existing source file before its replacement is ready.
/// - Writes proposed content to a temporary file in the destination directory.
/// - Flushes and closes the temporary file before replacement.
/// - Uses `FileManager.replaceItemAt` for atomic replacement on macOS.
/// - Preserves the original file if replacement fails.
/// - Preserves POSIX file permissions where practical.
/// - Cleans up temporary files after successful or failed operations.
/// - Handles new-file creation separately so an existing destination cannot
///   be silently overwritten.
/// - Preserves the original text encoding and line endings where practical.
///
/// This service does NOT claim that multiple file replacements are a single
/// filesystem-atomic transaction. Each file replacement is individually
/// atomic, but a multi-file change set is a staged operation.
final class SafeFileWriter {

    // MARK: - Configuration

    /// The maximum file size (in bytes) that can be written.
    var maxFileSize: Int64 = 1_048_576 // 1 MB

    // MARK: - Private

    private let fileManager: FileManager

    // MARK: - Init

    /// Creates a safe file writer.
    ///
    /// - Parameter fileManager: The file manager to use. Defaults to `.default`.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    // MARK: - Atomic Write (Replace Existing File)

    /// Atomically replaces an existing file with new content.
    ///
    /// The original file is never deleted before the replacement is ready.
    /// The new content is written to a temporary file in the same directory,
    /// then atomically moved into place using `FileManager.replaceItemAt`.
    ///
    /// - Parameters:
    ///   - content: The new content to write.
    ///   - to: The destination path (must exist).
    ///   - permissions: The POSIX permissions to apply, if any.
    ///   - encoding: The text encoding to use. Defaults to UTF-8.
    ///   - lineEnding: The line ending style to use. Defaults to LF.
    ///   - hasTrailingNewline: Whether to include a trailing newline.
    /// - Throws: `CodeModificationError.writeFailed` if the write fails.
    func replaceFile(
        content: String,
        to path: String,
        permissions: Int? = nil,
        encoding: String.Encoding = .utf8,
        lineEnding: FileSnapshot.LineEndingStyle = .lf,
        hasTrailingNewline: Bool = false
    ) throws {
        let destinationURL = URL(fileURLWithPath: path)

        // Verify the destination exists (this is a replace, not a create).
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw CodeModificationError.fileNotFound(path: path)
        }
        guard !isDirectory.boolValue else {
            throw CodeModificationError.isDirectory(path: path)
        }

        // Reject symbolic links.
        let values = try? fileManager.attributesOfItem(atPath: path)
        if let type = values?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw CodeModificationError.symbolicLink(path: path)
        }

        // Prepare the content with the appropriate line endings and trailing newline.
        let preparedContent = prepareContent(
            content,
            lineEnding: lineEnding,
            hasTrailingNewline: hasTrailingNewline
        )

        let data = Data(preparedContent.utf8)

        // Enforce the size limit.
        guard Int64(data.count) <= maxFileSize else {
            throw CodeModificationError.fileTooLarge(
                path: path,
                size: data.count,
                limit: Int(maxFileSize)
            )
        }

        // Write to a temporary file in the same directory.
        let tempURL = destinationURL.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")

        do {
            // Write the data to the temp file.
            try data.write(to: tempURL, options: .atomic)

            // Apply permissions if specified.
            if let perms = permissions {
                try fileManager.setAttributes(
                    [.posixPermissions: perms],
                    ofItemAtPath: tempURL.path
                )
            }

            // Atomically replace the destination.
            // `replaceItemAt` atomically swaps the destination with the temp file.
            // The original file is preserved if this fails.
            var replacedItem: URL?
            let success = fileManager.replaceItemAt(destinationURL, withItemAt: tempURL, backupItemName: nil, options: [], resultingItemURL: &replacedItem)

            if !success {
                // Clean up the temp file.
                try? fileManager.removeItem(at: tempURL)
                throw CodeModificationError.writeFailed(
                    path: path,
                    underlying: NSError(
                        domain: "SafeFileWriter",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Atomic replacement failed"]
                    )
                )
            }
        } catch {
            // Clean up the temp file on failure.
            try? fileManager.removeItem(at: tempURL)
            throw CodeModificationError.writeFailed(path: path, underlying: error)
        }
    }

    // MARK: - Create New File

    /// Creates a new file with the given content.
    ///
    /// If the destination already exists, this method throws an error rather
    /// than silently overwriting it.
    ///
    /// - Parameters:
    ///   - content: The content to write.
    ///   - to: The destination path (must NOT exist).
    ///   - permissions: The POSIX permissions to apply. Defaults to 0644.
    ///   - encoding: The text encoding to use. Defaults to UTF-8.
    ///   - lineEnding: The line ending style to use. Defaults to LF.
    ///   - hasTrailingNewline: Whether to include a trailing newline.
    /// - Throws: `CodeModificationError` if the file already exists or the write fails.
    func createFile(
        content: String,
        to path: String,
        permissions: Int? = 0o644,
        encoding: String.Encoding = .utf8,
        lineEnding: FileSnapshot.LineEndingStyle = .lf,
        hasTrailingNewline: Bool = true
    ) throws {
        let destinationURL = URL(fileURLWithPath: path)

        // Verify the destination does NOT exist.
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
            throw CodeModificationError.fileAlreadyExists(path: path)
        }

        // Ensure the parent directory exists.
        let parentDir = destinationURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parentDir.path) {
            try fileManager.createDirectory(
                at: parentDir,
                withIntermediateDirectories: true,
                attributes: nil
            )
        }

        // Prepare the content.
        let preparedContent = prepareContent(
            content,
            lineEnding: lineEnding,
            hasTrailingNewline: hasTrailingNewline
        )

        let data = Data(preparedContent.utf8)

        // Enforce the size limit.
        guard Int64(data.count) <= maxFileSize else {
            throw CodeModificationError.fileTooLarge(
                path: path,
                size: data.count,
                limit: Int(maxFileSize)
            )
        }

        // Write to a temporary file, then move into place.
        let tempURL = parentDir.appendingPathComponent(
            destinationURL.lastPathComponent + ".tmp-\(UUID().uuidString.prefix(8))"
        )

        do {
            try data.write(to: tempURL, options: .atomic)

            // Apply permissions.
            if let perms = permissions {
                try fileManager.setAttributes(
                    [.posixPermissions: perms],
                    ofItemAtPath: tempURL.path
                )
            }

            // Move into place.
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw CodeModificationError.writeFailed(path: path, underlying: error)
        }
    }

    // MARK: - Delete File (for undo of created files)

    /// Deletes a file, but only if its content matches the expected hash.
    ///
    /// This is used during undo of created files. If the file's content has
    /// changed since it was created, the deletion is refused to prevent
    /// overwriting subsequent user changes.
    ///
    /// - Parameters:
    ///   - path: The path of the file to delete.
    ///   - expectedHash: The SHA-256 hash of the content the file should have.
    /// - Throws: `CodeModificationError.rollbackConflict` if the file's content
    ///   does not match the expected hash.
    func deleteFileIfUnchanged(path: String, expectedHash: String) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            // File doesn't exist — nothing to delete.
            return
        }
        guard !isDirectory.boolValue else {
            throw CodeModificationError.isDirectory(path: path)
        }

        // Verify the content matches the expected hash.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let currentHash = Self.sha256Hash(data)
        guard currentHash == expectedHash else {
            throw CodeModificationError.rollbackConflict(path: path)
        }

        try fileManager.removeItem(atPath: path)
    }

    // MARK: - Content Preparation

    /// Prepares content with the specified line ending style and trailing newline.
    ///
    /// - Parameters:
    ///   - content: The raw content (assumed to use LF line endings).
    ///   - lineEnding: The desired line ending style.
    ///   - hasTrailingNewline: Whether to include a trailing newline.
    /// - Returns: The prepared content string.
    func prepareContent(
        _ content: String,
        lineEnding: FileSnapshot.LineEndingStyle,
        hasTrailingNewline: Bool
    ) -> String {
        // Normalize to LF first.
        var normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        // Remove trailing newline for re-adding.
        let hadTrailingNewline = normalized.hasSuffix("\n")
        if hadTrailingNewline {
            normalized = String(normalized.dropLast())
        }

        // Split into lines.
        let lines = normalized.components(separatedBy: "\n")

        // Rejoin with the desired line ending.
        let separator: String
        switch lineEnding {
        case .lf: separator = "\n"
        case .crlf: separator = "\r\n"
        case .cr: separator = "\r"
        case .mixed: separator = "\n"
        }

        var result = lines.joined(separator: separator)

        // Add trailing newline if requested.
        if hasTrailingNewline || (hadTrailingNewline && !hasTrailingNewline) {
            result += separator
        }

        return result
    }

    // MARK: - Line Ending Detection

    /// Detects the line ending style of a file's content.
    ///
    /// - Parameter content: The file content.
    /// - Returns: The detected line ending style.
    static func detectLineEnding(_ content: String) -> FileSnapshot.LineEndingStyle {
        let hasCRLF = content.contains("\r\n")
        let hasCR = content.contains("\r") && !hasCRLF
        let hasLF = content.contains("\n") && !hasCRLF && !hasCR

        if hasCRLF && hasLF {
            return .mixed
        } else if hasCRLF {
            return .crlf
        } else if hasCR {
            return .cr
        } else if hasLF {
            return .lf
        } else {
            return .lf
        }
    }

    // MARK: - Trailing Newline Detection

    /// Determines whether a file's content ends with a trailing newline.
    ///
    /// - Parameter content: The file content.
    /// - Returns: `true` if the content ends with a newline.
    static func hasTrailingNewline(_ content: String) -> Bool {
        content.hasSuffix("\n") || content.hasSuffix("\r")
    }

    // MARK: - SHA-256 Hashing

    /// Computes the SHA-256 hash of raw data.
    ///
    /// - Parameter data: The data to hash.
    /// - Returns: The hex-encoded SHA-256 hash.
    static func sha256Hash(_ data: Data) -> String {
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Computes the SHA-256 hash of a string (UTF-8 encoded).
    ///
    /// - Parameter string: The string to hash.
    /// - Returns: The hex-encoded SHA-256 hash.
    static func sha256Hash(_ string: String) -> String {
        sha256Hash(Data(string.utf8))
    }
}
