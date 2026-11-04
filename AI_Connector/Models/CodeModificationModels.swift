import Foundation

// MARK: - Application Mode

/// The operating mode of the AI Connector application.
enum AppMode: String, CaseIterable, Identifiable, Sendable {
    /// Conversational chat functionality.
    case chat = "Chat"
    /// Read-only workspace exploration and file analysis.
    case inspect = "Inspect"
    /// AI-assisted source-code modification.
    case code = "Code"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .chat: return "bubble.left.and.bubble.right"
        case .inspect: return "magnifyingglass"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }
}

// MARK: - Code Modification Operation

/// A single file operation within a code modification proposal.
///
/// Each operation has a type (create or modify), a workspace-relative path,
/// and the proposed content. Only create and modify operations are supported.
struct CodeModificationOperation: Identifiable, Hashable, Sendable {
    /// A unique identifier for this operation (derived from path + type).
    let id: UUID
    /// The type of operation to perform.
    let type: OperationType
    /// The workspace-relative path of the target file.
    let path: String
    /// The proposed content for the file.
    let content: String

    /// The type of file operation.
    enum OperationType: String, Codable, Sendable {
        /// Create a new file.
        case create = "create"
        /// Modify an existing file.
        case modify = "modify"
    }

    init(
        id: UUID = UUID(),
        type: OperationType,
        path: String,
        content: String
    ) {
        self.id = id
        self.type = type
        self.path = path
        self.content = content
    }
}

// MARK: - Code Modification Proposal

/// A complete, validated proposal for source-code modifications.
///
/// A proposal contains a set of file operations (max 5) that the user can
/// review, approve, or reject. The proposal is only created after the model's
/// complete response has been received and validated.
struct CodeModificationProposal: Identifiable, Sendable {
    /// A unique identifier for this proposal.
    let id: UUID
    /// The version of the code modification protocol.
    let protocolVersion: Int
    /// The user's original instructions for the modification.
    let userInstructions: String
    /// The model identifier that generated this proposal.
    let modelID: String
    /// The workspace path this proposal is associated with.
    let workspacePath: String
    /// The file operations in this proposal.
    let operations: [CodeModificationOperation]
    /// The timestamp when the proposal was created.
    let createdAt: Date
    /// The current status of this proposal.
    var status: ProposalStatus
    /// The diff for each operation (computed after validation).
    var diffs: [String: FileDiff]
    /// An error message if the proposal is invalid or has conflicts.
    var errorMessage: String?

    /// The current status of a proposal.
    enum ProposalStatus: String, Sendable {
        /// The proposal is pending user review.
        case pending = "pending"
        /// The proposal has been approved and applied.
        case applied = "applied"
        /// The proposal was rejected by the user.
        case rejected = "rejected"
        /// The proposal was discarded by the user.
        case discarded = "discarded"
        /// The proposal has a conflict (file changed since proposal was created).
        case conflict = "conflict"
    }

    init(
        id: UUID = UUID(),
        protocolVersion: Int = 1,
        userInstructions: String,
        modelID: String,
        workspacePath: String,
        operations: [CodeModificationOperation],
        createdAt: Date = Date(),
        status: ProposalStatus = .pending,
        diffs: [String: FileDiff] = [:],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.userInstructions = userInstructions
        self.modelID = modelID
        self.workspacePath = workspacePath
        self.operations = operations
        self.createdAt = createdAt
        self.status = status
        self.diffs = diffs
        self.errorMessage = errorMessage
    }

    /// Whether the proposal is valid and can be approved.
    var isValid: Bool {
        status == .pending && errorMessage == nil && !operations.isEmpty
    }

    /// The number of files affected by this proposal.
    var fileCount: Int { operations.count }

    /// The total number of lines added across all operations.
    var totalLinesAdded: Int {
        operations.reduce(0) { sum, op in
            sum + (diffs[op.path]?.linesAdded ?? 0)
        }
    }

    /// The total number of lines removed across all operations.
    var totalLinesRemoved: Int {
        operations.reduce(0) { sum, op in
            sum + (diffs[op.path]?.linesRemoved ?? 0)
        }
    }

