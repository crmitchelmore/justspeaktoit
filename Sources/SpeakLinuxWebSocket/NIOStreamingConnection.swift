import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
import SpeakCore

/// A failure from the NIO WebSocket transport, with the peer's close frame
/// when the connection ended with one.
public struct NIOWebSocketTransportError: LocalizedError, Sendable {
    public let message: String
    public let closeCode: Int?
    public let closeReason: String?
    public var errorDescription: String? { message }

    init(_ message: String, closeCode: Int? = nil, closeReason: String? = nil) {
        self.message = message
        self.closeCode = closeCode
        self.closeReason = closeReason
    }
}

/// The Linux live-transcription transport: SwiftNIO (with BoringSSL through
/// NIOSSL) behind the shared `StreamingWebSocketConnection` seam, so provider
/// framing, admission limits and finalisation stay in the SpeakCore clients.
///
/// Contract, as for WinHTTP: `onOpen` fires once, only after the upgrade and
/// never after `cancel`; messages are complete (fragments reassembled, up to
/// 4 MiB); every send completes exactly once; `cancel` promptly fails pending
/// sends and receives. Sends made before the upgrade wait for it.
public final class NIOStreamingConnection: StreamingWebSocketConnection, @unchecked Sendable {
    public static let maximumMessageBytes = 4 * 1_024 * 1_024
    private static let group = MultiThreadedEventLoopGroup.singleton

    private enum Phase { case idle, connecting, open, finished }

    private let request: URLRequest
    private let lock = NSLock()
    private var phase = Phase.idle
    private var channel: Channel?
    private var onOpen: (@Sendable () -> Void)?
    private var pendingSends: [(StreamingWebSocketMessage, @Sendable (Error?) -> Void)] = []
    private var inbox: [StreamingWebSocketMessage] = []
    private var receivers: [@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void] = []
    private var terminal: Error?

    public init(request: URLRequest) { self.request = request }

    deinit { channel?.close(promise: nil) }

    public func resume(onOpen: @escaping @Sendable () -> Void) {
        let start = lock.withLock { () -> Bool in
            guard phase == .idle else { return false }
            phase = .connecting
            self.onOpen = onOpen
            return true
        }
        guard start else { return }
        do {
            try connect()
        } catch {
            finish(error)
        }
    }

    public func send(_ message: StreamingWebSocketMessage, completion: @escaping @Sendable (Error?) -> Void) {
        let action = lock.withLock { () -> (Channel?, Error?) in
            if let terminal { return (nil, terminal) }
            if phase == .open, let channel { return (channel, nil) }
            pendingSends.append((message, completion))
            return (nil, nil)
        }
        if let error = action.1 { completion(error); return }
        if let channel = action.0 { write(message, on: channel, completion: completion) }
    }

    public func receive(completion: @escaping @Sendable (Result<StreamingWebSocketMessage, Error>) -> Void) {
        let delivery = lock.withLock { () -> Result<StreamingWebSocketMessage, Error>? in
            if !inbox.isEmpty { return .success(inbox.removeFirst()) }
            if let terminal { return .failure(terminal) }
            receivers.append(completion)
            return nil
        }
        if let delivery { completion(delivery) }
    }

    public func cancel() { finish(CancellationError()) }

    // MARK: Connection

