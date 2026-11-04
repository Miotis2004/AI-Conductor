import Foundation
import Crypto
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
///    sensitive files, and workspace boundaries.
/// 4. **Diff generation** — computes line-by-line diffs between the current
///    file content and the proposed content.
/// 5. **Conflict detection** — records SHA-256 hashes of files at proposal
///    time and verifies them before applying.
/// 6. **Safe filesystem operations** — writes files atomically within the
///    authorized workspace, preserving permissions.
/// 7. **Backup and rollback** — preserves original file content and supports
///    undo of the most recent change set.
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

    // MARK: - Configuration

    /// The maximum number of files that can be modified in a single proposal.
    let maxFilesPerProposal: Int = 5

    /// The maximum number of change sets to keep in history.
    let maxHistorySize: Int = 20

    /// The maximum file size (in bytes) that can be modified.
    var maxFileSize: Int64 = 1_048_576 // 1 MB

    // MARK: - Private

    private let workspaceService: WorkspaceService
    private let explorerService: WorkspaceExplorerService
    private let fileManager: FileManager
    private let backupDirectory: URL

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

        // Backups are stored in the app's private container, not in the user's
        // source directories. This keeps the user's workspace clean.
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = appSupport.appendingPathComponent("AI_Connector", isDirectory: true)
        self.backupDirectory = appDir.appendingPathComponent("Backups", isDirectory: true)

        // Ensure the backup directory exists.
        try? fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
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

        guard !fileContents.isEmpty else {
            throw CodeModificationError.incompleteProposal(reason: "No files selected")
        }

        guard fileContents.count <= maxFilesPerProposal else {
            throw CodeModificationError.tooManyFiles(count: fileContents.count, limit: maxFilesPerProposal)
        }

        var parts: [String] = []

        // System instruction for the model.
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

        """)

        // File contents.
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
        var seenPaths = Set<String>()

        for opJSON in decoded.operations {
            // Validate operation type.
            guard let opType = CodeModificationOperation.OperationType(rawValue: opJSON.type) else {
                throw CodeModificationError.unsupportedOperation(type: opJSON.type)
            }

            // Validate path.
            let path = opJSON.path
            try validatePath(path)

            // Check for duplicates.
            guard !seenPaths.contains(path) else {
                throw CodeModificationError.duplicatePath(path: path)
            }
            seenPaths.insert(path)

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

        // Create the proposal.
        let proposal = CodeModificationProposal(
            userInstructions: userInstructions,
            modelID: modelID,
            workspacePath: workspacePath,
            operations: operations
        )

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

            // Reject symbolic links.
            let values = try? fileManager.attributesOfItem(atPath: resolvedPath)
            if let type = values?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw CodeModificationError.symbolicLink(path: path)
            }
        }
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
        // dp[i][j] = length of LCS of oldLines[0..<i] and newLines[0..<j]
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
                // Fallback: should not reach here, but handle gracefully.
                break
            }
        }

        // Reverse to get the correct order.
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

            if fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    throw CodeModificationError.isDirectory(path: operation.path)
                }

                // Check for symbolic links.
                let values = try? fileManager.attributesOfItem(atPath: resolvedPath)
                if let type = values?[.type] as? FileAttributeType, type == .typeSymbolicLink {
                    throw CodeModificationError.symbolicLink(path: operation.path)
                }

                fileExists = true

                // Check size limit.
                let attributes = try? fileManager.attributesOfItem(atPath: resolvedPath)
                let fileSize = Int64(attributes?[.size] as? Int ?? 0)
                if fileSize > maxFileSize {
                    throw CodeModificationError.invalidProposal(
                        reason: "File exceeds size limit: \(operation.path)"
                    )
                }

                // Read the content.
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
                    let (isBinary, encoding) = FileInspectorService.detectEncoding(data: data)
                    if isBinary {
                        throw CodeModificationError.unsupportedFileType(path: operation.path)
                    }
                    currentContent = String(data: data, encoding: encoding ?? .utf8)
                        ?? String(decoding: data, as: UTF8.self)
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
            let contentHash = currentContent.map { sha256Hash($0) } ?? ""
            let permissions: Int?
            if fileExists, let attrs = try? fileManager.attributesOfItem(atPath: resolvedPath) {
                permissions = (attrs[.posixPermissions] as? Int)
            } else {
                permissions = nil
            }

            snapshots.append(
                FileSnapshot(
                    path: operation.path,
                    contentHash: contentHash,
                    content: currentContent ?? "",
                    existed: fileExists,
                    permissions: permissions
                )
            )
        }

        // Update the proposal with diffs.
        var finalized = proposal
        finalized.diffs = diffs
        finalized.status = .pending
        finalized.errorMessage = nil

        // Store snapshots in the proposal (via a side channel — we'll use
        // the change history when applying).
        // For now, we keep the snapshots in a temporary storage.
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
                    let currentHash = sha256Hash(String(data: data, encoding: .utf8) ?? "")
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
    /// This is a staged transaction: all files are written, and if any write
    /// fails, the previously written files are rolled back.
    ///
    /// - Parameter proposal: The proposal to apply.
    /// - Returns: The `AppliedChangeSet` record.
    /// - Throws: `CodeModificationError` if the application fails.
    func applyProposal(_ proposal: CodeModificationProposal) throws -> AppliedChangeSet {
        guard proposal.isValid else {
            throw CodeModificationError.incompleteProposal(reason: "Proposal is not valid")
        }

        // Verify no conflicts.
        try verifyNoConflicts(proposal)

        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            throw CodeModificationError.noWorkspace
        }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path

        guard workspaceService.startAccessing() else {
            throw CodeModificationError.workspaceNotAccessible
        }
        defer { workspaceService.stopAccessing() }

        // Phase 1: Write all files.
        // Track what was written so we can roll back on failure.
        var writtenFiles: [(path: String, resolvedPath: String, snapshot: FileSnapshot)] = []

        do {
            for (index, operation) in proposal.operations.enumerated() {
                let resolvedPath = workspaceURL.appendingPathComponent(operation.path).resolvingSymlinksInPath().path

                // Re-validate the path.
                guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
                    throw CodeModificationError.outsideWorkspace(path: operation.path)
                }

                // Ensure the parent directory exists.
                let parentDir = (resolvedPath as NSString).deletingLastPathComponent
                if !fileManager.fileExists(atPath: parentDir) {
                    try fileManager.createDirectory(
                        atPath: parentDir,
                        withIntermediateDirectories: true,
                        attributes: nil
                    )
                }

                // Write the file atomically.
                try writeFileAtomically(
                    content: operation.content,
                    to: resolvedPath,
                    permissions: pendingSnapshots[index].permissions
                )

                writtenFiles.append((operation.path, resolvedPath, pendingSnapshots[index]))
            }
        } catch {
            // Rollback: restore all previously written files.
            rollbackWrittenFiles(writtenFiles)
            throw error
        }

        // Phase 2: All writes succeeded. Create the change set record.
        let changeSet = AppliedChangeSet(
            proposalID: proposal.id,
            userInstructions: proposal.userInstructions,
            modelID: proposal.modelID,
            workspacePath: workspaceURL.path,
            fileSnapshots: pendingSnapshots,
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

        // Clear pending snapshots.
        pendingSnapshots = []

        return changeSet
    }

    // MARK: - Rollback

    /// Undoes the most recent change set.
    ///
    /// Restores all files to their pre-change state. For created files,
    /// the file is deleted. For modified files, the original content is
    /// restored.
    ///
    /// - Returns: The `AppliedChangeSet` that was rolled back.
    /// - Throws: `CodeModificationError` if the rollback fails.
    func undoLastChange() throws -> AppliedChangeSet {
        guard !changeHistory.isEmpty else {
            throw CodeModificationError.incompleteProposal(reason: "No changes to undo")
        }

        let changeSet = changeHistory[changeHistory.count - 1]

        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            throw CodeModificationError.noWorkspace
        }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path

        guard workspaceService.startAccessing() else {
            throw CodeModificationError.workspaceNotAccessible
        }
        defer { workspaceService.stopAccessing() }

        // Verify the workspace hasn't changed.
        guard workspaceURL.path == changeSet.workspacePath else {
            throw CodeModificationError.workspaceChanged
        }

        // Rollback each file.
        for snapshot in changeSet.fileSnapshots {
            let resolvedPath = workspaceURL.appendingPathComponent(snapshot.path).resolvingSymlinksInPath().path

            // Re-validate the path.
            guard explorerService.isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
                throw CodeModificationError.outsideWorkspace(path: snapshot.path)
            }

            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: resolvedPath, isDirectory: &isDirectory)

            if snapshot.existed {
                // The file existed before — restore its content.
                guard exists, !isDirectory.boolValue else {
                    throw CodeModificationError.rollbackConflict(path: snapshot.path)
                }

                // Verify the current content matches what we expect (the modified version).
                // We don't have the modified content stored, so we just restore.
                do {
                    try writeFileAtomically(
                        content: snapshot.content,
                        to: resolvedPath,
                        permissions: snapshot.permissions
                    )
                } catch {
                    throw CodeModificationError.restoreFailed(path: snapshot.path, underlying: error)
                }
            } else {
                // The file was created — delete it.
                if exists {
                    do {
                        try fileManager.removeItem(atPath: resolvedPath)
                    } catch {
                        throw CodeModificationError.restoreFailed(path: snapshot.path, underlying: error)
                    }
                }
            }
        }

        // Remove from history.
        changeHistory.removeLast()

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
    }

    // MARK: - Workspace Change Handling

    /// Invalidates the current proposal when the workspace changes.
    func invalidateOnWorkspaceChange() {
        if let proposal = currentProposal, proposal.status == .pending {
            var updated = proposal
            updated.status = .discarded
            updated.errorMessage = "Workspace changed. Proposal invalidated."
            currentProposal = updated
        }
        pendingSnapshots = []
        selectedFiles.removeAll()
    }

    // MARK: - Private Helpers

    /// Pending file snapshots, stored between finalization and application.
    private var pendingSnapshots: [FileSnapshot] = []

    /// Writes a file atomically using a temporary file and rename.
    ///
    /// - Parameters:
    ///   - content: The content to write.
    ///   - to: The destination path.
    ///   - permissions: The POSIX permissions to apply, if any.
    /// - Throws: `CodeModificationError.writeFailed` if the write fails.
    private func writeFileAtomically(
        content: String,
        to path: String,
        permissions: Int?
    ) throws {
        let destinationURL = URL(fileURLWithPath: path)
        let tempURL = destinationURL.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")

        do {
            // Write to the temporary file.
            let data = Data(content.utf8)
            try data.write(to: tempURL, options: .atomic)

            // Apply permissions if specified.
            if let perms = permissions {
                try fileManager.setAttributes(
                    [.posixPermissions: perms],
                    ofItemAtPath: tempURL.path
                )
            }

            // Atomically replace the destination.
            if fileManager.fileExists(atPath: path) {
                try fileManager.removeItem(atPath: path)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            // Clean up the temp file on failure.
            try? fileManager.removeItem(at: tempURL)
            throw CodeModificationError.writeFailed(path: path, underlying: error)
        }
    }

    /// Rolls back files that were written during a failed apply operation.
    private func rollbackWrittenFiles(
        _ writtenFiles: [(path: String, resolvedPath: String, snapshot: FileSnapshot)]
    ) {
        for file in writtenFiles.reversed() {
            do {
                if file.snapshot.existed {
                    // Restore the original content.
                    try writeFileAtomically(
                        content: file.snapshot.content,
                        to: file.resolvedPath,
                        permissions: file.snapshot.permissions
                    )
                } else {
                    // Delete the created file.
                    if fileManager.fileExists(atPath: file.resolvedPath) {
                        try fileManager.removeItem(atPath: file.resolvedPath)
                    }
                }
            } catch {
                NSLog("CodeModificationService: Failed to rollback \(file.path): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - SHA-256 Hashing

    /// Computes the SHA-256 hash of a string.
    ///
    /// - Parameter string: The string to hash.
    /// - Returns: The hex-encoded SHA-256 hash.
    func sha256Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}
