import Foundation
import CryptoKit
import Observation

// MARK: - Code Modification Service

/// A service that manages AI-proposed source-code modifications.
///
/// This service handles the full lifecycle of a code modification:
/// 1. **Request construction** — builds a structured prompt that instructs
///    the model to return a versioned JSON proposal.
/// 2. **Model output parsing** — extracts and parses the JSON proposal from
///    the model's response, handling markdown code fences.
/// 3. **Proposal validation** — validates operations, paths, file types,
///    sensitive files, workspace boundaries, file authorization, and
///    resource limits.
/// 4. **Diff generation** — computes line-by-line diffs between the current
///    file content and the proposed content.
/// 5. **Conflict detection** — records SHA-256 hashes of files at proposal
///    time and verifies them before applying.
/// 6. **Safe filesystem operations** — writes files atomically within the
///    authorized workspace, preserving permissions, encoding, and line endings.
/// 7. **Backup and rollback** — preserves original file content and supports
///    undo of the most recent change set with conflict detection.
/// 8. **Persistent recovery** — stores recovery records in the application's
///    private Application Support directory for cross-restart undo.
///
/// The service is `@MainActor`-isolated to match the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` setting.
@Observable
@MainActor
final class CodeModificationService {

    // MARK: - Published State

    /// The current code modification proposal, if any.
    private(set) var currentProposal: CodeModificationProposal?
    /// Whether a code modification request is in flight.
    private(set) var isGenerating: Bool = false
    /// The most recent error message, if any.
    private(set) var lastError: String?
    /// The history of applied change sets (bounded).
    private(set) var changeHistory: [AppliedChangeSet] = []
    /// The currently selected files for code modification (workspace-relative paths).
    private(set) var selectedFiles: [String] = []
    /// Whether an undo operation is available.
    var canUndo: Bool { !changeHistory.isEmpty }
    /// A warning message about a partially failed apply or undo, if any.
    private(set) var lastWarning: String?
    
    func setGenerating(_ generating: Bool) {
        isGenerating = generating
    }

    // MARK: - Configuration

    /// The maximum number of files that can be modified in a single proposal.
    let maxFilesPerProposal: Int = 5

    /// The maximum number of change sets to keep in history.
    let maxHistorySize: Int = 20

    /// The maximum file size (in bytes) that can be modified.
    var maxFileSize: Int64 = 1_048_576 // 1 MB

    /// The maximum aggregate proposal size (in bytes) across all files.
    var maxAggregateProposalSize: Int64 = 5_242_880 // 5 MB

    // MARK: - Private

    private let workspaceService: WorkspaceService
    private let explorerService: WorkspaceExplorerService
    private let fileManager: FileManager
    private let safeFileWriter: SafeFileWriter
    private let recoveryStore: RecoveryStore

    /// Pending file snapshots, stored between finalization and application.
    private var pendingSnapshots: [FileSnapshot] = []

    /// The workspace identity (canonical path) that the current proposal was
    /// created for. Used to detect workspace changes.
    private var proposalWorkspaceIdentity: String?

    // MARK: - Init

    /// Creates a code modification service.
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
        self.safeFileWriter = SafeFileWriter(fileManager: fileManager)
        self.recoveryStore = RecoveryStore(fileManager: fileManager)

