import SwiftUI

/// A sheet for entering, saving, or clearing the API key.
///
/// The key is stored in the macOS Keychain via `KeychainStore` and is never
/// persisted in source control or plain files.
struct APIKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ChatViewModel

    var body: some View {
        VStack(spacing: 16) {
            Text("API Key")
                .font(.title2.bold())

            Text("Enter the API key for your oMLX endpoint. The key is stored securely in the macOS Keychain and is never written to source control.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("API key", text: $viewModel.apiKey)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Button("Clear") {
                    viewModel.clearAPIKey()
                }
                .disabled(viewModel.apiKey.isEmpty)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    viewModel.saveAPIKey()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}
