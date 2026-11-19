import SpeakDesktopNativeBindings

extension WindowsNative {
    static func configureAbout() throws { try DesktopNativeBindings.configureAbout(for: .windows) }
}