    private func connect() throws {
        guard let url = request.url, let scheme = url.scheme?.lowercased(), let host = url.host,
              scheme == "ws" || scheme == "wss" else {
            throw NIOWebSocketTransportError("The live transcription address is not a WebSocket URL.")
        }
        let secure = scheme == "wss"
        let port = url.port ?? (secure ? 443 : 80)
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty { target += "?" + query }
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: url.port.map { "\(host):\($0)" } ?? host)
        for (name, value) in request.allHTTPHeaderFields ?? [:] where !Self.managedHeaders.contains(name.lowercased()) {
            headers.add(name: name, value: value)
        }
        let tls = secure ? try NIOSSLContext(configuration: .makeClientConfiguration()) : nil
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let upgrader = NIOWebSocketClientUpgrader(
            requestKey: key, maxFrameSize: Self.maximumMessageBytes, automaticErrorHandling: false,
            upgradePipelineHandler: { [weak self] channel, _ in
                channel.pipeline.addHandlers([
                    NIOWebSocketFrameAggregator(
                        minNonFinalFragmentSize: 0, maxAccumulatedFrameCount: 100_000,
                        maxAccumulatedFrameSize: Self.maximumMessageBytes
                    ),
                    FrameHandler(owner: self)
                ]).map { self?.opened(channel) }
            }
        )
        let initial = HandshakeHandler(target: target, headers: headers, owner: self)
        let bootstrap = ClientBootstrap(group: Self.group)
            .connectTimeout(.seconds(15))
            .channelOption(ChannelOptions.socketOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                do {
                    if let tls {
                        let handler = try NIOSSLClientHandler(context: tls, serverHostname: host)
                        try channel.pipeline.syncOperations.addHandler(handler)
                    }
                } catch { return channel.eventLoop.makeFailedFuture(error) }
                let upgrade: NIOHTTPClientUpgradeConfiguration = (
                    upgraders: [upgrader], completionHandler: { context in context.pipeline.removeHandler(initial, promise: nil) }
                )
                return channel.pipeline.addHTTPClientHandlers(withClientUpgrade: upgrade).flatMap {
                    channel.pipeline.addHandler(initial)
                }
            }
        bootstrap.connect(host: host, port: port).whenComplete { [weak self] result in
            switch result {
            case .success(let channel):
                guard let self else { channel.close(promise: nil); return }
                let keep = self.lock.withLock { () -> Bool in
                    guard self.terminal == nil else { return false }
                    self.channel = channel
                    return true
                }
                if !keep { channel.close(promise: nil) }
            case .failure(let error):
                self?.finish(NIOWebSocketTransportError("Could not connect for live transcription: \(error)"))
            }
        }
    }

    private static let managedHeaders: Set<String> = [
        "host", "connection", "upgrade", "sec-websocket-key", "sec-websocket-version", "content-length"
    ]

    fileprivate func opened(_ channel: Channel) {
        let (callback, sends) = lock.withLock { () -> ((@Sendable () -> Void)?, [(StreamingWebSocketMessage, @Sendable (Error?) -> Void)]) in
            guard terminal == nil, phase == .connecting else { return (nil, []) }
            phase = .open
            self.channel = channel
            defer { onOpen = nil; pendingSends = [] }
            return (onOpen, pendingSends)
        }
        callback?()
        for (message, completion) in sends { write(message, on: channel, completion: completion) }
    }

    private func write(_ message: StreamingWebSocketMessage, on channel: Channel, completion: @escaping @Sendable (Error?) -> Void) {
        var buffer = channel.allocator.buffer(capacity: 0)
        let opcode: WebSocketOpcode
        switch message {
        case .text(let text):
            buffer.writeString(text)
            opcode = .text
        case .binary(let data):
            buffer.writeBytes(data)
            opcode = .binary
        }
        let frame = WebSocketFrame(fin: true, opcode: opcode, maskKey: .random(), data: buffer)
        channel.writeAndFlush(frame).whenComplete { result in
            switch result {
            case .success: completion(nil)
            case .failure(let error): completion(NIOWebSocketTransportError("Sending live audio failed: \(error)"))
            }
        }
    }

    fileprivate func deliver(_ message: StreamingWebSocketMessage) {
        let receiver = lock.withLock { () -> (@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void)? in
            guard terminal == nil else { return nil }
            if receivers.isEmpty { inbox.append(message); return nil }
            return receivers.removeFirst()
        }
        receiver?(.success(message))
    }

    /// Ends the connection once: pending sends and receives fail with `error`;
    /// messages already received stay readable before it.
    fileprivate func finish(_ error: Error) {
        let (channel, sends, waiting) = lock.withLock { () -> (Channel?, [(StreamingWebSocketMessage, @Sendable (Error?) -> Void)], [@Sendable (Result<StreamingWebSocketMessage, Error>) -> Void]) in
            guard terminal == nil else { return (nil, [], []) }
            terminal = error
            phase = .finished
            onOpen = nil
            defer { pendingSends = []; receivers = [] }
            let failWaiting = inbox.isEmpty ? receivers : []
            return (self.channel, pendingSends, failWaiting)
        }
        channel?.close(promise: nil)
        for (_, completion) in sends { completion(error) }
        for receiver in waiting { receiver(.failure(error)) }
    }
}

/// Sends the upgrade request once the socket (and TLS) is up and reports a
/// refused upgrade. The upgrade handler adds the WebSocket headers.
private final class HandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let target: String
    private let headers: HTTPHeaders
    private weak var owner: NIOStreamingConnection?

    init(target: String, headers: HTTPHeaders, owner: NIOStreamingConnection) {
        self.target = target
        self.headers = headers
        self.owner = owner
    }

    func channelActive(context: ChannelHandlerContext) {
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: target, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head(let head) = unwrapInboundIn(data), head.status != .switchingProtocols {
            owner?.finish(NIOWebSocketTransportError(
                "The live transcription service refused the connection (HTTP \(head.status.code))."
            ))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        owner?.finish(NIOWebSocketTransportError("The live transcription connection failed: \(error)"))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.finish(NIOWebSocketTransportError("The live transcription connection closed before it opened."))
        context.fireChannelInactive()
    }
}

/// Complete messages from the aggregator; answers pings and close frames.
private final class FrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private weak var owner: NIOStreamingConnection?
    private var closeSent = false

    init(owner: NIOStreamingConnection?) { self.owner = owner }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        var payload = frame.unmaskedData
        switch frame.opcode {
        case .text:
            let bytes = payload.readBytes(length: payload.readableBytes) ?? []
            guard let text = String(validating: bytes, as: UTF8.self) else {
                fail(context, NIOWebSocketTransportError("The live transcription service sent invalid text."))
                return
            }
            owner?.deliver(.text(text))
        case .binary:
            owner?.deliver(.binary(Data(payload.readBytes(length: payload.readableBytes) ?? [])))
        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            var code: Int?
            var reason: String?
            if payload.readableBytes >= 2, let raw = payload.readInteger(as: UInt16.self) {
                code = Int(raw)
                reason = payload.readString(length: payload.readableBytes)
            }
            // Acknowledge first: the write is queued ahead of the close below.
            if !closeSent {
                closeSent = true
                var echo = context.channel.allocator.buffer(capacity: 2)
                echo.writeInteger(UInt16(code ?? 1_000))
                let reply = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: echo)
                context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
            }
            owner?.finish(NIOWebSocketTransportError(
                "The live transcription service closed the connection\(code.map { " (\($0))" } ?? "").",
                closeCode: code, closeReason: reason
            ))
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(context, NIOWebSocketTransportError("The live transcription connection failed: \(error)"))
    }

    func channelInactive(context: ChannelHandlerContext) {
        owner?.finish(NIOWebSocketTransportError("The live transcription connection closed."))
        context.fireChannelInactive()
    }

    private func fail(_ context: ChannelHandlerContext, _ error: Error) {
        owner?.finish(error)
        context.close(promise: nil)
    }
}
