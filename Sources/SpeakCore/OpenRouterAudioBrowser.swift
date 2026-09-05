import SwiftUI

/// One live catalogue and selection flow for both apps. Discovery never uploads audio or text.
@MainActor
public struct OpenRouterAudioBrowser: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var catalog: OpenRouterAudioCatalog
    @State private var filter: OpenRouterAudioFilter
    private let apiKeyProvider: @Sendable () async -> String?
    private let selectedTranscriptionID: String?
    private let selectedSpeechID: String?
    private let onSelectTranscription: ((String) -> Void)?
    private let onSelectSpeech: ((String) -> Void)?

    public init(
        apiKeyProvider: @escaping @Sendable () async -> String?,
        selectedTranscriptionID: String?,
        selectedSpeechID: String?,
        initialCapability: OpenRouterAudioCapability = .transcription,
        onSelectTranscription: ((String) -> Void)? = nil,
        onSelectSpeech: ((String) -> Void)? = nil
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.selectedTranscriptionID = selectedTranscriptionID
        self.selectedSpeechID = selectedSpeechID
        self.onSelectTranscription = onSelectTranscription
        self.onSelectSpeech = onSelectSpeech
        _catalog = StateObject(wrappedValue: OpenRouterAudioCatalog(apiKeyProvider: apiKeyProvider))
        _filter = State(initialValue: OpenRouterAudioFilter(
            capability: onSelectTranscription == nil ? .speech : initialCapability
        ))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls.padding()
                List {
                    status
                    ForEach(catalog.models.filter(filter.matches).sorted { $0.name < $1.name }) { model in
                        NavigationLink {
                            OpenRouterAudioModelDetail(
                                model: model,
                                capability: filter.capability,
                                apiKeyProvider: apiKeyProvider,
                                selectedSpeechID: selectedSpeechID
                            ) { identifier in
                                if filter.capability == .transcription {
                                    onSelectTranscription?(identifier)
                                } else {
                                    onSelectSpeech?(identifier)
                                }
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.name).font(.headline)
                                Text(model.id).font(.caption).foregroundStyle(.secondary)
                                if isSelected(model) {
                                    Label("Selected", systemImage: "checkmark.circle.fill")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("OpenRouter audio models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await catalog.refresh(force: true) }
                    }
                    .disabled(catalog.isRefreshing)
                }
            }
            .task { await catalog.refresh() }
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 500, idealHeight: 680)
        #endif
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use your OpenRouter key for cloud transcription and speech. Browsing downloads model metadata only.")
                .font(.caption).foregroundStyle(.secondary)
            Picker("Capability", selection: $filter.capability) {
                if onSelectTranscription != nil {
                    Text("Speech to text").tag(OpenRouterAudioCapability.transcription)
                }
                if onSelectSpeech != nil {
                    Text("Text to speech").tag(OpenRouterAudioCapability.speech)
                }
            }
            .pickerStyle(.segmented)
            TextField("Search models", text: $filter.query).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Provider", selection: $filter.provider) {
                    Text("All providers").tag("")
                    ForEach(providers, id: \.self) { Text($0).tag($0) }
                }
                Toggle("Zero listed prices", isOn: $filter.freeOnly)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if catalog.isRefreshing { ProgressView("Refreshing models…") }
        if let error = catalog.errorMessage { Text(error).foregroundStyle(.orange) }
        if let updated = catalog.lastUpdated {
            Text("\(catalog.isStale ? "Cached, refresh needed" : "Updated"): \(updated.formatted())")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let missing = missingSelection {
            Label("Selected model is unavailable in this catalogue: \(missing). Your selection is retained.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
        if !catalog.isRefreshing, catalog.models.filter(filter.matches).isEmpty {
            Text("No matching models. Change the filters or refresh the catalogue.")
                .foregroundStyle(.secondary)
        }
    }

    private var providers: [String] {
        Array(Set(catalog.models.map(OpenRouterAudioFilter.provider))).sorted()
    }

    private func isSelected(_ model: OpenRouterAudioModel) -> Bool {
        if filter.capability == .transcription { return selectedTranscriptionID == model.transcriptionSelectionID }
        return selectedSpeechID.flatMap(OpenRouterSpeechSelection.init(id:))?.modelID == model.id
    }

    private var missingSelection: String? {
        let identifier: String?
        if filter.capability == .transcription {
            identifier = selectedTranscriptionID.flatMap(OpenRouterTranscriptionSelection.modelID(from:))
        } else {
            identifier = selectedSpeechID.flatMap(OpenRouterSpeechSelection.init(id:))?.modelID
        }
        guard let identifier, catalog.lastUpdated != nil,
              !catalog.models(for: filter.capability).contains(where: { $0.id == identifier }) else { return nil }
        return identifier
    }
}
