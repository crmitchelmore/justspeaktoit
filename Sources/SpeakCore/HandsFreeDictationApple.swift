import Foundation

extension HandsFreeDictationMachine.Failure {
    public init(_ error: Error) {
        guard let modelError = error as? AppleLocalModelError else {
            self = .captureFailed
            return
        }
        switch modelError {
        case .speechDetectorUnavailable, .speechDetectorFailed, .speechTranscriberUnavailable:
            self = .detectorUnavailable
        case .localeUnsupported:
            self = .localeUnsupported
        case .modelAssetsUnavailable:
            self = .assetsUnavailable
        case .compatibleAudioFormatUnavailable:
            self = .audioUnavailable
        case .foundationModelUnavailable, .emptyTranscript:
            self = .captureFailed
        }
    }

    public var message: String {
        switch self {
        case .detectorUnavailable:
            return "Hands-free dictation needs Apple's on-device speech detector, "
                + "which isn't available on this device."
        case .assetsUnavailable:
            return "Hands-free dictation couldn't install Apple's on-device speech models."
        case .localeUnsupported:
            return "Hands-free dictation doesn't support this language on this device."
        case .audioUnavailable:
            return "Hands-free dictation couldn't access the microphone."
        case .captureFailed:
            return "Hands-free dictation stopped because the recording session failed."
        case .unsupportedConfiguration:
            return "Hands-free dictation requires an Apple on-device streaming model."
        }
    }
}

extension HandsFreeDictationPolicy {
    public static let sensitivity: AppleSpeechDetectorSensitivity = .medium

    public static func supportsCapture(modelID: String, isStreaming: Bool) -> Bool {
        isStreaming && AppleLocalModels.isSpeechAnalyzerModel(modelID)
    }
}

extension HandsFreeDictationMachine {
    public mutating func handle(sessionError: Error) -> [Effect] {
        handle(.sessionFailed(Failure(sessionError)))
    }
}
