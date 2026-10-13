import CLinuxSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform

extension LinuxHostPlatform {
    package static var comparisonDigest: LocalModelDigestProvider? { LinuxSHA256Hasher.provider }

    package static func comparisonPresentation(_ presentation: DesktopComparisonPresentation) {
        let result = jsti_comparison_present(
            presentation.models, presentation.rounds, presentation.detail, presentation.selected,
            presentation.busy ? 1 : 0, presentation.recording ? 1 : 0, presentation.judgeable ? 1 : 0,
            presentation.sync.enabled ? 1 : 0, presentation.sync.available ? 1 : 0
        )
        if result != 0 { update("Comparison window is no longer open; results remain saved.") }
    }
}
