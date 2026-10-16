import Foundation

/// A single-use native request with a bounded blocking run and thread-safe
/// cancellation. The request owns all native state until run/cancel return.
public protocol DesktopNativeClipboardReadRequest: AnyObject, Sendable {
    func run() throws -> String?
    func cancel()
}

public enum DesktopNativeClipboardRead {
    public static let timeoutMilliseconds: UInt32 = 2000

    public static func read(_ request: any DesktopNativeClipboardReadRequest) async throws -> String? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let result: String?
            do {
                result = try await Task.detached { try request.run() }.value
            } catch let error as DesktopClipboardReadError {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            return result
        } onCancel: {
            request.cancel()
        }
    }

    /// Shared C-adapter status/UTF-8 contract, not a platform capability list.
    public static func result(status: Int32, text: [CChar], error: String) throws -> String? {
        switch status {
        case 0: return try decodeText(text)
        case 1: return nil
        case 2: throw DesktopClipboardReadError.tooLarge
        case 3: throw DesktopClipboardReadError.invalidText
        case 4: throw DesktopClipboardReadError.timedOut
        case 5: throw CancellationError()
        case 6:
            throw DesktopClipboardReadError.unsupported(
                error.isEmpty ? "Background clipboard command reads are unsupported." : error
            )
        case 7: throw DesktopClipboardReadError.busy
        default:
            throw DesktopClipboardReadError.nativeFailure(
                error.isEmpty ? "The native clipboard read failed with status \(status) and no error message." : error
            )
        }
    }

    private static func decodeText(_ text: [CChar]) throws -> String {
        guard text.count <= DesktopClipboardVoiceCommands.maximumClipboardUTF8Bytes + 1 else {
            throw DesktopClipboardReadError.tooLarge
        }
        guard text.last == 0 else { throw DesktopClipboardReadError.invalidText }
        let result = text.withUnsafeBufferPointer { buffer in
            buffer.baseAddress.flatMap { String(validatingCString: $0) }
        }
        guard let result else { throw DesktopClipboardReadError.invalidText }
        return result
    }
}
