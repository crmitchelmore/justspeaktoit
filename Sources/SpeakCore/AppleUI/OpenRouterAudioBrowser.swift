import SwiftUI

/// One live catalogue and selection flow for both apps. Discovery never uploads audio or text.
@MainActor
public struct OpenRouterAudioBrowser: View {
    @StateObject private var catalog: OpenRouterAudioCatalog
    @State private var capability: OpenRouterAudioCapability
    @Environment(\.dismiss) private var dismiss
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
        _capability = State(initialValue: onSelectTranscription == nil ? .speech : initialCapability)
    }

    public var body: some View {
        OpenRouterModelBrowser(
            title: "OpenRouter audio models",
            intro: "Use your OpenRouter key for cloud transcription and speech. "
                + "Browsing downloads model metadata only.",
            items: catalog.models(for: capability).sorted { $0.name < $1.name },
            status: OpenRouterBrowserStatus(
                isRefreshing: catalog.isRefreshing, errorMessage: catalog.errorMessage,
                lastUpdated: catalog.lastUpdated, isStale: catalog.isStale, missingSelection: missingSelection
            ),
            canRefresh: true,
            embedded: false,
            searchText: OpenRouterAudioFilter.searchText(for:),
            provider: OpenRouterAudioFilter.provider(for:),
            hasZeroPrices: OpenRouterAudioFilter.hasZeroPrices,
            name: \.name,
            subtitle: \.id,
            isSelected: isSelected,
            refresh: { force in await catalog.refresh(force: force) },
            onBack: nil,
            header: { capabilityPicker },
            detail: { model in
                OpenRouterAudioModelDetail(
                    model: model,
                    capability: capability,
                    apiKeyProvider: apiKeyProvider,
                    selectedSpeechID: selectedSpeechID
                ) { identifier in
                    if capability == .transcription {
                        onSelectTranscription?(identifier)
                    } else {
                        onSelectSpeech?(identifier)
                    }
                    dismiss()
                }
            }
        )
    }

    @ViewBuilder
    private var capabilityPicker: some View {
        if onSelectTranscription != nil, onSelectSpeech != nil {
            Picker("Capability", selection: $capability) {
                Text("Speech to text").tag(OpenRouterAudioCapability.transcription)
                Text("Text to speech").tag(OpenRouterAudioCapability.speech)
            }
            .pickerStyle(.segmented)
        }
    }

    private func isSelected(_ model: OpenRouterAudioModel) -> Bool {
        if capability == .transcription { return selectedTranscriptionID == model.transcriptionSelectionID }
        return selectedSpeechID.flatMap(OpenRouterSpeechSelection.init(id:))?.modelID == model.id
    }

    private var missingSelection: String? {
        let identifier: String?
        if capability == .transcription {
            identifier = selectedTranscriptionID.flatMap(OpenRouterTranscriptionSelection.modelID(from:))
        } else {
            identifier = selectedSpeechID.flatMap(OpenRouterSpeechSelection.init(id:))?.modelID
        }
        guard let identifier, catalog.lastUpdated != nil,
              !catalog.models(for: capability).contains(where: { $0.id == identifier }) else { return nil }
        return identifier
    }
}
