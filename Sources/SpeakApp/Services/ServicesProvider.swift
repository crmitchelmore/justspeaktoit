import AppKit
import Foundation

/// Registers Speak as a macOS Service for right-click menu integration.
@MainActor
final class ServicesProvider: NSObject {
    private weak var ttsManager: TextToSpeechManager?
    private weak var appSettings: AppSettings?

    init(ttsManager: TextToSpeechManager, appSettings: AppSettings) {
        self.ttsManager = ttsManager
        self.appSettings = appSettings
        super.init()
    }

    /// Registers the services with the system.
    func registerServices() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Service handler for "Speak with Speak".
    @objc func speakText(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>?
    ) {
        guard let text = pboard.string(forType: .string), !text.isEmpty else {
            error?.pointee = "No text selected" as NSString
            return
        }

        Task { @MainActor [weak self] in
            guard let self, let ttsManager else { return }
            do {
                _ = try await ttsManager.synthesize(text: text)
            } catch {
                // Error is handled by TTS manager
            }
        }
    }
}
