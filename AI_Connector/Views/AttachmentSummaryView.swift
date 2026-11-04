import SwiftUI

/// A compact view showing the files attached to the current prompt.
///
/// Displays each attachment with its filename, size, and estimated token
/// count. Allows individual removal of attachments. Shows a warning when
/// the total attachment size or token count is large.
struct AttachmentSummaryView: View {
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        if viewModel.attachmentService.hasAttachments {
            VStack(alignment: .leading, spacing: 6) {
                // Header
                HStack {
                    Image(systemName: "paperclip")
                        .foregroundStyle(.secondary)
                    Text("Attachments (\(viewModel.attachmentService.attachments.count))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()

                    // Total size and tokens
                    HStack(spacing: 8) {
                        Text(FileInspectorService.formatByteCount(viewModel.attachmentService.totalFileSize))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("~\(viewModel.attachmentService.totalEstimatedTokens) tokens (est.)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    Button {
                        viewModel.removeAllAttachments()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove all attachments")
                }

                // Context warning
                if let warning = viewModel.contextWarning {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(warning)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }

                // Attachment list
                ForEach(viewModel.attachmentService.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text(attachment.fileName)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Text(attachment.relativePath)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Text(FileInspectorService.formatByteCount(attachment.fileSize))
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Text("~\(attachment.estimatedTokens) tok")
                            .font(.caption2)
                            .foregroundStyle(.orange)

                        Button {
                            viewModel.removeAttachment(id: attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove attachment")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    )
                }
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            )
        }
    }
}
