import AppKit
import Foundation

#if canImport(AppKit)
@available(macOS 10.12.2, *)
extension NSTouchBarItem.Identifier {
    static let speakRecord = NSTouchBarItem.Identifier("com.speak.touchbar.record")
    static let speakPlayPause = NSTouchBarItem.Identifier("com.speak.touchbar.playpause")
    static let speakVoiceSwitch = NSTouchBarItem.Identifier("com.speak.touchbar.voice")
}

/// Provides Touch Bar support for Speak.
@available(macOS 10.12.2, *)
@MainActor
final class TouchBarProvider: NSObject, NSTouchBarDelegate {
    private weak var mainManager: MainManager?
    private weak var ttsManager: TextToSpeechManager?
    private weak var appSettings: AppSettings?

    init(mainManager: MainManager, ttsManager: TextToSpeechManager, appSettings: AppSettings) {
        self.mainManager = mainManager
        self.ttsManager = ttsManager
        self.appSettings = appSettings
        super.init()
    }

    func makeTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.defaultItemIdentifiers = [
            .speakRecord,
            .speakPlayPause,
            .flexibleSpace,
            .speakVoiceSwitch
        ]
        return touchBar
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        switch identifier {
        case .speakRecord:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(
                image: NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Record")!,
                target: self,
                action: #selector(recordTapped)
            )
            button.bezelColor = .systemRed
            item.view = button
            item.customizationLabel = "Record"
            return item

        case .speakPlayPause:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(
                image: NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play/Pause")!,
                target: self,
                action: #selector(playPauseTapped)
            )
            item.view = button
            item.customizationLabel = "Play/Pause"
            return item

        case .speakVoiceSwitch:
            let item = NSPopoverTouchBarItem(identifier: identifier)
            item.collapsedRepresentationImage = NSImage(
                systemSymbolName: "person.wave.2",
                accessibilityDescription: "Voice"
            )
            item.customizationLabel = "Voice"

            let popoverBar = NSTouchBar()
            popoverBar.delegate = self
            popoverBar.defaultItemIdentifiers = [.init("voice1"), .init("voice2"), .init("voice3")]
            item.popoverTouchBar = popoverBar

            return item

        default:
            if identifier.rawValue.starts(with: "voice") {
                let item = NSCustomTouchBarItem(identifier: identifier)
                let voiceNumber = identifier.rawValue.replacingOccurrences(of: "voice", with: "")
                let button = NSButton(
                    title: "Voice \(voiceNumber)",
                    target: self,
                    action: #selector(voiceTapped(_:))
                )
                button.tag = Int(voiceNumber) ?? 1
                item.view = button
                return item
            }
            return nil
        }
    }

    @objc private func recordTapped() {
        mainManager?.toggleRecordingFromUI()
    }

    @objc private func playPauseTapped() {
        guard let ttsManager else { return }
        if ttsManager.isPlaying {
            ttsManager.pause()
        } else {
            ttsManager.resume()
        }
    }

    @objc private func voiceTapped(_ sender: NSButton) {
        guard let appSettings else { return }
        let favorites = appSettings.ttsFavoriteVoices
        let index = sender.tag - 1
        if index < favorites.count {
            appSettings.defaultTTSVoice = favorites[index]
        }
    }
}
#endif
