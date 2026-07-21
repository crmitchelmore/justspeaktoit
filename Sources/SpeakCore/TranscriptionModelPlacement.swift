import Foundation

/// Shared catalogue projections used by both platform settings UIs.
///
/// `liveTranscription` remains the complete routing catalogue. These projections
/// decide where a model is presented, so adding another `apple/...` live model
/// automatically places it under Local without duplicating platform-specific lists.
public extension ModelCatalog {
    static var onDeviceLiveTranscription: [Option] {
        liveTranscription.filter { ModelRouting.family(for: $0.id) == .appleSpeech }
    }

    static var remoteLiveTranscription: [Option] {
        liveTranscription.filter { ModelRouting.family(for: $0.id) != .appleSpeech }
    }

    static var defaultOnDeviceLiveTranscriptionModel: String {
        onDeviceLiveTranscription.first?.id ?? "apple/local/SFSpeechRecognizer"
    }

    static var defaultRemoteLiveTranscriptionModel: String? {
        remoteLiveTranscription.first?.id
    }

    static func isOnDeviceLiveTranscriptionModel(_ identifier: String) -> Bool {
        ModelRouting.family(for: identifier) == .appleSpeech
    }
}
