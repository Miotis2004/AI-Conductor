import Foundation
import Observation

// MARK: - File Attachment

/// A file that has been attached to a chat prompt.
struct FileAttachment: Identifiable, Hashable, Sendable {
    /// A unique identifier for this attachment.
    let id: UUID
    /// The resolved (canonical) path of the file.
    let resolvedPath: String
    /// The path relative to the workspace root.
    let relativePath: String
    /// The file name.
    let fileName: String
    /// The file size in bytes (at the time of attachment).
    let fileSize: Int64
    /// The estimated token count for this file's content.
    let estimatedTokens: Int
    /// Whether this file is sensitive (should not be attached by default).
    let isSensitive: Bool

    init(
        id: UUID = UUID(),
        resolvedPath: String,
        relativePath: String,
        fileName: String,
        fileSize: Int64,
        estimatedTokens: Int,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.resolvedPath = resolvedPath
        self.relativePath = relativePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.estimatedTokens = estimatedTokens
        self.isSensitive = isSensitive
    }
}

// MARK: - Attachment Errors

/// Errors that can occur when managing file attachments.
enum AttachmentError: LocalizedError {
    /// The file is outside the workspace.
    case outsideWorkspace(path: String)
    /// The file is a symbolic link that resolves outside the workspace.
    case symlinkEscape(path: String)
    /// The file does not exist or has been moved.
    case fileNotFound(path: String)
    /// The file is not accessible.
    case fileNotAccessible(path: String, underlying: Error)
    /// The file is sensitive and cannot be attached.
    case sensitiveFile(path: String)
    /// The file is a directory, not a file.
    case isDirectory(path: String)
    /// The file is binary and cannot be attached as text.
    case binaryFile(path: String)
    /// The file exceeds the size limit.
    case fileTooLarge(path: String, size: Int64, limit: Int64)
    /// No workspace is selected.
    case noWorkspace

    var errorDescription: String? {
        switch self {
        case .outsideWorkspace(let path):
            return "File is outside the workspace: \(path)"
        case .symlinkEscape(let path):
            return "Symbolic link resolves outside the workspace: \(path)"
        case .fileNotFound(let path):
            return "File not found (may have been moved or deleted): \(path)"
        case .fileNotAccessible(let path, let underlying):
            return "File is not accessible: \(path) — \(underlying.localizedDescription)"
        case .sensitiveFile(let path):
            return "File appears to contain sensitive data and cannot be attached: \(path)"
        case .isDirectory(let path):
            return "Path is a directory, not a file: \(path)"
        case .binaryFile(let path):
            return "Binary file cannot be attached as text: \(path)"
        case .fileTooLarge(let path, let size, let limit):
            return "File exceeds the size limit: \(path) (\(size) bytes > \(limit) bytes)"
        case .noWorkspace:
            return "No workspace selected."
        }
    }
}

// MARK: - Attachment Service

/// A service that manages file attachments for chat prompts.
///
/// Attachments are explicit: the user must deliberately add files. The
/// service validates that files remain within the authorized workspace at
/// both attachment time and submission time, and excludes sensitive files
/// (`.env`, private keys, credentials, etc.) from the default workflow.
///
/// The service is `@MainActor`-isolated to match the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` setting.
@Observable
@MainActor
final class AttachmentService {

    // MARK: - Published State

    /// The list of files attached to the current prompt.
    private(set) var attachments: [FileAttachment] = []

    // MARK: - Configuration

    /// The maximum file size (in bytes) that can be attached.
    var maxSizeLimit: Int64 = 1_048_576 // 1 MB

    // MARK: - Private

    private let workspaceService: WorkspaceService
    private let explorerService: WorkspaceExplorerService
    private let fileManager: FileManager

    // MARK: - Init

    /// Creates an attachment service.
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

    // MARK: - Add Attachment

    /// Adds a file to the attachment list.
    ///
    /// Validates that the file is within the workspace, is not sensitive,
    /// is not binary, and does not exceed the size limit.
    ///
    /// - Parameters:
    ///   - resolvedPath: The resolved (canonical) path of the file.
    ///   - relativePath: The path relative to the workspace root.
    /// - Returns: The created `FileAttachment` on success.
    /// - Throws: `AttachmentError` if the file cannot be attached.
    @discardableResult
    func addAttachment(resolvedPath: String, relativePath: String) throws -> FileAttachment {
        // Validate workspace.
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            throw AttachmentError.noWorkspace
        }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path

