import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

extension WindowsHostPlatform {
    package static var comparisonDigest: LocalModelDigestProvider? { WindowsSHA256Hasher.provider }
}

func comparisonWindowEvent(
    _ event: Int32, _ text: UnsafePointer<CChar>?, _ index: Int32, _ context: UnsafeMutableRawPointer?
) {
    guard (100...109).contains(event) || (120...129).contains(event), let context else {
        windowEvent(event, text, index, context)
        return
    }
    guard let holder = NativeCallbackContext<WindowsEventContext>.resolve(context) else { return }
    let controller = holder.controller
    let value = text.map(String.init(cString:)) ?? ""
    holder.enqueueSettings { await controller.enqueueComparisonEvent(event, text: value, index: index) }
}
