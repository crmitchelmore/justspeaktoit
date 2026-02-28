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

#Preview {
    NavigationStack {
        ConversationListView()
    }
}
#endif
