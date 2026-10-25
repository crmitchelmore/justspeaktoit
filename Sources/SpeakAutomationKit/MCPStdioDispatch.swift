import Foundation
import SpeakCore

/// Reader-owned admission and serial output; worker state is protected across EOF/cancellation.
/// Only the explicitly cancellable await path crosses the reader's serial execution boundary.
final class MCPStdioDispatch: @unchecked Sendable {
    private let handler: MCPRequestHandler
    private let writeData: (Data, () -> Bool) -> Bool
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var waits: [String: AutomationRequestCancellation] = [:]
    private var closed = false
    var activeAwaitWorkerCount: Int { self.lock.withLock { self.waits.count } }

    init(handler: MCPRequestHandler, output: FileHandle) {
        self.handler = handler
        let writer = MCPBoundedOutput(output: output)
        self.writeData = { writer.write($0, isClosed: $1) }
    }

    init(handler: MCPRequestHandler, writeData: @escaping (Data, () -> Bool) -> Bool) {
        self.handler = handler
        self.writeData = writeData
    }

    func dispatch(_ data: Data) {
        guard self.lock.withLock({ !self.closed }) else { return }
        guard let line = String(data: data, encoding: .utf8) else {
            self.write(MCPRequestHandler.encode(MCPRequestHandler.errorResponse(
                id: nil, code: -32700, message: "Parse error: request was not valid UTF-8.")))
            return
        }
        guard data.count <= AutomationLimits.maxFrameBytes else {
            self.write(MCPRequestHandler.encode(MCPRequestHandler.errorResponse(
                id: nil, code: -32600, message: "Request exceeds the size limit.")))
            return
        }
        let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let params = message?["params"] as? [String: Any]
        if self.handleCancellation(message, data: data) { return }
        guard let message, message["method"] as? String == "tools/call",
              params?["name"] as? String == AutomationCommand.awaitTranscript.rawValue else {
            if let response = self.handler.handle(line: line) { self.write(response) }
            return
        }
        self.dispatchAwait(line: line, message: message, data: data)
    }

    private func dispatchAwait(line: String, message: [String: Any], data: Data) {
        guard message["id"] != nil else { return }
        guard let key = MCPRequestHandler.awaitIdentity(in: data) else {
            self.write(MCPRequestHandler.encode(MCPRequestHandler.errorResponse(
                id: nil, code: -32600, message: "Await requires a string or 64-bit integer JSON-RPC ID.")))
            return
        }
        let cancellation = AutomationRequestCancellation()
        let admitted = self.lock.withLock {
            guard !self.closed, self.waits[key] == nil,
                  self.waits.count < AutomationLimits.maxTranscriptWaits else { return false }
            self.waits[key] = cancellation
            return true
        }
        guard admitted else {
            self.write(MCPRequestHandler.encode(MCPRequestHandler.errorResponse(
                id: message["id"], code: -32600, message: "Await worker limit or duplicate active JSON-RPC ID.")))
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { self.lock.withLock { _ = self.waits.removeValue(forKey: key) } }
            let response = self.handler.handle(line: line, cancellation: cancellation)
            if let response { self.write(response) }
        }
    }

    private func handleCancellation(_ message: [String: Any]?, data: Data) -> Bool {
        guard message?["method"] as? String == "notifications/cancelled", message?["id"] == nil else { return false }
        if let key = MCPRequestHandler.awaitIdentity(in: data, cancellation: true) {
            let wait = self.lock.withLock { self.waits[key] }
            wait?.cancel()
        }
        return true
    }

    func write(_ line: String) {
        self.outputLock.withLock {
            guard self.lock.withLock({ !self.closed }), let data = (line + "\n").data(using: .utf8) else { return }
            if !self.writeData(data, { self.lock.withLock { self.closed } }) {
                // A partial frame cannot be followed by a second JSON response.
                let active = self.markClosed()
                for wait in active { wait.cancel() }
            }
        }
    }

    func close() {
        let active = self.markClosed()
        for wait in active { wait.cancel() }
        // Finish any already-admitted write before returning; later workers see closed.
        // Cancellation precedes this barrier so a blocked stdout never delays socket shutdown.
        self.outputLock.withLock {}
    }

    private func markClosed() -> [AutomationRequestCancellation] {
        self.lock.withLock {
            self.closed = true
            return Array(self.waits.values)
        }
    }

}
