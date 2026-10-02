import SpeakCore

/// The native bridge already records the peer's close status on the terminal
/// receive failure. Shared providers read it through the close-reporting seam
/// to tell a normal end of stream from a dropped connection; a failure without
/// a close frame reports nil.
extension WinHTTPWebSocketError: StreamingWebSocketCloseReporting {
    public var webSocketCloseCode: Int? { closeCode.map(Int.init) }
}
