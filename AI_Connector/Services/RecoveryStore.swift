import Foundation
import Observation

// MARK: - Recovery Store

/// A service that manages persistent recovery records for applied change sets.
///
/// Recovery records are stored in the application's private Application Support
/// directory, never inside the user's project directories. Each record is a
/// JSON file containing the original file contents, applied-content hashes,
/// affected paths, workspace identity, and change-set metadata.
///
/// The store maintains a bounded history of the most recent 20 applied change
/// sets. Records are written atomically (write to temp file, then rename) to
/// protect against partially completed writes.
///
/// API credentials are never included in recovery records.
///
/// The service is `@MainActor`-isolated to match the project's
/// `SWIFT_DEFAULT_ACTOR_ISOLATION` setting.
@Observable
@MainActor
final class RecoveryStore {

    // MARK: - Published State

    /// The most recent recovery error, if any.
    private(set) var lastError: String?

    // MARK: - Configuration

    /// The maximum number of recovery records to retain.
    let maxRecordCount: Int = 20

    // MARK: - Private

    private let fileManager: FileManager
    /// The directory where recovery records are stored.
    let recordsDirectory: URL

    // MARK: - Init

    /// Creates a recovery store.
    ///
    /// - Parameter fileManager: The file manager to use. Defaults to `.default`.
    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let appDir = appSupport.appendingPathComponent("AI_Connector", isDirectory: true)
        self.recordsDirectory = appDir.appendingPathComponent("Recovery", isDirectory: true)

        // Ensure the records directory exists.
        try? fileManager.createDirectory(at: recordsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Load History

    /// Loads all recovery records from disk, sorted by `appliedAt` (oldest first).
    ///
    /// Corrupted or incomplete records are reported via `lastError` but do not
    /// prevent loading of other valid records.
    ///
    /// - Returns: An array of `RecoveryRecord` values, oldest first.
    func loadAll() -> [RecoveryRecord] {
        lastError = nil

        guard fileManager.fileExists(atPath: recordsDirectory.path) else {
            return []
        }

        let fileURLs: [URL]
        do {
            fileURLs = try fileManager.contentsOfDirectory(
                at: recordsDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            lastError = "Failed to read recovery directory: \(error.localizedDescription)"
            return []
        }

        var records: [RecoveryRecord] = []

        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: fileURL)
                let record = try JSONDecoder().decode(RecoveryRecord.self, from: data)

                // Validate the format version.
                guard record.formatVersion == RecoveryRecord.currentFormatVersion else {
                    lastError = "Recovery record \(fileURL.lastPathComponent) has unsupported format version \(record.formatVersion)."
                    continue
                }

                // Validate that the record is complete.
                guard !record.fileSnapshots.isEmpty else {
                    lastError = "Recovery record \(fileURL.lastPathComponent) is incomplete (no file snapshots)."
                    continue
                }

                records.append(record)
            } catch {
                lastError = "Recovery record \(fileURL.lastPathComponent) is corrupted: \(error.localizedDescription)"
                // Do not delete the corrupted file; report it and skip.
                continue
            }
        }

        // Sort by appliedAt (oldest first).
        records.sort { $0.appliedAt < $1.appliedAt }

        // Enforce the bounded history.
        if records.count > maxRecordCount {
            let toRemove = records.prefix(records.count - maxRecordCount)
            for record in toRemove {
                let fileURL = recordFileURL(for: record)
                try? fileManager.removeItem(at: fileURL)
            }
            records = Array(records.suffix(maxRecordCount))
        }

        return records
    }

    /// Loads recovery records for a specific workspace.
    ///
    /// - Parameter workspacePath: The canonical path of the workspace.
    /// - Returns: An array of `RecoveryRecord` values for the workspace, oldest first.
    func load(forWorkspace workspacePath: String) -> [RecoveryRecord] {
        let all = loadAll()
        let canonical = URL(fileURLWithPath: workspacePath).resolvingSymlinksInPath().path
        return all.filter {
            URL(fileURLWithPath: $0.workspacePath).resolvingSymlinksInPath().path == canonical
        }
    }

    // MARK: - Save

    /// Saves a recovery record to disk atomically.
    ///
    /// The record is written to a temporary file first, then renamed to its
    /// final location. This protects against partially completed writes.
    ///
    /// - Parameter record: The recovery record to save.
    /// - Throws: `CodeModificationError` if the save fails.
    func save(_ record: RecoveryRecord) throws {
        let fileURL = recordFileURL(for: record)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw CodeModificationError.backupFailed(
                path: recordFileURL(for: record).lastPathComponent,
                underlying: error
            )
        }

        // Write atomically: temp file, then rename.
        let tempURL = fileURL.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        do {
            try data.write(to: tempURL, options: .atomic)
            try fileManager.moveItem(at: tempURL, to: fileURL)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw CodeModificationError.backupFailed(
                path: fileURL.lastPathComponent,
                underlying: error
            )
        }

        // Enforce the bounded history: remove oldest records beyond the limit.
        enforceHistoryLimit()
    }

    // MARK: - Delete

    /// Deletes a recovery record from disk.
    ///
    /// - Parameter record: The recovery record to delete.
    func delete(_ record: RecoveryRecord) {
        let fileURL = recordFileURL(for: record)
        try? fileManager.removeItem(at: fileURL)
    }

    /// Deletes all recovery records for a specific workspace.
    ///
    /// - Parameter workspacePath: The canonical path of the workspace.
    func deleteAll(forWorkspace workspacePath: String) {
        let records = load(forWorkspace: workspacePath)
        for record in records {
            delete(record)
        }
    }

    // MARK: - Private Helpers

    /// Computes the file URL for a recovery record.
    private func recordFileURL(for record: RecoveryRecord) -> URL {
        recordsDirectory.appendingPathComponent("\(record.changeSetID.uuidString).json")
    }

    /// Enforces the bounded history by removing the oldest records beyond the limit.
    private func enforceHistoryLimit() {
        let all = loadAll()
        guard all.count > maxRecordCount else { return }
        let toRemove = all.prefix(all.count - maxRecordCount)
        for record in toRemove {
            delete(record)
        }
    }
}
