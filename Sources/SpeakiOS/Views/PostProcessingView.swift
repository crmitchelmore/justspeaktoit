#if os(iOS)
import SwiftUI
import SpeakCore

// swiftlint:disable file_length

// MARK: - Post-Processing Manager

/// Manages post-processing of transcriptions: on device, through a native
/// provider, or through OpenRouter, following the selected model's route.
@MainActor
public final class iOSPostProcessingManager: ObservableObject { // swiftlint:disable:this type_name
    public static let shared = iOSPostProcessingManager()

    @Published public var isProcessing = false
    @Published public var processedText = ""
    @Published public var error: String?
    @Published public var streamingText = ""

    private var streamTask: Task<Void, Never>?

    private init() {}

    /// Process text using the configured model and prompt.
    public func process(
        text: String,
        model: String,
        apiKey: String
    ) async {
        guard !text.isEmpty else { return }
        let usesAppleModel = model == AppleLocalModels.foundationModelID
        guard usesAppleModel || !apiKey.isEmpty else {
            error = PostProcessingError.apiKeyMissing(providerName: Self.keyProviderName(for: model))
                .errorDescription
            return
        }

        isProcessing = true
        error = nil
        streamingText = ""
        processedText = ""

        // Cancel any existing stream
        streamTask?.cancel()

        streamTask = Task {
            do {
                let effectivePrompt = Self.effectiveSystemPrompt()

                if usesAppleModel {
                    streamingText = try await AppleFoundationModelPolisher.process(
                        text: text,
                        systemPrompt: effectivePrompt
                    )
                } else {
                    // Use streaming for real-time updates
                    for try await chunk in sendChatStreaming(
                        systemPrompt: effectivePrompt,
                        userMessage: TranscriptCleanupPolicy.userMessage(transcript: text),
                        model: model,
                        apiKey: apiKey
                    ) {
                        if Task.isCancelled { break }
                        streamingText += chunk
                    }
                }

                processedText = streamingText
                isProcessing = false
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                    isProcessing = false
                }
            }
        }
    }

    /// Cancel any in-progress processing.
    public func cancel() {
        streamTask?.cancel()
        streamTask = nil
        isProcessing = false
    }

    /// Runs post-processing once and returns the full polished result. Unlike
    /// `process`, this does not mutate the shared published UI state, so it's
    /// safe to call for background work such as reprocessing a history entry.
    /// Reuses the same OpenRouter streaming path as the interactive editor.
    public func polish(
        text: String,
        model: String,
        apiKey: String
    ) async throws -> String {
        try await polish(
            text: text,
            systemPrompt: Self.effectiveSystemPrompt(),
            userMessage: TranscriptCleanupPolicy.userMessage(transcript: text),
            model: model,
            apiKey: apiKey
        )
    }

    /// Variant with an explicit prompt pair, used by the Polish Text App
    /// Intent so a custom Shortcuts prompt can replace the default cleanup
    /// contract (see `AutomationIntentSupport.polishRequest`).
    public func polish(
        text: String,
        systemPrompt: String,
        userMessage: String,
        model: String,
        apiKey: String
    ) async throws -> String {
        guard !text.isEmpty else { return text }
        if model == AppleLocalModels.foundationModelID {
            // Send the caller's prompt pair verbatim: rebuilding the cleanup
            // payload here would discard a custom Shortcuts prompt.
            return try await AppleFoundationModelPolisher.respond(
                systemPrompt: systemPrompt,
                userMessage: userMessage
            )
        }
        guard !apiKey.isEmpty else {
            throw PostProcessingError.apiKeyMissing(providerName: Self.keyProviderName(for: model))
        }

        var result = ""
        for try await chunk in sendChatStreaming(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            model: model,
            apiKey: apiKey
        ) {
            try Task.checkCancellation()
            result += chunk
        }
        return result
    }

    nonisolated static func effectiveSystemPrompt() -> String {
        TranscriptCleanupPolicy.systemPrompt()
    }

    nonisolated static func keyProviderName(for model: String) -> String {
        if case .apiKey(_, let providerName) = ModelCredentialResolver.requirement(
            for: model, purpose: .postProcessing
        ) { return providerName }
        return "OpenRouter"
    }

    // MARK: - Remote API

    /// Streams a chat completion through the shared SpeakCore client. `apiKey` is
    /// the key for the model's route: the native provider's key for a `native/`
    /// model, otherwise the OpenRouter key.
    private func sendChatStreaming(
        systemPrompt: String,
        userMessage: String,
        model: String,
        apiKey: String
    ) -> AsyncThrowingStream<String, Error> {
        OpenRouterAPIClient(apiKey: apiKey, nativeAPIKeyProvider: { _ in apiKey }).sendChatStreaming(
            systemPrompt: systemPrompt,
            messages: [ChatMessage(role: .user, content: userMessage)],
            model: model,
            temperature: 0.2
        )
    }
}

enum PostProcessingError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case apiKeyMissing(providerName: String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code): return "Server error: \(code)"
        case .apiKeyMissing(let providerName): return "\(providerName) API key is required"
        case .emptyResult: return "Polishing returned no text"
        }
    }
}

// MARK: - Post-Processing View