    /// The total number of lines changed (added + removed).
    var totalLinesChanged: Int {
        totalLinesAdded + totalLinesRemoved
    }
}

// MARK: - File Diff

/// A line-by-line diff between two versions of a file.
struct FileDiff: Sendable {
    /// The workspace-relative path of the file.
    let path: String
    /// The operation type (create or modify).
    let operationType: CodeModificationOperation.OperationType
    /// The diff lines, in order.
    let lines: [DiffLine]
    /// The number of lines added.
    let linesAdded: Int
    /// The number of lines removed.
    let linesRemoved: Int
    /// The number of unchanged lines.
    let linesUnchanged: Int

    init(
        path: String,
        operationType: CodeModificationOperation.OperationType,
        lines: [DiffLine],
        linesAdded: Int,
        linesRemoved: Int,
        linesUnchanged: Int
    ) {
        self.path = path
        self.operationType = operationType
        self.lines = lines
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.linesUnchanged = linesUnchanged
    }

    /// A single line in a diff.
    struct DiffLine: Identifiable, Sendable {
        /// A unique identifier for this diff line.
        let id: Int
        /// The type of this diff line.
        let type: LineType
        /// The line content (without trailing newline).
        let content: String
        /// The line number in the old file (for context and removed lines).
        let oldLineNumber: Int?
        /// The line number in the new file (for context and added lines).
        let newLineNumber: Int?

        /// The type of a diff line.
        enum LineType: String, Sendable {
            /// An unchanged context line.
            case context = "context"
            /// An added line (present in new, not in old).
            case added = "added"
            /// A removed line (present in old, not in new).
            case removed = "removed"
        }

        init(
            id: Int,
            type: LineType,
            content: String,
            oldLineNumber: Int? = nil,
            newLineNumber: Int? = nil
        ) {
            self.id = id
            self.type = type
            self.content = content
            self.oldLineNumber = oldLineNumber
            self.newLineNumber = newLineNumber
        }
    }
}

// MARK: - File Snapshot

/// A snapshot of a file's state at a point in time, used for conflict
/// detection and rollback.
struct FileSnapshot: Sendable {
    /// The workspace-relative path of the file.
    let path: String
    /// The SHA-256 hash of the file's content at snapshot time (before the change).
    let contentHash: String
    /// The file's content at snapshot time (for rollback).
    let content: String
    /// Whether the file existed at snapshot time.
    let existed: Bool
    /// The file's permissions (POSIX mode) at snapshot time, if available.
    let permissions: Int?
    /// The text encoding of the file at snapshot time (e.g. "utf8", "isoLatin1").
    /// `nil` for new files or when encoding could not be determined.
    let encoding: String?
    /// The line ending style of the file at snapshot time.
    let lineEnding: LineEndingStyle
    /// Whether the file ended with a trailing newline at snapshot time.
    let hasTrailingNewline: Bool
    /// The SHA-256 hash of the file's content after the change was applied.
    /// Used to verify the file hasn't been modified since the change was applied,
    /// before performing an undo.
    let appliedContentHash: String?

    /// The line ending style of a file.
    enum LineEndingStyle: String, Sendable, Codable {
        /// Unix-style line endings (LF).
        case lf = "lf"
        /// Windows-style line endings (CRLF).
        case crlf = "crlf"
        /// Old Mac-style line endings (CR).
        case cr = "cr"
        /// Mixed or unknown line endings.
        case mixed = "mixed"
    }

    init(
        path: String,
        contentHash: String,
        content: String,
        existed: Bool,
        permissions: Int? = nil,
        encoding: String? = nil,
        lineEnding: LineEndingStyle = .lf,
        hasTrailingNewline: Bool = false,
        appliedContentHash: String? = nil
    ) {
        self.path = path
        self.contentHash = contentHash
        self.content = content
        self.existed = existed
        self.permissions = permissions
        self.encoding = encoding
        self.lineEnding = lineEnding
        self.hasTrailingNewline = hasTrailingNewline
        self.appliedContentHash = appliedContentHash
    }
}

// MARK: - Applied Change Set

