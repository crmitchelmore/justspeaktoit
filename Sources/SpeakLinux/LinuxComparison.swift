import CLinuxSupport
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform

extension LinuxHostPlatform {
    package static var comparisonDigest: LocalModelDigestProvider? { LinuxSHA256Hasher.provider }
}