/// Full-screen post-processing view with editable text and model selection.
public struct PostProcessingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appVisualDensity) private var density
    @StateObject private var processor = iOSPostProcessingManager.shared
    @ObservedObject private var settings = AppSettings.shared

    @State private var inputText: String
    @State private var showingModelPicker = false
    @FocusState private var isTextFieldFocused: Bool

    private let onComplete: (String) -> Void

    public init(initialText: String, onComplete: @escaping (String) -> Void) {
        _inputText = State(initialValue: initialText)
        self.onComplete = onComplete
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Input/Output area
                ScrollView {
                    VStack(
                        alignment: .leading,
                        spacing: density.isCompact ? density.sectionSpacing : 16
                    ) {
                        // Input section
                        VStack(
                            alignment: .leading,
                            spacing: density.isCompact ? density.cardContentSpacing : 8
                        ) {
                            Label("Input", systemImage: "text.alignleft")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextEditor(text: $inputText)
                                .accessibilityLabel("Input")
                                .font(.body)
                                .frame(minHeight: density.isCompact ? 64 : 120)
                                .padding(density.isCompact ? 4 : 8)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(
                                    RoundedRectangle(cornerRadius: density.isCompact ? 8 : 10)
                                )
                                .focused($isTextFieldFocused)
                        }

                        // Output section (shows during/after processing)
                        if processor.isProcessing || !processor.streamingText.isEmpty
                            || !processor.processedText.isEmpty {
                            VStack(
                                alignment: .leading,
                                spacing: density.isCompact ? density.cardContentSpacing : 8
                            ) {
                                HStack {
                                    Label("Output", systemImage: "wand.and.stars")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)

                                    Spacer()

                                    if processor.isProcessing {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    }
                                }

                                Text(processor.isProcessing ? processor.streamingText : processor.processedText)
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(density.isCompact ? 6 : 12)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(
                                        RoundedRectangle(cornerRadius: density.isCompact ? 8 : 10)
                                    )
                                    .textSelection(.enabled)
                            }
                        }

                        // Error display
                        if let error = processor.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(density.isCompact ? density.pagePadding : 16)
                }

                Divider()

                // Model & Settings bar
                VStack(spacing: density.isCompact ? density.cardContentSpacing : 12) {
                    // Model selector
                    Button {
                        showingModelPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "cpu")
                            Text(modelDisplayName)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                        }
                        .padding(.horizontal, density.isCompact ? 8 : 12)
                        .padding(.vertical, density.isCompact ? 0 : 10)
                        .frame(minHeight: density.isCompact ? 44 : nil)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(
                            RoundedRectangle(cornerRadius: density.isCompact ? 6 : 8)
                        )
                    }
                    .buttonStyle(.plain)

                    // Action buttons
                    HStack(spacing: density.isCompact ? 6 : 12) {
                        // Process button
                        Button {
                            Task {
                                isTextFieldFocused = false
                                await processor.process(
                                    text: inputText,
                                    model: settings.postProcessingModel,
                                    apiKey: settings.postProcessingAPIKey(for: settings.postProcessingModel)
                                )
                            }
                        } label: {
                            HStack {
                                if processor.isProcessing {
                                    ProgressView()
                                        .tint(.white)
                                } else {
                                    Image(systemName: "wand.and.stars")
                                }
                                Text(processor.isProcessing ? "Processing..." : "Process")
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(inputText.isEmpty || !settings.hasPostProcessingKey || processor.isProcessing)

                        // Use result button
                        if !processor.processedText.isEmpty {
                            Button {
                                onComplete(processor.processedText)
                                dismiss()
                            } label: {
                                Image(systemName: "checkmark")
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .accessibilityLabel("Use polished text")
                            .accessibilityIdentifier("postProcessingUseResult")
                        }
                    }

                    // API key warning
                    if !settings.hasPostProcessingKey {
                        Label(
                            "Add \(settings.postProcessingKeyProviderName) API key in Settings",
                            systemImage: "key"
                        )
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(density.isCompact ? density.pagePadding : 16)
                .background(Color(.systemBackground))
            }
            .navigationTitle("Post-Process")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        processor.cancel()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if !processor.processedText.isEmpty {
                        Button("Use") {
                            onComplete(processor.processedText)
                            dismiss()
                        }
                    }
                }
            }
            .sheet(isPresented: $showingModelPicker) {
                modelPickerSheet
            }
        }
    }
}

private extension PostProcessingView {
    private var modelDisplayName: String {
        let model = settings.postProcessingModel
        return ModelPickerGrouping.selectionLabel(
            for: model, displayName: ModelCatalog.friendlyName(for: model), purpose: .postProcessing
        )
    }

    // MARK: - Model Picker Sheet

    @ViewBuilder
    private var modelPickerSheet: some View {
        NavigationStack {
            List {
                PostProcessingModelPickerRows(settings: settings, showsDescriptions: !density.isCompact) {
                    showingModelPicker = false
                }
            }
            .navigationTitle("Select Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingModelPicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

}

#Preview {
    PostProcessingView(initialText: "this is some test text that needs cleaning up") { result in
        print("Result: \(result)")
    }
}
#endif
