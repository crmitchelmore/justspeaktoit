import SpeakCore
import SwiftUI

// MARK: - Pronunciation Entry Helper

struct PronunciationEntryView: View {
  @Binding var dictionary: [String: String]
  @State private var newWord = ""
  @State private var newPronunciation = ""

  var body: some View {
    HStack(spacing: 8) {
      TextField("Word", text: $newWord)
        .textFieldStyle(.roundedBorder)
        .frame(width: 120)

      Text("→")
        .foregroundStyle(.secondary)

      TextField("Pronunciation", text: $newPronunciation)
        .textFieldStyle(.roundedBorder)
        .frame(width: 150)

      Button("Add") {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let pronunciation = newPronunciation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, !pronunciation.isEmpty else { return }
        dictionary[word] = pronunciation
        newWord = ""
        newPronunciation = ""
      }
      .buttonStyle(.bordered)
      .disabled(newWord.isEmpty || newPronunciation.isEmpty)
    }

    Text("Example: \"GIF\" → \"jif\" or \"API\" → \"A P I\"")
      .font(.caption2)
      .foregroundStyle(.tertiary)
  }
}
