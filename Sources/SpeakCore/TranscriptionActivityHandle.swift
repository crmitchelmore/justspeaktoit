#if os(iOS)
import ActivityKit
import Foundation

/// A narrow ActivityKit boundary lets lifecycle races be exercised without system UI.
@MainActor
protocol TranscriptionActivityHandle: AnyObject {
    var nativeActivity: Activity<TranscriptionActivityAttributes>? { get }
    var id: String { get }
    var activityState: ActivityState { get }
    var supportsUpdateTimestamps: Bool { get }
    var transcriptionState: TranscriptionActivityAttributes.ContentState { get }
    func updateTranscription(_ state: TranscriptionActivityAttributes.ContentState, timestamp: Date) async
    func endTranscription(_ state: TranscriptionActivityAttributes.ContentState?, timestamp: Date) async
    func observeState(_ handler: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never>
}

extension Activity: TranscriptionActivityHandle where Attributes == TranscriptionActivityAttributes {
    var nativeActivity: Activity<TranscriptionActivityAttributes>? { self }
    var transcriptionState: TranscriptionActivityAttributes.ContentState { content.state }
    var supportsUpdateTimestamps: Bool {
        if #available(iOS 17.2, *) { return true }
        return false
    }

    func updateTranscription(_ state: TranscriptionActivityAttributes.ContentState, timestamp: Date) async {
        if #available(iOS 17.2, *) {
            // ActivityKit ignores a payload older than its last accepted update.
            await update(.init(state: state, staleDate: nil), timestamp: timestamp)
        } else {
            await update(.init(state: state, staleDate: nil))
        }
    }

    func endTranscription(_ state: TranscriptionActivityAttributes.ContentState?, timestamp: Date) async {
        let content = state.map { ActivityContent(state: $0, staleDate: nil) }
        // A final state is a result row: keep it on screen for the row's window.
        let policy: ActivityUIDismissalPolicy = state == nil
            ? .immediate
            : .after(.now + TranscriptionActivityManager.resultRowDuration)
        if #available(iOS 17.2, *) {
            await end(content, dismissalPolicy: policy, timestamp: timestamp)
        } else {
            await end(content, dismissalPolicy: policy)
        }
    }

    func observeState(_ handler: @escaping @MainActor (ActivityState) -> Void) -> Task<Void, Never> {
        Task {
            for await state in activityStateUpdates {
                guard !Task.isCancelled else { return }
                handler(state)
            }
        }
    }
}
#endif
