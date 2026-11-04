import SwiftUI

/// A read-only view for displaying the contents of a selected file.
///
/// Shows the filename, relative path, file size, and line numbers.
/// Uses a monospaced font and preserves indentation and whitespace.
/// Displays appropriate messages for binary files and files that exceed
/// the size limit.
struct FileInspectorView: View {
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "doc.text")
                    .foregroundStyle(.secondary)
                Text("File Preview")
                    .font(.headline)
                Spacer()

                if viewModel.fileInspectorService.currentResult != nil {
                    Button {
                        viewModel.clearFileSelection()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close preview")
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Content
            if let result = viewModel.fileInspectorService.currentResult {
                fileContent(result: result)
            } else {
                Text("Select a file to preview its contents.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        }
        .frame(minWidth: 200)
    }

    // MARK: - File Content

    @ViewBuilder
    private func fileContent(result: FileInspectorResult) -> some View {
        // File metadata
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(result.fileName)
                    .font(.body.weight(.medium))
                Spacer()
                Text(FileInspectorService.formatByteCount(result.fileSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(result.relativePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let encoding = result.encoding {
                Text("Encoding: \(encoding)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)

        // Content area
        if result.isBinary {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text("Binary file")
                    .font(.body)
                Text(result.errorMessage ?? "This file contains binary data and cannot be displayed as text.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if result.exceedsSizeLimit {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.title2)
                Text("File too large")
                    .font(.body)
                Text(result.errorMessage ?? "This file exceeds the preview size limit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if let errorMessage = result.errorMessage {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if let content = result.content {
            // Display the file content with line numbers.
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .top, spacing: 0) {
                    // Line numbers
                    lineNumbers(count: result.lineCount)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 40, alignment: .trailing)
                        .padding(.trailing, 8)

                    // Content
                    Text(content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }

        // Attach button
        if !result.isBinary && !result.exceedsSizeLimit && result.errorMessage == nil {
            HStack {
                Button {
                    if let path = viewModel.fileInspectorService.selectedFilePath {
                        viewModel.attachFile(
                            resolvedPath: path,
                            relativePath: result.relativePath
                        )
                    }
                } label: {
                    Label("Attach to Prompt", systemImage: "paperclip")
                }
                .controlSize(.small)

                Spacer()

                if result.lineCount > 0 {
                    Text("\(result.lineCount) lines")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Line Numbers

    @ViewBuilder
    private func lineNumbers(count: Int) -> some View {
        // Display line numbers in a single Text view for performance.
        // For very large files, this could be optimized with a lazy approach.
        let numbers = (1...min(count, 10000)).map { String($0) }.joined(separator: "\n")
        Text(numbers)
    }
}
