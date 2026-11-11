import SpeakCore
import SwiftUI

struct SSMLHelperView: View {
  @Binding var text: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("SSML Helper")
        .font(.title2.bold())

      Text(
        "Wrap your text with SSML tags for advanced control. Common tags:"
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(VoiceSynthesisMarkup.examples, id: \.text) { example in
            ssmlExample(example.text, description: example.description)
          }
        }
      }
      .frame(height: 200)

      HStack {
        Button("Close") {
          dismiss()
        }
        .buttonStyle(.bordered)
        .keyboardShortcut(.cancelAction)

        Spacer()

        Button("Wrap with <speak>") {
          text = VoiceSynthesisMarkup.wrapping(text)
          dismiss()
        }
        .buttonStyle(.borderedProminent)
      }
    }
    .padding(24)
    .frame(width: 500)
  }

  private func ssmlExample(_ tag: String, description: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text(tag)
        .font(.system(.caption, design: .monospaced))
        .padding(6)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(4)

      Text(description)
        .font(.caption)
        .foregroundStyle(.secondary)

      Spacer()

      CopyButton(presentation: .titleOnly) {
        CopyFeedback.writeToPasteboard(tag)
      }
      .buttonStyle(.borderless)
      .controlSize(.mini)
    }
  }
}
