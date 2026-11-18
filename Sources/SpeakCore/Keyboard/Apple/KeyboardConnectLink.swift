import Foundation

/// The link the keyboard opens to reconnect Instant Dictation.
///
/// A keyboard extension cannot use the microphone, so dictation runs in the
/// containing app's Instant Dictation session, and iOS only lets an app start
/// that session from the foreground. Telling the user to "open Just Speak"
/// was not enough: opening the app did nothing unless Instant Dictation had
/// already been switched on in Keyboard settings. Tapping the keyboard's mic
/// while it is disconnected opens this link instead, and the app treats it as
/// the user asking to connect: it starts the session and tells them to go back.
public enum KeyboardConnectLink {
    public static let host = "keyboard-connect"

    public static func url(scheme: String = ReleaseTrain.current.urlScheme) -> URL? {
        URL(string: "\(scheme)://\(host)")
    }

    public static func matches(_ url: URL, scheme: String = ReleaseTrain.current.urlScheme) -> Bool {
        url.scheme?.lowercased() == scheme.lowercased() && url.host?.lowercased() == host
    }
}
