#if os(macOS)
import AppKit
import Foundation
import SpeakCore

/// Executes automation commands on behalf of a local client.
///
/// A protocol so `AutomationServer` can be exercised without the whole app
/// environment, and so the concrete handler stays the only place that knows
/// about `MainManager`.
@MainActor
protocol AutomationCommandHandling: AnyObject {
    func handle(_ request: AutomationRequest) async -> AutomationResponse
}

/// Accepts `speak` CLI and MCP connections on a local UNIX domain socket.
///
/// A socket rather than the Bonjour transport: automation clients are same-machine
/// processes, so pairing codes and network discovery would add ceremony without
/// adding safety. Access control is filesystem permissions — the socket lives in
/// the user's Application Support directory and is created with mode 0600.
@MainActor
final class AutomationServer {
    private let socketPath: String
    /// Held strongly: the handler exists to serve this socket, so its lifetime is
    /// the socket's lifetime and `stop()` is what releases it.
    private var handler: (any AutomationCommandHandling)?
    private var listeningSource: DispatchSourceRead?
    /// Closes the socket when the app quits, so no stale socket file is left for
    /// a client to connect to and fail against confusingly.
    private var terminationObserver: NSObjectProtocol?
    private nonisolated let queue = DispatchQueue(
        label: "com.justspeaktoit.automation",
        qos: .userInitiated,
        attributes: .concurrent
    )
    /// Replayed responses keyed by request id *and* command, so a client that
    /// retries after a timeout re-reads its result instead of starting a second
    /// dictation session — and a client that reuses an id for a different command
    /// never receives the earlier command's answer.
    private var completedRequests: [CompletedKey: AutomationResponse] = [:]
    private var completionOrder: [CompletedKey] = []
    /// Commands still running, so a retry joins the original run instead of
    /// starting a second one.
    private var inFlight: [CompletedKey: Task<AutomationResponse, Never>] = [:]
    private static let maxRememberedRequests = 64

    private struct CompletedKey: Hashable {
        let id: String
        let command: AutomationCommand
    }

    private(set) var isRunning = false

    init(socketPath: String = AutomationEndpoint.socketPath()) {
        self.socketPath = socketPath
    }

    func start(handler: any AutomationCommandHandling) throws {
        guard !self.isRunning else { return }

        // After the socket exists, so a start that fails to bind leaves nothing
        // retained behind a server that is not running.
        let descriptor = try Self.makeListeningSocket(at: self.socketPath)
        self.handler = handler
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            Self.configureAcceptedSocket(client)
            self.serve(client: client)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()

        self.listeningSource = source
        self.isRunning = true
        self.terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        SpeakLogger.transport.info("Automation socket listening")
    }

