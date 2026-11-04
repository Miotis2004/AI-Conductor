import Foundation
import Observation

// MARK: - File Inspector Result

/// The result of inspecting a file for display.
struct FileInspectorResult: Sendable {
    /// The file name.
    let fileName: String
    /// The path relative to the workspace root.
    let relativePath: String
    /// The file size in bytes.
    let fileSize: Int64
    /// The file content as a string (for text files).
    let content: String?
    /// The number of lines in the file.
    let lineCount: Int
    /// Whether the file is a binary file.
    let isBinary: Bool
    /// Whether the file exceeded the size limit and was not loaded.
    let exceedsSizeLimit: Bool
    /// The encoding used to decode the file, if applicable.
    let encoding: String?
    /// An error message if the file could not be inspected.
    let errorMessage: String?

    init(
        fileName: String,
        relativePath: String,
        fileSize: Int64,
        content: String? = nil,
        lineCount: Int = 0,
        isBinary: Bool = false,
        exceedsSizeLimit: Bool = false,
        encoding: String? = nil,
        errorMessage: String? = nil
    ) {
        self.fileName = fileName
        self.relativePath = relativePath
        self.fileSize = fileSize
        self.content = content
        self.lineCount = lineCount
        self.isBinary = isBinary
        self.exceedsSizeLimit = exceedsSizeLimit
        self.encoding = encoding
        self.errorMessage = errorMessage
    }
}

// MARK: - File Inspector Errors

/// Errors that can occur during file inspection.
enum FileInspectorError: LocalizedError {
    /// The file does not exist.
    case fileNotFound(path: String)
    /// The file is not accessible.
    case fileNotAccessible(underlying: Error)
    /// The file is outside the workspace.
    case outsideWorkspace(path: String)
    /// The file is a symbolic link that resolves outside the workspace.
    case symlinkEscape(path: String)
    /// The file is a directory, not a file.
    case isDirectory(path: String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .fileNotAccessible(let underlying):
            return "File is not accessible: \(underlying.localizedDescription)"
        case .outsideWorkspace(let path):
            return "File is outside the workspace: \(path)"
        case .symlinkEscape(let path):
            return "Symbolic link resolves outside the workspace: \(path)"
        case .isDirectory(let path):
            return "Path is a directory, not a file: \(path)"
        }
    }
}

// MARK: - File Inspector Service

/// A read-only service for inspecting files in the workspace.
///
/// This service never modifies files. It reads file contents for display,
/// detects binary files, handles various text encodings, and enforces a
/// configurable size limit to avoid loading excessively large files.
///
/// The service is `@MainActor`-isolated to match the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` setting.
@Observable
@MainActor
final class FileInspectorService {

    // MARK: - Published State

    /// The result of the most recent file inspection.
    private(set) var currentResult: FileInspectorResult?
    /// The currently selected file's resolved path.
    private(set) var selectedFilePath: String?

    // MARK: - Configuration

    /// The maximum file size (in bytes) to load for preview.
    /// Files larger than this are not loaded; the user is informed.
    var maxSizeLimit: Int64 = 1_048_576 // 1 MB

    // MARK: - Private

    private let workspaceService: WorkspaceService
    private let explorerService: WorkspaceExplorerService
    private let fileManager: FileManager

    // MARK: - Init

    /// Creates a file inspector service.
    ///
    /// - Parameters:
    ///   - workspaceService: The workspace service.
    ///   - explorerService: The workspace explorer service (for path validation).
    ///   - fileManager: The file manager to use. Defaults to `.default`.
    init(
        workspaceService: WorkspaceService,
        explorerService: WorkspaceExplorerService,
        fileManager: FileManager = .default
    ) {
        self.workspaceService = workspaceService
        self.explorerService = explorerService
        self.fileManager = fileManager
    }

    // MARK: - Inspect File

    /// Inspects a file for display in the preview area.
    ///
    /// - Parameters:
    ///   - resolvedPath: The resolved (canonical) path of the file.
    ///   - relativePath: The path relative to the workspace root.
    /// - Returns: A `FileInspectorResult` describing the file.
    @discardableResult
    func inspectFile(resolvedPath: String, relativePath: String) -> FileInspectorResult {
        // Validate the file is within the workspace.
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            let result = FileInspectorResult(
                fileName: (resolvedPath as NSString).lastPathComponent,
                relativePath: relativePath,
                fileSize: 0,
                errorMessage: "No workspace selected or access expired."
            )
            currentResult = result
            selectedFilePath = nil
            return result
        }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path

