import SwiftUI

/// A sidebar view for exploring the workspace directory tree.
///
/// Displays the workspace directory tree with expandable/collapsible folders.
/// Supports refresh, file selection for inspection, and attaching files to prompts.
struct WorkspaceExplorerView: View {
    @Bindable var viewModel: ChatViewModel
    @State private var selectedEntryID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("Workspace")
                    .font(.headline)
                Spacer()

                if viewModel.explorerService.isEnumerating {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    viewModel.refreshExplorer()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Refresh workspace")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Error display
            if let error = viewModel.explorerService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }

            // Directory tree
            ScrollView {
                if viewModel.workspaceService.selectedDirectory == nil {
                    Text("No workspace selected")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else if viewModel.explorerService.rootEntries.isEmpty {
                    Text("Empty directory")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.explorerService.rootEntries) { entry in
                            entryRow(entry: entry, depth: 0)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 180)
    }

    // MARK: - Entry Row

    private func entryRow(entry: WorkspaceEntry, depth: Int) -> AnyView {
        let row = HStack(spacing: 4) {
            // Indentation
            Color.clear
                .frame(width: CGFloat(depth) * 16, height: 1)

            // Expand/collapse button for directories
            if entry.isDirectory {
                Button {
                    if entry.isExpanded {
                        viewModel.collapseDirectory(entryID: entry.id)
                    } else {
                        viewModel.expandDirectory(entryID: entry.id)
                    }
                } label: {
                    Image(systemName: entry.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear
                    .frame(width: 12, height: 1)
            }

            // Icon
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                .font(.caption)
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)

            // Name
            Text(entry.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            // File size for files
            if !entry.isDirectory && entry.size > 0 {
                Text(FileInspectorService.formatByteCount(entry.size))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            selectedEntryID == entry.id
                ? Color.accentColor.opacity(0.15)
                : Color.clear
        )
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDirectory {
                // Toggle expand/collapse
                if entry.isExpanded {
                    viewModel.collapseDirectory(entryID: entry.id)
                } else {
                    viewModel.expandDirectory(entryID: entry.id)
                }
            } else {
                // Select file for inspection
                selectedEntryID = entry.id
                viewModel.inspectFile(
                    resolvedPath: entry.resolvedPath,
                    relativePath: entry.relativePath
                )
            }
        }
        .contextMenu {
            if !entry.isDirectory {
                Button {
                    viewModel.attachFile(
                        resolvedPath: entry.resolvedPath,
                        relativePath: entry.relativePath
                    )
                } label: {
                    Label("Attach to Prompt", systemImage: "paperclip")
                }
                .disabled(viewModel.explorerService.isSensitiveFile(entry.relativePath))
            }
        }

        // Children (if expanded)
        if entry.isDirectory, let children = entry.children {
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    AnyView(row)
                    ForEach(children) { child in
                        entryRow(entry: child, depth: depth + 1)
                    }
                }
            )
        }

        return AnyView(row)
    }
}
