import Foundation

/// A bounded, content-free description of a failure, for the local log.
///
/// A failure that came back from a provider carries the provider's words. The
/// batch transcription error is the sharp case: it is constructed with the raw
/// HTTP response body and its `localizedDescription` interpolates that body, so
/// `"\(error.localizedDescription, privacy: .public)"` puts unbounded remote
/// content into device logs, where log collection and support tooling can read
/// it. A recovery pass that promises nothing leaves the device must not do
/// that.
///
/// This label carries only things that cannot be content: the error's type name
/// (a compile-time constant), the bridged `NSError` domain and numeric code, and
/// an optional HTTP status the caller recognised. It never reads the error's
/// message or `userInfo`.
public enum RemoteFailureLabel {
    public static func label(for error: Error, status: Int? = nil) -> String {
        if error is CancellationError { return "cancelled" }
        let bridged = error as NSError
        var fields = [
            "type=\(String(describing: type(of: error)))",
            "domain=\(bridged.domain)",
            "code=\(bridged.code)"
        ]
        if let status { fields.append("http=\(status)") }
        return fields.joined(separator: " ")
    }
}
