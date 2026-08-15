#if os(macOS)
import Foundation
import SpeakCore

// MARK: - Socket IO

/// Blocking descriptor helpers and per-connection socket configuration, kept out
/// of the main class body: they touch no instance state and only ever run on the
/// serving queue. Internal (not private) because the connection-handling code in
/// `AutomationServer.swift` calls them across the file split.
extension AutomationServer {
    nonisolated static func send(_ response: AutomationResponse, to client: Int32) {
        guard let payload = try? AutomationCoding.encoder().encode(response) else { return }
        let frame: Data
        do {
            frame = try AutomationFraming.frame(payload)
        } catch {
            // History and transcript text are user data and can exceed the wire
            // bound. Return a small structured failure rather than closing the
            // socket and making the client misdiagnose an app timeout.
            let failure = AutomationResponse.failure(
                id: response.id,
                command: response.command,
                error: AutomationError(
                    code: .internalError,
                    message: "Automation reply exceeds the size limit. Request less history or a smaller result."
                )
            )
            guard let fallbackPayload = try? AutomationCoding.encoder().encode(failure),
                  let fallbackFrame = try? AutomationFraming.frame(fallbackPayload) else { return }
            frame = fallbackFrame
        }
        try? Self.write(descriptor: client, data: frame)
    }

    /// Bounds how long a half-open client can hold a serving slot. Only covers the
    /// request read and the reply write — the command itself runs on the main actor
    /// with its own deadline, so a slow transcription is not cut short here.
    /// Applies the safety properties every accepted connection needs before any
    /// request bytes are read or reply bytes are written.
    nonisolated static func configureAcceptedSocket(_ descriptor: Int32) {
        var noSignal: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        )
        var timeout = timeval(tv_sec: Int(AutomationLimits.defaultTimeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    nonisolated static func readExactly(descriptor: Int32, count: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let read = buffer.withUnsafeMutableBytes { pointer -> Int in
                guard let base = pointer.baseAddress else { return -1 }
                return Darwin.read(descriptor, base.advanced(by: received), count - received)
            }
            if read > 0 {
                received += read
                continue
            }
            if read < 0, errno == EINTR { continue }
            throw AutomationError(code: .invalidArgument, message: "Automation request ended early.")
        }
        return Data(buffer)
    }

    nonisolated static func write(descriptor: Int32, data: Data) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < data.count {
                let written = Darwin.write(descriptor, base.advanced(by: sent), data.count - sent)
                if written > 0 {
                    sent += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                throw AutomationError(code: .internalError, message: "Could not write the automation reply.")
            }
        }
    }
}
#endif
