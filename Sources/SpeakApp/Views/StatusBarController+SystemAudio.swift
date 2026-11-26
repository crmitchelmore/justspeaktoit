import AppKit
import SpeakCore

extension StatusBarController {
    func addSystemAudioMenuItems(to menu: NSMenu) {
        guard #available(macOS 14.2, *), !isMainManagerBusy else { return }
        let systemItem = NSMenuItem(
            title: "Record System Audio",
            action: #selector(startSystemAudioRecording),
            keyEquivalent: ""
        )
        systemItem.target = self
        systemItem.setAccessibilityIdentifier("statusBarRecordSystemAudioItem")
        menu.addItem(systemItem)

        let bothItem = NSMenuItem(
            title: "Record Mic + System Audio",
            action: #selector(startBothAudioRecording),
            keyEquivalent: ""
        )
        bothItem.target = self
        bothItem.setAccessibilityIdentifier("statusBarRecordBothAudioItem")
        menu.addItem(bothItem)
    }

    @objc private func startSystemAudioRecording() {
        startRecording(captureSource: .system)
    }

    @objc private func startBothAudioRecording() {
        startRecording(captureSource: .both)
    }
}
