import CLinuxSupport
import SpeakLinuxPlatform

enum LinuxSelectionIntegrationCheck {
    static func run() throws {
        try LinuxNative.call { jsti_atspi_selection_integration_check($0, $1) }
        print("AT-SPI selection: isolated protocol, bounds, privacy, expiry, consent and cleanup checks passed.")
    }
}
