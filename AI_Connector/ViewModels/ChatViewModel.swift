import Foundation
import SwiftUI
import Observation
import AppKit
import UniformTypeIdentifiers

// MARK: - Connection State

/// Represents the current connection state to the oMLX endpoint.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

// MARK: - Chat ViewModel

/// The view model that drives the chat interface.
///
/// It is `@MainActor`-isolated (matching the project's `SWIFT_DEFAULT_ACTOR_ISOLATION`)
/// and uses `@Observable` for SwiftUI integration.
@Observable
@MainActor
final class ChatViewModel {
    // MARK: - Published State

    /// The current connection state.
    var connectionState: ConnectionState = .disconnected
    /// The list of models fetched from the server.
    var models: [OpenAIModel] = []
    /// The currently selected model identifier.
    var selectedModelID: String?
    /// The user's prompt text.
    var prompt: String = ""
    /// The assistant's response text.
    var response: String = ""
    /// Whether a chat completion request is in flight.
    var isLoading: Bool = false
    /// The API key (loaded from / saved to the Keychain).
    var apiKey: String = ""
    /// The base URL of the oMLX endpoint.
    var baseURL: String = "http://127.0.0.1:8000/v1"
    /// Performance statistics for the most recent request.
    var requestStats: RequestStats?
    /// The in-memory conversation history.
    var conversation: ConversationHistory = ConversationHistory()
    /// A message to display to the user (e.g. save confirmation or error).
    var statusMessage: String?

    // MARK: - Private

    private var client: OpenAIClient?
    private var streamTask: Task<Void, Never>?
    /// The workspace service for managing the selected directory.
    let workspaceService: WorkspaceService
    /// The workspace explorer service for directory enumeration.
    let explorerService: WorkspaceExplorerService
    /// The file inspector service for read-only file viewing.
    let fileInspectorService: FileInspectorService
    /// The attachment service for managing file attachments.
    let attachmentService: AttachmentService
    /// The context budget service for estimating context usage.
    let contextBudgetService: ContextBudgetService
    /// The prompt assembler for building structured model requests.
    let promptAssembler: PromptAssembler
    /// The model identifier used for the most recent request, used for
    /// chat export headers.
    private var lastModelID: String?
    /// A warning message about context budget, if any.
    var contextWarning: String?
    /// Whether the sidebar (workspace explorer) is visible.
    var isSidebarVisible: Bool = true

    // MARK: - Init

    init() {
        self.workspaceService = WorkspaceService()
        self.explorerService = WorkspaceExplorerService(workspaceService: workspaceService)
        self.fileInspectorService = FileInspectorService(
            workspaceService: workspaceService,
            explorerService: explorerService
        )
        self.attachmentService = AttachmentService(
            workspaceService: workspaceService,
            explorerService: explorerService
        )
        self.contextBudgetService = ContextBudgetService()
        self.promptAssembler = PromptAssembler()
        self.apiKey = KeychainStore.load() ?? ""
    }

    // MARK: - Connection

    /// Connects to the oMLX endpoint and fetches the list of available models.
    func connect() async {
        guard let url = URL(string: baseURL) else {
            connectionState = .failed("Invalid base URL: \(baseURL)")
            return
        }

        connectionState = .connecting
        models = []
        selectedModelID = nil
        response = ""
        requestStats = nil

        let client = OpenAIClient(baseURL: url, apiKey: apiKey)
        self.client = client

        do {
            let fetched = try await client.fetchModels()
            models = fetched
            selectedModelID = fetched.first?.id
            connectionState = .connected
        } catch let error as OpenAIError {
            connectionState = .failed(error.localizedDescription)
        } catch {
            connectionState = .failed(error.localizedDescription)
        }
    }

    // MARK: - Chat

