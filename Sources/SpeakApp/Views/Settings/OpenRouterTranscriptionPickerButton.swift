import SpeakCore
import SwiftUI

@MainActor
struct OpenRouterTranscriptionPickerButton: View {
    @Binding var selection: String
    let storage: SecureAppStorage
    @State private var showsModels = false

    var body: some View {
        Button("Browse OpenRouter speech-to-text models…") { showsModels = true }
            .sheet(isPresented: $showsModels) {
                OpenRouterAudioBrowser(
                    apiKeyProvider: { [storage] in
                        try? await storage.secret(identifier: "openrouter.apiKey")
                    },
                    selectedTranscriptionID: selection,
                    selectedSpeechID: nil,
                    onSelectTranscription: { selection = $0 }
                )
            }
    }
}
