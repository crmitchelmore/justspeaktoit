import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform
import CWindowsSupport

// The shared desktop host specialised for Windows. The names predate the
// shared SpeakDesktopHost target and keep Windows call sites unchanged.
typealias WindowsAppController = DesktopHostController<WindowsHostPlatform>
typealias WindowsControllerEffects = DesktopHostEffects
typealias WindowsRecordingCapture = DesktopRecordingCapture
typealias WindowsCaptureContext = DesktopCaptureContext
typealias WindowsTranscriptionRequest = DesktopHostTranscriptionRequest
typealias WindowsRecordingOutput = DesktopHostRecordingOutput<WindowsHostPlatform>
typealias WindowsNativeError = DesktopHostError

/// Win32 window, Credential Manager, WASAPI, Media Foundation and UI Automation
/// behind the shared desktop host.
enum WindowsHostPlatform: DesktopHostPlatform {
    typealias VoiceOutputSettings = WindowsVoiceOutputSettings

    package static let displayName = "Windows"
    package static let credentialStoreName = "Windows Credential Manager"

    package static func update(_ status: String, transcript: String?, state: Int32) {
        WindowsNative.update(status, transcript: transcript, state: state)
    }

    package static func recordingState(_ state: Int32) { WindowsNative.recordingState(state) }

    package static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool) {
        WindowsNative.history(records, selected: selected, selectRecord: selectRecord)
    }

    package static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    ) {
        WindowsNative.historyPresentation(record, variant: variant, status: status)
    }

    package static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool) {
        WindowsNative.transcriptVariant(variant, for: record, switchable: switchable)
    }

    package static func publishModels(status: String, refreshing: Bool) throws {
        try WindowsModels.publish(status: status, refreshing: refreshing)
    }

    package static func apiKey(name: String) throws -> String { try WindowsNative.apiKey(name: name) }

    package static func saveAPIKey(_ key: String, name: String) throws { try WindowsNative.saveAPIKey(key, name: name) }

    package static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        WindowsNative.uploadStaging(directory: directory)
    }

    package static func preparePrivateDirectory(_ directory: URL) throws {
        try directory.path.withCString { path in
            try WindowsNative.checked { jsti_private_directory_prepare(path, $0, $1) }
        }
    }

    package static func convertAudio(input: URL, output: URL) async throws -> TimeInterval {
        try await WindowsAudioConversion.convert(input: input, output: output).duration
    }

    package static func openFile(_ url: URL) throws {
        try url.path.withCString { path in
            try WindowsNative.checked { jsti_shell_open_file(path, $0, $1) }
        }
    }

    package static func copyToClipboard(_ text: String) throws {
        try text.withCString { text in
            try WindowsNative.checked { jsti_clipboard_write(text, $0, $1) }
        }
    }

    /// Clipboard-only copies without a destination; otherwise insertion only
    /// ever targets the field captured at the recording hotkey.
    package static func makeOutputJob(
        options: WindowsTextOutputOptions, target: WindowsInsertionTarget?
    ) -> WindowsOutputJob? {
        if options.method == .clipboardOnly {
            guard let clipboard = try? WindowsClipboardOutput() else { return nil }
            return .clipboard(clipboard)
        }
        return target.map { .insertion($0, options) }
    }

    package static func cancel(_ job: WindowsOutputJob) { job.cancel() }

    package static func isClipboard(_ job: WindowsOutputJob) -> Bool {
        if case .clipboard = job { return true }
        return false
    }

    package static func makeReadAloudState() -> WindowsReadAloudState { WindowsReadAloudState() }

    package static func stopReadAloud(_ state: inout WindowsReadAloudState) {
        state.task?.cancel()
        state.task = nil
    }

    package static var defaultHotKey: WindowsHotKeySettings { WindowsHotKeySettings() }

    package static func readyHint(_ hotKey: WindowsHotKeySettings) -> String { hotKey.readyHint }

    package static func finishHint(_ hotKey: WindowsHotKeySettings, for trigger: HotKeySessionTrigger) -> String {
        hotKey.finishHint(for: trigger)
    }

    package static func makePlayback() -> WindowsAudioPlaybackController {
        WindowsAudioPlaybackController(
            backend: WindowsAudioPlaybackNativeBackend(),
            presenter: WindowsAudioPlaybackPresenter(show: { WindowsNative.playback($0) }, status: { _ in })
        )
    }
}

extension WindowsAppController {
    init(directory: URL) throws {
        try self.init(directory: directory, effects: WindowsNativeEffects())
    }
}

extension WindowsAudioPlaybackController: DesktopHostPlayback {
    package func setStatusHandler(_ handler: @escaping @Sendable (_ revision: UInt64, _ message: String) -> Void) {
        setPresenter(WindowsAudioPlaybackPresenter(
            show: { WindowsNative.playback($0) },
            status: { handler($0.revision, $0.message) }
        ))
    }
}

extension WindowsNative {
    /// Record-bound playback display into the native latest-only mailbox. Safe
    /// from any thread; the window ignores reports for an unselected record.
    static func playback(_ display: WindowsAudioPlaybackDisplay) {
        let result = display.recordID.uuidString.withCString { record in
            display.text.withCString { jsti_window_set_playback(record, display.state.rawValue, $0) }
        }
        if result != 0 { update("The playback controls could not be refreshed.") }
    }
}
