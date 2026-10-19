import Foundation
import SpeakCore

/// A prepared, idle capture route. Preparation never opens the microphone:
/// no stream starts, no audio is read and no privacy indicator appears.
package protocol DesktopCapturePreparation: AnyObject, Sendable {
    /// False once the bounded lifetime has ended or the endpoint was unavailable.
    var isActive: Bool { get }
    /// May block while the preparation worker ends; never called on the controller.
    func release()
}

extension DesktopHostController {
    /// Each idle period may hold one preparation for at most ten minutes.
    static var capturePreparationLifetimeMilliseconds: UInt32 { 600_000 }

    var capturePreparationEnabled: Bool {
        !closed && (settings.configuration?.audioPreWarmingEnabled ?? true)
    }

    var capturePreparationEligible: Bool {
        guard capturePreparationEnabled, isReady, !busy, activeOperations == 0, recording == nil,
              handsFreeRun == nil, ownedCaptureStartup == nil, ownedDictation == nil,
              ownedDictationAdmission == nil else { return false }
        return true
    }

    /// Runs on idle transitions and after invalidation. Keeps a live
    /// preparation for the same device; an ended lifetime is renewed only by
    /// a later idle transition, never by a timer.
    func reconcileCapturePreparation() {
        let deviceID = settings.microphoneDeviceID ?? ""
        if let current = capturePreparation, current.deviceID == deviceID, current.value.isActive,
           capturePreparationEnabled {
            return
        }
        releaseCapturePreparation()
        guard capturePreparationEligible else { return }
        guard let prepared = effects.prepareCaptureWhileIdle(
            deviceID: deviceID, lifetimeMilliseconds: Self.capturePreparationLifetimeMilliseconds
        ) else { return }
        capturePreparation = (deviceID, prepared)
    }

    /// Device, settings, credential or shutdown changes discard the prepared route.
    func refreshCapturePreparation() {
        releaseCapturePreparation()
        reconcileCapturePreparation()
    }

    func releaseCapturePreparation() {
        guard let prepared = capturePreparation?.value else { return }
        capturePreparation = nil
        Task.detached(priority: .utility) { prepared.release() }
    }
}
