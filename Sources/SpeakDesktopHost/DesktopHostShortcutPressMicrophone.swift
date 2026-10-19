import Foundation
import SpeakCore
import SpeakDesktop

/// Opens the microphone when a hold or double-tap shortcut is pressed, before
/// the gesture resolves, so the driver and endpoint are already running when
/// the recording capture opens. Like macOS, the press capture is closed when
/// recording starts or after a short safety timeout when the press resolves
/// to no recording. Unlike macOS, its audio is never handed to the recording:
/// every frame is discarded as it arrives, so nothing is stored or sent.
extension DesktopHostController {
    var shortcutPressMicrophoneEligible: Bool {
        guard !closed, isReady, settings.configuration?.warmMicrophoneOnKeyPress ?? true,
              !busy, activeOperations == 0, recording == nil, handsFreeRun == nil,
              ownedCaptureStartup == nil, ownedDictation == nil, ownedDictationAdmission == nil
        else { return false }
        return true
    }

    /// The macOS bound: long enough for a hold or a double tap to resolve.
    static func shortcutPressMicrophoneTimeout(hold: Double, doubleTap: Double) -> Double {
        max(2.5, hold + 2 * doubleTap + 1)
    }

    /// Called at a hold or double-tap key-down; press-to-toggle starts at once
    /// and gains nothing. `deviceID` nil uses the saved microphone.
    package func warmMicrophoneForShortcutPress(deviceID: String? = nil) {
        guard shortcutPressMicrophone == nil, shortcutPressMicrophoneEligible else { return }
        let context = DesktopCaptureContext(onPCM: { _, _ in }, onFailure: { _ in })
        let capture: any DesktopRecordingCapture
        do {
            capture = try effects.makeCapture(
                context: context, deviceID: deviceID ?? settings.microphoneDeviceID ?? "",
                sampleRate: PCMRecordingFile.sampleRate, frameMilliseconds: 100
            )
        } catch { return }
        do { try capture.start() } catch {
            capture.destroy()
            return
        }
        let id = UUID()
        shortcutPressMicrophone = (id, capture)
        let configuration = settings.configuration
        let timeout = Self.shortcutPressMicrophoneTimeout(
            hold: configuration?.number("holdThreshold") ?? HotKeyGestureTiming.defaultHoldThreshold,
            doubleTap: configuration?.number("doubleTapWindow") ?? HotKeyGestureTiming.defaultDoubleTapWindow
        )
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.endShortcutPressMicrophone(id: id)
        }
    }

    /// Ends the press capture; with an `id`, only that press's capture.
    func endShortcutPressMicrophone(id: UUID? = nil) {
        guard let current = shortcutPressMicrophone, id == nil || current.id == id else { return }
        shortcutPressMicrophone = nil
        try? current.capture.stop()
        current.capture.destroy()
    }
}
