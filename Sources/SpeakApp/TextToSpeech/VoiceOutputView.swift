import SpeakCore
import SwiftUI

/// The Voice Output page. The draft lives in `VoiceOutputComposer`; each card
/// is its own view over it.
struct VoiceOutputView: View {
  @EnvironmentObject private var tts: TextToSpeechManager
  @EnvironmentObject private var settings: AppSettings
  @Environment(\.appVisualDensity) private var density
  @StateObject private var composer = VoiceOutputComposer()

  private var sectionSpacing: CGFloat {
    density.isCompact ? density.sectionSpacing : 24
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: sectionSpacing) {
        VoiceOutputHeader(composer: composer)
        contentSections
      }
      .padding(density.pagePadding)
      .frame(maxWidth: 1100, alignment: .center)
    }
    .background(
      LinearGradient(
        colors: [Color.green.opacity(0.08), Color(nsColor: .windowBackgroundColor)],
        startPoint: .top,
        endPoint: .bottom
      )
      .ignoresSafeArea()
    )
    .task {
      composer.selectedVoice = settings.defaultTTSVoice
      await composer.loadAvailableVoices(from: tts, defaultVoice: settings.defaultTTSVoice)
    }
    .onChange(of: composer.selectedVoice) { _, _ in
      composer.updateEstimatedCost(using: tts)
    }
    .fileImporter(
      isPresented: $composer.isImportingFile,
      allowedContentTypes: [.plainText, .text, .utf8PlainText],
      allowsMultipleSelection: false
    ) { result in
      composer.readImportedFile(result)
    }
    .sheet(isPresented: $composer.showingSSMLHelper) {
      SSMLHelperView(text: $composer.inputText)
    }
  }

  private var contentSections: some View {
    LazyVStack(spacing: sectionSpacing) {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: density.gridMinimumWidth), spacing: sectionSpacing)],
        spacing: sectionSpacing
      ) {
        VoiceOutputInputSourceCard(composer: composer)
        VoiceOutputVoiceCard(composer: composer)
      }

      VoiceOutputControlsCard(composer: composer)
      VoiceOutputTextCard(composer: composer)

      if tts.lastResult != nil || tts.lastError != nil {
        VoiceOutputResultCard()
      }
    }
  }
}
