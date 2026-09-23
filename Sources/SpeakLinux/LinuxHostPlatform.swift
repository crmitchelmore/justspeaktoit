import Foundation
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

typealias LinuxAppController = DesktopHostController<LinuxHostPlatform>

/// The shortcut the desktop shows for dictation. Persisted only as an
/// activation style for now; the key itself is chosen by the desktop (portal)
/// or fixed at Ctrl+Alt+Space (X11).
struct LinuxHotKeySettings: Codable, Equatable, Sendable {
    var style: String = HotKeyActivationStyle.pressToToggle.rawValue
}

/// Read aloud is not implemented on Linux yet; the setting stays absent.
struct LinuxVoiceOutputSettings: Codable, Equatable, Sendable {}

/// GTK 4/libadwaita, the Secret Service, libpulse and the X11 or portal
/// output paths behind the shared desktop host.
enum LinuxHostPlatform: DesktopHostPlatform {
    typealias VoiceOutputSettings = LinuxVoiceOutputSettings

    package static let displayName = "Linux"
    package static let credentialStoreName = "the desktop keyring (Secret Service)"

    /// Facts discovered at startup that output planning needs.
    private final class Runtime: @unchecked Sendable {
        let lock = NSLock()
        var session = LinuxDesktopSession()
        var remoteDesktopAvailable = false
        var shortcut = "the dictation shortcut"
    }
    private static let runtime = Runtime()

    static func configure(session: LinuxDesktopSession, remoteDesktopAvailable: Bool) {
        runtime.lock.withLock {
            runtime.session = session
            runtime.remoteDesktopAvailable = remoteDesktopAvailable
        }
    }

    static var session: LinuxDesktopSession { runtime.lock.withLock { runtime.session } }

    /// What the status line calls the shortcut, e.g. "Ctrl+Alt+Space".
    static var shortcutName: String {
        get { runtime.lock.withLock { runtime.shortcut } }
        set { runtime.lock.withLock { runtime.shortcut = newValue } }
    }

    // MARK: Window presenter

    package static func update(_ status: String, transcript: String?, state: Int32) {
        _ = jsti_window_update(status, transcript, state)
    }

    package static func recordingState(_ state: Int32) { _ = jsti_window_update(nil, nil, state) }

    package static func history(_ records: [DesktopRecordingStore.Record], selected: UUID?, selectRecord: Bool) {
        LinuxWindow.history(records, selected: selected, selectRecord: selectRecord)
    }

    package static func historyPresentation(
        _ record: DesktopRecordingStore.Record, variant: DesktopTranscriptVariant, status: String
    ) {
        let effective: Int32 = record.hasTranscriptVariants && variant == .processed ? 0 : 1
        let selected: Int32 = record.result == nil ? -1 : effective
        _ = jsti_window_set_history_presentation(
            record.id.uuidString, selected, record.hasTranscriptVariants ? 1 : 0, record.text(for: variant) ?? "",
            status
        )
    }

    package static func transcriptVariant(_ variant: DesktopTranscriptVariant?, for record: UUID?, switchable: Bool) {
        let selected: Int32 = variant.map { $0 == .original ? 1 : 0 } ?? -1
        _ = jsti_window_set_transcript_variant(record?.uuidString ?? "", selected, switchable ? 1 : 0)
    }

    package static func publishModels(status: String, refreshing: Bool) throws {
        try LinuxWindow.publishModels(status: status, refreshing: refreshing, selected: -1)
    }

    // MARK: Credentials, files and audio

    package static func apiKey(name: String) throws -> String { try LinuxCredentialStore.read(name: name) }

    package static func saveAPIKey(_ key: String, name: String) throws { try LinuxCredentialStore.save(key, name: name) }

    package static func uploadStaging(directory: URL) -> SharedMultipartUploadStaging {
        SharedMultipartUploadStaging(
            directory: directory,
            securityPolicy: .init(
                prepareDirectory: { url, _ in try LinuxFiles.preparePrivateDirectory(url) },
                createFile: { url, _ in
                    try LinuxFiles.createPrivateFile(url)
                    return true
                }
            )
        )
    }

    package static func preparePrivateDirectory(_ directory: URL) throws {
        try LinuxFiles.preparePrivateDirectory(directory)
    }

    package static func convertAudio(input: URL, output: URL) async throws -> TimeInterval {
        throw DesktopHostError(
            message: "This model needs 16 kHz WAV audio, and converting other imported formats is not available on "
                + "Linux yet. Import a 16 kHz mono WAV file or choose another model."
        )
    }

    package static func openFile(_ url: URL) throws { try LinuxFiles.open(url) }

    package static func copyToClipboard(_ text: String) throws { try LinuxClipboard.write(text) }

    // MARK: Output and playback

    package static func makeOutputJob(
        options: LinuxTextOutputOptions, target: LinuxInsertionTarget?
    ) -> LinuxOutputJob? {
        let (session, portal) = runtime.lock.withLock { (runtime.session, runtime.remoteDesktopAvailable) }
        guard let plan = LinuxOutputPlan.make(
            options: options, target: target, session: session, portalAvailable: portal
        ) else { return nil }
        return LinuxOutputJob(plan: plan, native: LinuxOutputNativeAdapter())
    }

    package static func cancel(_ job: LinuxOutputJob) { job.cancel() }

    package static func isClipboard(_ job: LinuxOutputJob) -> Bool { job.plan.isClipboard }

    package static func makePlayback() -> LinuxUnavailablePlayback { LinuxUnavailablePlayback() }

    package static func makeReadAloudState() {}

    package static func stopReadAloud(_ state: inout Void) {}

    // MARK: Shortcut text

    package static var defaultHotKey: LinuxHotKeySettings { LinuxHotKeySettings() }

    package static func readyHint(_ hotKey: LinuxHotKeySettings) -> String {
        "\(shortcutName) starts or stops recording."
    }

    package static func finishHint(_ hotKey: LinuxHotKeySettings, for trigger: HotKeySessionTrigger) -> String {
        switch trigger {
        case .other: return "Select Stop recording or press \(shortcutName) to finish."
        default: return "Press \(shortcutName) to finish."
        }
    }
}

/// History playback is not implemented on Linux yet: Open audio uses the
/// desktop's default player instead.
final class LinuxUnavailablePlayback: DesktopHostPlayback, @unchecked Sendable {
    package func setStatusHandler(_ handler: @escaping @Sendable (UInt64, String) -> Void) {}
    package func isCurrent(revision: UInt64) -> Bool { false }
    package func play(recordID: UUID, path: String, knownDuration: TimeInterval?) throws {
        throw DesktopHostError(message: "In-app playback is not available on Linux yet. Use Open audio.")
    }
    package func togglePause(recordID: UUID) -> Bool { false }
    package func stop() {}
    package func stop(unless recordID: UUID) {}
    package func stopAndWait() async throws {}
    package func close() async throws {}
}
