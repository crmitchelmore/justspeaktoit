import Foundation

/// Immutable synthesis controls. Hosts retain unsupported stored choices, but
/// must validate them against the actual route before reading credentials.
public struct VoiceSynthesisOptions: Codable, Equatable, Sendable {
    public static let speedRange: ClosedRange<Double> = 0.5...2
    public static let pitchRange: ClosedRange<Double> = -12...12
    public static let defaultSpeed = 1.0
    public static let defaultPitch = 0.0
    public static let defaultUseSSML = false

    public let speed: Double
    public let pitch: Double
    public let useSSML: Bool

    public init(
        speed: Double = VoiceSynthesisOptions.defaultSpeed,
        pitch: Double = VoiceSynthesisOptions.defaultPitch,
        useSSML: Bool = VoiceSynthesisOptions.defaultUseSSML
    ) throws {
        guard speed.isFinite, Self.speedRange.contains(speed),
              pitch.isFinite, Self.pitchRange.contains(pitch), pitch.rounded() == pitch else {
            throw VoiceSynthesisConfigurationError.invalidControls
        }
        self.speed = speed
        self.pitch = pitch
        self.useSSML = useSSML
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                speed: values.decode(Double.self, forKey: .speed),
                pitch: values.decode(Double.self, forKey: .pitch),
                useSSML: values.decode(Bool.self, forKey: .useSSML)
            )
        } catch let error as VoiceSynthesisConfigurationError {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: error.localizedDescription))
        }
    }

    public func validate(for capabilities: VoiceSynthesisCapabilities) throws {
        guard capabilities.speed || speed == Self.defaultSpeed, capabilities.pitch || pitch == Self.defaultPitch,
              capabilities.ssml || !useSSML else {
            throw VoiceSynthesisConfigurationError.unsupportedControls
        }
        guard !capabilities.speed || capabilities.speedRange.contains(speed) else {
            throw VoiceSynthesisConfigurationError.unsupportedSpeed(
                minimum: capabilities.speedRange.lowerBound, maximum: capabilities.speedRange.upperBound)
        }
    }
}

public struct VoiceSynthesisCapabilities: Equatable, Sendable {
    public let speed: Bool
    public let pitch: Bool
    public let ssml: Bool
    public let speedRange: ClosedRange<Double>
    public var nativeFlags: Int32 { (speed ? 1 : 0) | (pitch ? 2 : 0) | (ssml ? 4 : 0) }

    public init(
        speed: Bool, pitch: Bool, ssml: Bool,
        speedRange: ClosedRange<Double> = VoiceSynthesisOptions.speedRange
    ) {
        self.speed = speed
        self.pitch = pitch
        self.ssml = ssml
        self.speedRange = speedRange
    }

    public static let naturalSpeech = Self(speed: false, pitch: false, ssml: false)
    public static let azureNeural = Self(speed: true, pitch: true, ssml: true)
    public static let azureMAI = Self(speed: false, pitch: false, ssml: true)
    public static let xai = Self(speed: true, pitch: false, ssml: false, speedRange: XAITTSAPI.speedRange)
    public static let cartesia = Self(speed: true, pitch: false, ssml: false, speedRange: CartesiaTTSAPI.speedRange)
    public static let openai = Self(speed: true, pitch: false, ssml: false)
}

public enum VoiceSynthesisConfigurationError: LocalizedError, Equatable {
    case invalidControls
    case unsupportedControls
    case unsupportedVoice
    case unsupportedSpeed(minimum: Double, maximum: Double)

    public var errorDescription: String? {
        switch self {
        case .invalidControls:
            "Choose speed between 0.5 and 2, and a whole-number pitch between -12 and 12 semitones."
        case .unsupportedControls:
            "This voice cannot apply the saved speed, pitch or SSML choices. "
                + "Choose a compatible voice or normal controls."
        case .unsupportedVoice:
            "The stored voice is not available on this host. "
                + "Choose an executable voice; stored choices are unchanged."
        case .unsupportedSpeed(let minimum, let maximum):
            "This voice supports speed between \(minimum) and \(maximum). "
                + "Choose a supported speed or normal controls; stored choices are unchanged."
        }
    }
}
