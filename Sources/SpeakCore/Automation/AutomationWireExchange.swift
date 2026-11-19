import Foundation

/// One connected, blocking automation byte stream: a UNIX domain socket on
/// macOS, a named-pipe instance on Windows.
///
/// Implementations bound every call by their own deadline and throw either an
/// `AutomationError` or a transport error their owner handles. They block the
/// calling thread, so they are never used on a UI thread.
public protocol AutomationByteStream {
    /// Reads exactly `count` bytes, or throws.
    func readExactly(_ count: Int) throws -> Data
    /// Writes every byte of `data`, or throws.
    func writeAll(_ data: Data) throws
}

/// The exchange every local automation transport performs: one length-prefixed
/// JSON request, then one length-prefixed JSON reply.
///
/// Framing, bounds, decoding and the replies a server owes a bad request live
/// here once, so a client and a server on different platforms cannot disagree.
/// Transports supply only bytes, deadlines and their own connection errors.
public enum AutomationWireExchange {
    // MARK: - Client

    /// Validates, encodes and frames `request`. Called before a connection is
    /// opened, so a bad argument fails without a round trip.
    public static func requestFrame(for request: AutomationRequest) throws -> Data {
        let validated = try request.validated()
        return try AutomationFraming.frame(AutomationCoding.encoder().encode(validated))
    }

    /// Reads and decodes one reply, rejecting a length above the frame limit
    /// before a byte of body is allocated.
    public static func readResponse(from stream: some AutomationByteStream) throws -> AutomationResponse {
        let prefix = try stream.readExactly(AutomationFraming.prefixLength)
        let length = try AutomationFraming.payloadLength(from: prefix)
        return try self.decodeResponse(stream.readExactly(length))
    }

    /// Decodes a reply body and checks its schema.
    public static func decodeResponse(_ body: Data) throws -> AutomationResponse {
        do {
            let response = try AutomationCoding.decoder().decode(AutomationResponse.self, from: body)
            guard response.schemaVersion == AutomationSchema.currentVersion else {
                throw AutomationError(
                    code: .schemaMismatch,
                    message: "The app replied with automation schema v\(response.schemaVersion); "
                        + "this speak build understands v\(AutomationSchema.currentVersion). Update the CLI."
                )
            }
            return response
        } catch let error as AutomationError {
            throw error
        } catch {
            // Never echo the raw body: it is app-controlled and could contain
            // transcript text the caller did not ask for.
            throw AutomationError(code: .internalError, message: "Could not decode the app's automation reply.")
        }
    }

    // MARK: - Server

    /// Reads and decodes one request. Framing violations throw `AutomationError`,
    /// undecodable JSON throws the decoder's error, and the stream's own errors
    /// pass through unchanged so the transport can decide whether to reply.
    public static func readRequest(from stream: some AutomationByteStream) throws -> AutomationRequest {
        let prefix = try stream.readExactly(AutomationFraming.prefixLength)
        let length = try AutomationFraming.payloadLength(from: prefix)
        return try AutomationCoding.decoder().decode(AutomationRequest.self, from: stream.readExactly(length))
    }

    /// The reply owed to a request that could not be read or decoded: bounded,
    /// and never echoing the bytes the client sent.
    public static func malformedRequestResponse(for error: Error) -> AutomationResponse {
        .failure(
            id: "unknown",
            command: .status,
            error: error as? AutomationError
                ?? AutomationError(code: .invalidArgument, message: "Malformed automation request.")
        )
    }

    /// Frames a reply for the wire, or nil if it cannot be encoded at all.
    ///
    /// History and transcript text are user data and can exceed the frame bound.
    /// An oversized reply becomes a small structured failure rather than a closed
    /// connection the client would misdiagnose as the app timing out.
    public static func responseFrame(for response: AutomationResponse) -> Data? {
        guard let payload = try? AutomationCoding.encoder().encode(response) else { return nil }
        if let frame = try? AutomationFraming.frame(payload) {
            return frame
        }
        let failure = AutomationResponse.failure(
            id: response.id,
            command: response.command,
            error: AutomationError(
                code: .internalError,
                message: "Automation reply exceeds the size limit. Request less history or a smaller result."
            )
        )
        guard let fallback = try? AutomationCoding.encoder().encode(failure) else { return nil }
        return try? AutomationFraming.frame(fallback)
    }
}
