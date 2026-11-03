import SwiftUI

/// The main chat interface for the AI Connector.
///
/// Layout (top to bottom):
/// 1. Connection bar — base URL, API key button, connect button, status indicator
/// 2. Model selector — a `Picker` populated from `GET /v1/models`
/// 3. `VSplitView` with two resizable panels:
///    - Top: Prompt input + Send/Stop buttons
///    - Bottom: Response display + performance stats
struct ContentView: View {
    @State private var viewModel = ChatViewModel()
    @State private var showAPIKeySheet = false

    var body: some View {
        VStack(spacing: 12) {
            connectionBar
            Divider()
            modelSelector

            VSplitView {
                promptPanel
                    .frame(minHeight: 120)
                    .layoutPriority(1)

                responsePanel
                    .frame(minHeight: 120)
                    .layoutPriority(1)
            }
            .frame(minHeight: 300)
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

    // MARK: - Prompt Panel (Top of VSplitView)

    private var promptPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt")
                .font(.caption)
                .foregroundStyle(.secondary)

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

            HStack(spacing: 8) {
                Button {
                    Task {
                        await viewModel.send()
                    }
                } label: {
                    if viewModel.isLoading {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Generating…")
                        }
                    } else {
                        Label("Send", systemImage: "paperplane.fill")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    viewModel.isLoading
                        || viewModel.selectedModelID == nil
                        || viewModel.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
