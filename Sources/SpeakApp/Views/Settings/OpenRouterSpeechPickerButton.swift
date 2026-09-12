import SpeakCore
import SwiftUI

struct OpenRouterSpeechPickerButton: View {
    @EnvironmentObject private var tts: TextToSpeechManager
    @Binding var selectedVoice: String
    @State private var isPresented = false

    var body: some View {
        Button("Browse OpenRouter Speech…") { isPresented = true }
            .buttonStyle(.bordered)
            .sheet(isPresented: $isPresented) {
                OpenRouterAudioBrowser(
                    apiKeyProvider: { await tts.openRouterAPIKey() },
                    selectedTranscriptionID: nil,
                    selectedSpeechID: selectedVoice,
                    onSelectSpeech: { selection in
                        selectedVoice = selection
                        isPresented = false
                    }
                )
            }
    }
}