/// A record of an applied change set, used for rollback.
struct AppliedChangeSet: Identifiable, Sendable {
    /// A unique identifier for this change set.
    let id: UUID
    /// The proposal that was applied.
    let proposalID: UUID
    /// The user's instructions for the change.
    let userInstructions: String
    /// The model identifier used.
    let modelID: String
    /// The workspace path.
    let workspacePath: String
    /// The timestamp when the change set was applied.
    let appliedAt: Date
    /// Snapshots of the files as they were before the change (for rollback).
    let fileSnapshots: [FileSnapshot]
    /// The paths of files that were created by this change set.
    let createdFiles: [String]
    /// The paths of files that were modified by this change set.
    let modifiedFiles: [String]

    init(
        id: UUID = UUID(),
        proposalID: UUID,
        userInstructions: String,
        modelID: String,
        workspacePath: String,
        appliedAt: Date = Date(),
        fileSnapshots: [FileSnapshot],
        createdFiles: [String],
        modifiedFiles: [String]
    ) {
        self.id = id
        self.proposalID = proposalID
        self.userInstructions = userInstructions
        self.modelID = modelID
        self.workspacePath = workspacePath
        self.appliedAt = appliedAt
        self.fileSnapshots = fileSnapshots
        self.createdFiles = createdFiles
        self.modifiedFiles = modifiedFiles
    }
}

// MARK: - Recovery Record

/// A persistent recovery record for an applied change set.
///
/// Stored in the application's private Application Support directory as JSON.
/// Preserves the information needed to undo a change set across application
/// restarts. Never stored inside the user's project directories.
///
/// API credentials are never included in recovery records.
struct RecoveryRecord: Codable, Sendable {
    /// The version of the recovery record format.
    let formatVersion: Int
    /// The unique identifier of the change set.
    let changeSetID: UUID
    /// The proposal that was applied.
    let proposalID: UUID
    /// The user's instructions for the change.
    let userInstructions: String
    /// The model identifier used.
    let modelID: String
    /// The canonical path of the workspace where the change was applied.
    let workspacePath: String
    /// The timestamp when the change set was applied.
    let appliedAt: Date
    /// Snapshots of the files as they were before the change (for rollback).
    let fileSnapshots: [FileSnapshot]
    /// The paths of files that were created by this change set.
    let createdFiles: [String]
    /// The paths of files that were modified by this change set.
    let modifiedFiles: [String]
    /// Whether the change set was fully applied (all files written successfully).
    let fullyApplied: Bool
    /// Paths of files that could not be restored after a partial failure, if any.
    let unrestoredFiles: [String]

    /// The current version of the recovery record format.
    static let currentFormatVersion = 1

    init(
        changeSetID: UUID,
        proposalID: UUID,
        userInstructions: String,
        modelID: String,
        workspacePath: String,
        appliedAt: Date = Date(),
        fileSnapshots: [FileSnapshot],
        createdFiles: [String],
        modifiedFiles: [String],
        fullyApplied: Bool = true,
        unrestoredFiles: [String] = []
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.changeSetID = changeSetID
        self.proposalID = proposalID
        self.userInstructions = userInstructions
        self.modelID = modelID
        self.workspacePath = workspacePath
        self.appliedAt = appliedAt
        self.fileSnapshots = fileSnapshots
        self.createdFiles = createdFiles
        self.modifiedFiles = modifiedFiles
        self.fullyApplied = fullyApplied
        self.unrestoredFiles = unrestoredFiles
    }

    /// Creates a `RecoveryRecord` from an `AppliedChangeSet`.
    init(from changeSet: AppliedChangeSet, fullyApplied: Bool = true, unrestoredFiles: [String] = []) {
        self.init(
            changeSetID: changeSet.id,
            proposalID: changeSet.proposalID,
            userInstructions: changeSet.userInstructions,
            modelID: changeSet.modelID,
            workspacePath: changeSet.workspacePath,
            appliedAt: changeSet.appliedAt,
            fileSnapshots: changeSet.fileSnapshots,
            createdFiles: changeSet.createdFiles,
            modifiedFiles: changeSet.modifiedFiles,
            fullyApplied: fullyApplied,
            unrestoredFiles: unrestoredFiles
        )
    }

