import Foundation

/// How a saved microphone choice applies to the inputs the device offers now.
///
/// iOS resolves `AVAudioSessionPortDescription.uid` values with this; macOS,
/// Windows and Linux resolve their own device lists. An empty or missing UID
/// means the system default.
public enum PreferredAudioInputResolution: Equatable, Sendable {
    /// No microphone chosen: follow the system route.
    case systemDefault
    /// The chosen microphone is connected and should be preferred.
    case selected(uid: String)
    /// The chosen microphone is not connected; the system route is used.
    case unavailable(uid: String)

    public init(storedUID: String?, availableUIDs: [String]) {
        guard let uid = storedUID, !uid.isEmpty else {
            self = .systemDefault
            return
        }
        self = availableUIDs.contains(uid) ? .selected(uid: uid) : .unavailable(uid: uid)
    }

    /// The input to request from the system, or `nil` for the system default.
    public var uidToApply: String? {
        if case .selected(let uid) = self { return uid }
        return nil
    }

    public var isFallback: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// Shown while recording when the chosen microphone is missing.
    public static func fallbackNotice(currentInputName: String?) -> String {
        let name = currentInputName.flatMap { $0.isEmpty ? nil : $0 }
        guard let name else {
            return "Your chosen microphone isn't connected, so the system default is used."
        }
        return "Your chosen microphone isn't connected, so \(name) is used."
    }
}

/// The kind of an audio input, from an `AVAudioSession.Port` raw value.
public enum AudioInputKind: String, Equatable, Sendable {
    case builtIn
    case wired
    case bluetooth
    case usb
    case lineIn
    case carAudio
    case other

    public init(portType: String) {
        switch portType {
        case "MicrophoneBuiltIn": self = .builtIn
        case "MicrophoneWired": self = .wired
        case "BluetoothHFP", "BluetoothLE": self = .bluetooth
        case "USBAudio": self = .usb
        case "LineIn": self = .lineIn
        case "CarAudio": self = .carAudio
        default: self = .other
        }
    }

    public var displayName: String {
        switch self {
        case .builtIn: "Built-in"
        case .wired: "Wired headset"
        case .bluetooth: "Bluetooth"
        case .usb: "USB"
        case .lineIn: "Line in"
        case .carAudio: "Car"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .builtIn: "mic"
        case .wired: "headphones"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .usb: "cable.connector"
        case .lineIn: "cable.connector.horizontal"
        case .carAudio: "car"
        case .other: "mic.circle"
        }
    }
}