    /// Creates, binds and listens on the owner-only automation socket.
    private nonisolated static func makeListeningSocket(at socketPath: String) throws -> Int32 {
        let directory = (socketPath as NSString).deletingLastPathComponent
        try Self.prepareSocketDirectory(at: directory)
        // A socket file survives a crash, and bind() fails on an existing path, so
        // clear any stale one before binding.
        try? FileManager.default.removeItem(atPath: socketPath)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw AutomationError(code: .internalError, message: "Could not create the automation socket.")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count < capacity else {
            close(descriptor)
            throw AutomationError(
                code: .internalError,
                message: "Automation socket path exceeds the \(capacity - 1) byte platform limit."
            )
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for offset in 0..<pathBytes.count {
                    destination[offset] = CChar(bitPattern: pathBytes[offset])
                }
                destination[pathBytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        // bind() creates the socket with umask-derived permissions, so narrow the
        // umask across the call rather than widening the window until chmod runs.
        let previousMask = umask(0o177)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(descriptor, sockaddrPointer, size)
            }
        }
        umask(previousMask)
        guard bound == 0 else {
            close(descriptor)
            throw AutomationError(code: .internalError, message: "Could not bind the automation socket.")
        }
        // Owner-only: any other local user must not be able to drive dictation.
        chmod(socketPath, 0o600)

        guard listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw AutomationError(code: .internalError, message: "Could not listen on the automation socket.")
        }
        return descriptor
    }

    /// Creates an owner-only leaf directory or verifies that an existing one is
    /// already private. Never chmod an existing override parent: a caller may
    /// deliberately place the socket under a shared system directory such as
    /// `/tmp`, whose permissions the app must not change.
    private nonisolated static func prepareSocketDirectory(at directory: String) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw AutomationError(code: .invalidArgument, message: "Automation socket parent is not a directory.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: directory)
            let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o777
            guard owner == geteuid(), permissions & 0o777 == 0o700 else {
                throw AutomationError(
                    code: .invalidArgument,
                    message: "Automation socket parent must be owned by the current user with permissions 0700."
                )
            }
            return
        }

        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory)
    }

    func stop() {
        guard self.isRunning else { return }
        self.listeningSource?.cancel()
        self.listeningSource = nil
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        self.handler = nil
        try? FileManager.default.removeItem(atPath: self.socketPath)
        // In-flight work outlives the listener otherwise: its tasks hold a
        // reference to the handler and would keep answering — and mutating the
        // caches — after automation was turned off.
        for work in self.inFlight.values {
            work.cancel()
        }
        self.inFlight.removeAll()
        self.completedRequests.removeAll()
        self.completionOrder.removeAll()
        self.isRunning = false
        SpeakLogger.transport.info("Automation socket stopped")
    }

    deinit {
        // `stop()` is @MainActor, but the source's cancel handler owns closing the
        // descriptor, so cancelling the source here is enough to release the listener.
        self.listeningSource?.cancel()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Connection handling

    /// Reads and writes on the serving queue, hopping to the main actor only to
    /// run the command. Socket IO is blocking, so doing it on the main actor would
    /// let a stalled client freeze the UI.
    private nonisolated func serve(client: Int32) {
        self.queue.async {
            let request: AutomationRequest
            do {
                let prefix = try Self.readExactly(descriptor: client, count: AutomationFraming.prefixLength)
                let length = try AutomationFraming.payloadLength(from: prefix)
                let body = try Self.readExactly(descriptor: client, count: length)
                request = try AutomationCoding.decoder().decode(AutomationRequest.self, from: body)
            } catch {
                // Decode failures and short reads are client bugs; reply with a bounded,
                // non-echoing error rather than dropping the connection silently.
                let failure = AutomationResponse.failure(
                    id: "unknown",
                    command: .status,
                    error: error as? AutomationError
                        ?? AutomationError(code: .invalidArgument, message: "Malformed automation request.")
                )
                Self.send(failure, to: client)
                close(client)
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    Self.send(
                        AutomationResponse.failure(
                            id: request.id,
                            command: request.command,
                            error: AutomationError(code: .internalError, message: "Automation is shutting down.")
                        ),
                        to: client
                    )
                    close(client)
                    return
                }
                let response = await self.respond(to: request)
                self.queue.async {
                    Self.send(response, to: client)
                    close(client)
                }
            }
        }
    }

    private func respond(to request: AutomationRequest) async -> AutomationResponse {
        let key = CompletedKey(id: request.id, command: request.command)
        if let cached = self.completedRequests[key] {
            return cached
        }

        let work: Task<AutomationResponse, Never>
        if let existing = self.inFlight[key] {
            // A retry of a command that is still running joins the original run
            // rather than starting a second dictation session.
            work = existing
        } else {
            let validated: AutomationRequest
            do {
                validated = try request.validated()
            } catch let error as AutomationError {
                return .failure(id: request.id, command: request.command, error: error)
            } catch {
                return .failure(
                    id: request.id,
                    command: request.command,
                    error: AutomationError(code: .invalidArgument, message: "Automation request was rejected.")
                )
            }
            guard let handler = self.handler else {
                return .failure(
                    id: request.id,
                    command: request.command,
                    error: AutomationError(code: .internalError, message: "Automation is not wired up in this build.")
                )
            }
            work = Task { @MainActor [weak self] in
                let response = await handler.handle(validated)
                self?.finish(key: key, response: response)
                return response
            }
            self.inFlight[key] = work
        }

        return await AutomationDeadline.value(
            of: work,
            within: request.resolvedTimeout,
            id: request.id,
            command: request.command
        )
    }

    private func finish(key: CompletedKey, response: AutomationResponse) {
        // A command orphaned by `stop()` outlives the caches it was cleared from,
        // so without this a response from before an off/on toggle could be
        // replayed to a client that connected after it.
        guard self.isRunning else { return }
        self.inFlight.removeValue(forKey: key)
        self.completedRequests[key] = response
        self.completionOrder.append(key)
        while self.completionOrder.count > Self.maxRememberedRequests {
            let evicted = self.completionOrder.removeFirst()
            self.completedRequests.removeValue(forKey: evicted)
        }
    }

    private nonisolated static func send(_ response: AutomationResponse, to client: Int32) {
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
}

// MARK: - Socket IO

/// Blocking descriptor helpers, kept out of the class body: they touch no state
/// and only ever run on the serving queue.
private extension AutomationServer {
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
