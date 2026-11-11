import Combine
import Foundation

/// Persists `CaptureOnboardingState` and publishes it to the UI.
///
/// All the decisions live in `CaptureOnboardingPolicy`; this type only loads,
/// applies and saves. Every mutation goes through a policy function, so the
/// store cannot invent progress the rules would not allow.
@MainActor
public final class CaptureOnboardingStore: ObservableObject {
    public static let shared = CaptureOnboardingStore()

    static let storageKey = "captureOnboarding.state.v1"

    @Published public private(set) var state: CaptureOnboardingState

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.state = Self.load(from: defaults)
    }

    /// Folds a finished dictation in. Safe to call for every completion: a
    /// blank transcript is ignored by the policy.
    public func recordDictation(trigger: CaptureTrigger, transcript: String) {
        self.apply(CaptureOnboardingPolicy.recordingDictation(self.state, trigger: trigger, transcript: transcript))
    }

    public func completeFirstRun() {
        self.apply(CaptureOnboardingPolicy.completingFirstRun(self.state))
    }

    public func dismissCard(_ trigger: CaptureTrigger) {
        self.apply(CaptureOnboardingPolicy.dismissingCard(self.state, trigger: trigger))
    }

    public func offeredCard(hardware: CaptureHardwareProfile) -> CaptureTrigger? {
        CaptureOnboardingPolicy.offeredCard(state: self.state, hardware: hardware)
    }

    public var shouldPresentFirstRun: Bool {
        CaptureOnboardingPolicy.shouldPresentFirstRun(state: self.state)
    }

    private func apply(_ next: CaptureOnboardingState) {
        guard next != self.state else { return }
        self.state = next
        guard let data = try? JSONEncoder().encode(next) else { return }
        self.defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> CaptureOnboardingState {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(CaptureOnboardingState.self, from: data)
        else {
            return CaptureOnboardingState()
        }
        return decoded
    }
}
