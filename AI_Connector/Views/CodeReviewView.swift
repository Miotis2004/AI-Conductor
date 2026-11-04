import SwiftUI

/// A view for reviewing AI-proposed code modifications.
///
/// Displays the diff for each file in the proposal with visual differentiation
/// between added, removed, and unchanged lines. Provides Approve, Reject, and
/// Undo controls.
struct CodeReviewView: View {
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.secondary)
                Text("Code Review")
                    .font(.headline)
                Spacer()

                if let proposal = viewModel.codeModificationService.currentProposal {
                    Text("\(proposal.fileCount) file\(proposal.fileCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)

            // Content
            if let proposal = viewModel.codeModificationService.currentProposal {
                proposalContent(proposal: proposal)
            } else if viewModel.codeModificationService.isGenerating {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("Generating proposal…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                Text("No proposal to review.\nSelect files and send a modification request.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
        .frame(minWidth: 200)
    }

    // MARK: - Proposal Content

    @ViewBuilder
    private func proposalContent(proposal: CodeModificationProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Proposal summary
            HStack(spacing: 8) {
                statusBadge(for: proposal)
                Text(proposal.userInstructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                Spacer()
            }
            .padding(.horizontal, 8)

            // Error message
            if let error = proposal.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
            }

            // Warning message (e.g., partial recovery failure)
            if let warning = viewModel.codeModificationService.lastWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
                .padding(.horizontal, 8)
            }

            // Diffs
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(proposal.operations) { operation in
                        if let diff = proposal.diffs[operation.path] {
                            diffSection(diff: diff)
                        }
                    }
                }
                .padding(8)
            }

            // Action buttons
            HStack(spacing: 8) {
                Button {
                    viewModel.approveProposal()
                } label: {
                    Label("Approve All", systemImage: "checkmark.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!proposal.isValid)
                .help("Apply all proposed changes")

                Button {
                    viewModel.rejectProposal()
                } label: {
                    Label("Reject All", systemImage: "xmark.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)
                .disabled(proposal.status != .pending)
                .help("Discard the proposal without applying changes")

                if viewModel.codeModificationService.canUndo {
                    Button {
                        viewModel.undoLastChange()
                    } label: {
                        Label("Undo Last", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Revert the most recent applied change")
                } else {
                    Button {
                    } label: {
                        Label("Undo Last", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(true)
                    .help("No changes to undo")
                }

                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private func statusBadge(for proposal: CodeModificationProposal) -> some View {
        let (text, color): (String, Color) = {
            switch proposal.status {
            case .pending: return ("Pending", .orange)
            case .applied: return ("Applied", .green)
            case .rejected: return ("Rejected", .red)
            case .discarded: return ("Discarded", .secondary)
            case .conflict: return ("Conflict", .red)
            }
        }()
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
    }

    // MARK: - Diff Section

    @ViewBuilder
    private func diffSection(diff: FileDiff) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // File header
            HStack(spacing: 8) {
                Image(systemName: diff.operationType == .create ? "plus.circle.fill" : "pencil.circle.fill")
                    .font(.caption)
                    .foregroundStyle(diff.operationType == .create ? .green : .blue)

                Text(diff.path)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                // Line change summary
                if diff.linesAdded > 0 {
                    Text("+\(diff.linesAdded)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.green)
                }
                if diff.linesRemoved > 0 {
                    Text("-\(diff.linesRemoved)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            // Diff lines
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(diff.lines) { line in
                        diffLineView(line: line)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 300)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
    }

    // MARK: - Diff Line View

    @ViewBuilder
    private func diffLineView(line: FileDiff.DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Line numbers
            HStack(spacing: 0) {
                Text(line.oldLineNumber.map(String.init) ?? "")
                    .frame(width: 30, alignment: .trailing)
                Text(line.newLineNumber.map(String.init) ?? "")
                    .frame(width: 30, alignment: .trailing)
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.tertiary)
            .padding(.trailing, 8)

            // Diff marker
            Text(diffMarker(for: line.type))
                .font(.system(.body, design: .monospaced))
                .frame(width: 16, alignment: .center)

            // Content
            Text(line.content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .background(lineBackground(for: line.type))
    }

    private func diffMarker(for type: FileDiff.DiffLine.LineType) -> String {
        switch type {
        case .context: return " "
        case .added: return "+"
        case .removed: return "-"
        }
    }

    private func lineBackground(for type: FileDiff.DiffLine.LineType) -> Color {
        switch type {
        case .context: return Color.clear
        case .added: return Color.green.opacity(0.15)
        case .removed: return Color.red.opacity(0.15)
        }
    }
}
