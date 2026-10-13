import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

extension WindowsHostPlatform {
    package static var comparisonDigest: LocalModelDigestProvider? { WindowsSHA256Hasher.provider }

    package static func comparisonPresentation(_ presentation: DesktopComparisonPresentation) {
        let result = jsti_comparison_present(
            presentation.models, presentation.rounds, presentation.detail, presentation.selected,
            presentation.busy ? 1 : 0, presentation.recording ? 1 : 0, presentation.judgeable ? 1 : 0
        )
        if result != 0 { WindowsNative.update("Comparison window is no longer open; results remain saved.") }
    }
}

func comparisonWindowEvent(
    _ event: Int32, _ text: UnsafePointer<CChar>?, _ index: Int32, _ context: UnsafeMutableRawPointer?
) {
    guard (100...109).contains(event) || (120...129).contains(event), let context else {
        windowEvent(event, text, index, context)
        return
    }
    let holder = Unmanaged<WindowsEventContext>.fromOpaque(context).takeUnretainedValue()
    let controller = holder.controller
    let value = text.map(String.init(cString:)) ?? ""
    holder.enqueueSettings { await controller.comparisonEvent(event, text: value, index: index) }
}