        // Restore recovery history from disk.
        restoreRecoveryHistory()
    }

    // MARK: - Recovery History Restoration

    /// Restores the in-memory change history from persistent recovery records.
    ///
    /// Called at initialization to recover undo history across application
    /// restarts. Only records matching the current workspace are loaded.
    private func restoreRecoveryHistory() {
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            return
        }

        let canonicalPath = workspaceURL.resolvingSymlinksInPath().path
        let records = recoveryStore.load(forWorkspace: canonicalPath)

        for record in records {
            changeHistory.append(record.appliedChangeSet)
        }

        // Enforce the bounded history.
        if changeHistory.count > maxHistorySize {
            changeHistory.removeFirst(changeHistory.count - maxHistorySize)
        }
    }

    // MARK: - File Selection

    /// Adds a file to the selection for code modification.
    ///
    /// - Parameter relativePath: The workspace-relative path of the file.
    func selectFile(relativePath: String) {
        guard !selectedFiles.contains(relativePath) else { return }
        guard selectedFiles.count < maxFilesPerProposal else { return }
        selectedFiles.append(relativePath)
    }

    /// Removes a file from the selection.
    ///
    /// - Parameter relativePath: The workspace-relative path of the file.
    func deselectFile(relativePath: String) {
        selectedFiles.removeAll { $0 == relativePath }
    }

    /// Clears all selected files.
    func clearFileSelection() {
        selectedFiles.removeAll()
    }

    // MARK: - Request Construction

    /// Builds the prompt for a code modification request.
    ///
    /// The prompt includes:
    /// - A system instruction to return a versioned JSON proposal.
    /// - The current content of each selected file (for modify operations).
    /// - The user's instructions for the modification.
    ///
    /// For create-only requests (no files selected), the prompt instructs the
    /// model to return a `create` operation with a workspace-relative path.
    ///
    /// - Parameters:
    ///   - userInstructions: The user's description of the desired modification.
    ///   - fileContents: An array of `(relativePath, content)` tuples for the selected files.
    /// - Returns: The assembled prompt text.
    /// - Throws: `CodeModificationError` if the request cannot be constructed.
    func buildModificationPrompt(
        userInstructions: String,
        fileContents: [(relativePath: String, content: String)]
    ) throws -> String {
        guard !userInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodeModificationError.incompleteProposal(reason: "No instructions provided")
        }

        guard fileContents.count <= maxFilesPerProposal else {
            throw CodeModificationError.tooManyFiles(count: fileContents.count, limit: maxFilesPerProposal)
        }

        var parts: [String] = []

        // System instruction for the model.
        if fileContents.isEmpty {
            // Create-only request.
            parts.append("""
            You are a code modification assistant. The user wants to create a new file in their workspace.

            You MUST respond with a JSON object (and nothing else) that follows this exact schema:

            {
              "protocolVersion": 1,
              "operations": [
                {
                  "type": "create",
                  "path": "workspace-relative/path/to/new/file",
                  "content": "the complete content of the new file"
                }
              ]
            }

            Rules:
            - "type" must be "create" for new files.
            - "path" must be a workspace-relative path (no leading slash, no "..").
            - "content" must be the COMPLETE content of the new file.
            - You may propose at most \(maxFilesPerProposal) operations.
            - Do NOT include any text outside the JSON object.
            - Do NOT use markdown code fences. Return raw JSON only.
            - The file must not already exist in the workspace.
            - Use UTF-8 encoding with LF line endings for new files.

            """)
        } else {
            // Modify request (with optional create operations).
            parts.append("""
            You are a code modification assistant. The user will provide the current content of one or more files and instructions for how to modify them.

            You MUST respond with a JSON object (and nothing else) that follows this exact schema:

            {
              "protocolVersion": 1,
              "operations": [
                {
                  "type": "create" | "modify",
                  "path": "workspace-relative/path/to/file",
                  "content": "the complete new content of the file"
                }
              ]
            }

            Rules:
            - "type" must be either "create" (for new files) or "modify" (for existing files).
            - "path" must be a workspace-relative path (no leading slash, no "..").
            - "content" must be the COMPLETE content of the file after the modification.
            - You may propose at most \(maxFilesPerProposal) operations.
            - Do NOT include any text outside the JSON object.
            - Do NOT use markdown code fences. Return raw JSON only.
            - For "modify" operations, include the complete file content, not just the changed lines.
            - Preserve the existing code style and formatting of the file.
            - Only modify files that the user has provided. Do not reference files that were not provided.
            - For "create" operations, the file must not already exist.

            """)
        }

        // File contents (only for modify requests).
        for file in fileContents {
            parts.append("<<<FILE: \(file.relativePath)")
            parts.append(file.content)
            parts.append("END_FILE>>>")
            parts.append("")
        }

        // User instructions.
        parts.append("User instructions:")
        parts.append(userInstructions)

        return parts.joined(separator: "\n")
    }

    // MARK: - Model Output Parsing

    /// Parses the model's response text into a `CodeModificationProposal`.
    ///
    /// Handles:
    /// - Raw JSON
    /// - JSON wrapped in markdown code fences (```json ... ```)
    /// - JSON with leading/trailing whitespace
    ///
    /// - Parameters:
    ///   - modelResponse: The raw text response from the model.
    ///   - userInstructions: The user's original instructions.
    ///   - modelID: The model identifier that generated the response.
    ///   - workspacePath: The workspace path.
    /// - Returns: A validated `CodeModificationProposal`.
    /// - Throws: `CodeModificationError` if the response cannot be parsed or is invalid.
    func parseModelResponse(
        _ modelResponse: String,
        userInstructions: String,
        modelID: String,
        workspacePath: String
    ) throws -> CodeModificationProposal {
        // Check for empty response.
        let trimmed = modelResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CodeModificationError.emptyModelOutput
        }

        // Extract JSON from the response.
        let jsonText = extractJSON(from: trimmed)

        // Decode the JSON.
        let decoded: CodeModificationProtocol.ModelResponse
        do {
            decoded = try JSONDecoder().decode(
                CodeModificationProtocol.ModelResponse.self,
                from: Data(jsonText.utf8)
            )
        } catch {
            throw CodeModificationError.invalidJSON(underlying: error)
        }

        // Validate the protocol version.
        guard decoded.protocolVersion == CodeModificationProtocol.currentVersion else {
            throw CodeModificationError.invalidProposal(
                reason: "Unsupported protocol version \(decoded.protocolVersion). Expected \(CodeModificationProtocol.currentVersion)."
            )
        }

        // Convert JSON operations to typed operations.
        var operations: [CodeModificationOperation] = []
        var seenResolvedPaths = Set<String>()
        var totalContentBytes = 0

        for opJSON in decoded.operations {
            // Validate operation type.
            guard let opType = CodeModificationOperation.OperationType(rawValue: opJSON.type) else {
                throw CodeModificationError.unsupportedOperation(type: opJSON.type)
            }

            // Validate path.
            let path = opJSON.path
            try validatePath(path)

            // Check for duplicates (using resolved paths to catch different
            // representations of the same file).
            let resolvedPath = resolveWorkspacePath(path)
            guard !seenResolvedPaths.contains(resolvedPath) else {
                throw CodeModificationError.duplicatePath(path: path)
            }
            seenResolvedPaths.insert(resolvedPath)

            // Enforce per-file size limit.
            let contentBytes = opJSON.content.utf8.count
            guard contentBytes <= Int(maxFileSize) else {
                throw CodeModificationError.fileTooLarge(
                    path: path,
                    size: contentBytes,
                    limit: Int(maxFileSize)
                )
            }

            totalContentBytes += contentBytes

            operations.append(
                CodeModificationOperation(
                    type: opType,
                    path: path,
                    content: opJSON.content
                )
            )
        }

        // Validate file count.
        guard operations.count <= maxFilesPerProposal else {
            throw CodeModificationError.tooManyFiles(count: operations.count, limit: maxFilesPerProposal)
        }

        guard !operations.isEmpty else {
            throw CodeModificationError.incompleteProposal(reason: "No operations in proposal")
        }

        // Enforce aggregate size limit.
        guard Int64(totalContentBytes) <= maxAggregateProposalSize else {
            throw CodeModificationError.proposalTooLarge(
                totalBytes: totalContentBytes,
                limit: Int(maxAggregateProposalSize)
            )
        }

        // Validate file authorization: every modify operation must reference
        // a file the user explicitly selected.
        let authorizedFiles = Set(selectedFiles)
        for op in operations where op.type == .modify {
            guard authorizedFiles.contains(op.path) else {
                throw CodeModificationError.unauthorizedFile(path: op.path)
            }
        }

        // Create the proposal.
        let proposal = CodeModificationProposal(
            userInstructions: userInstructions,
            modelID: modelID,
            workspacePath: workspacePath,
            operations: operations
        )

        // Record the workspace identity for this proposal.
        proposalWorkspaceIdentity = workspacePath

        return proposal
    }

    /// Extracts JSON text from a model response, handling markdown code fences.
    ///
    /// - Parameter text: The raw model response text.
    /// - Returns: The extracted JSON text.
    private func extractJSON(from text: String) -> String {
        // Check for markdown code fences.
        let fencePattern = "```"
        if let firstFence = text.range(of: fencePattern) {
            let afterFirstFence = text[firstFence.upperBound...]
            // Skip the language identifier (e.g., "json").
            let newlineRange = afterFirstFence.range(of: "\n")
            let contentStart: String
            if let nl = newlineRange {
                contentStart = String(afterFirstFence[nl.upperBound...])
            } else {
                contentStart = String(afterFirstFence)
            }

            // Find the closing fence.
            if let lastFence = contentStart.range(of: fencePattern, options: .backwards) {
                let jsonContent = String(contentStart[..<lastFence.lowerBound])
                return jsonContent.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // No code fences — return the text as-is (assumed to be raw JSON).
        return text
    }

    // MARK: - Path Validation

    /// Validates a workspace-relative path for a code modification operation.
    ///
    /// Rejects:
    /// - Absolute paths (starting with `/`)
    /// - Paths with `..` components (traversal)
    /// - Paths with null bytes
    /// - Empty paths
    /// - Paths that resolve outside the workspace
    /// - Sensitive files
    /// - Paths that are directories
    /// - Symbolic links
    /// - Paths whose parent directory is a symbolic link
    ///
    /// - Parameter path: The workspace-relative path to validate.
    /// - Throws: `CodeModificationError` if the path is invalid.
    func validatePath(_ path: String) throws {
        // Reject empty paths.
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CodeModificationError.invalidPath(path: path)
        }

        // Reject absolute paths.
        guard !path.hasPrefix("/") else {
            throw CodeModificationError.invalidPath(path: path)
        }

        // Reject null bytes.
        guard !path.contains("\0") else {
            throw CodeModificationError.invalidPath(path: path)
        }

        // Reject paths with ".." components.
        let components = path.split(separator: "/")
        if components.contains("..") {
            throw CodeModificationError.invalidPath(path: path)
        }

        // Validate against the workspace.
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            throw CodeModificationError.noWorkspace
        }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path
        let resolvedPath = (workspaceURL.appendingPathComponent(path).resolvingSymlinksInPath()).path

        // Enforce workspace boundary.
        guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
            throw CodeModificationError.outsideWorkspace(path: path)
        }

        // Check for sensitive files.
        if explorerService.isSensitiveFile(path) {
            throw CodeModificationError.sensitiveFile(path: path)
        }

        // Ensure security-scoped access for filesystem checks.
        guard workspaceService.startAccessing() else {
            throw CodeModificationError.workspaceNotAccessible
        }
        defer { workspaceService.stopAccessing() }

        // Check if the path exists.
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) {
            // Reject directories.
            if isDirectory.boolValue {
                throw CodeModificationError.isDirectory(path: path)
            }

            // Check the original path without following the link.
            if (try? fileManager.destinationOfSymbolicLink(
                atPath: workspaceURL.appendingPathComponent(path).path
            )) != nil {
                throw CodeModificationError.symbolicLink(path: path)
            }
        }

        // Check for symbolic-link parent directories.
        // Walk up the path components and check if any parent is a symlink.
        try validateNoSymlinkParents(
            relativePath: path,
            workspaceURL: workspaceURL,
            resolvedRoot: resolvedRoot
        )
    }

    /// Validates that no parent directory of the given path is a symbolic link.
    ///
    /// - Parameters:
    ///   - relativePath: The workspace-relative path.
    ///   - workspaceURL: The workspace root URL.
    ///   - resolvedRoot: The resolved workspace root path.
    /// - Throws: `CodeModificationError.symlinkParentDirectory` if a parent is a symlink.
    private func validateNoSymlinkParents(
        relativePath: String,
        workspaceURL: URL,
        resolvedRoot: String
    ) throws {
        let components = relativePath.split(separator: "/").map(String.init)
        guard components.count > 1 else { return }

        // Check each parent directory (excluding the final component).
        for i in 0..<(components.count - 1) {
            let parentRelative = components[0...i].joined(separator: "/")
            let originalParent = workspaceURL.appendingPathComponent(parentRelative).path
            if (try? fileManager.destinationOfSymbolicLink(atPath: originalParent)) != nil {
                throw CodeModificationError.symlinkParentDirectory(path: relativePath)
            }
            let parentPath = URL(fileURLWithPath: originalParent).resolvingSymlinksInPath().path

            // Verify the parent is still within the workspace.
            guard explorerService.isWithinWorkspace(parentPath, resolvedRoot: resolvedRoot) else {
                throw CodeModificationError.outsideWorkspace(path: relativePath)
            }
        }
    }

    /// Resolves a workspace-relative path to its canonical (resolved) path.
    ///
    /// - Parameter relativePath: The workspace-relative path.
    /// - Returns: The resolved canonical path, or the original path if resolution fails.
    private func resolveWorkspacePath(_ relativePath: String) -> String {
        guard let workspaceURL = workspaceService.selectedDirectory else {
            return relativePath
        }
        return workspaceURL.appendingPathComponent(relativePath).resolvingSymlinksInPath().path
    }

    // MARK: - Diff Generation

    /// Generates a `FileDiff` for a single operation.
    ///
    /// For create operations, all lines are marked as added.
    /// For modify operations, a line-by-line diff is computed.
    ///
    /// - Parameters:
    ///   - operation: The operation to generate a diff for.
    ///   - currentContent: The current content of the file (nil for new files).
    /// - Returns: A `FileDiff` describing the changes.
    func generateDiff(
        for operation: CodeModificationOperation,
        currentContent: String?
    ) -> FileDiff {
        let newLines = operation.content.components(separatedBy: "\n")
        // Remove the trailing empty element if the content ends with a newline.
        let cleanedNewLines: [String]
        if newLines.last?.isEmpty == true && newLines.count > 1 {
            cleanedNewLines = Array(newLines.dropLast())
        } else {
            cleanedNewLines = newLines
        }

        if operation.type == .create {
            // All lines are added.
            let diffLines: [FileDiff.DiffLine] = cleanedNewLines.enumerated().map { index, line in
                FileDiff.DiffLine(
                    id: index,
                    type: .added,
                    content: line,
                    oldLineNumber: nil,
                    newLineNumber: index + 1
                )
            }
            return FileDiff(
                path: operation.path,
                operationType: .create,
                lines: diffLines,
                linesAdded: cleanedNewLines.count,
                linesRemoved: 0,
                linesUnchanged: 0
            )
        } else {
            // Modify: compute a line-by-line diff.
            let oldLines: [String]
            if let current = currentContent {
                let split = current.components(separatedBy: "\n")
                if split.last?.isEmpty == true && split.count > 1 {
                    oldLines = Array(split.dropLast())
                } else {
                    oldLines = split
                }
            } else {
                oldLines = []
            }

            let diffLines = computeLineDiff(oldLines: oldLines, newLines: cleanedNewLines)

            let added = diffLines.filter { $0.type == .added }.count
            let removed = diffLines.filter { $0.type == .removed }.count
            let unchanged = diffLines.filter { $0.type == .context }.count

            return FileDiff(
                path: operation.path,
                operationType: .modify,
                lines: diffLines,
                linesAdded: added,
                linesRemoved: removed,
                linesUnchanged: unchanged
            )
        }
    }

    /// Computes a line-by-line diff between two arrays of lines.
    ///
    /// Uses a simple LCS-based approach to identify added, removed, and
    /// unchanged lines.
    ///
    /// - Parameters:
    ///   - oldLines: The lines from the old version.
    ///   - newLines: The lines from the new version.
    /// - Returns: An array of `DiffLine` values.
    func computeLineDiff(oldLines: [String], newLines: [String]) -> [FileDiff.DiffLine] {
        let oldCount = oldLines.count
        let newCount = newLines.count

        // Build the LCS table.
        var dp = [[Int]](repeating: [Int](repeating: 0, count: newCount + 1), count: oldCount + 1)

        for i in 1...oldCount {
            for j in 1...newCount {
                if oldLines[i - 1] == newLines[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack to produce the diff.
        var result: [FileDiff.DiffLine] = []
        var i = oldCount
        var j = newCount
        var backtracked: [(type: FileDiff.DiffLine.LineType, oldLine: Int, newLine: Int, content: String)] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && oldLines[i - 1] == newLines[j - 1] {
                backtracked.append((.context, i, j, oldLines[i - 1]))
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
                backtracked.append((.added, 0, j, newLines[j - 1]))
                j -= 1
            } else if i > 0 && (j == 0 || dp[i - 1][j] > dp[i][j - 1]) {
                backtracked.append((.removed, i, 0, oldLines[i - 1]))
                i -= 1
            } else {
                break
            }
        }

        backtracked.reverse()

        // Assign line numbers.
        var oldLineNum = 0
        var newLineNum = 0
        for (index, entry) in backtracked.enumerated() {
            switch entry.type {
            case .context:
                oldLineNum += 1
                newLineNum += 1
                result.append(FileDiff.DiffLine(
                    id: index,
                    type: .context,
                    content: entry.content,
                    oldLineNumber: oldLineNum,
                    newLineNumber: newLineNum
                ))
            case .added:
                newLineNum += 1
                result.append(FileDiff.DiffLine(
                    id: index,
                    type: .added,
                    content: entry.content,
                    oldLineNumber: nil,
                    newLineNumber: newLineNum
                ))
            case .removed:
                oldLineNum += 1
                result.append(FileDiff.DiffLine(
                    id: index,
                    type: .removed,
                    content: entry.content,
                    oldLineNumber: oldLineNum,
                    newLineNumber: nil
                ))
            }
        }

        return result
    }

    // MARK: - Proposal Finalization

    /// Finalizes a proposal by computing diffs and recording file snapshots.
    ///
    /// This should be called after `parseModelResponse` succeeds and before
    /// the proposal is presented to the user for review.
    ///
    /// - Parameter proposal: The proposal to finalize.
    /// - Returns: The finalized proposal with diffs and snapshots.
    /// - Throws: `CodeModificationError` if finalization fails.
    func finalizeProposal(_ proposal: CodeModificationProposal) throws -> CodeModificationProposal {
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            throw CodeModificationError.noWorkspace
        }

        // Verify workspace identity matches.
        let currentCanonical = workspaceURL.resolvingSymlinksInPath().path
        guard proposal.workspacePath == currentCanonical ||
              URL(fileURLWithPath: proposal.workspacePath).resolvingSymlinksInPath().path == currentCanonical else {
            throw CodeModificationError.workspaceIdentityMismatch
        }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path

        guard workspaceService.startAccessing() else {
            throw CodeModificationError.workspaceNotAccessible
        }
        defer { workspaceService.stopAccessing() }

        var diffs: [String: FileDiff] = [:]
        var snapshots: [FileSnapshot] = []

        for operation in proposal.operations {
            let resolvedPath = workspaceURL.appendingPathComponent(operation.path).resolvingSymlinksInPath().path

            // Re-validate the path.
            guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
                throw CodeModificationError.outsideWorkspace(path: operation.path)
            }

            // Check for sensitive files.
            if explorerService.isSensitiveFile(operation.path) {
                throw CodeModificationError.sensitiveFile(path: operation.path)
            }

            // Read the current content (if the file exists).
            var currentContent: String? = nil
            var fileExists = false
            var isDirectory: ObjCBool = false
            var fileEncoding: String.Encoding = .utf8
            var fileLineEnding: FileSnapshot.LineEndingStyle = .lf
            var fileHasTrailingNewline = false
            var filePermissions: Int? = nil

            if fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    throw CodeModificationError.isDirectory(path: operation.path)
                }

                if (try? fileManager.destinationOfSymbolicLink(
                    atPath: workspaceURL.appendingPathComponent(operation.path).path
                )) != nil {
                    throw CodeModificationError.symbolicLink(path: operation.path)
                }

                fileExists = true

                // Check size limit.
                let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath)
                let fileSize = Int64(attributes?[.size] as? Int ?? 0)
                if fileSize > maxFileSize {
                    throw CodeModificationError.fileTooLarge(
                        path: operation.path,
                        size: Int(fileSize),
                        limit: Int(maxFileSize)
                    )
                }

                // Record permissions.
                filePermissions = (attributes?[.posixPermissions] as? Int)

                // Read the content.
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
                    let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
                    if isBinary {
                        throw CodeModificationError.unsupportedFileType(path: operation.path)
                    }
                    fileEncoding = encoding ?? .utf8
                    guard let decoded = String(data: data, encoding: fileEncoding) else {
                        throw CodeModificationError.unsupportedEncoding(path: operation.path, encoding: "\(fileEncoding)")
                    }
                    currentContent = decoded

                    // Detect line endings and trailing newline.
                    if let content = currentContent {
                        fileLineEnding = SafeFileWriter.detectLineEnding(content)
                        fileHasTrailingNewline = SafeFileWriter.hasTrailingNewline(content)
                    }
                } catch {
                    throw CodeModificationError.readFailed(path: operation.path, underlying: error)
                }
            }

            // For modify operations, the file must exist.
            if operation.type == .modify && !fileExists {
                throw CodeModificationError.fileNotFound(path: operation.path)
            }

            // For create operations, the file must NOT exist.
            if operation.type == .create && fileExists {
                throw CodeModificationError.fileAlreadyExists(path: operation.path)
            }

            // Generate the diff.
            let diff = generateDiff(for: operation, currentContent: currentContent)
            diffs[operation.path] = diff

            // Record a snapshot for conflict detection and rollback.
            let contentHash = fileExists
                ? SafeFileWriter.sha256Hash(try Data(contentsOf: URL(fileURLWithPath: resolvedPath)))
                : ""

            snapshots.append(
                FileSnapshot(
                    path: operation.path,
                    contentHash: contentHash,
                    content: currentContent ?? "",
                    existed: fileExists,
                    permissions: filePermissions,
                    encoding: String(fileEncoding.rawValue),
                    lineEnding: fileLineEnding,
                    hasTrailingNewline: fileHasTrailingNewline
                )
            )
        }

        // Update the proposal with diffs.
        var finalized = proposal
        finalized.diffs = diffs
        finalized.status = .pending
        finalized.errorMessage = nil

        // Store snapshots for use during application.
        self.pendingSnapshots = snapshots

        currentProposal = finalized
        return finalized
    }

    // MARK: - Conflict Detection

    /// Verifies that the files have not been modified since the proposal was created.
    ///
    /// - Parameter proposal: The proposal to verify.
    /// - Returns: `true` if all files match their snapshots.
    /// - Throws: `CodeModificationError.fileConflict` if any file has changed.
    func verifyNoConflicts(_ proposal: CodeModificationProposal) throws -> Bool {
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            throw CodeModificationError.noWorkspace
        }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path

        guard workspaceService.startAccessing() else {
            throw CodeModificationError.workspaceNotAccessible
        }
        defer { workspaceService.stopAccessing() }

        for snapshot in pendingSnapshots {
            let resolvedPath = workspaceURL.appendingPathComponent(snapshot.path).resolvingSymlinksInPath().path

            // Re-validate the path.
            guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
                throw CodeModificationError.outsideWorkspace(path: snapshot.path)
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory)

            if snapshot.existed {
                // The file should still exist.
                guard exists, !isDirectory.boolValue else {
                    throw CodeModificationError.fileConflict(path: snapshot.path)
                }

                // Verify the hash.
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
                    let currentHash = SafeFileWriter.sha256Hash(data)
                    guard currentHash == snapshot.contentHash else {
                        throw CodeModificationError.fileConflict(path: snapshot.path)
                    }
                } catch {
                    throw CodeModificationError.fileConflict(path: snapshot.path)
                }
            } else {
                // The file should NOT exist (for create operations).
                guard !exists else {
                    throw CodeModificationError.fileAlreadyExists(path: snapshot.path)
                }
            }
        }

        return true
    }

    // MARK: - Apply Proposal

    /// Applies the current proposal, writing all files atomically.
    ///
    /// This is a staged transaction: all files are validated first, then
    /// written one by one. If any write fails, the previously written files
    /// are rolled back. This is NOT a true filesystem-atomic transaction
    /// across multiple independent files.
    ///
    /// - Parameter proposal: The proposal to apply.
    /// - Returns: The `AppliedChangeSet` record.
    /// - Throws: `CodeModificationError` if the application fails.
    func applyProposal(_ proposal: CodeModificationProposal) throws -> AppliedChangeSet {
        guard proposal.isValid else {
            throw CodeModificationError.incompleteProposal(reason: "Proposal is not valid")
        }

        // Verify workspace identity.
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            throw CodeModificationError.noWorkspace
        }

        let currentCanonical = workspaceURL.resolvingSymlinksInPath().path
        guard URL(fileURLWithPath: proposal.workspacePath).resolvingSymlinksInPath().path == currentCanonical else {
            throw CodeModificationError.workspaceIdentityMismatch
        }

        // Verify no conflicts.
        try verifyNoConflicts(proposal)

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path

        guard workspaceService.startAccessing() else {
            throw CodeModificationError.workspaceNotAccessible
        }
        defer { workspaceService.stopAccessing() }

        guard pendingSnapshots.count == proposal.operations.count,
              currentProposal?.id == proposal.id else {
            throw CodeModificationError.incompleteProposal(reason: "Proposal snapshots are missing or stale")
        }

        // Phase 1: Validate all operations before beginning writes.
        for (index, operation) in proposal.operations.enumerated() {
            let resolvedPath = workspaceURL.appendingPathComponent(operation.path).resolvingSymlinksInPath().path

            guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
                throw CodeModificationError.outsideWorkspace(path: operation.path)
            }

            try validatePath(operation.path)

            // Re-validate authorization for modify operations.
            if operation.type == .modify {
                let authorizedFiles = Set(selectedFiles)
                guard authorizedFiles.contains(operation.path) else {
                    throw CodeModificationError.unauthorizedFile(path: operation.path)
                }
            }
        }

        // Persist a recovery journal before changing any workspace files.
        let journal = RecoveryRecord(
            changeSetID: proposal.id,
            proposalID: proposal.id,
            userInstructions: proposal.userInstructions,
            modelID: proposal.modelID,
            workspacePath: currentCanonical,
            fileSnapshots: pendingSnapshots,
            createdFiles: proposal.operations.filter { $0.type == .create }.map { $0.path },
            modifiedFiles: proposal.operations.filter { $0.type == .modify }.map { $0.path },
            fullyApplied: false
        )
        try recoveryStore.save(journal)

        // Phase 2: Write all files, tracking what was written for rollback.
        var writtenFiles: [(path: String, resolvedPath: String, snapshot: FileSnapshot)] = []
        var appliedHashes: [String: String] = [:]

        do {
            for (index, operation) in proposal.operations.enumerated() {
                let resolvedPath = workspaceURL.appendingPathComponent(operation.path).resolvingSymlinksInPath().path

                try validatePath(operation.path)

                // Re-validate the path immediately before writing.
                guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
                    throw CodeModificationError.outsideWorkspace(path: operation.path)
                }

                let snapshot = pendingSnapshots[index]

                if operation.type == .modify {
                    // Replace the existing file atomically.
                    try safeFileWriter.replaceFile(
                        content: operation.content,
                        to: resolvedPath,
                        permissions: snapshot.permissions,
                        encoding: encodingFromSnapshot(snapshot),
                        lineEnding: snapshot.lineEnding,
                        hasTrailingNewline: snapshot.hasTrailingNewline
                    )
                } else {
                    // Create the new file.
                    try safeFileWriter.createFile(
                        content: operation.content,
                        to: resolvedPath,
                        permissions: snapshot.permissions ?? 0o644,
                        encoding: .utf8,
                        lineEnding: .lf,
                        hasTrailingNewline: true
                    )
                }

                // Hash the exact bytes written, including encoding and newlines.
                let storedData = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
                appliedHashes[operation.path] = SafeFileWriter.sha256Hash(storedData)

                writtenFiles.append((operation.path, resolvedPath, snapshot))
            }
        } catch {
            // Rollback: restore all previously written files.
            let unrestored = rollbackWrittenFiles(writtenFiles)
            if !unrestored.isEmpty {
                lastWarning = "Apply failed and some files could not be restored: \(unrestored.joined(separator: ", ")). The workspace may be partially modified."
                let partial = RecoveryRecord(
                    changeSetID: journal.changeSetID,
                    proposalID: journal.proposalID,
                    userInstructions: journal.userInstructions,
                    modelID: journal.modelID,
                    workspacePath: journal.workspacePath,
                    appliedAt: journal.appliedAt,
                    fileSnapshots: journal.fileSnapshots,
                    createdFiles: journal.createdFiles,
                    modifiedFiles: journal.modifiedFiles,
                    fullyApplied: false,
                    unrestoredFiles: unrestored
                )
                try? recoveryStore.save(partial)
            } else {
                recoveryStore.delete(journal)
            }
            throw error
        }

        // Phase 3: All writes succeeded. Create the change set record.
        // Update snapshots with applied content hashes.
        var finalSnapshots = pendingSnapshots
        for i in 0..<finalSnapshots.count {
            if let hash = appliedHashes[finalSnapshots[i].path] {
                finalSnapshots[i] = FileSnapshot(
                    path: finalSnapshots[i].path,
                    contentHash: finalSnapshots[i].contentHash,
                    content: finalSnapshots[i].content,
                    existed: finalSnapshots[i].existed,
                    permissions: finalSnapshots[i].permissions,
                    encoding: finalSnapshots[i].encoding,
                    lineEnding: finalSnapshots[i].lineEnding,
                    hasTrailingNewline: finalSnapshots[i].hasTrailingNewline,
                    appliedContentHash: hash
                )
            }
        }

        let changeSet = AppliedChangeSet(
            id: proposal.id,
            proposalID: proposal.id,
            userInstructions: proposal.userInstructions,
            modelID: proposal.modelID,
            workspacePath: currentCanonical,
            fileSnapshots: finalSnapshots,
            createdFiles: proposal.operations.filter { $0.type == .create }.map { $0.path },
            modifiedFiles: proposal.operations.filter { $0.type == .modify }.map { $0.path }
        )

        // Update the proposal status.
        var updated = proposal
        updated.status = .applied
        currentProposal = updated

        // Add to history (bounded).
        changeHistory.append(changeSet)
        if changeHistory.count > maxHistorySize {
            changeHistory.removeFirst(changeHistory.count - maxHistorySize)
        }

        // Persist the recovery record.
        do {
            let record = RecoveryRecord(from: changeSet)
            try recoveryStore.save(record)
        } catch {
            lastWarning = "Changes were applied but the recovery record could not be saved: \(error.localizedDescription). Undo may not be available after restart."
        }

        // Do not hide recovery persistence warnings.
        pendingSnapshots = []

        return changeSet
    }

    // MARK: - Rollback (Undo)

    /// Undoes the most recent change set.
    ///
    /// Before restoring any file, verifies that the current file content
    /// matches the applied version (using SHA-256 hashes). If the file has
    /// been modified since the change was applied, the restore is refused
    /// to prevent overwriting subsequent user changes.
    ///
    /// For files created by AI Connector, the file is deleted only if its
    /// content still matches the version originally created.
    ///
    /// All files in the change set are validated before any restoration
    /// begins. If any file has a conflict, the entire undo is refused.
    ///
    /// - Returns: The `AppliedChangeSet` that was rolled back.
    /// - Throws: `CodeModificationError` if the rollback fails or encounters conflicts.
    func undoLastChange() throws -> AppliedChangeSet {
        guard !changeHistory.isEmpty else {
            throw CodeModificationError.incompleteProposal(reason: "No changes to undo")
        }

        let changeSet = changeHistory[changeHistory.count - 1]

        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            throw CodeModificationError.noWorkspace
        }

        let currentCanonical = workspaceURL.resolvingSymlinksInPath().path

        // Verify the workspace hasn't changed.
        guard URL(fileURLWithPath: changeSet.workspacePath).resolvingSymlinksInPath().path == currentCanonical else {
            throw CodeModificationError.workspaceChanged
        }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path

        guard workspaceService.startAccessing() else {
            throw CodeModificationError.workspaceNotAccessible
        }
        defer { workspaceService.stopAccessing() }

        // Phase 1: Validate ALL files before beginning any restoration.
        var conflicts: [String] = []

        for snapshot in changeSet.fileSnapshots {
            let resolvedPath = workspaceURL.appendingPathComponent(snapshot.path).resolvingSymlinksInPath().path

            guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
                conflicts.append(snapshot.path)
                continue
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory)

            guard snapshot.appliedContentHash != nil else {
                conflicts.append(snapshot.path)
                continue
            }

            if snapshot.existed {
                // The file existed before — verify it matches the applied version.
                guard exists, !isDirectory.boolValue else {
                    conflicts.append(snapshot.path)
                    continue
                }

                // Verify the current content matches the applied version.
                if let appliedHash = snapshot.appliedContentHash {
                    do {
                        let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
                        let currentHash = SafeFileWriter.sha256Hash(data)
                        guard currentHash == appliedHash else {
                            conflicts.append(snapshot.path)
                            continue
                        }
                    } catch {
                        conflicts.append(snapshot.path)
                        continue
                    }
                }
            } else {
                // The file was created — verify it still matches the created version.
                if exists {
                    guard !isDirectory.boolValue else {
                        conflicts.append(snapshot.path)
                        continue
                    }
                    if let appliedHash = snapshot.appliedContentHash {
                        do {
                            let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
                            let currentHash = SafeFileWriter.sha256Hash(data)
                            guard currentHash == appliedHash else {
                                conflicts.append(snapshot.path)
                                continue
                            }
                        } catch {
                            conflicts.append(snapshot.path)
                            continue
                        }
                    }
                }
            }
        }

        // Re-check path safety for undo as well as content hashes.
        for snapshot in changeSet.fileSnapshots {
            do {
                try validatePath(snapshot.path)
            } catch {
                conflicts.append(snapshot.path)
            }
        }

        // If any conflicts, refuse the entire undo.
        if !conflicts.isEmpty {
            throw CodeModificationError.undoConflicts(paths: conflicts)
        }

        // Phase 2: All files validated. Perform the restoration.
        var restored: [String] = []
        var failed: [String] = []

        for snapshot in changeSet.fileSnapshots {
            let resolvedPath = workspaceURL.appendingPathComponent(snapshot.path).resolvingSymlinksInPath().path

            do {
                if snapshot.existed {
                    // Restore the original content.
                    try safeFileWriter.replaceFile(
                        content: snapshot.content,
                        to: resolvedPath,
                        permissions: snapshot.permissions,
                        encoding: encodingFromSnapshot(snapshot),
                        lineEnding: snapshot.lineEnding,
                        hasTrailingNewline: snapshot.hasTrailingNewline
                    )
                } else {
                    // Delete the created file (only if content matches).
                    if let appliedHash = snapshot.appliedContentHash {
                        try safeFileWriter.deleteFileIfUnchanged(
                            path: resolvedPath,
                            expectedHash: appliedHash
                        )
                    } else {
                        throw CodeModificationError.rollbackConflict(path: snapshot.path)
                    }
                }
                restored.append(snapshot.path)
            } catch {
                failed.append(snapshot.path)
            }
        }

        // Phase 3: Handle the results.
        if !failed.isEmpty {
            // Some files could not be restored. Preserve the change set in history.
            lastWarning = "Undo partially completed. Could not restore: \(failed.joined(separator: ", ")). The workspace may be in an inconsistent state."
            throw CodeModificationError.undoPartialFailure(restored: restored, failed: failed)
        }

        // All files restored successfully. Remove from history.
        changeHistory.removeLast()

        // Delete the recovery record.
        let record = RecoveryRecord(from: changeSet)
        recoveryStore.delete(record)

        lastWarning = nil

        return changeSet
    }

    // MARK: - Reject / Discard

    /// Rejects the current proposal without applying any changes.
    func rejectProposal() {
        guard let proposal = currentProposal else { return }
        var updated = proposal
        updated.status = .rejected
        currentProposal = updated
        pendingSnapshots = []
    }

    /// Discards the current proposal.
    func discardProposal() {
        guard let proposal = currentProposal else { return }
        var updated = proposal
        updated.status = .discarded
        currentProposal = updated
        pendingSnapshots = []
    }

    /// Clears the current proposal and all state.
    func clear() {
        currentProposal = nil
        pendingSnapshots = []
        selectedFiles.removeAll()
        lastError = nil
        lastWarning = nil
        proposalWorkspaceIdentity = nil
    }

    // MARK: - Workspace Change Handling

    /// Invalidates the current proposal when the workspace changes.
    ///
    /// - Parameter newWorkspacePath: The new workspace path, or `nil` if cleared.
    func invalidateOnWorkspaceChange(newWorkspacePath: String? = nil) {
        // Invalidate any pending proposal.
        if let proposal = currentProposal, proposal.status == .pending {
            var updated = proposal
            updated.status = .discarded
            updated.errorMessage = "Workspace changed. Proposal invalidated."
            currentProposal = updated
        }

        pendingSnapshots = []
        selectedFiles.removeAll()
        proposalWorkspaceIdentity = nil

        // If the workspace was cleared, clear the change history for the old workspace.
        if newWorkspacePath == nil {
            // Keep the history in memory but it won't be usable without a workspace.
            // The recovery records remain on disk for when the workspace is re-selected.
        }
    }

    // MARK: - Private Helpers

    /// Converts a snapshot's encoding string to a `String.Encoding`.
    private func encodingFromSnapshot(
        _ snapshot: FileSnapshot
    ) -> String.Encoding {
        guard let encodingStr = snapshot.encoding else {
            return .utf8
        }

        if let rawValue = UInt(encodingStr) {
            return String.Encoding(rawValue: rawValue)
        }

        // Compatibility with older recovery snapshots.
        let lower = encodingStr.lowercased()

        if lower.contains("utf8") || lower.contains("utf-8") {
            return .utf8
        }
        if lower.contains("utf16") && lower.contains("little") {
            return .utf16LittleEndian
        }
        if lower.contains("utf16") && lower.contains("big") {
            return .utf16BigEndian
        }
        if lower.contains("latin") || lower.contains("iso") {
            return .isoLatin1
        }

        return .utf8
    }

    /// Rolls back files that were written during a failed apply operation.
    ///
    /// - Returns: An array of paths that could not be restored.
    private func rollbackWrittenFiles(
        _ writtenFiles: [(path: String, resolvedPath: String, snapshot: FileSnapshot)]
    ) -> [String] {
        var unrestored: [String] = []

        for file in writtenFiles.reversed() {
            do {
                if file.snapshot.existed {
                    // Restore the original content.
                    try safeFileWriter.replaceFile(
                        content: file.snapshot.content,
                        to: file.resolvedPath,
                        permissions: file.snapshot.permissions,
                        encoding: encodingFromSnapshot(file.snapshot),
                        lineEnding: file.snapshot.lineEnding,
                        hasTrailingNewline: file.snapshot.hasTrailingNewline
                    )
                } else {
                    // Delete the created file.
                    if fileManager.fileExists(atPath: file.resolvedPath) {
                        try fileManager.removeItem(atPath: file.resolvedPath)
                    }
                }
            } catch {
                NSLog("CodeModificationService: Failed to rollback \(file.path): \(error.localizedDescription)")
                unrestored.append(file.path)
            }
        }

        return unrestored
    }
}
