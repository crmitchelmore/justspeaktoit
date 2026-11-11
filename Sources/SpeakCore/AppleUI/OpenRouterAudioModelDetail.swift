import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct OpenRouterAudioModelDetail: View {
    let model: OpenRouterAudioModel
    let capability: OpenRouterAudioCapability
    let onSelect: (String) -> Void
    @StateObject private var preview = OpenRouterAudioPreview()
    @State private var voice = ""
    @State private var sampleText = "Hello. This is a speech preview."
    @State private var importsAudio = false
    @State private var importError: String?
    private let client: OpenRouterAudioClient

    init(
        model: OpenRouterAudioModel,
        capability: OpenRouterAudioCapability,
        apiKeyProvider: @escaping @Sendable () async -> String?,
        selectedSpeechID: String?,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        self.capability = capability
        self.onSelect = onSelect
        client = OpenRouterAudioClient(apiKeyProvider: apiKeyProvider)
        let previous = selectedSpeechID.flatMap(OpenRouterSpeechSelection.init(id:))
        _voice = State(initialValue: previous?.modelID == model.id
            ? previous?.voice ?? "" : model.supportedVoices.first ?? "")
    }

    var body: some View {
        Form {
            Section("Model") {
                Text(model.name).font(.headline)
                Text(model.id).font(.caption).textSelection(.enabled)
                Text(model.description)
                LabeledContent("Input", value: model.inputModalities.joined(separator: ", "))
                LabeledContent("Output", value: model.outputModalities.joined(separator: ", "))
                if let length = model.contextLength { LabeledContent("Context limit", value: String(length)) }
                if let expiry = model.expirationDate { LabeledContent("Retirement date", value: expiry) }
            }
            pricing
            if capability == .speech { voicePicker }
            Section {
                Button(capability == .transcription ? "Use for transcription" : "Use for speech") {
                    onSelect(selectionID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isSelectionValid)
            }
            testSection
        }
        .formStyle(.grouped)
        .navigationTitle(model.name)
        .fileImporter(isPresented: $importsAudio, allowedContentTypes: [.audio]) { result in
            switch result {
            case let .success(url):
                importError = nil
                preview.transcribe(file: url, model: model.id, client: client)
            case .failure:
                importError = "Could not open the audio file. Choose another file."
            }
        }
        .onDisappear {
            preview.cancel()
            sampleText = ""
        }
    }

    private var pricing: some View {
        Section("Provider pricing") {
            if model.pricing.isEmpty {
                Text("Pricing is not listed for this model.")
            } else {
                ForEach(model.pricing.keys.sorted(), id: \.self) { key in
                    LabeledContent(key, value: model.pricing[key] ?? "")
                }
                Text("These are the provider's listed values. Units vary by model; check OpenRouter before use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Link("Model details on OpenRouter", destination: modelURL)
        }
    }

    private var voicePicker: some View {
        Section("Voice") {
            if model.supportedVoices.isEmpty {
                TextField("Voice ID (blank for provider default)", text: $voice)
                Text("This model does not list voices. It may require a voice ID from its documentation.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Voice", selection: $voice) {
                    Text("Provider default").tag("")
                    if !voice.isEmpty, !model.supportedVoices.contains(voice) {
                        Text("\(voice) — unavailable").tag(voice)
                    }
                    ForEach(model.supportedVoices, id: \.self) { Text($0).tag($0) }
                }
            }
            if !isSelectionValid {
                Text("Choose an available voice or enter a valid voice ID of up to 512 bytes.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text("Preview and exported audio use the provider default speed. Normal playback can adjust speed locally.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var testSection: some View {
        Section("Test this model") {
            Text("Testing sends your chosen audio or text to OpenRouter and its provider and may incur charges. "
                 + "Test content is not added to History. Preview audio is deleted after playback or when you leave.")
                .font(.caption).foregroundStyle(.secondary)
            if capability == .transcription {
                Button("Choose audio and transcribe…") { importsAudio = true }
                    .disabled(preview.isBusy)
            } else {
                TextField("Preview text", text: $sampleText, axis: .vertical).lineLimit(3...6)
                Button("Generate and play preview") {
                    preview.speak(text: sampleText, model: model.id, voice: selectedVoice, client: client)
                }
                .disabled(preview.isBusy || !isSelectionValid
                          || sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if preview.isBusy { ProgressView("Waiting for provider…") }
            if preview.isBusy || preview.isPlaying || !preview.transcript.isEmpty || !sampleText.isEmpty {
                Button("Cancel and clear", role: .cancel) {
                    preview.cancel()
                    sampleText = ""
                }
            }
            if let importError { Text(importError).foregroundStyle(.orange) }
            if !preview.status.isEmpty { Text(preview.status).font(.caption) }
            if !preview.transcript.isEmpty { Text(preview.transcript).textSelection(.enabled) }
        }
    }

    private var isSelectionValid: Bool {
        guard capability == .speech else { return true }
        guard OpenRouterSpeechSelection(id: selectionID) != nil else { return false }
        return selectedVoice.map { model.supportedVoices.isEmpty || model.supportedVoices.contains($0) } ?? true
    }

    private var selectedVoice: String? {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var selectionID: String {
        capability == .transcription ? model.transcriptionSelectionID
            : OpenRouterSpeechSelection(modelID: model.id, voice: selectedVoice).id
    }

    private var modelURL: URL {
        URL(string: "https://openrouter.ai")!.appendingPathComponent(model.id)
    }
}
