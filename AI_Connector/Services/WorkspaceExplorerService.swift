import Foundation
import Observation

// MARK: - Workspace Entry

/// A single entry in the workspace directory tree.
struct WorkspaceEntry: Identifiable, Hashable, Sendable {
    /// A unique identifier for this entry (its resolved path).
    let id: String
    /// The name of the file or directory.
    let name: String
    /// Whether this entry is a directory.
    let isDirectory: Bool
    /// The resolved (canonical) path of this entry.
    let resolvedPath: String
    /// The path relative to the workspace root.
    let relativePath: String
    /// The size of the file in bytes (0 for directories).
    let size: Int64
    /// Whether this entry is currently expanded (directories only).
    var isExpanded: Bool
    /// The child entries (directories only, lazily populated).
    var children: [WorkspaceEntry]?

    init(
        name: String,
        isDirectory: Bool,
        resolvedPath: String,
        relativePath: String,
        size: Int64 = 0,
        isExpanded: Bool = false,
        children: [WorkspaceEntry]? = nil
    ) {
        self.id = resolvedPath
        self.name = name
        self.isDirectory = isDirectory
        self.resolvedPath = resolvedPath
        self.relativePath = relativePath
        self.size = size
        self.isExpanded = isExpanded
        self.children = children
    }
}

// MARK: - Workspace Explorer Errors

/// Errors that can occur during workspace enumeration.
enum WorkspaceExplorerError: LocalizedError {
    /// The workspace directory is not accessible.
    case workspaceNotAccessible
    /// The directory could not be enumerated.
    case enumerationFailed(underlying: Error)
    /// The path is outside the authorized workspace.
    case outsideWorkspace(path: String)
    /// The path is a symbolic link that resolves outside the workspace.
    case symlinkEscape(path: String)
    /// The file or directory does not exist.
    case notFound(path: String)

    var errorDescription: String? {
        switch self {
        case .workspaceNotAccessible:
            return "The workspace directory is not accessible."
        case .enumerationFailed(let underlying):
            return "Failed to enumerate directory: \(underlying.localizedDescription)"
        case .outsideWorkspace(let path):
            return "Path is outside the workspace: \(path)"
        case .symlinkEscape(let path):
            return "Symbolic link resolves outside the workspace: \(path)"
        case .notFound(let path):
            return "File or directory not found: \(path)"
        }
    }
}

// MARK: - Workspace Explorer Service

/// A service that enumerates the workspace directory tree lazily.
///
/// This service is read-only: it never creates, modifies, or deletes files.
/// It enforces workspace boundaries using resolved (canonical) filesystem
/// paths, not simple string-prefix comparisons, to prevent symbolic link
/// escapes and path traversal.
///
/// The service is `@MainActor`-isolated to match the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` setting.
@Observable
@MainActor
final class WorkspaceExplorerService {

    // MARK: - Published State

    /// The top-level entries in the workspace root.
    private(set) var rootEntries: [WorkspaceEntry] = []
    /// Whether the workspace is currently being enumerated.
    private(set) var isEnumerating: Bool = false
    /// The last enumeration error, if any.
    private(set) var lastError: String?

    // MARK: - Configuration

    /// Directory names that are excluded from enumeration by default.
    static let excludedDirectoryNames: Set<String> = [
        ".git", ".build", "DerivedData", "node_modules",
        "dist", "build", ".cache", ".gradle", ".mypy_cache",
        ".pytest_cache", ".tox", ".venv", "venv", "__pycache__",
        ".idea", ".vscode", ".DS_Store", "Pods", ".swiftpm",
        ".next", ".nuxt", ".svelte-kit", "target", ".cargo",
    ]

    /// File extensions that are considered source/text files for display.
    static let includedFileExtensions: Set<String> = [
        // Source code
        "swift", "c", "h", "m", "mm", "cpp", "hpp", "cc", "cxx",
        "java", "kt", "kts", "go", "rs", "py", "rb", "js", "jsx",
        "ts", "tsx", "vue", "svelte", "php", "cs", "fs", "fsx",
        "scala", "clj", "ex", "exs", "erl", "hs", "elm", "lua",
        "pl", "r", "jl", "dart", "zig", "nim", "cr", "groovy",
        "v", "sv", "vhd", "asm", "s", "S",
        // Markup / config
        "html", "htm", "css", "scss", "sass", "less", "xml", "yml",
        "yaml", "json", "toml", "ini", "cfg", "conf", "properties",
        "env", "sh", "bash", "zsh", "fish", "ps1", "bat", "cmd",
        // Documentation
        "md", "markdown", "rst", "txt", "adoc", "org",
        // Data
        "csv", "tsv", "sql", "graphql", "gql", "proto", "thrift",
        "avsc", "avdl", "avpr",
        // Build / project
        "xcodeproj", "xcworkspace", "pbxproj", "plist", "entitlements",
        "gradle", "cmake", "make", "mk", "podspec", "gemspec",
        "cabal", "hpack", "mel", "pp", "ppm",
        // Web
        "wasm", "wat", "glsl", "vert", "frag", "comp", "tesc", "tese",
        // Misc text
        "log", "diff", "patch", "lock", "sum", "mod",
    ]