        // Enforce workspace boundary.
        guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
            throw AttachmentError.outsideWorkspace(path: resolvedPath)
        }

        // Ensure security-scoped access.
        guard workspaceService.startAccessing() else {
            throw AttachmentError.fileNotAccessible(path: resolvedPath, underlying: NSError(
                domain: "AttachmentService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Cannot access workspace"]
            ))
        }
        defer { workspaceService.stopAccessing() }

        // Check if the file exists.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            throw AttachmentError.fileNotFound(path: resolvedPath)
        }

        // Reject directories.
        guard !isDirectory.boolValue else {
            throw AttachmentError.isDirectory(path: resolvedPath)
        }

        // Check for sensitive files.
        let fileName = (resolvedPath as NSString).lastPathComponent
        if explorerService.isSensitiveFile(relativePath) {
            throw AttachmentError.sensitiveFile(path: relativePath)
        }

        // Get the file size.
        let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath)
        let fileSize = Int64(attributes?[.size] as? Int ?? 0)

        // Check size limit.
        if fileSize > maxSizeLimit {
            throw AttachmentError.fileTooLarge(path: relativePath, size: fileSize, limit: maxSizeLimit)
        }

        // Check for binary content.
        let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
        let (isBinary, _) = FileInspectorService.detectEncoding(data: data)
        if isBinary {
            throw AttachmentError.binaryFile(path: relativePath)
        }

        // Estimate tokens (~4 characters per token).
        let content = String(data: data, encoding: .utf8) ?? ""
        let estimatedTokens = max(1, content.count / 4)

        // Check if already attached.
        if attachments.contains(where: { $0.resolvedPath == resolvedPath }) {
            // Already attached — return the existing one.
            return attachments.first(where: { $0.resolvedPath == resolvedPath })!
        }

        let attachment = FileAttachment(
            resolvedPath: resolvedPath,
            relativePath: relativePath,
            fileName: fileName,
            fileSize: fileSize,
            estimatedTokens: estimatedTokens,
            isSensitive: false
        )
        attachments.append(attachment)
        return attachment
    }

    // MARK: - Remove Attachment

    /// Removes an attachment by its identifier.
    ///
    /// - Parameter id: The identifier of the attachment to remove.
    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Removes an attachment by its resolved path.
    ///
    /// - Parameter resolvedPath: The resolved path of the file to remove.
    func removeAttachment(resolvedPath: String) {
        attachments.removeAll { $0.resolvedPath == resolvedPath }
    }

    /// Removes all attachments.
    func removeAllAttachments() {
        attachments.removeAll()
    }

    // MARK: - Aggregated Properties

    /// The total estimated token count for all attachments.
    var totalEstimatedTokens: Int {
        attachments.reduce(0) { $0 + $1.estimatedTokens }
    }

    /// The total file size in bytes for all attachments.
    var totalFileSize: Int64 {
        attachments.reduce(0) { $0 + $1.fileSize }
    }

    /// Whether any attachments are present.
    var hasAttachments: Bool {
        !attachments.isEmpty
    }

    // MARK: - Read Attachments at Submission Time

    /// Reads the content of all attached files at submission time.
    ///
    /// Re-validates that each file is still within the workspace and
    /// accessible. If a file has been moved or deleted, an error is
    /// surfaced for that specific file.
    ///
    /// - Returns: An array of `(attachment, content)` tuples.
    /// - Throws: `AttachmentError` if any file cannot be read.
    func readAttachments() throws -> [(attachment: FileAttachment, content: String)] {
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            throw AttachmentError.noWorkspace
        }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path

        guard workspaceService.startAccessing() else {
            throw AttachmentError.fileNotAccessible(
                path: workspaceURL.path,
                underlying: NSError(
                    domain: "AttachmentService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot access workspace"]
                )
            )
        }
        defer { workspaceService.stopAccessing() }

        var results: [(attachment: FileAttachment, content: String)] = []

        for attachment in attachments {
            // Re-validate the file is within the workspace.
            guard explorerService.isWithinWorkspace(attachment.resolvedPath, resolvedRoot: resolvedRoot) else {
                throw AttachmentError.outsideWorkspace(path: attachment.relativePath)
            }

            // Check if the file still exists.
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: attachment.resolvedPath, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw AttachmentError.fileNotFound(path: attachment.relativePath)
            }

            // Read the content.
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: attachment.resolvedPath))
                let content = String(data: data, encoding: .utf8)
                    ?? String(decoding: data, as: UTF8.self)
                results.append((attachment, content))
            } catch {
                throw AttachmentError.fileNotAccessible(
                    path: attachment.relativePath,
                    underlying: error
                )
            }
        }

        return results
    }
}
