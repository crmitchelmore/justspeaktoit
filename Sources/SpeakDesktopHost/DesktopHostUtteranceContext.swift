import Foundation
import SpeakCore
import SpeakDesktop

package struct DesktopHostRecordingConfiguration: Sendable {
    package let configuration: DesktopConfiguration?
    package let azureEndpoint: String
    package let sampleRate: Int
}

/// App identity and insertion destination belong to the same utterance.
package struct DesktopHostUtteranceContext<Target: Sendable>: Sendable {
    package let target: Target?
    package let executablePath: String?
    package let profileNotice: String?

    package init(target: Target?, executablePath: String?, profileNotice: String? = nil) {
        self.target = target
        self.executablePath = executablePath
        self.profileNotice = profileNotice
    }
}
