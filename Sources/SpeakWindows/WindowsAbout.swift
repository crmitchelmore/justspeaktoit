import CWindowsSupport
import SpeakCore
import SpeakDesktopHost

extension WindowsNative {
    static func configureAbout() throws {
        let strings = ConfigurationStrings()
        let links = AppInformationLink.allCases.map {
            JSTIAboutLink(title: strings.add($0.title), url: strings.add($0.url.absoluteString))
        }
        let details = strings.add(DesktopAboutInformation.current().details(for: .windows))
        let result = withExtendedLifetime(strings) {
            links.withUnsafeBufferPointer {
                jsti_window_configure_about(details, $0.baseAddress, $0.count)
            }
        }
        guard result == 0 else {
            throw DesktopHostError(message: "The About information could not be configured.")
        }
    }
}