    /// Sends the current prompt to the selected model using streaming.
    ///
    /// The prompt is captured as an immutable value before sending. The
    /// prompt editor is cleared only after the backend accepts the request
    /// (HTTP 2xx). If the request fails before acceptance, the prompt is
    /// preserved.
    ///
    /// Falls back to non-streaming if the streaming request fails before any
    /// content has been received.
    func send() async {
        guard let modelID = selectedModelID,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Capture the submitted prompt as an immutable value before sending.
        let submittedPrompt = prompt

        // Assemble the final prompt, including any attached file contents.
        // File contents are read at submission time and validated against
        // the workspace boundary.
        let finalPrompt: String
        do {
            if attachmentService.hasAttachments {
                // Read all attachments and assemble the prompt.
                let fileContents = try attachmentService.readAttachments()
                let files = fileContents.map { (relativePath: $0.attachment.relativePath, content: $0.content) }
                finalPrompt = promptAssembler.assemblePrompt(userPrompt: submittedPrompt, files: files)
            } else {
                // No attachments — use the plain prompt (preserves ordinary chat behavior).
                finalPrompt = submittedPrompt
            }
        } catch {
            statusMessage = "Failed to read attachments: \(error.localizedDescription)"
            return
        }

        // Check context budget before sending.
        if let model = models.first(where: { $0.id == modelID }) {
            let budget = contextBudgetService.calculateBudget(
                maxModelLen: model.maxModelLen,
                promptText: finalPrompt,
                attachmentTokenEstimates: attachmentService.attachments.map { $0.estimatedTokens }
            )
            contextWarning = contextBudgetService.warningMessage(for: budget)
            if budget.exceedsBudget {
                statusMessage = contextWarning
                return
            }
        }

        // Rebuild the client in case the API key or base URL changed.
        guard let url = URL(string: baseURL) else {
            connectionState = .failed("Invalid base URL: \(baseURL)")
            return
        }
        let client = OpenAIClient(baseURL: url, apiKey: apiKey)
        self.client = client
        self.lastModelID = modelID

        isLoading = true
        response = ""
        requestStats = nil
        statusMessage = nil
        contextWarning = nil

        // Create a conversation entry for this exchange.
        // Store the user's original prompt (not the assembled one with file
        // contents) in the conversation history for display purposes.
        let entry = ConversationEntry(
            userPrompt: submittedPrompt,
            assistantResponse: "",
            status: .completed,
            modelID: modelID
        )
        conversation.append(entry)

        // Track timing locally.
        let startTime = Date()
        var firstTokenTime: Date?
        var receivedAnyContent = false
        var serverReportedTokens: Int?
        var wasAccepted = false

        defer {
            isLoading = false
            streamTask = nil
        }

        let stream = client.streamChatCompletion(
            model: modelID,
            prompt: finalPrompt,
            onAccepted: { [weak self] statusCode in
                // Clear the prompt editor only after the backend accepts
                // the request (HTTP 2xx). This does not wait for the
                // entire response to finish.
                if (200..<300).contains(statusCode) {
                    wasAccepted = true
                    self?.prompt = ""
                }
            }
        )

        streamTask = Task {
            do {
                for try await chunk in stream {
                    // Check for cancellation.
                    if Task.isCancelled {
                        break
                    }

                    // Extract content from the first choice's delta.
                    if let delta = chunk.choices.first?.delta,
                       let content = delta.content,
                       !content.isEmpty {
                        if !receivedAnyContent {
                            firstTokenTime = Date()
                            receivedAnyContent = true
                        }
                        response += content
                    }

                    // Capture server-reported usage if present.
                    if let usage = chunk.usage {
                        serverReportedTokens = usage.completionTokens
                    }
                }
            } catch let error as OpenAIError {
                // Streaming failed — fall back to non-streaming if we
                // haven't received any content yet.
                if !receivedAnyContent {
                    await self.fallbackToNonStreaming(
                        client: client,
                        model: modelID,
                        prompt: finalPrompt,
                        startTime: startTime
                    )
                } else {
                    // We got partial content before the error.
                    self.response = "Error: \(error.localizedDescription)"
                    self.connectionState = .failed(error.localizedDescription)
                }
            } catch {
                if !receivedAnyContent {
                    await self.fallbackToNonStreaming(
                        client: client,
                        model: modelID,
                        prompt: finalPrompt,
                        startTime: startTime
                    )
                } else {
                    self.response = "Error: \(error.localizedDescription)"
                    self.connectionState = .failed(error.localizedDescription)
                }
            }

            // If the request was not accepted (failed before HTTP response),
            // restore the prompt so the user can retry.
            if !wasAccepted {
                self.prompt = submittedPrompt
            }

            // Compute final stats.
            let endTime = Date()
            let totalElapsed = endTime.timeIntervalSince(startTime)
            let ttft = firstTokenTime?.timeIntervalSince(startTime)

            // Estimate tokens if the server didn't report usage.
            // Rough estimate: ~4 characters per token for English text.
            // Only estimate when content was actually received.
            let estimatedTokens: Int?
            if receivedAnyContent {
                estimatedTokens = max(1, response.count / 4)
            } else {
                estimatedTokens = 0
            }
            let outputTokens = serverReportedTokens ?? estimatedTokens
            let isServerReported = serverReportedTokens != nil

            // Tokens per second: tokens generated / time from first token to end.
            // Only compute when we actually have tokens and a valid time window.
            let tps: Double?
            if let tokens = outputTokens, tokens > 0, let firstTime = firstTokenTime {
                let generationTime = endTime.timeIntervalSince(firstTime)
                tps = generationTime > 0 ? Double(tokens) / generationTime : nil
            } else {
                tps = nil
            }

            self.requestStats = RequestStats(
                timeToFirstToken: ttft,
                totalElapsed: totalElapsed,
                outputTokens: outputTokens,
                outputTokensIsServerReported: isServerReported,
                averageTokensPerSecond: tps
            )

            // Update the conversation entry with the final response and status.
            let finalStatus: ConversationStatus
            if Task.isCancelled {
                finalStatus = .interrupted
            } else if self.connectionState == .connected {
                finalStatus = .completed
            } else {
                finalStatus = .failed
            }
            self.conversation.updateResponse(
                for: entry.id,
                response: self.response,
                status: finalStatus
            )

            if !Task.isCancelled {
                self.connectionState = .connected
            }
        }

        // Wait for the stream task to complete.
        await streamTask?.value
    }

