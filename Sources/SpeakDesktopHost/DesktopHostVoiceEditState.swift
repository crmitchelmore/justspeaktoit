import Foundation
import SpeakCore
import SpeakDesktop

package enum DesktopHostVoiceEditDelivery: Sendable {
    case replaced(String)
    case recovery(String)

    var status: String {
        switch self {
        case .replaced(let message), .recovery(let message): return message
        }
    }

    var presentation: DesktopHUDState {
        switch self {
        case .replaced(let message): return .success(message)
        case .recovery(let message): return .failure(message, headline: "Check voice edit")
        }
    }
}

package struct DesktopHostVoiceEditSource: Sendable {
    let executablePath: String?
    let capture: @Sendable () async throws -> String
    let replace: @Sendable (String) async throws -> DesktopHostVoiceEditDelivery
    let cancel: @Sendable () -> Void

    package init(
        executablePath: String?, capture: @escaping @Sendable () async throws -> String,
        replace: @escaping @Sendable (String) async throws -> DesktopHostVoiceEditDelivery,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.executablePath = executablePath
        self.capture = capture
        self.replace = replace
        self.cancel = cancel
    }
}

struct DesktopHostVoiceEditState {
    var active: DesktopHostVoiceEditRun?
    var workers = 0
    var waiters: [CheckedContinuation<Void, Never>] = []
}

/// Mutable run state is confined to its owning DesktopHostController actor.
final class DesktopHostVoiceEditRun: @unchecked Sendable {
    enum Phase { case preparing, listening, processing, retired }
    let id = UUID()
    let source: DesktopHostVoiceEditSource
    let profile: DesktopProfileSession
    let configuration: DesktopConfiguration?
    let rewriteModel: String
    let temperature: Double
    var phase = Phase.preparing
    var task: Task<Void, Never>?
    var selection = ""
    var key = ""
    var transcriptionKey = ""
    var endpoint = ""
    var keywords: [String] = []
    var heldModel: String?
    var scratch: URL?
    var file: PCMRecordingFile?
    var capture: (any DesktopRecordingCapture)?
    var live: DesktopLiveSession?
    var stopping: Task<TimeInterval, Error>?
    var retirement: Task<Void, Never>?
    var retirementStatus: String?
    var retirementHUD: DesktopHUDState?
    var workers = 0
    var busyHeld = true

    init(
        source: DesktopHostVoiceEditSource, profile: DesktopProfileSession,
        configuration: DesktopConfiguration?, processing: DesktopPostProcessing.Options
    ) {
        self.source = source
        self.profile = profile
        self.configuration = configuration
        rewriteModel = VoiceEditPolicy.modelIdentifier(configured: processing.modelIdentifier)
        temperature = processing.temperature
    }
}

private final class DesktopVoiceEditClosingAudio: @unchecked Sendable {
    let capture: any DesktopRecordingCapture
    let file: PCMRecordingFile
    init(capture: any DesktopRecordingCapture, file: PCMRecordingFile) {
        self.capture = capture
        self.file = file
    }
    func finish() async throws -> TimeInterval {
        try await Task.detached {
            try DesktopHostRecordingStop.stop(self.capture, file: self.file)
        }.value
    }
}

extension DesktopHostController {
    func stopVoiceEditAudio(_ run: DesktopHostVoiceEditRun) async throws -> TimeInterval {
        if let stopping = run.stopping { return try await stopping.value }
        guard let file = run.file else { return 0 }
        let stopping: Task<TimeInterval, Error>
        if let capture = run.capture {
            run.capture = nil
            let audio = DesktopVoiceEditClosingAudio(capture: capture, file: file)
            stopping = Task { try await audio.finish() }
        } else {
            stopping = Task { try file.finish() }
        }
        run.stopping = stopping
        return try await stopping.value
    }
}
