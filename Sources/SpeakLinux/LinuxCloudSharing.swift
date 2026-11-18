import Foundation
import SpeakDesktop
import SpeakDesktopHost
import CLinuxSupport

extension LinuxHostPlatform {
    package static func requestCloudSharingConsent(id: UUID, prompt: DesktopCloudSharingPrompt) throws {
        let strings = DesktopNativeStrings()
        let native = cloudSharingRows(prompt.entries, strings: strings)
        let result = withExtendedLifetime(strings) {
            native.withUnsafeBufferPointer {
                jsti_window_request_cloud_sharing(
                    id.uuidString, prompt.title, prompt.intro, $0.baseAddress, $0.count, prompt.allowTitle,
                    prompt.notNowTitle
                )
            }
        }
        guard result == 0 else { throw DesktopHostError(message: "Could not show the cloud sharing question.") }
    }

    package static func presentCloudSharing(_ presentation: DesktopCloudSharingPresentation) {
        let strings = DesktopNativeStrings()
        let native = cloudSharingRows(presentation.entries, strings: strings)
        let result = withExtendedLifetime(strings) {
            native.withUnsafeBufferPointer {
                jsti_window_set_cloud_sharing(
                    presentation.title, presentation.footer, presentation.emptyText, $0.baseAddress, $0.count
                )
            }
        }
        if result != 0 { update("The AI provider privacy settings could not be refreshed.") }
    }

    private static func cloudSharingRows(
        _ entries: [DesktopCloudSharingEntry], strings: DesktopNativeStrings
    ) -> [JSTICloudSharingRow] {
        entries.map {
            JSTICloudSharingRow(
                identifier: strings.add($0.providerID), name: strings.add($0.name), detail: strings.add($0.detail),
                policy_url: strings.add($0.privacyPolicyURL), withdraw_label: strings.add($0.withdrawLabel)
            )
        }
    }
}
