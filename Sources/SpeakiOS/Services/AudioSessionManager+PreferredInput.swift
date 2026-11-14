#if os(iOS)
import AVFoundation
import SpeakCore
import UIKit
import os.log

private let logger = SpeakLogger.logger(category: "PreferredAudioInput")

/// What happened to the saved microphone choice on the latest recording,
/// shared by every ``AudioSessionManager`` so the recording screen can say
/// when it fell back to the system route.
@MainActor
final class PreferredAudioInputStatus: ObservableObject {
    struct Fallback: Equatable {
        let uid: String
        let notice: String
    }

    static let shared = PreferredAudioInputStatus()

    @Published private(set) var fallback: Fallback?

    /// The notice to show, while the saved choice is still the one that was missing.
    func notice(forSavedUID uid: String?) -> String? {
        guard let fallback, fallback.uid == uid else { return nil }
        return fallback.notice
    }

    func update(_ resolution: PreferredAudioInputResolution, currentInputName: String?) {
        guard case .unavailable(let uid) = resolution else {
            fallback = nil
            return
        }
        let next = Fallback(
            uid: uid,
            notice: PreferredAudioInputResolution.fallbackNotice(currentInputName: currentInputName)
        )
        guard next != fallback else { return }
        fallback = next
        UIAccessibility.post(notification: .announcement, argument: next.notice)
    }
}

extension AudioSessionManager {
    /// The saved microphone UID; replaceable so tests need no shared settings.
    static var savedPreferredInputUID: @MainActor () -> String? = { AppSettings.shared.preferredAudioInputUID }

    /// Prefers the saved microphone on the active recording session, or the
    /// system route when none is saved or it is not connected.
    ///
    /// `setPreferredInput` is valid only once the category is set and the
    /// session is active, and it changes the route asynchronously, so this
    /// waits briefly for the route to settle: the capture engine must read its
    /// input format from the new route, or its first configuration change
    /// would stop the recording as a microphone change.
    func applyPreferredInput(on session: AVAudioSession) async {
        // Keyboard readiness may be recording on this mixable session; a
        // route change under it would stop that capture.
        if Self.activeSessionHold?() == true, session.categoryOptions.contains(.mixWithOthers) { return }
        let inputs = session.availableInputs ?? []
        let resolution = PreferredAudioInputResolution(
            storedUID: Self.savedPreferredInputUID(),
            availableUIDs: inputs.map(\.uid)
        )
        let target = resolution.uidToApply.flatMap { uid in inputs.first { $0.uid == uid } }
        if session.preferredInput?.uid != target?.uid {
            do {
                try session.setPreferredInput(target)
            } catch {
                logger.error("Preferred input not applied: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let target { await waitForInputRoute(target.uid, on: session) }
        publishPreferredInputStatus(resolution, session: session)
    }

    /// Re-checks the saved choice after a route change, so a microphone that
    /// disconnects mid-recording shows the fallback notice.
    func refreshPreferredInputStatus() {
        guard isConfigured, configureRecording == nil else { return }
        let session = AVAudioSession.sharedInstance()
        let resolution = PreferredAudioInputResolution(
            storedUID: Self.savedPreferredInputUID(),
            availableUIDs: (session.availableInputs ?? []).map(\.uid)
        )
        publishPreferredInputStatus(resolution, session: session)
    }

    private func publishPreferredInputStatus(_ resolution: PreferredAudioInputResolution, session: AVAudioSession) {
        if resolution.isFallback {
            let route = session.currentRoute.inputs.map(\.portType.rawValue).joined(separator: "+")
            logger.info("Saved input not connected; using \(route, privacy: .public)")
        }
        PreferredAudioInputStatus.shared.update(
            resolution,
            currentInputName: session.currentRoute.inputs.first?.portName
        )
    }

    private func waitForInputRoute(_ uid: String, on session: AVAudioSession) async {
        for _ in 0..<10 {
            if session.currentRoute.inputs.contains(where: { $0.uid == uid }) { return }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
        }
        logger.info("Preferred input route did not settle within 500 ms")
    }
}
#endif
