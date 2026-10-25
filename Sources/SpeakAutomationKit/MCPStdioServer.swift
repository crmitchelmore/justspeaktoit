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

    /// Serves until stdin closes. Only await calls use bounded concurrent workers;
    /// existing commands retain their serial ordering on the framing reader.
    public func serve() {
        let dispatcher = MCPStdioDispatch(handler: self.handler, output: self.output)
        defer { dispatcher.close() }
        var buffer = Data()
        var skippingOversizedLine = false
        while true {
            let chunk = self.input.availableData
            if chunk.isEmpty {
                self.drain(&buffer, skipping: &skippingOversizedLine, isFinal: true, dispatcher: dispatcher)
                return
            }
            buffer.append(chunk)
            self.drain(&buffer, skipping: &skippingOversizedLine, isFinal: false, dispatcher: dispatcher)
            // Guard against a client that never sends a newline. Complete messages
            // have already been answered above, so only an unterminated line can be
            // this large: report it once and resync on the next newline instead of
            // emitting an error for every following fragment.
            if buffer.count > AutomationLimits.maxFrameBytes {
                if !skippingOversizedLine {
                    dispatcher.write(MCPRequestHandler.encode(MCPRequestHandler.errorResponse(
                        id: nil,
                        code: -32600,
                        message: "Request exceeds the size limit."
                    )))
                }
                buffer.removeAll(keepingCapacity: false)
                skippingOversizedLine = true
            }
        }
    }

    private func drain(_ buffer: inout Data, skipping: inout Bool, isFinal: Bool, dispatcher: MCPStdioDispatch) {
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer[buffer.startIndex..<index]
            buffer = buffer[buffer.index(after: index)...]
            guard !skipping else {
                // Tail of an oversized line: it has already been reported.
                skipping = false
                continue
            }
            dispatcher.dispatch(Data(lineData))
        }
        if isFinal, !buffer.isEmpty {
            if !skipping {
                dispatcher.dispatch(buffer)
            }
            buffer.removeAll(keepingCapacity: false)
        }
    }

}
