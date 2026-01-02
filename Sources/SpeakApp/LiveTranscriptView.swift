import SwiftUI

/// A reusable scrolling transcript display that shows live transcription with support for
/// interim (in-progress) vs final text, auto-scrolling, and smooth text updates.
struct LiveTranscriptView: View {
    let finalText: String
    let interimText: String
    let maxHeight: CGFloat
    let showStats: Bool

    @State private var scrollProxy: ScrollViewProxy?

    init(
        finalText: String,
        interimText: String = "",
        maxHeight: CGFloat = 200,
        showStats: Bool = true
    ) {
        self.finalText = finalText
        self.interimText = interimText
        self.maxHeight = maxHeight
        self.showStats = showStats
    }

    private var fullText: String {
        if interimText.isEmpty {
            return finalText
        }
        if finalText.isEmpty {
            return interimText
        }
        return finalText + " " + interimText
    }

    private var wordCount: Int {
        fullText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private var characterCount: Int {
        fullText.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        transcriptContent
                            .id("transcriptBottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: maxHeight)
                .onChange(of: fullText) { _ in
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("transcriptBottom", anchor: .bottom)
                    }
                }
                .onAppear {
                    proxy.scrollTo("transcriptBottom", anchor: .bottom)
                }
            }

            if showStats && !fullText.isEmpty {
                statsView
            }
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if fullText.isEmpty {
            Text("Listening...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .italic()
        } else {
            // Use Text with attributed string for different styling
            Group {
                if interimText.isEmpty {
                    Text(finalText)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                } else if finalText.isEmpty {
                    Text(interimText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(finalText)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    + Text(" ")
                    + Text(interimText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .italic()
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var statsView: some View {
        HStack(spacing: 12) {
            Label("\(wordCount) words", systemImage: "text.word.spacing")
            Label("\(characterCount) chars", systemImage: "character.cursor.ibeam")
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Preview

struct LiveTranscriptView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            // Empty state
            LiveTranscriptView(finalText: "", interimText: "")
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))

            // Only interim text
            LiveTranscriptView(finalText: "", interimText: "This is being spoken...")
                .padding()
                .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))

            // Final + interim
            LiveTranscriptView(
                finalText: "Hello, this is a completed sentence.",
                interimText: "And this is still being"
            )
            .padding()
            .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))

            // Long text
            LiveTranscriptView(
                finalText: String(repeating: "This is a long transcript that should scroll. ", count: 10),
                interimText: "Still speaking..."
            )
            .padding()
            .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
        }
        .padding()
        .frame(width: 400)
    }
}
