import SwiftUI

/// The main chat interface for the AI Connector.
///
/// Layout (top to bottom):
/// 1. Connection bar — base URL, API key button, connect button, status indicator
/// 2. Model selector — a `Picker` populated from `GET /v1/models`
/// 3. Workspace bar — current directory, browse button, access status, sidebar toggle
/// 4. `HSplitView` with:
///    - Left: Collapsible workspace explorer sidebar (directory tree + file inspector)
///    - Right: `VSplitView` with:
///      - Top: Prompt input + attachment summary + Send/Stop buttons
///      - Bottom: Response display + performance stats + save chat buttons
struct ContentView: View {
    @State private var viewModel = ChatViewModel()
    @State private var showAPIKeySheet = false

    var body: some View {
        VStack(spacing: 12) {
            connectionBar
            Divider()
            modelSelector
            modeSelector
            workspaceBar
            Divider()

            HSplitView {
                // Left: Workspace explorer sidebar (collapsible)
                if viewModel.isSidebarVisible {
                    sidebar
                        .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
                }

                // Right: Main area (mode-dependent)
                VSplitView {
                    promptPanel
                        .frame(minHeight: 120)
                        .layoutPriority(1)

                    if viewModel.appMode == .code {
                        CodeReviewView(viewModel: viewModel)
                            .frame(minHeight: 120)
                            .layoutPriority(1)
                    } else {
                        responsePanel
                            .frame(minHeight: 120)
                            .layoutPriority(1)
                    }
                }
                .frame(minWidth: 320, minHeight: 300)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 480)
        .sheet(isPresented: $showAPIKeySheet) {
            APIKeySettingsView(viewModel: viewModel)
        }
        .onAppear {
            Task {
                await viewModel.connect()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // Workspace explorer (top half)
            WorkspaceExplorerView(viewModel: viewModel)
                .frame(maxHeight: .infinity)

            Divider()

            // Bottom half: mode-dependent
            if viewModel.appMode == .code {
                CodeReviewView(viewModel: viewModel)
                    .frame(maxHeight: .infinity)
            } else {
                FileInspectorView(viewModel: viewModel)
                    .frame(maxHeight: .infinity)
            }
        }
    }

    // MARK: - Connection Bar

    private var connectionBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(.secondary)

            TextField("Base URL", text: $viewModel.baseURL)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)

            Button {
                showAPIKeySheet = true
            } label: {
                Label(
                    viewModel.apiKey.isEmpty ? "Set API Key" : "API Key Set",
                    systemImage: viewModel.apiKey.isEmpty ? "key.slash" : "key"
                )
            }
            .help("Configure the API key (stored in Keychain)")

            Button {
                Task {
                    await viewModel.connect()
                }
            } label: {
                if viewModel.connectionState == .connecting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Connect", systemImage: "arrow.clockwise")
                }
            }
            .disabled(viewModel.connectionState == .connecting)

            Spacer()

