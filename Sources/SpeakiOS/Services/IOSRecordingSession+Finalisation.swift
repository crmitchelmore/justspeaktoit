#if os(iOS)
import Foundation

extension IOSRecordingSession {
    var stopCompletionTimeout: TimeInterval { 10 }
}

extension IOSTranscriptionSession {
    var stopCompletionTimeout: TimeInterval {
        guard case .shared(let transcriber) = backend else { return 10 }
        return transcriber.stopCompletionTimeout
    }

}
#endif
