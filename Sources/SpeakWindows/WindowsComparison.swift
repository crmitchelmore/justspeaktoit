import Foundation
import CWindowsSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakWindowsPlatform

extension WindowsHostPlatform {
    package static var comparisonDigest: LocalModelDigestProvider? { WindowsSHA256Hasher.provider }
}
