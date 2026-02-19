#if os(iOS)
import SwiftUI
import SpeakCore

// MARK: - OpenClaw Chat View

/// Main voice chat interface for OpenClaw conversations.
public struct OpenClawChatView: View {
    @StateObject private var coordinator = OpenClawChatCoordinator()
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var settings = OpenClawSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var textInput = ""
    @State private var showingSettings = false

    /// When set, the view opens this existing conversation. When nil, creates a new one.
    private let initialConversation: OpenClawClient.Conversation?

    public init(conversation: OpenClawClient.Conversation? = nil) {
        self.initialConversation = conversation
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let conv = coordinator.currentConversation {
                            ForEach(conv.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }

                        // Streaming response
                        if !coordinator.streamingResponse.isEmpty {
                            MessageBubble(
                                message: .init(
                                    role: "assistant",
                                    content: coordinator.streamingResponse
                                )
                            )
                            .id("streaming")
                        }

                        // Recording indicator
                        if coordinator.isRecording {
                            RecordingIndicator(
                                partialText: coordinator.partialTranscript,
                                showAcknowledgeHint: settings.conversationModeEnabled
                            )
                                .id("recording")
                        }

                        // Processing indicator
                        if coordinator.isProcessing && coordinator.streamingResponse.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Thinking…")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .id("processing")
                        }
                    }
                    .padding()
                }
                .onChange(of: coordinator.currentConversation?.messages.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(coordinator.currentConversation?.messages.last?.id, anchor: .bottom)
                    }
                }
                .onChange(of: coordinator.streamingResponse) { _, _ in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard settings.conversationModeEnabled,
                          coordinator.isRecording || coordinator.isSpeaking else { return }
                    Task {
                        await coordinator.handleAcknowledgeSignal()
                    }
                }
            }

            Divider()

            // Input area
            VStack(spacing: 0) {
                conversationModeBar
                inputBar
            }
        }
        .navigationTitle(coordinator.currentConversation?.title ?? "OpenClaw")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                connectionBadge
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    coordinator.startNewConversation()
                } label: {
                    Image(systemName: "plus.message")
                }
                .accessibilityLabel("New Conversation")
            }
        }
        .onAppear {
            if coordinator.currentConversation == nil {
                if let conv = initialConversation {
                    coordinator.selectConversation(conv)
                } else {
                    coordinator.startNewConversation()
                    // Only connect here if startNewConversation didn't
                    // already trigger a reconnect.
                    if settings.isConfigured {
                        coordinator.connect()
                    }
                }
            }
            Task {
                await coordinator.conversationModeChanged(isEnabled: settings.conversationModeEnabled)
            }
        }
        .onDisappear {
            coordinator.stopAllAndDisconnect()
        }
        .onChange(of: settings.conversationModeEnabled) { _, isEnabled in
            Task {
                await coordinator.conversationModeChanged(isEnabled: isEnabled)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // App backgrounded while in a conversation — start Live Activity
                coordinator.startLiveActivityIfNeeded()
            case .active:
                // App returned — end the Live Activity (UI is visible)
                coordinator.endLiveActivity()
            default:
                break
            }
        }
        .alert("Error", isPresented: .init(
            get: { coordinator.error != nil },
            set: { if !$0 { coordinator.error = nil } }
        )) {
            Button("OK") { coordinator.error = nil }
        } message: {
            Text(coordinator.error?.localizedDescription ?? "Unknown error")
        }
    }

    // MARK: - Input Bar

    @ViewBuilder
    private var conversationModeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $settings.conversationModeEnabled) {
                Label("Conversation Mode", systemImage: "waveform.badge.mic")
                    .font(.subheadline.weight(.semibold))
            }
            .toggleStyle(.switch)
            .tint(.accentColor)
            .frame(minHeight: 44)

            if settings.conversationModeEnabled {
                Text("Tap the chat area to acknowledge")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var inputBar: some View {
        HStack(spacing: 12) {
            // Text field
            TextField("Type a message…", text: $textInput, axis: .vertical)
                .font(.body)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 50)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.28), lineWidth: 1)
                )
                .submitLabel(.send)
                .onSubmit {
                    sendTextIfNeeded()
                }

            // Voice button
            Button {
                Task {
                    if coordinator.isRecording {
                        await coordinator.stopVoiceInputAndSend()
                    } else {
                        try? await coordinator.startVoiceInput()
                    }
                }
            } label: {
                Image(systemName: coordinator.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(coordinator.isRecording ? .red : Color.accentColor)
                    .frame(width: 52, height: 52)
            }
            .accessibilityLabel(coordinator.isRecording ? "Stop recording" : "Start voice input")

            // Send button (only when text entered)
            if !textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    sendTextIfNeeded()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 52, height: 52)
                }
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Send message")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .animation(.spring(response: 0.2), value: textInput.isEmpty)
    }

    // MARK: - Connection Badge

    @ViewBuilder
    private var connectionBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)
            if coordinator.isSpeaking {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var connectionColor: Color {
        switch coordinator.connectionState {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }

    // MARK: - Actions

    private func sendTextIfNeeded() {
        let text = textInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        textInput = ""
        Task {
            await coordinator.sendTextMessage(text)
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: OpenClawClient.ChatMessage

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .foregroundStyle(isUser ? .white : .primary)
                    .textSelection(.enabled)

                Text(message.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(isUser ? .white.opacity(0.7) : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isUser ? Color.accentColor : Color(.systemGray5),
                in: RoundedRectangle(cornerRadius: 18)
            )

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Recording Indicator

struct RecordingIndicator: View {
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
                Text("Tap the chat area, use headset tap, or say your keyword to send.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal)
        .onAppear {
            pulseScale = 1.3
        }
    }
}

#Preview {
    NavigationStack {
        OpenClawChatView()
    }
}
#endif
