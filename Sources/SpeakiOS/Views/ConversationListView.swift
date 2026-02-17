#if os(iOS)
import SwiftUI
import SpeakCore

// MARK: - Conversation List View

/// Shows a list of OpenClaw conversations with the ability to create new ones.
public struct ConversationListView: View {
    @ObservedObject private var store = ConversationStore.shared
    @ObservedObject private var settings = OpenClawSettings.shared
    @State private var showingClearConfirmation = false

    public init() {}

    public var body: some View {
        Group {
            if !settings.isConfigured {
                unconfiguredState
            } else if store.conversations.isEmpty {
                emptyState
            } else {
                conversationList
            }
        }
        .navigationTitle("OpenClaw")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    NavigationLink {
                        OpenClawSettingsView()
                    } label: {
                        Image(systemName: "gear")
                    }

                    if !store.conversations.isEmpty {
                        Button(role: .destructive) {
                            showingClearConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .confirmationDialog(
            "Clear All Conversations",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) {
                store.clearAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete all \(store.conversations.count) conversations.")
        }
    }

    // MARK: - States

    private var unconfiguredState: some View {
        ContentUnavailableView {
            Label("Setup Required", systemImage: "bolt.horizontal.icloud")
        } description: {
            Text("Configure your OpenClaw gateway connection to start chatting.")
        } actions: {
            NavigationLink("Configure") {
                OpenClawSettingsView()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Start a new voice conversation with your AI assistant.")
        } actions: {
            NavigationLink("New Conversation") {
                OpenClawChatView(conversation: nil)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - List

    private var conversationList: some View {
        List {
            // New conversation button
            Section {
                NavigationLink {
                    OpenClawChatView(conversation: nil)
                } label: {
                    Label("New Conversation", systemImage: "plus.message")
                        .foregroundStyle(Color.accentColor)
                }
            }

            // Existing conversations
            Section("Recent") {
                ForEach(store.conversations) { conv in
                    NavigationLink {
                        OpenClawChatView(conversation: conv)
                    } label: {
                        ConversationRow(conversation: conv)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            store.deleteConversation(conv.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Conversation Row

struct ConversationRow: View {
    let conversation: OpenClawClient.Conversation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(conversation.title)
                    .font(.headline)
                    .lineLimit(1)

                Spacer()

                Text(conversation.updatedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let lastMessage = conversation.messages.last {
                Text(lastMessage.content)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            HStack {
                Label("\(conversation.messages.count)", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - OpenClaw Settings View

public struct OpenClawSettingsView: View {
    @ObservedObject private var settings = OpenClawSettings.shared
    @State private var tokenInput = ""
    @State private var urlInput = ""
    @State private var testState: OpenClawConnectionTester.Result = .idle

    public init() {}

    public var body: some View {
        Form {
            Section("Gateway Connection") {
                Toggle(isOn: $settings.enabled) {
                    Label("Enable OpenClaw", systemImage: "bolt.horizontal.icloud")
                }

                TextField("host:port or wss://hostname", text: $urlInput)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onAppear { urlInput = settings.gatewayURL }
                    .onChange(of: urlInput) { _, newValue in
                        settings.gatewayURL = newValue
                        testState = .idle
                    }

                Text("Enter host:port for local connections or a Tailscale/public hostname. "
                     + "The ws:// or wss:// prefix is added automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                SecureField("Gateway Token", text: $tokenInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .onAppear { tokenInput = settings.token.isEmpty ? "" : "••••••••" }

                if !tokenInput.isEmpty && tokenInput != "••••••••" {
                    Button("Save Token") {
                        settings.token = tokenInput
                        tokenInput = "••••••••"
                    }
                }

                // Test Connection
                Button {
                    if !tokenInput.isEmpty && tokenInput != "••••••••" {
                        settings.token = tokenInput
                        tokenInput = "••••••••"
                    }
                    Task { await testConnection() }
                } label: {
                    HStack {
                        switch testState {
                        case .idle:
                            Label("Test Connection", systemImage: "antenna.radiowaves.left.and.right")
                        case .testing:
                            ProgressView()
                                .controlSize(.small)
                            Text("Testing…")
                        case .success(let msg):
                            Label(msg, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure(let msg):
                            Label(msg, systemImage: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .disabled(settings.gatewayURL.isEmpty || settings.token.isEmpty || testState == .testing)

                // Status
                HStack {
                    Text("Status")
                    Spacer()
                    Text(settings.isConfigured ? "Configured" : "Not Configured")
                        .foregroundStyle(settings.isConfigured ? .green : .secondary)
                }
            }

            Section("Voice Output") {
                Toggle(isOn: $settings.ttsEnabled) {
                    Label("Read Responses Aloud", systemImage: "speaker.wave.2")
                }

                if settings.ttsEnabled {
                    Text("Responses will be spoken using Deepgram Aura TTS (requires Deepgram API key).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $settings.summariseResponses) {
                    Label("Summarise for Voice", systemImage: "text.quote")
                }

                if settings.summariseResponses {
                    Text(
                        "Long responses will be summarised into concise voice-friendly text "
                            + "before speaking (requires OpenRouter API key)."
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("How It Works") {
                VStack(alignment: .leading, spacing: 8) {
                    InfoStepRow(number: 1, text: "Tap the mic to record your voice message")
                    InfoStepRow(number: 2, text: "Your speech is transcribed using your selected model")
                    InfoStepRow(number: 3, text: "The text is sent to your OpenClaw agent")
                    InfoStepRow(number: 4, text: "The response is summarised and spoken back to you")
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("OpenClaw Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Connection Test

    private func testConnection() async {
        testState = .testing
        testState = await OpenClawConnectionTester.test(
            rawURL: settings.gatewayURL,
            token: settings.token
        )
    }
}

struct InfoStepRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: Circle())

            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack {
        ConversationListView()
    }
}

#Preview("Settings") {
    NavigationStack {
        OpenClawSettingsView()
    }
}
#endif
