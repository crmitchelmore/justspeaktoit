#if os(iOS)
import SwiftUI
import SpeakCore

// MARK: - Post-Processing Manager

/// Manages post-processing of transcriptions via OpenRouter API.
@MainActor
public final class iOSPostProcessingManager: ObservableObject {
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
        prompt: String,
        apiKey: String
    ) async {
        guard !text.isEmpty else { return }
        guard !apiKey.isEmpty else {
            error = "OpenRouter API key required for post-processing"
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
                let effectivePrompt = prompt.isEmpty ? AppSettings.defaultPostProcessingPrompt : prompt
                
                // Use streaming for real-time updates
                for try await chunk in sendChatStreaming(
                    systemPrompt: effectivePrompt,
                    userMessage: text,
                    model: model,
                    apiKey: apiKey
                ) {
                    if Task.isCancelled { break }
                    streamingText += chunk
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
    
    // MARK: - OpenRouter API
    
    private func sendChatStreaming(
        systemPrompt: String,
        userMessage: String,
        model: String,
        apiKey: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let url = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
                        continuation.finish(throwing: PostProcessingError.invalidURL)
                        return
                    }
                    
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
                    request.setValue("JustSpeakToIt iOS", forHTTPHeaderField: "X-Title")
                    request.setValue("https://justspeaktoit.com", forHTTPHeaderField: "HTTP-Referer")
                    
                    let body: [String: Any] = [
                        "model": model,
                        "temperature": 0.2,
                        "stream": true,
                        "messages": [
                            ["role": "system", "content": systemPrompt],
                            ["role": "user", "content": userMessage]
                        ]
                    ]
                    
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                    
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: PostProcessingError.invalidResponse)
                        return
                    }
                    
                    guard httpResponse.statusCode == 200 else {
                        continuation.finish(throwing: PostProcessingError.httpError(httpResponse.statusCode))
                        return
                    }
                    
                    // Parse SSE stream
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }
                        
                        guard line.hasPrefix("data: ") else { continue }
                        let data = String(line.dropFirst(6))
                        
                        if data == "[DONE]" {
                            break
                        }
                        
                        guard let jsonData = data.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let content = delta["content"] as? String else {
                            continue
                        }
                        
                        continuation.yield(content)
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

enum PostProcessingError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case apiKeyMissing
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid API URL"
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code): return "Server error: \(code)"
        case .apiKeyMissing: return "OpenRouter API key is required"
        }
    }
}

// MARK: - Post-Processing View

/// Full-screen post-processing view with editable text and model selection.
public struct PostProcessingView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var processor = iOSPostProcessingManager.shared
    @ObservedObject private var settings = AppSettings.shared
    
    @State private var inputText: String
    @State private var showingModelPicker = false
    @State private var showingPromptEditor = false
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
                    VStack(alignment: .leading, spacing: 16) {
                        // Input section
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Input", systemImage: "text.alignleft")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            
                            TextEditor(text: $inputText)
                                .font(.body)
                                .frame(minHeight: 120)
                                .padding(8)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .focused($isTextFieldFocused)
                        }
                        
                        // Output section (shows during/after processing)
                        if processor.isProcessing || !processor.streamingText.isEmpty || !processor.processedText.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
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
                                    .padding(12)
                                    .background(Color(.tertiarySystemBackground))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
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
                    .padding()
                }
                
                Divider()
                
                // Model & Settings bar
                VStack(spacing: 12) {
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
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    
                    // Action buttons
                    HStack(spacing: 12) {
                        // Prompt settings
                        Button {
                            showingPromptEditor = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        
                        // Process button
                        Button {
                            Task {
                                isTextFieldFocused = false
                                await processor.process(
                                    text: inputText,
                                    model: settings.postProcessingModel,
                                    prompt: settings.postProcessingPrompt,
                                    apiKey: settings.openRouterAPIKey
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
                        .disabled(inputText.isEmpty || !settings.hasOpenRouterKey || processor.isProcessing)
                        
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
                        }
                    }
                    
                    // API key warning
                    if !settings.hasOpenRouterKey {
                        Label("Add OpenRouter API key in Settings", systemImage: "key")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding()
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
            .sheet(isPresented: $showingPromptEditor) {
                promptEditorSheet
            }
        }
    }
    
    private var modelDisplayName: String {
        AppSettings.postProcessingModels.first { $0.id == settings.postProcessingModel }?.name 
            ?? settings.postProcessingModel
    }
    
    // MARK: - Model Picker Sheet
    
    @ViewBuilder
    private var modelPickerSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(AppSettings.postProcessingModels.enumerated()), id: \.offset) { _, model in
                    Button {
                        settings.postProcessingModel = model.id
                        showingModelPicker = false
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.name)
                                    .foregroundStyle(.primary)
                                Text(model.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            if settings.postProcessingModel == model.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
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
    
    // MARK: - Prompt Editor Sheet
    
    @ViewBuilder
    private var promptEditorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $settings.postProcessingPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 200)
                } header: {
                    Text("Custom System Prompt")
                } footer: {
                    Text("Leave empty to use the default prompt. The prompt instructs the AI how to clean up your transcription.")
                }
                
                Section {
                    Button("Reset to Default") {
                        settings.postProcessingPrompt = ""
                    }
                    .foregroundStyle(.red)
                }
                
                Section("Default Prompt Preview") {
                    Text(AppSettings.defaultPostProcessingPrompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Prompt Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showingPromptEditor = false
                    }
                }
            }
        }
    }
}

#Preview {
    PostProcessingView(initialText: "this is some test text that needs cleaning up") { result in
        print("Result: \(result)")
    }
}
#endif
