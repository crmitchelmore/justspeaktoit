import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

extension DesktopHostController {
    /// A controller for a computer whose user already allowed every catalogued cloud provider, so tests of
    /// recording, post-processing, voice and comparison reach the send they exercise. Tests of the consent
    /// prompt itself construct the controller directly, which starts with nothing allowed.
    static func consented(
        directory: URL, effects: any DesktopHostEffects<Platform>, shutdownGrace: Duration = DesktopHostShutdown.grace,
        ownedDictationCapability: DesktopHostOwnedDictationCapability? = nil
    ) throws -> DesktopHostController<Platform> {
        let url = directory.appendingPathComponent(DesktopCloudSharingConsentStore.fileName)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var consent = CloudSharingConsent()
            consent.grant(CloudSharingProviderCatalogue.all.map {
                CloudSharingRequest(provider: $0, kinds: Set(CloudSharedDataKind.allCases))
            })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(consent).write(to: url)
        }
        return try DesktopHostController<Platform>(
            directory: directory, effects: effects, shutdownGrace: shutdownGrace,
            ownedDictationCapability: ownedDictationCapability)
    }
}