    /// Converts this recovery record to an `AppliedChangeSet` for in-memory use.
    var appliedChangeSet: AppliedChangeSet {
        AppliedChangeSet(
            id: changeSetID,
            proposalID: proposalID,
            userInstructions: userInstructions,
            modelID: modelID,
            workspacePath: workspacePath,
            appliedAt: appliedAt,
            fileSnapshots: fileSnapshots,
            createdFiles: createdFiles,
            modifiedFiles: modifiedFiles
        )
    }
}

// MARK: - Code Modification Errors

/// Errors that can occur during code modification operations.
enum CodeModificationError: LocalizedError {
    /// The model output could not be parsed as valid JSON.
    case invalidJSON(underlying: Error)
    /// The model output is not a valid code modification proposal.
    case invalidProposal(reason: String)
    /// The proposal contains more than the maximum number of files.
    case tooManyFiles(count: Int, limit: Int)
    /// The proposal contains duplicate target paths.
    case duplicatePath(path: String)
    /// The proposal contains an unsupported operation type.
    case unsupportedOperation(type: String)
    /// The proposal references a file the user did not authorize.
    case unauthorizedFile(path: String)
    /// The proposal targets a path outside the workspace.
    case outsideWorkspace(path: String)
    /// The proposal targets a path with traversal or absolute path.
    case invalidPath(path: String)
    /// The proposal targets a sensitive file.
    case sensitiveFile(path: String)
    /// The proposal targets a directory.
    case isDirectory(path: String)
    /// The proposal targets a symbolic link.
    case symbolicLink(path: String)
    /// The proposal targets an unsupported file type.
    case unsupportedFileType(path: String)
    /// The file was modified since the proposal was created (conflict).
    case fileConflict(path: String)
    /// A new file destination already exists.
    case fileAlreadyExists(path: String)
    /// The file does not exist (for modify operations).
    case fileNotFound(path: String)
    /// The workspace is not accessible.
    case workspaceNotAccessible
    /// The workspace was changed, invalidating the proposal.
    case workspaceChanged
    /// The file could not be written.
    case writeFailed(path: String, underlying: Error)
    /// The file could not be read.
    case readFailed(path: String, underlying: Error)
    /// The file could not be backed up.
    case backupFailed(path: String, underlying: Error)
    /// The file could not be restored during rollback.
    case restoreFailed(path: String, underlying: Error)
    /// The file was modified since the change set was applied (rollback conflict).
    case rollbackConflict(path: String)
    /// The proposal is incomplete or invalid.
    case incompleteProposal(reason: String)
    /// No workspace is selected.
    case noWorkspace
    /// The model output is empty.
    case emptyModelOutput
    /// The model output does not contain a valid proposal (ordinary chat response).
    case notAProposal
    /// The proposal exceeds the maximum aggregate output size.
    case proposalTooLarge(totalBytes: Int, limit: Int)
    /// A single file in the proposal exceeds the maximum per-file output size.
    case fileTooLarge(path: String, size: Int, limit: Int)
    /// The proposal targets a path whose parent directory is a symbolic link.
    case symlinkParentDirectory(path: String)
    /// The proposal targets a path that is an unsupported filesystem object.
    case unsupportedFileObject(path: String)
    /// The proposal's workspace identity does not match the current workspace.
    case workspaceIdentityMismatch
    /// A recovery record was corrupted or incomplete.
    case corruptedRecoveryRecord(reason: String)
    /// The file's encoding is not supported for modification.
    case unsupportedEncoding(path: String, encoding: String)
    /// The proposal was invalidated because the workspace changed.
    case proposalInvalidated(reason: String)
    /// The undo operation encountered conflicts in multiple files.
    case undoConflicts(paths: [String])
    /// The undo operation could not be completed; some files could not be restored.
    case undoPartialFailure(restored: [String], failed: [String])

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let underlying):
            return "Failed to parse model output as JSON: \(underlying.localizedDescription)"
        case .invalidProposal(let reason):
            return "Invalid proposal: \(reason)"
        case .tooManyFiles(let count, let limit):
            return "Proposal affects \(count) files, exceeding the limit of \(limit)."
        case .duplicatePath(let path):
            return "Proposal contains duplicate path: \(path)"
        case .unsupportedOperation(let type):
            return "Unsupported operation type: \(type). Only 'create' and 'modify' are supported."
        case .unauthorizedFile(let path):
            return "File was not authorized for editing: \(path)"
        case .outsideWorkspace(let path):
            return "Path is outside the workspace: \(path)"
        case .invalidPath(let path):
            return "Invalid path (absolute or traversal): \(path)"
        case .sensitiveFile(let path):
            return "File is sensitive and cannot be modified: \(path)"
        case .isDirectory(let path):
            return "Path is a directory, not a file: \(path)"
        case .symbolicLink(let path):
            return "Path is a symbolic link and cannot be modified: \(path)"
        case .unsupportedFileType(let path):
            return "File type is not supported for modification: \(path)"
        case .fileConflict(let path):
            return "File has been modified since the proposal was created: \(path)"
        case .fileAlreadyExists(let path):
            return "File already exists (cannot create): \(path)"
        case .fileNotFound(let path):
            return "File not found (cannot modify): \(path)"
        case .workspaceNotAccessible:
            return "The workspace is not accessible."
        case .workspaceChanged:
            return "The workspace has changed. The proposal is no longer valid."
        case .writeFailed(let path, let underlying):
            return "Failed to write file \(path): \(underlying.localizedDescription)"
        case .readFailed(let path, let underlying):
            return "Failed to read file \(path): \(underlying.localizedDescription)"
        case .backupFailed(let path, let underlying):
            return "Failed to back up file \(path): \(underlying.localizedDescription)"
        case .restoreFailed(let path, let underlying):
            return "Failed to restore file \(path): \(underlying.localizedDescription)"
        case .rollbackConflict(let path):
            return "File has been modified since the change was applied: \(path)"
        case .incompleteProposal(let reason):
            return "Proposal is incomplete: \(reason)"
        case .noWorkspace:
            return "No workspace selected."
        case .emptyModelOutput:
            return "The model returned no output."
        case .notAProposal:
            return "The model response is not a code modification proposal."
        case .proposalTooLarge(let totalBytes, let limit):
            return "Proposal exceeds maximum aggregate size (\(totalBytes) bytes, limit \(limit) bytes)."
        case .fileTooLarge(let path, let size, let limit):
            return "File \(path) exceeds maximum size (\(size) bytes, limit \(limit) bytes)."
        case .symlinkParentDirectory(let path):
            return "Path \(path) is inside a symbolic-link directory and cannot be modified."
        case .unsupportedFileObject(let path):
            return "Path \(path) is an unsupported filesystem object."
        case .workspaceIdentityMismatch:
            return "The proposal was created for a different workspace and cannot be applied."
        case .corruptedRecoveryRecord(let reason):
            return "Recovery record is corrupted or incomplete: \(reason)"
        case .unsupportedEncoding(let path, let encoding):
            return "File \(path) uses unsupported encoding '\(encoding)' and cannot be safely modified."
        case .proposalInvalidated(let reason):
            return "Proposal invalidated: \(reason)"
        case .undoConflicts(let paths):
            return "Cannot undo: the following files have been modified since the change was applied: \(paths.joined(separator: ", "))"
        case .undoPartialFailure(let restored, let failed):
            return "Undo partially completed. Restored: \(restored.joined(separator: ", ")). Could not restore: \(failed.joined(separator: ", "))."
        }
    }
}

// MARK: - Code Modification Protocol (JSON)

/// The JSON protocol for code modification requests and responses.
///
/// The model is instructed to return a JSON object with this structure.
/// The `protocolVersion` field ensures forward compatibility.
struct CodeModificationProtocol: Sendable {
    /// The current version of the code modification protocol.
    static let currentVersion = 1

    /// The JSON structure the model is expected to return.
    struct ModelResponse: Codable, Sendable {
        /// The protocol version.
        let protocolVersion: Int
        /// The operations to perform.
        let operations: [OperationJSON]

        /// A single operation in the model's JSON response.
        struct OperationJSON: Codable, Sendable {
            /// The operation type ("create" or "modify").
            let type: String
            /// The workspace-relative path.
            let path: String
            /// The proposed content.
            let content: String
        }
    }
}
