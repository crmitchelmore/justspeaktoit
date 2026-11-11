import SpeakDesktopNativeBindings

extension LinuxWindow {
    static func configureAbout() throws { try DesktopNativeBindings.configureAbout(for: .linux) }
}
