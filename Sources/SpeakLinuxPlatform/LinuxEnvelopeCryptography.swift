import Foundation
import SpeakDesktopSync
import CLinuxSupport

public typealias LinuxEnvelopeCryptography = DesktopNativeEnvelopeCryptography

extension DesktopNativeEnvelopeCryptography {
    /// The system's OpenSSL (libcrypto).
    public init() {
        self.init(
            pbkdf2: jsti_crypto_pbkdf2_sha256, seal: jsti_crypto_aes_gcm_seal,
            open: jsti_crypto_aes_gcm_open, random: jsti_crypto_random
        )
    }
}