        // Enforce workspace boundary.
        guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
            let result = FileInspectorResult(
                fileName: (resolvedPath as NSString).lastPathComponent,
                relativePath: relativePath,
                fileSize: 0,
                errorMessage: "File is outside the workspace."
            )
            currentResult = result
            selectedFilePath = nil
            return result
        }

        // Ensure security-scoped access is active.
        guard workspaceService.startAccessing() else {
            let result = FileInspectorResult(
                fileName: (resolvedPath as NSString).lastPathComponent,
                relativePath: relativePath,
                fileSize: 0,
                errorMessage: "Cannot access workspace. Please re-select the folder."
            )
            currentResult = result
            selectedFilePath = nil
            return result
        }
        defer { workspaceService.stopAccessing() }

        // Check if the file exists.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            let result = FileInspectorResult(
                fileName: (resolvedPath as NSString).lastPathComponent,
                relativePath: relativePath,
                fileSize: 0,
                errorMessage: "File not found. It may have been moved or deleted."
            )
            currentResult = result
            selectedFilePath = nil
            return result
        }

        // Reject directories.
        guard !isDirectory.boolValue else {
            let result = FileInspectorResult(
                fileName: (resolvedPath as NSString).lastPathComponent,
                relativePath: relativePath,
                fileSize: 0,
                errorMessage: "Path is a directory, not a file."
            )
            currentResult = result
            selectedFilePath = nil
            return result
        }

        // Get the file size.
        let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath)
        let fileSize = Int64(attributes?[.size] as? Int ?? 0)

        // Check size limit.
        if fileSize > maxSizeLimit {
            let result = FileInspectorResult(
                fileName: (resolvedPath as NSString).lastPathComponent,
                relativePath: relativePath,
                fileSize: fileSize,
                exceedsSizeLimit: true,
                errorMessage: "File is too large to preview (\(Self.formatByteCount(fileSize))). Limit is \(Self.formatByteCount(maxSizeLimit))."
            )
            currentResult = result
            selectedFilePath = resolvedPath
            return result
        }

        // Read the file content.
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))

            // Detect binary vs text.
            let (isBinary, encoding) = Self.detectEncoding(data: data)

            if isBinary {
                let result = FileInspectorResult(
                    fileName: (resolvedPath as NSString).lastPathComponent,
                    relativePath: relativePath,
                    fileSize: fileSize,
                    isBinary: true,
                    errorMessage: "Binary file — cannot display as text."
                )
                currentResult = result
                selectedFilePath = resolvedPath
                return result
            }

            // Decode the text.
            let content: String
            if let encoding = encoding, let decoded = String(data: data, encoding: encoding) {
                content = decoded
            } else {
                // Fallback: replace invalid sequences.
                content = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            }

            let lineCount = content.components(separatedBy: .newlines).count

            let result = FileInspectorResult(
                fileName: (resolvedPath as NSString).lastPathComponent,
                relativePath: relativePath,
                fileSize: fileSize,
                content: content,
                lineCount: lineCount,
                encoding: encoding?.description
            )
            currentResult = result
            selectedFilePath = resolvedPath
            return result
        } catch {
            let result = FileInspectorResult(
                fileName: (resolvedPath as NSString).lastPathComponent,
                relativePath: relativePath,
                fileSize: fileSize,
                errorMessage: "Failed to read file: \(error.localizedDescription)"
            )
            currentResult = result
            selectedFilePath = nil
            return result
        }
    }

    // MARK: - Clear Selection

    /// Clears the current file selection.
    func clearSelection() {
        currentResult = nil
        selectedFilePath = nil
    }

    // MARK: - Encoding Detection

    /// Detects whether data is binary and, if text, determines the encoding.
    ///
    /// - Parameter data: The file data to analyze.
    /// - Returns: A tuple of `(isBinary, encoding)`. The encoding is `nil`
    ///   for binary files.
    static func detectEncoding(data: Data) -> (isBinary: Bool, encoding: String.Encoding?) {
        // Check for null bytes in the first 8KB — a strong indicator of binary.
        let checkLength = min(data.count, 8192)
        let prefix = data.prefix(checkLength)

        for byte in prefix {
            if byte == 0 {
                return (true, nil)
            }
        }

        // Try UTF-8 first (most common).
        if let _ = String(data: data, encoding: .utf8) {
            // Verify it's actually valid UTF-8 by checking for replacement characters.
            let string = String(data: data, encoding: .utf8)!
            if !string.contains("\u{FFFD}") {
                return (false, .utf8)
            }
        }

        // Try UTF-16 with BOM.
        if data.count >= 2 {
            if data[0] == 0xFF && data[1] == 0xFE {
                return (false, .utf16LittleEndian)
            }
            if data[0] == 0xFE && data[1] == 0xFF {
                return (false, .utf16BigEndian)
            }
        }

        // Try UTF-8 with BOM.
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            return (false, .utf8)
        }

        // Try ISO-8859-1 (Latin-1) — decodes any byte sequence.
        if let _ = String(data: data, encoding: .isoLatin1) {
            return (false, .isoLatin1)
        }

        // If all else fails, treat as binary.
        return (true, nil)
    }

    // MARK: - Byte Count Formatting

    /// Formats a byte count as a human-readable string.
    static func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
