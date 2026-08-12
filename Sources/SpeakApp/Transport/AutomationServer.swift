#if os(macOS)
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
  private weak var handler: (any AutomationCommandHandling)?
  private var listeningSource: DispatchSourceRead?
  private var listeningDescriptor: Int32 = -1
  private nonisolated let queue = DispatchQueue(label: "com.justspeaktoit.automation", qos: .userInitiated)
  /// Replayed responses keyed by request id, so a client that retries after a
  /// timeout re-reads its result instead of starting a second dictation session.
  private var completedRequests: [String: AutomationResponse] = [:]
  private var completionOrder: [String] = []
  private static let maxRememberedRequests = 64

  private(set) var isRunning = false

  init(socketPath: String = AutomationEndpoint.socketPath()) {
    self.socketPath = socketPath
  }

  func start(handler: any AutomationCommandHandling) throws {
    guard !self.isRunning else { return }
    self.handler = handler

    let descriptor = try Self.makeListeningSocket(at: self.socketPath)
    let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: self.queue)
    source.setEventHandler { [weak self] in
      guard let self else { return }
      let client = accept(descriptor, nil, nil)
      guard client >= 0 else { return }
      Self.applyReceiveTimeout(to: client)
      self.serve(client: client)
    }
    source.setCancelHandler {
      close(descriptor)
    }
    source.resume()

    self.listeningSource = source
    self.listeningDescriptor = descriptor
    self.isRunning = true
    SpeakLogger.transport.info("Automation socket listening")
  }

  /// Creates, binds and listens on the owner-only automation socket.
  private nonisolated static func makeListeningSocket(at socketPath: String) throws -> Int32 {
    let directory = (socketPath as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(
      atPath: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
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
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(descriptor, sockaddrPointer, size)
      }
    }
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

  func stop() {
    guard self.isRunning else { return }
    self.listeningSource?.cancel()
    self.listeningSource = nil
    self.listeningDescriptor = -1
    try? FileManager.default.removeItem(atPath: self.socketPath)
    self.completedRequests.removeAll()
    self.completionOrder.removeAll()
    self.isRunning = false
    SpeakLogger.transport.info("Automation socket stopped")
  }

  deinit {
    // `stop()` is @MainActor, but the source's cancel handler owns closing the
    // descriptor, so cancelling the source here is enough to release the listener.
    self.listeningSource?.cancel()
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
    if let cached = self.completedRequests[request.id] {
      return cached
    }
    let response: AutomationResponse
    do {
      let validated = try request.validated()
      guard let handler = self.handler else {
        throw AutomationError(code: .internalError, message: "Automation is not wired up in this build.")
      }
      response = await handler.handle(validated)
    } catch let error as AutomationError {
      response = .failure(id: request.id, command: request.command, error: error)
    } catch {
      response = .failure(
        id: request.id,
        command: request.command,
        error: AutomationError(code: .internalError, message: "Automation command failed.")
      )
    }
    self.remember(response)
    return response
  }

  private func remember(_ response: AutomationResponse) {
    self.completedRequests[response.id] = response
    self.completionOrder.append(response.id)
    while self.completionOrder.count > Self.maxRememberedRequests {
      let evicted = self.completionOrder.removeFirst()
      self.completedRequests.removeValue(forKey: evicted)
    }
  }

  private nonisolated static func send(_ response: AutomationResponse, to client: Int32) {
    guard let payload = try? AutomationCoding.encoder().encode(response),
      let frame = try? AutomationFraming.frame(payload) else { return }
    try? Self.write(descriptor: client, data: frame)
  }

  /// Bounds how long a half-open client can hold a serving slot. Only covers the
  /// request read and the reply write — the command itself runs on the main actor
  /// with its own deadline, so a slow transcription is not cut short here.
  private nonisolated static func applyReceiveTimeout(to descriptor: Int32) {
    var timeout = timeval(tv_sec: Int(AutomationLimits.defaultTimeout), tv_usec: 0)
    setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
  }

  // MARK: - Socket IO

  private nonisolated static func readExactly(descriptor: Int32, count: Int) throws -> Data {
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

  private nonisolated static func write(descriptor: Int32, data: Data) throws {
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