    /// Cancels the active streaming request.
    func stopGeneration() {
        streamTask?.cancel()
        streamTask = nil
        isLoading = false
        connectionState = .connected
    }

    // MARK: - Non-Streaming Fallback

    private func fallbackToNonStreaming(
        client: OpenAIClient,
        model: String,
        prompt: String,
        startTime: Date
    ) async {
        do {
            let result = try await client.sendChatCompletion(model: model, prompt: prompt)
            let endTime = Date()
            let totalElapsed = endTime.timeIntervalSince(startTime)

            let content = result.choices.first?.message.content ?? ""
            response = content

            let serverTokens = result.usage?.completionTokens
            let estimatedTokens: Int?
            if !content.isEmpty {
                estimatedTokens = max(1, content.count / 4)
            } else {
                estimatedTokens = 0
            }
            let outputTokens = serverTokens ?? estimatedTokens
            let isServerReported = serverTokens != nil

            // For non-streaming, TTFT == total elapsed (no incremental delivery).
            let tps: Double?
            if let tokens = outputTokens, tokens > 0, totalElapsed > 0 {
                tps = Double(tokens) / totalElapsed
            } else {
                tps = nil
            }

            requestStats = RequestStats(
                timeToFirstToken: totalElapsed,
                totalElapsed: totalElapsed,
                outputTokens: outputTokens,
                outputTokensIsServerReported: isServerReported,
                averageTokensPerSecond: tps
            )
            connectionState = .connected
        } catch let error as OpenAIError {
            response = "Error: \(error.localizedDescription)"
            connectionState = .failed(error.localizedDescription)
        } catch {
            response = "Error: \(error.localizedDescription)"
            connectionState = .failed(error.localizedDescription)
        }
    }

    // MARK: - API Key

    /// Persists the current API key to the Keychain.
    func saveAPIKey() {
        KeychainStore.save(apiKey)
    }

    /// Clears the stored API key from the Keychain and the UI.
    func clearAPIKey() {
        KeychainStore.delete()
        apiKey = ""
    }

    // MARK: - Conversation

    /// Clears the conversation history.
    func clearConversation() {
        conversation.clear()
    }

    // MARK: - Save Chat

