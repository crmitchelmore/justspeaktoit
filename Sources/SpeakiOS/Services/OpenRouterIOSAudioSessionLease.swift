#if os(iOS)
import AVFoundation
import Foundation

/// Shared only by the OpenRouter file and progressive playback adapters.
/// Prior activation is unknown: neither a borrower nor this lease deactivates it.
@MainActor
struct OpenRouterIOSAudioSessionLease {
    struct Configuration: Equatable {
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions

        init(session: AVAudioSession) {
            category = session.category
            mode = session.mode
            options = session.categoryOptions
        }

        init(category: AVAudioSession.Category, mode: AVAudioSession.Mode, options: AVAudioSession.CategoryOptions) {
            self.category = category
            self.mode = mode
            self.options = options
        }
    }

    struct Access {
        let configuration: () -> Configuration
        let install: (Configuration) throws -> Void

        static var live: Self {
            let session = AVAudioSession.sharedInstance()
            return Self(configuration: { Configuration(session: session) }, install: {
                try session.setCategory($0.category, mode: $0.mode, options: $0.options)
            })
        }
    }

    let previous: Configuration
    let installed: Configuration
    private let access: Access

    static func acquire(using access: Access = .live) throws -> Self? {
        let previous = access.configuration()
        switch previous.category {
        case .playAndRecord, .multiRoute:
            return nil
        case .record:
            throw OpenRouterIOSVoiceOutputError.recordingInProgress
        default:
            let installed = Configuration(category: .playback, mode: .spokenAudio, options: [.mixWithOthers])
            try access.install(installed)
            return Self(previous: previous, installed: installed, access: access)
        }
    }

    func restoreIfUnchanged() {
        guard access.configuration() == installed else { return }
        try? access.install(previous)
    }

    nonisolated static func interruptsPlayback(_ notice: Notification) -> Bool {
        switch notice.name {
        case AVAudioSession.interruptionNotification:
            (notice.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                == AVAudioSession.InterruptionType.began.rawValue
        case AVAudioSession.routeChangeNotification:
            (notice.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        default:
            true
        }
    }
}
#endif