    /// Sensitive file names that should never be attached to prompts.
    static let sensitiveFileNames: Set<String> = [
        ".env", ".env.local", ".env.development", ".env.production",
        "id_rsa", "id_rsa.pub", "id_dsa", "id_dsa.pub",
        "id_ecdsa", "id_ecdsa.pub", "id_ed25519", "id_ed25519.pub",
        "credentials", "credentials.json", "secrets", "secrets.json",
        "secrets.yml", "secrets.yaml", "token", "token.json",
        "api_key", "api_key.txt", "apikey", "apikey.txt",
        "keychain", "keychain.json", "keychain.plist",
        "private.pem", "private.key", "cert.pem", "cert.key",
        "keystore", "truststore", "p12", "pfx",
        "npmrc", "netrc", "git-credentials", "htpasswd",
    ]

    /// Sensitive file extensions that should never be attached to prompts.
    static let sensitiveFileExtensions: Set<String> = [
        "pem", "key", "p12", "pfx", "keystore", "truststore",
    ]

    // MARK: - Private

    private let workspaceService: WorkspaceService
    private let fileManager: FileManager

    // MARK: - Init

    /// Creates a workspace explorer service.
    ///
    /// - Parameters:
    ///   - workspaceService: The workspace service that manages the selected directory.
    ///   - fileManager: The file manager to use. Defaults to `.default`.
    init(
        workspaceService: WorkspaceService,
        fileManager: FileManager = .default
    ) {
        self.workspaceService = workspaceService
        self.fileManager = fileManager
    }

    // MARK: - Refresh

    /// Refreshes the workspace root entries.
    ///
    /// This re-enumerates the top-level directory contents. Previously
    /// expanded subdirectories are re-enumerated as well.
    func refresh() {
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            rootEntries = []
            lastError = "No workspace selected or access expired."
            return
        }

        isEnumerating = true
        lastError = nil
        defer { isEnumerating = false }