    /// Saves the current conversation as a new text file using `NSSavePanel`.
    ///
    /// The user chooses the destination and filename. The file is written
    /// as UTF-8 with a header containing the export date, model identifier,
    /// and entry count.
    func saveChatAsNew() {
        guard !conversation.isEmpty else {
            statusMessage = "There is no conversation to save."
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.text]
        panel.nameFieldStringValue = "chat-export.txt"
        panel.title = "Save Chat"
        panel.message = "Choose where to save the conversation."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return
        }

        do {
            try ChatExportService.saveNew(
                conversation,
                modelID: lastModelID ?? selectedModelID ?? "unknown",
                to: url
            )
            statusMessage = "Chat saved to \(url.lastPathComponent)"
        } catch let error as ChatExportError {
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = "Failed to save chat: \(error.localizedDescription)"
        }
    }

    /// Appends the current conversation to an existing text file using `NSOpenPanel`.
    ///
    /// The user selects an existing text file. The conversation is appended
    /// to the end of the file, preserving existing content. If the same
    /// conversation has already been appended, the user is asked to confirm.
    func appendChatToExisting() {
        guard !conversation.isEmpty else {
            statusMessage = "There is no conversation to append."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.text, UTType.plainText]
        panel.title = "Append Chat"
        panel.message = "Select an existing text file to append the conversation to."

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return
        }

        // Read the existing content for duplicate detection.
        let existingContent: String?
        do {
            existingContent = try String(contentsOf: url, encoding: .utf8)
        } catch {
            // If the file can't be read, proceed without duplicate detection.
            existingContent = nil
        }

        do {
            try ChatExportService.append(
                conversation,
                modelID: lastModelID ?? selectedModelID ?? "unknown",
                to: url,
                existingContent: existingContent
            )
            statusMessage = "Chat appended to \(url.lastPathComponent)"
        } catch ChatExportError.duplicateExport {
            // Ask the user to confirm re-appending the same conversation.
            let alert = NSAlert()
            alert.messageText = "Duplicate Conversation"
            alert.informativeText = "This conversation appears to have already been saved to the selected file. Append it again?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Append Again")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else {
                return
            }

            // Force append without duplicate detection.
            do {
                try ChatExportService.append(
                    conversation,
                    modelID: lastModelID ?? selectedModelID ?? "unknown",
                    to: url,
                    existingContent: nil
                )
                statusMessage = "Chat appended to \(url.lastPathComponent)"
            } catch let error as ChatExportError {
                statusMessage = error.localizedDescription
            } catch {
                statusMessage = "Failed to append chat: \(error.localizedDescription)"
            }
        } catch let error as ChatExportError {
            statusMessage = error.localizedDescription
        } catch {
            statusMessage = "Failed to append chat: \(error.localizedDescription)"
        }
    }

    // MARK: - Workspace Explorer

    /// Refreshes the workspace explorer.
    func refreshExplorer() {
        explorerService.refresh()
    }

    /// Expands a directory in the workspace explorer.
    func expandDirectory(entryID: String) {
        explorerService.expand(entryID: entryID)
    }

    /// Collapses a directory in the workspace explorer.
    func collapseDirectory(entryID: String) {
        explorerService.collapse(entryID: entryID)
    }

    // MARK: - File Inspector

    /// Inspects a file for display in the preview area.
    func inspectFile(resolvedPath: String, relativePath: String) {
        fileInspectorService.inspectFile(resolvedPath: resolvedPath, relativePath: relativePath)
    }

    /// Clears the file inspector selection.
    func clearFileSelection() {
        fileInspectorService.clearSelection()
    }

    // MARK: - Attachments

    /// Adds a file to the attachment list.
    func attachFile(resolvedPath: String, relativePath: String) {
        do {
            try attachmentService.addAttachment(resolvedPath: resolvedPath, relativePath: relativePath)
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Removes an attachment by its identifier.
    func removeAttachment(id: UUID) {
        attachmentService.removeAttachment(id: id)
    }

    /// Removes all attachments.
    func removeAllAttachments() {
        attachmentService.removeAllAttachments()
    }

    // MARK: - Sidebar

    /// Toggles the visibility of the workspace explorer sidebar.
    func toggleSidebar() {
        isSidebarVisible.toggle()
    }
}
