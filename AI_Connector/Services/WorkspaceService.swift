import Foundation
import AppKit
import Observation

// MARK: - Workspace Access State

/// The access state of the selected workspace directory.
enum WorkspaceAccessState: Equatable, Sendable {
    /// No workspace directory has been selected.
    case none
    /// The workspace directory is accessible.
    case accessible
    /// The workspace directory is not accessible (stale bookmark, moved,
    /// or permission revoked). The user must re-select it.
    case needsRenewal
}

// MARK: - Workspace Service

/// A service that manages the user-selected workspace directory.
///
/// The workspace directory is a configuration setting only. This service
/// does not enumerate, read, modify, or execute files in the directory.
/// Those capabilities will be implemented in later phases.
///
/// The service uses security-scoped bookmarks for persistent access, as
/// required by the macOS App Sandbox. The bookmark is stored in `UserDefaults`
/// so the selection is restored after application restart.
///
/// All methods are `@MainActor`-isolated because they interact with
/// `NSOpenPanel` and `URL` security-scoped access, which must be used from
/// the main thread.
@Observable
@MainActor
final class WorkspaceService {

    // MARK: - Published State

    /// The currently selected workspace directory, or `nil` if none.
    private(set) var selectedDirectory: URL?
    /// The access state of the selected directory.
    private(set) var accessState: WorkspaceAccessState = .none

    // MARK: - Private

    private let defaults: UserDefaults
    private let bookmarkKey = "workspace.bookmark"
    private let pathKey = "workspace.path"

    // MARK: - Init

    /// Creates a workspace service and restores the previously selected
    /// directory from a stored security-scoped bookmark.
    ///
    /// - Parameter defaults: The `UserDefaults` to use. Defaults to `.standard`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restoreFromBookmark()
    }

    // MARK: - Browse

    /// Presents the native macOS folder selection dialog and, if the user
    /// selects a directory, stores a security-scoped bookmark for it.
    ///
    /// Only directories can be selected. The user's selection is persisted
    /// so it can be restored after application restart.
    func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Workspace"
        panel.message = "Choose the workspace folder for this project."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return
        }

        selectDirectory(url)
    }

    // MARK: - Selection

    /// Selects the given directory as the workspace, creating and storing a
    /// security-scoped bookmark.
    ///
    /// - Parameter url: The directory URL to select.
    func selectDirectory(_ url: URL) {
        // Create a security-scoped bookmark for persistent access.
        do {
            let bookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmarkData, forKey: bookmarkKey)
        } catch {
            NSLog("WorkspaceService: Failed to create bookmark: \(error.localizedDescription)")
        }
        defaults.set(url.path, forKey: pathKey)

        // Start a security-scoped access session for the current launch.
        _ = url.startAccessingSecurityScopedResource()

        selectedDirectory = url
        accessState = .accessible
    }

    // MARK: - Restoration

    /// Attempts to restore the previously selected directory from the stored
    /// security-scoped bookmark.
    ///
    /// Handles stale or inaccessible bookmarks gracefully: if the bookmark
    /// cannot be resolved, the access state is set to `.needsRenewal` so the
    /// UI can prompt the user to re-select the directory.
    private func restoreFromBookmark() {
        guard let bookmarkData = defaults.data(forKey: bookmarkKey) else {
            // No stored bookmark — check for a stored path as a fallback.
            if let path = defaults.string(forKey: pathKey) {
                let url = URL(fileURLWithPath: path)
                selectedDirectory = url
                accessState = .needsRenewal
            }
            return
        }

        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )

            if stale {
                // The bookmark is stale — the resource may have moved or
                // been renamed. Try to start a security-scoped access
                // session; if it fails, the bookmark is unusable.
                if url.startAccessingSecurityScopedResource() {
                    url.stopAccessingSecurityScopedResource()
                    // The resource is still accessible; the bookmark just
                    // needs to be refreshed.
                    selectedDirectory = url
                    accessState = .accessible
                    refreshBookmark(for: url)
                } else {
                    // Cannot access the resource — prompt for re-selection.
                    selectedDirectory = url
                    accessState = .needsRenewal
                }
            } else {
                // The bookmark is valid.
                if url.startAccessingSecurityScopedResource() {
                    selectedDirectory = url
                    accessState = .accessible
                } else {
                    // The resource exists but access was denied.
                    selectedDirectory = url
                    accessState = .needsRenewal
                }
            }
        } catch {
            // The bookmark could not be resolved (e.g. the resource was
            // deleted or the volume was unmounted).
            if let path = defaults.string(forKey: pathKey) {
                let url = URL(fileURLWithPath: path)
                selectedDirectory = url
            }
            accessState = .needsRenewal
            NSLog("WorkspaceService: Failed to resolve bookmark: \(error.localizedDescription)")
        }
    }

    /// Refreshes the security-scoped bookmark for the given directory.
    ///
    /// This is called when a stale bookmark is successfully resolved, to
    /// update the stored bookmark to a fresh one.
    private func refreshBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: bookmarkKey)
        } catch {
            NSLog("WorkspaceService: Failed to refresh bookmark: \(error.localizedDescription)")
        }
    }

    // MARK: - Access Management

    /// Starts a security-scoped access session for the selected directory.
    ///
    /// Call this before performing any file operations on the workspace
    /// directory (in later phases). The caller must call
    /// `stopAccessingSecurityScopedResource()` when done.
    ///
    /// - Returns: `true` if access was successfully started.
    @discardableResult
    func startAccessing() -> Bool {
        guard let url = selectedDirectory else { return false }
        return url.startAccessingSecurityScopedResource()
    }

    /// Stops the security-scoped access session for the selected directory.
    func stopAccessing() {
        selectedDirectory?.stopAccessingSecurityScopedResource()
    }

    // MARK: - Clear

    /// Clears the selected workspace and removes the stored bookmark.
    func clear() {
        stopAccessing()
        selectedDirectory = nil
        accessState = .none
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: pathKey)
    }
}