            connectionStatusIndicator
        }
    }

    @ViewBuilder
    private var connectionStatusIndicator: some View {
        switch viewModel.connectionState {
        case .disconnected:
            statusBadge(text: "Disconnected", color: .secondary)
        case .connecting:
            statusBadge(text: "Connecting…", color: .orange)
        case .connected:
            statusBadge(text: "Connected", color: .green)
        case .failed(let message):
            statusBadge(text: "Error", color: .red)
                .help(message)
        }
    }

    private func statusBadge(text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
    }

    // MARK: - Model Selector

    @ViewBuilder
    private var modelSelector: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .foregroundStyle(.secondary)

            Picker("Model", selection: $viewModel.selectedModelID) {
                if viewModel.models.isEmpty {
                    Text("No models available")
                        .tag(nil as String?)
                } else {
                    ForEach(viewModel.models) { model in
                        Text(model.id).tag(model.id as String?)
                    }
                }
            }
            .labelsHidden()
            .disabled(viewModel.models.isEmpty || viewModel.connectionState == .connecting)

            // Show max context info if available
            if let model = viewModel.models.first(where: { $0.id == viewModel.selectedModelID }),
               let maxLen = model.maxModelLen {
                Text("ctx: \(maxLen) tokens")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            switch viewModel.connectionState {
            case .failed(let message):
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            default:
                EmptyView()
            }
        }
    }

    // MARK: - Mode Selector

    private var modeSelector: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(.secondary)

            Picker("Mode", selection: Binding(
                get: { viewModel.appMode },
                set: { viewModel.switchMode($0) }
            )) {
                ForEach(AppMode.allCases) { mode in
                    Label(mode.rawValue, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            Spacer()
        }
    }

    // MARK: - Workspace Bar

    private var workspaceBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)

            if let directory = viewModel.workspaceService.selectedDirectory {
                Text(directory.path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(directory.path)

                switch viewModel.workspaceService.accessState {
                case .accessible:
                    statusBadge(text: "Workspace", color: .green)
                case .needsRenewal:
                    statusBadge(text: "Access Expired", color: .orange)
                        .help("Workspace access must be renewed. Click Browse to re-select the folder.")
                case .none:
                    EmptyView()
                }
            } else {
                Text("No workspace selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                let oldPath = viewModel.workspaceService.selectedDirectory?.path
                viewModel.workspaceService.browse()
                let newPath = viewModel.workspaceService.selectedDirectory?.path
                if oldPath != newPath {
                    viewModel.invalidateCodeModification()
                }
            } label: {
                Label("Browse", systemImage: "folder.badge.gearshape")
            }
            .controlSize(.small)

            if viewModel.workspaceService.selectedDirectory != nil {
                Button {
                    viewModel.workspaceService.clear()
                    viewModel.removeAllAttachments()
                    viewModel.clearFileSelection()
                    viewModel.invalidateCodeModification()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
                .help("Clear workspace selection")
            }

            Spacer()

            // Sidebar toggle
            Button {
                viewModel.toggleSidebar()
            } label: {
                Image(systemName: viewModel.isSidebarVisible ? "sidebar.left" : "sidebar.leading")
                    .foregroundStyle(viewModel.isSidebarVisible ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .controlSize(.small)
            .help(viewModel.isSidebarVisible ? "Hide workspace explorer" : "Show workspace explorer")
        }
    }

    // MARK: - Prompt Panel (Top of VSplitView)

    private var promptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Mode-specific header
            HStack {
                Text(viewModel.appMode == .code ? "Modification Instructions" : "Prompt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.appMode == .code {
                    Text("\(viewModel.codeModificationService.selectedFiles.count)/\(viewModel.codeModificationService.maxFilesPerProposal) files selected")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            TextEditor(text: $viewModel.prompt)
                .font(.body)
                .frame(minHeight: 80)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            // Mode-specific content
            if viewModel.appMode == .code {
                // Selected files for modification
                if !viewModel.codeModificationService.selectedFiles.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(viewModel.codeModificationService.selectedFiles, id: \.self) { path in
                            HStack(spacing: 2) {
                                Text((path as NSString).lastPathComponent)
                                    .font(.caption2)
                                Button {
                                    viewModel.deselectFileFromModification(relativePath: path)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.accentColor.opacity(0.15))
                            )
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                }
            } else {
                // Attachment summary (shown when files are attached)
                AttachmentSummaryView(viewModel: viewModel)
            }

            HStack(spacing: 8) {
                Button {
                    Task {
                        if viewModel.appMode == .code {
                            await viewModel.sendCodeModification()
                        } else {
                            await viewModel.send()
                        }
                    }
                } label: {
                    if viewModel.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(viewModel.appMode == .code ? "Generating…" : "Generating…")
                        }
                    } else {
                        Label(
                            viewModel.appMode == .code ? "Propose Changes" : "Send",
                            systemImage: viewModel.appMode == .code ? "chevron.left.forwardslash.chevron.right" : "paperplane.fill"
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    viewModel.isLoading
                        || viewModel.selectedModelID == nil
                        || viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || (viewModel.appMode == .code && viewModel.codeModificationService.selectedFiles.isEmpty)
                )

                if viewModel.isLoading {
                    Button {
                        viewModel.stopGeneration()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .tint(.red)
                }

                Spacer()
            }
        }
        .padding(12)
    }

    // MARK: - Response Panel (Bottom of VSplitView)

    private var responsePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Response")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                if viewModel.response.isEmpty {
                    Text(viewModel.isLoading
                         ? "Waiting for response…"
                         : "The assistant's response will appear here.")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(viewModel.response)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 80)
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )

            // Performance stats — only shown after a request completes.
            if let stats = viewModel.requestStats {
                statsBar(stats: stats)
            }

            // Status message (save confirmation, errors, etc.)
            if let message = viewModel.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            // Save chat buttons — only shown in Chat mode (always visible here).
            HStack(spacing: 8) {
                Button {
                    viewModel.saveChatAsNew()
                } label: {
                    Label("Save Chat", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)
                .disabled(viewModel.conversation.isEmpty)

                Button {
                    viewModel.appendChatToExisting()
                } label: {
                    Label("Append to File", systemImage: "text.append")
                }
                .controlSize(.small)
                .disabled(viewModel.conversation.isEmpty)

                if !viewModel.conversation.isEmpty {
                    Button {
                        viewModel.clearConversation()
                    } label: {
                        Label("Clear History", systemImage: "trash")
                    }
                    .controlSize(.small)
                    .tint(.red)
                }

                Spacer()
            }
        }
        .padding(12)
    }

    // MARK: - Stats Bar

    private func statsBar(stats: RequestStats) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let ttft = stats.timeToFirstToken {
                statItem(
                    label: "TTFT",
                    value: String(format: "%.2fs", ttft),
                    isEstimated: false
                )
            }

            if let total = stats.totalElapsed {
                statItem(
                    label: "Total",
                    value: String(format: "%.2fs", total),
                    isEstimated: false
                )
            }

            if let tokens = stats.outputTokens {
                statItem(
                    label: "Tokens",
                    value: "\(tokens)",
                    isEstimated: !stats.outputTokensIsServerReported
                )
            }

            if let tps = stats.averageTokensPerSecond {
                statItem(
                    label: "Speed",
                    value: String(format: "%.1f tok/s", tps),
                    isEstimated: false
                )
            }

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        )
    }

    private func statItem(label: String, value: String, isEstimated: Bool) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .fontWeight(.medium)
            if isEstimated {
                Text("est.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Estimated locally — not reported by the server")
            }
        }
    }
}

#Preview {
    ContentView()
}
