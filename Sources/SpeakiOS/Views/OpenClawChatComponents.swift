#if os(iOS)
import SpeakCore
import SwiftUI

struct MessageBubble: View {
    @Environment(\.appVisualDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let message: OpenClawClient.ChatMessage

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: density.isCompact ? 20 : 60) }

            Group {
                if density.prefersInlineLayout(dynamicTypeSize: dynamicTypeSize) {
                    HStack(alignment: .lastTextBaseline, spacing: density.inlineSpacing) {
                        messageText
                        timestampText
                    }
                } else {
                    VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                        messageText
                        timestampText
                    }
                }
            }
            .padding(.horizontal, density.isCompact ? 8 : 14)
            .padding(.vertical, density.isCompact ? 4 : 10)
            .background(
                isUser ? Color.accentColor : Color(.systemGray5),
                in: RoundedRectangle(cornerRadius: density.isCompact ? 10 : 18)
            )

            if !isUser { Spacer(minLength: density.isCompact ? 20 : 60) }
        }
    }

    private var messageText: some View {
        Text(message.content)
            .font(density.isCompact ? .subheadline : .body)
            .foregroundStyle(isUser ? .white : .primary)
            .textSelection(.enabled)
    }

    private var timestampText: some View {
        Text(message.timestamp, style: .time)
            .font(.caption2)
            .foregroundStyle(isUser ? .white.opacity(0.7) : .secondary)
    }
}

struct RecordingIndicator: View {
    @Environment(\.appVisualDensity) private var density
    let partialText: String
    let showAcknowledgeHint: Bool
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Circle()
                    .fill(.red)
                    .frame(width: 12, height: 12)
                    .scaleEffect(pulseScale)
                    .animation(
                        .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: pulseScale
                    )

                if partialText.isEmpty {
                    Text("Listening…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(partialText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if showAcknowledgeHint {
                Text(
                    density.isCompact
                        ? "Tap chat, headset, or keyword to send."
                        : "Tap the chat area, use headset tap, or say your keyword to send."
                )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(density.isCompact ? 1 : nil)
            }
        }
        .padding(.horizontal, density.isCompact ? density.pagePadding : 16)
        .onAppear {
            pulseScale = 1.3
        }
    }
}
#endif
