import Foundation

public enum RecordingFeedbackSound: String, CaseIterable, Sendable {
    case start
    case stop

    var resourceName: String { "recording_\(rawValue)" }
    var fileExtension: String { "m4a" }
}

/// One catalogue for Apple's player and the portable desktop feedback channel.
public enum RecordingFeedbackProfile: String, CaseIterable, Identifiable, Sendable {
    case classic
    case bubbly
    case futuristic
    case soft

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: return "Classic"
        case .bubbly: return "Bubbly"
        case .futuristic: return "Futuristic"
        case .soft: return "Soft"
        }
    }

    public func resourceName(for sound: RecordingFeedbackSound) -> String {
        self == .classic ? sound.resourceName : "\(sound.resourceName)_\(rawValue)"
    }

    public func filename(for sound: RecordingFeedbackSound) -> String {
        "\(resourceName(for: sound)).\(sound.fileExtension)"
    }
}

public enum RecordingFeedbackDefaults {
    public static let enabled = true
    public static let profile = RecordingFeedbackProfile.classic
    public static let volume = 0.7

    public static let filenames = RecordingFeedbackProfile.allCases.flatMap { profile in
        RecordingFeedbackSound.allCases.map { profile.filename(for: $0) }
    }

    /// Matches AVAudioPlayer's existing quiet-range volume curve.
    public static func gain(for volume: Float) -> Float {
        let linear = max(0, min(1, volume))
        return linear * linear
    }
}
