import SpeakCore

/// A plain value type that captures the current capture-health state for HUD display.
/// Owned by `HUDManager` and updated by `MainManager` on event-driven triggers.
struct CaptureHealthSnapshot: Equatable {
    enum MicrophonePermission: Equatable {
        case granted
        case denied
        case notDetermined

        var isGranted: Bool { self == .granted }
    }

    var microphonePermission: MicrophonePermission
    /// `true` when CoreAudio reports zero input devices with usable channels — e.g. a Mac Mini with no mic attached.
    var noInputDevicesAvailable: Bool
    var inputDeviceName: String
    var providerLabel: String
    var latencyTier: LatencyTier

    static let empty = CaptureHealthSnapshot(
        microphonePermission: .notDetermined,
        noInputDevicesAvailable: false,
        inputDeviceName: "Unknown",
        providerLabel: "Unknown",
        latencyTier: .medium
    )
}
