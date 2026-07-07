#if os(iOS)
import AVFoundation
import Foundation

/// Manages iOS audio session configuration for recording and transcription.
@MainActor
public final class AudioSessionManager: ObservableObject {
    @Published private(set) public var isConfigured = false
    @Published private(set) public var currentRoute: String = "Unknown"
    @Published private(set) public var lastError: Error?

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?

    public var onInterruption: ((Bool) -> Void)?
    public var onRouteChange: (() -> Void)?

    public init() {
        setupNotificationObservers()
    }

    deinit {
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Configure audio session for recording with speech recognition.
    ///
    /// The two configuration calls are attempted separately so a failure can be
    /// attributed to the exact step, and both throw an
    /// ``AudioSessionConfigurationError`` carrying the decoded `OSStatus` code
    /// plus a snapshot of the live session state.
    public func configureForRecording() async throws {
        let session = AVAudioSession.sharedInstance()

        do {
            // Preferred: an isolated (non-mixable) measurement session for the
            // cleanest capture.
            try configureCategory(on: session, mixWithOthers: false)
            try await activate(session)
        } catch let error as AudioSessionConfigurationError
            where error.operation == .setActive
            && AudioSessionActivation.isCannotInterruptOthers(error.underlying) {
            // A `cannotInterruptOthers` rejection is how the system refuses a
            // *non-mixable* session that tries to go active from the background
            // (Action Button / Shortcuts / Siri). Retrying the identical
            // activation cannot clear it, so re-configure as a *mixable* session
            // and try once more — mixable sessions are allowed to activate from
            // the background because they don't interrupt other audio.
            try configureCategory(on: session, mixWithOthers: true)
            try await activate(session)
        }

        lastError = nil
        isConfigured = true
        updateCurrentRoute()

        let inputRoute = Self.routeDescription(ports: session.currentRoute.inputs)
        print("[AudioSessionManager] Configured for recording: \(inputRoute)")
    }

    /// Recording options common to both the isolated and mixable configurations.
    /// `allowBluetooth` enables headsets, `defaultToSpeaker` improves UX, and the
    /// A2DP variant keeps high-quality Bluetooth output available.
    private static let baseRecordingOptions: AVAudioSession.CategoryOptions =
        [.allowBluetooth, .defaultToSpeaker, .allowBluetoothA2DP]

    /// Applies the `playAndRecord`/`measurement` category, optionally adding
    /// `mixWithOthers` so the session can activate from the background without
    /// interrupting other audio.
    private func configureCategory(on session: AVAudioSession, mixWithOthers: Bool) throws {
        var options = Self.baseRecordingOptions
        if mixWithOthers { options.insert(.mixWithOthers) }
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: options)
        } catch {
            throw configurationFailure(.setCategory, error, session)
        }
    }

    /// Activates the session, retrying transient `cannotInterruptOthers` failures
    /// with a short back-off before surfacing a diagnostic error.
    private func activate(_ session: AVAudioSession) async throws {
        do {
            try await AudioSessionActivation.activate {
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            }
        } catch {
            throw configurationFailure(.setActive, error, session)
        }
    }

    /// Builds a diagnostic error for a failed configuration step, snapshotting
    /// the live session state so production failures are traceable from logs.
    private func configurationFailure(
        _ operation: AudioSessionConfigurationError.Operation,
        _ error: Error,
        _ session: AVAudioSession
    ) -> AudioSessionConfigurationError {
        let failure = AudioSessionConfigurationError(
            operation: operation,
            underlying: error as NSError,
            diagnostics: Self.diagnostics(for: session)
        )
        lastError = failure
        isConfigured = false
        return failure
    }

    /// Snapshots the current audio session state into a transferable value.
    static func diagnostics(for session: AVAudioSession) -> AudioSessionDiagnostics {
        AudioSessionDiagnostics(
            category: session.category.rawValue,
            mode: session.mode.rawValue,
            options: describe(options: session.categoryOptions),
            isOtherAudioPlaying: session.isOtherAudioPlaying,
            inputRoute: routeDescription(ports: session.currentRoute.inputs),
            outputRoute: routeDescription(ports: session.currentRoute.outputs)
        )
    }

    /// Describes the audio route using stable, non-localised `portType`
    /// identifiers (e.g. `MicrophoneBuiltIn`, `BluetoothHFP`, `Speaker`) rather
    /// than `portName`, which can leak personal device names (e.g. a user's
    /// AirPods) into logs and is localised.
    private static func routeDescription(ports: [AVAudioSessionPortDescription]) -> String {
        ports.isEmpty ? "none" : ports.map(\.portType.rawValue).joined(separator: "+")
    }

    private static func describe(options: AVAudioSession.CategoryOptions) -> String {
        var names: [String] = []
        if options.contains(.mixWithOthers) { names.append("mixWithOthers") }
        if options.contains(.duckOthers) { names.append("duckOthers") }
        if options.contains(.allowBluetooth) { names.append("allowBluetooth") }
        if options.contains(.defaultToSpeaker) { names.append("defaultToSpeaker") }
        if options.contains(.interruptSpokenAudioAndMixWithOthers) {
            names.append("interruptSpokenAudioAndMixWithOthers")
        }
        if options.contains(.allowBluetoothA2DP) { names.append("allowBluetoothA2DP") }
        if options.contains(.allowAirPlay) { names.append("allowAirPlay") }
        if #available(iOS 14.5, *), options.contains(.overrideMutedMicrophoneInterruption) {
            names.append("overrideMutedMicrophoneInterruption")
        }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    /// Deactivate audio session when done recording.
    public func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            isConfigured = false
            print("[AudioSessionManager] Deactivated")
        } catch {
            print("[AudioSessionManager] Failed to deactivate: \(error.localizedDescription)")
        }
    }

    /// Check if microphone permission is granted.
    public func hasMicrophonePermission() -> Bool {
        AVAudioSession.sharedInstance().recordPermission == .granted
    }

    /// Request microphone permission.
    public func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    // MARK: - Private

    private func setupNotificationObservers() {
        // Interruption observer (phone calls, Siri, etc.)
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        // Route change observer (headphones plugged/unplugged, Bluetooth changes)
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }

        switch type {
        case .began:
            print("[AudioSessionManager] Interruption began")
            onInterruption?(true)

        case .ended:
            print("[AudioSessionManager] Interruption ended")
            // Check if we should resume
            if let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                if options.contains(.shouldResume) {
                    print("[AudioSessionManager] Should resume after interruption")
                }
            }
            onInterruption?(false)

        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }

        print("[AudioSessionManager] Route changed: \(reason)")
        updateCurrentRoute()
        onRouteChange?()
    }

    private func updateCurrentRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        if let input = route.inputs.first {
            currentRoute = input.portName
        } else {
            currentRoute = "No input"
        }
    }
}
#endif
