import Foundation
import SpeakCore

/// Newline-delimited JSON-RPC transport for the MCP server, per the MCP stdio
/// transport: one message per line on stdin, one reply per line on stdout.
///
/// Nothing else may be written to stdout — diagnostics go to stderr — or the
/// client's parser breaks.
public struct MCPStdioServer {
    private let handler: MCPRequestHandler
    private let input: FileHandle
    private let output: FileHandle

    public init(
        handler: MCPRequestHandler,
        input: FileHandle = .standardInput,
        output: FileHandle = .standardOutput
    ) {
        self.handler = handler
        self.input = input
        self.output = output
    }

    /// Serves until stdin closes. Blocking and single-threaded: MCP stdio clients
    /// send one request at a time, and serialising them keeps dictation start/stop
    /// ordering predictable.
    public func serve() {
        var buffer = Data()
        while true {
            let chunk = self.input.availableData
            if chunk.isEmpty {
                self.drain(&buffer, isFinal: true)
                return
            }
            buffer.append(chunk)
            // Guard against a client that never sends a newline.
            if buffer.count > AutomationLimits.maxFrameBytes {
                self.write(MCPRequestHandler.encode(MCPRequestHandler.errorResponse(
                    id: nil,
                    code: -32600,
                    message: "Request exceeds the size limit."
                )))
                buffer.removeAll(keepingCapacity: false)
                continue
            }
            self.drain(&buffer, isFinal: false)
        }
    }

    private func drain(_ buffer: inout Data, isFinal: Bool) {
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer = buffer[buffer.index(after: index)...]
            self.dispatch(lineData)
        }
        if isFinal, !buffer.isEmpty {
            self.dispatch(buffer)
            buffer.removeAll(keepingCapacity: false)
        }
    }

    private func dispatch(_ lineData: Data) {
        guard let line = String(data: Data(lineData), encoding: .utf8) else {
            self.write(MCPRequestHandler.encode(MCPRequestHandler.errorResponse(
                id: nil,
                code: -32700,
                message: "Parse error: request was not valid UTF-8."
            )))
            return
        }
        guard let response = self.handler.handle(line: line) else { return }
        self.write(response)
    }

    private func write(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        self.output.write(data)
    }
}
