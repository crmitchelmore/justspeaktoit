#if os(iOS)
import Combine
import Foundation

public enum HomeScreenQuickAction {
    public static let transcribe = "com.justspeaktoit.ios.quickaction.transcribe"
}

@MainActor
public final class HomeScreenQuickActionState: ObservableObject {
    public static let shared = HomeScreenQuickActionState()

    @Published public private(set) var triggerCount = 0
    private var pendingTranscribeAction = false

    private init() {}

    public func queueTranscribeAction() {
        pendingTranscribeAction = true
        triggerCount += 1
    }

    public func consumePendingTranscribeAction() -> Bool {
        guard pendingTranscribeAction else { return false }
        pendingTranscribeAction = false
        return true
    }
}
#endif