        // Ensure security-scoped access is active.
        guard workspaceService.startAccessing() else {
            lastError = "Cannot access workspace. Please re-select the folder."
            rootEntries = []
            return
        }
        defer { workspaceService.stopAccessing() }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path
        let entries = enumerateDirectory(at: workspaceURL, resolvedRoot: resolvedRoot, relativePath: "")
        rootEntries = entries
    }

    // MARK: - Expand / Collapse

    /// Expands a directory entry, enumerating its children lazily.
    ///
    /// - Parameter entryID: The identifier (resolved path) of the directory to expand.
    func expand(entryID: String) {
        guard let workspaceURL = workspaceService.selectedDirectory,
              workspaceService.accessState == .accessible else {
            return
        }

        // Ensure security-scoped access is active.
        guard workspaceService.startAccessing() else {
            lastError = "Cannot access workspace. Please re-select the folder."
            return
        }
        defer { workspaceService.stopAccessing() }

        let resolvedRoot = workspaceURL.resolvingSymlinksInPath().path
        let directoryURL = URL(fileURLWithPath: entryID)

        // Validate the path is within the workspace.
        guard isWithinWorkspace(entryID, resolvedRoot: resolvedRoot) else {
            lastError = "Path is outside the workspace."
            return
        }

        // Check if it's a directory.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: entryID, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        // Enumerate children.
        let children = enumerateDirectory(at: directoryURL, resolvedRoot: resolvedRoot, relativePath: relativePath(for: entryID, root: resolvedRoot))

        // Update the entry in the tree.
        updateEntry(entryID: entryID, in: &rootEntries) { entry in
            entry.isExpanded = true
            entry.children = children
        }
    }

    /// Collapses a directory entry, removing its children from memory.
    ///
    /// - Parameter entryID: The identifier (resolved path) of the directory to collapse.
    func collapse(entryID: String) {
        updateEntry(entryID: entryID, in: &rootEntries) { entry in
            entry.isExpanded = false
            entry.children = nil
        }
    }

    // MARK: - Directory Enumeration

    /// Enumerates the contents of a directory, applying filtering rules.
    ///
    /// - Parameters:
    ///   - directoryURL: The directory to enumerate.
    ///   - resolvedRoot: The resolved (canonical) path of the workspace root.
    ///   - relativePath: The path of the directory relative to the workspace root.
    /// - Returns: An array of `WorkspaceEntry` values, sorted with directories first.
    private func enumerateDirectory(
        at directoryURL: URL,
        resolvedRoot: String,
        relativePath: String
    ) -> [WorkspaceEntry] {
        let directoryPath = directoryURL.path

        // Validate the directory is within the workspace.
        guard isWithinWorkspace(directoryPath, resolvedRoot: resolvedRoot) else {
            return []
        }

        // Check if the directory is accessible.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return []
        }

        // Get the directory contents.
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            // The directory may be inaccessible (permissions, disconnected drive, etc.).
            NSLog("WorkspaceExplorer: Failed to enumerate \(directoryPath): \(error.localizedDescription)")
            return []
        }

        var entries: [WorkspaceEntry] = []

        for url in contents {
            let name = url.lastPathComponent

            // Skip excluded directories.
            if Self.excludedDirectoryNames.contains(name) {
                continue
            }

            // Get resource values.
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey])
            let isDir = values?.isDirectory ?? false
            let size = Int64(values?.totalFileAllocatedSize ?? 0)

            // Resolve the path (follows symlinks).
            let resolvedPath = url.resolvingSymlinksInPath().path

            // Enforce workspace boundary using resolved paths.
            guard isWithinWorkspace(resolvedPath, resolvedRoot: resolvedRoot) else {
                // This is a symlink that escapes the workspace — skip it.
                continue
            }

            // For files, check if the extension is included.
            if !isDir {
                let ext = url.pathExtension.lowercased()
                // Include files with known extensions, or files with no extension
                // (e.g. Makefile, Dockerfile, LICENSE).
                if !Self.includedFileExtensions.contains(ext) && !ext.isEmpty {
                    continue
                }
            }

            let entryRelativePath: String
            if relativePath.isEmpty {
                entryRelativePath = name
            } else {
                entryRelativePath = "\(relativePath)/\(name)"
            }

            let entry = WorkspaceEntry(
                name: name,
                isDirectory: isDir,
                resolvedPath: resolvedPath,
                relativePath: entryRelativePath,
                size: isDir ? 0 : size,
                isExpanded: false,
                children: nil
            )
            entries.append(entry)
        }

        // Sort: directories first, then alphabetically (case-insensitive).
        entries.sort { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory {
                return lhs.isDirectory && !rhs.isDirectory
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        return entries
    }

    // MARK: - Path Validation

    /// Determines whether a resolved path is within the workspace root.
    ///
    /// Uses resolved (canonical) filesystem paths, not simple string-prefix
    /// comparisons, to prevent symbolic link escapes and path traversal.
    ///
    /// - Parameters:
    ///   - path: The resolved path to check.
    ///   - resolvedRoot: The resolved (canonical) path of the workspace root.
    /// - Returns: `true` if the path is within the workspace root.
    func isWithinWorkspace(_ path: String, resolvedRoot: String) -> Bool {
        // Both paths are already resolved (canonical), so we can safely
        // compare them. The resolved root should end with a separator or
        // be an exact match.
        let normalizedRoot = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"

        // Exact match (the root itself).
        if path == resolvedRoot {
            return true
        }

        // The path must start with the normalized root.
        guard path.hasPrefix(normalizedRoot) else {
            return false
        }

        // Additional safety: ensure the path doesn't contain ".." components
        // that could indicate traversal (even though resolved paths shouldn't
        // contain these, this is a defense-in-depth check).
        let components = path.split(separator: "/")
        if components.contains("..") {
            return false
        }

        return true
    }

    /// Computes the relative path of a resolved path with respect to the workspace root.
    private func relativePath(for resolvedPath: String, root: String) -> String {
        let normalizedRoot = root.hasSuffix("/") ? root : root + "/"
        guard resolvedPath.hasPrefix(normalizedRoot) else {
            return resolvedPath
        }
        return String(resolvedPath.dropFirst(normalizedRoot.count))
    }

    // MARK: - Tree Update Helpers

    /// Recursively updates an entry in the tree by its identifier.
    private func updateEntry(
        entryID: String,
        in entries: inout [WorkspaceEntry],
        _ update: (inout WorkspaceEntry) -> Void
    ) {
        for index in entries.indices {
            if entries[index].id == entryID {
                update(&entries[index])
                return
            }
            if let children = entries[index].children {
                var updatedChildren = children
                updateEntry(entryID: entryID, in: &updatedChildren, update)
                entries[index].children = updatedChildren
                // Check if we found it in the children.
                if updatedChildren != children {
                    return
                }
            }
        }
    }

    // MARK: - Sensitive File Check

    /// Determines whether a file is sensitive and should not be attached to prompts.
    ///
    /// - Parameter relativePath: The path of the file relative to the workspace root.
    /// - Returns: `true` if the file is sensitive.
    func isSensitiveFile(_ relativePath: String) -> Bool {
        let name = (relativePath as NSString).lastPathComponent
        if Self.sensitiveFileNames.contains(name.lowercased()) {
            return true
        }
        let ext = (relativePath as NSString).pathExtension.lowercased()
        if Self.sensitiveFileExtensions.contains(ext) {
            return true
        }
        // Also check for files with "secret" or "credential" in the name.
        let lowerName = name.lowercased()
        if lowerName.contains("secret") || lowerName.contains("credential") || lowerName.contains("private_key") {
            return true
        }
        return false
    }
}
