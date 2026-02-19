#if os(iOS)
import ActivityKit
import Foundation
import SpeakCore

// MARK: - OpenClaw Activity Attributes

/// ActivityKit attributes for OpenClaw voice conversation sessions.
/// Shows recording state and conversation info on the lock screen / Dynamic Island.
public struct OpenClawActivityAttributes: ActivityAttributes {

    /// Dynamic content updated during the activity.
    public struct ContentState: Codable, Hashable {
        /// Current conversation status
        public var status: ConversationStatus
        /// Conversation title (first ~60 chars)
        public var title: String
        /// Number of messages exchanged
        public var messageCount: Int
        /// Duration in seconds
        public var duration: Int

        public init(
            status: ConversationStatus = .recording,
            title: String = "OpenClaw",
            messageCount: Int = 0,
            duration: Int = 0
        ) {
            self.status = status
            self.title = title
            self.messageCount = messageCount
            self.duration = duration
        }
    }

    /// Conversation status
    public enum ConversationStatus: String, Codable, Hashable {
        case recording
        case processing
        case speaking
        case idle
        case ended
    }

    /// Session identifier
    public var sessionId: String
    /// Start time of the session
    public var startTime: Date

    public init(
        sessionId: String = UUID().uuidString,
        startTime: Date = Date()
    ) {
        self.sessionId = sessionId
        self.startTime = startTime
    }
}

// MARK: - OpenClaw Activity Manager

/// Manages the Live Activity lifecycle for OpenClaw voice conversations.
@MainActor
public final class OpenClawActivityManager: ObservableObject {
    @Published public private(set) var currentActivity: Activity<OpenClawActivityAttributes>?
    @Published public private(set) var isActivityRunning = false

    private var lastUpdateTime: Date = .distantPast
    private let minimumUpdateInterval: TimeInterval = 1.0

    public init() {}

    /// Starts a Live Activity for an OpenClaw conversation session.
    public func startActivity(title: String, messageCount: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        endActivity()

        let attributes = OpenClawActivityAttributes()
        let initialState = OpenClawActivityAttributes.ContentState(
            status: .recording,
            title: String(title.prefix(60)),
            messageCount: messageCount
        )

        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initialState, staleDate: nil),
                pushType: nil
            )
            currentActivity = activity
            isActivityRunning = true
        } catch {
            print("[OpenClawActivityManager] Failed to start activity: \(error)")
        }
    }

    /// Updates the Live Activity state.
    public func updateActivity(
        status: OpenClawActivityAttributes.ConversationStatus,
        title: String,
        messageCount: Int,
        duration: Int
    ) {
        guard let activity = currentActivity else { return }

        let now = Date()
        guard now.timeIntervalSince(lastUpdateTime) >= minimumUpdateInterval else { return }
        lastUpdateTime = now

        let state = OpenClawActivityAttributes.ContentState(
            status: status,
            title: String(title.prefix(60)),
            messageCount: messageCount,
            duration: duration
        )

        Task {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    /// Ends the current activity immediately.
    public func endActivity() {
        guard let activity = currentActivity else { return }

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
            await MainActor.run {
                currentActivity = nil
                isActivityRunning = false
            }
        }
    }

    /// Marks the activity as ended with a brief dismissal delay.
    public func completeActivity(messageCount: Int, duration: Int) {
        guard let activity = currentActivity else { return }

        let finalState = OpenClawActivityAttributes.ContentState(
            status: .ended,
            title: activity.content.state.title,
            messageCount: messageCount,
            duration: duration
        )

        Task {
            await activity.end(
                .init(state: finalState, staleDate: nil),
                dismissalPolicy: .after(.now + 5)
            )
            await MainActor.run {
                currentActivity = nil
                isActivityRunning = false
            }
        }
    }
}
#endif
