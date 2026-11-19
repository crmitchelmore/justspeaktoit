import Foundation
import SpeakCore

/// Throws `CloudSharingConsentRequiredError`, after asking the user, when any
/// of the requests lacks consent.
typealias CloudSharingConsentCheck = @MainActor ([CloudSharingRequest]) throws -> Void

/// The consent half of `SessionStartHost`.
@MainActor
protocol SessionStartConsentHost: AnyObject {
  /// Cloud AI providers this start would send content to without the user's
  /// permission (issue #1805); empty when the start may go ahead.
  func missingCloudSharingConsent() -> [CloudSharingRequest]
  /// Asks for that permission. Nothing was captured, so nothing is lost.
  func publishCloudSharingConsentRequired(_ requests: [CloudSharingRequest])
}

/// Explicit permission before the first send to each cloud AI provider
/// (App Store guideline 5.1.2(i), issue #1805). Starts are refused before
/// capture while permission is missing, so no recording is ever held hostage.
extension MainManager {
  func missingCloudSharingConsent() -> [CloudSharingRequest] {
    cloudSharingConsent.missing(appSettings.dictationCloudSharingRequests)
  }

  /// The check for sends outside a dictation start (file transcription,
  /// Voice Edit, read aloud): asks, and throws so nothing is uploaded. The
  /// caller's audio or text stays where it was for a retry.
  func requireCloudSharingConsent(_ requests: [CloudSharingRequest]) throws {
    let missing = cloudSharingConsent.missing(requests)
    guard !missing.isEmpty else { return }
    pendingCloudSharingRequests = CloudSharingConsent.merged(pendingCloudSharingRequests + missing)
    presentCloudSharingConsent?()
    throw CloudSharingConsentRequiredError(requests: missing)
  }

  func publishCloudSharingConsentRequired(_ requests: [CloudSharingRequest]) {
    let message = CloudSharingConsent.blockedMessage(for: requests)
    state = .failed(message)
    lastErrorMessage = message
    pendingCloudSharingRequests = requests
    presentCloudSharingConsent?()
  }

  /// Allow: records consent for exactly what was asked. The user starts again;
  /// nothing was captured while the sheet was up.
  func allowCloudSharing() {
    cloudSharingConsent.grant(pendingCloudSharingRequests)
    dismissCloudSharingConsent()
  }

  /// Use on-device instead: moves the cloud steps on device, records no consent.
  func useOnDeviceInsteadOfCloudSharing() {
    appSettings.moveCloudStepsOnDevice(pendingCloudSharingRequests)
    dismissCloudSharingConsent()
  }

  func dismissCloudSharingConsent() {
    let message = CloudSharingConsent.blockedMessage(for: pendingCloudSharingRequests)
    pendingCloudSharingRequests = []
    if state == .failed(message) {
      state = .idle
      lastErrorMessage = nil
    }
  }
}
