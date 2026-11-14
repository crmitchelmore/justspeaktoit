import Foundation
import SpeakCore

/// A final transcript a paired phone sent, ready to insert at the cursor.
package struct DesktopTransportDelivery: Equatable, Sendable {
    package let text: String
    package let deviceName: String

    package init(text: String, deviceName: String) {
        self.text = text
        self.deviceName = deviceName
    }
}

/// What the Settings card shows.
package struct DesktopTransportReceiverStatus: Equatable, Sendable {
    package enum State: Equatable, Sendable {
        case off
        case listening
        case unavailable(String)
    }

    package var enabled: Bool
    package var state: State
    package var pairingCode: String
    package var devices: [TransportReceiverPairedDevice]
    /// Phones connected and authenticated right now.
    package var connected: [String]
    package var serviceName: String

    package init(
        enabled: Bool = false, state: State = .off, pairingCode: String = "",
        devices: [TransportReceiverPairedDevice] = [], connected: [String] = [], serviceName: String = ""
    ) {
        self.enabled = enabled
        self.state = state
        self.pairingCode = pairingCode
        self.devices = devices
        self.connected = connected
        self.serviceName = serviceName
    }

    /// One sentence for the status line.
    package var summary: String {
        switch state {
        case .off:
            return "Off. Turn this on to receive transcripts from a paired phone."
        case .unavailable(let reason):
            return "Unavailable: \(reason)"
        case .listening:
            if connected.isEmpty {
                return "On. Phones on this network can find “\(serviceName)”."
            }
            return "On. Connected: \(connected.joined(separator: ", "))."
        }
    }
}

/// The desktop receiver for transcripts sent from a phone (F46).
///
/// It listens on an ephemeral TCP port, advertises it over DNS-SD with the
/// release train's service type, and runs the shared `SpeakTransportWire` v2
/// protocol: a WebSocket per phone, the encrypted handshake, the pairing code
/// or a device credential, then final transcripts that it hands to `deliver`.
/// Each connection has its own thread; the shared pairing state is locked.
package final class DesktopTransportReceiver: @unchecked Sendable {
    /// Phones connected at once; more are refused before any handshake.
    package static let maximumConnections = 8
    private static let pollMilliseconds: Int32 = 250
    private static let readChunk = 16 * 1024

    private final class Run: @unchecked Sendable {
        let listener: any DesktopTransportListener
        let advertiser: any DesktopTransportAdvertiser
        let threads = DispatchGroup()
        private let lock = NSLock()
        private var stopped = false

        init(listener: any DesktopTransportListener, advertiser: any DesktopTransportAdvertiser) {
            self.listener = listener
            self.advertiser = advertiser
        }

        var isStopped: Bool { lock.withLock { stopped } }
        func stop() { lock.withLock { stopped = true } }
    }

    private final class Link {
        var deviceName: String?
    }

    private let storage: DesktopTransportReceiverStorage
    private let endpoints: DesktopTransportEndpoints
    private let serviceName: String
    private let serviceType: String
    private let unauthenticatedTimeout: TimeInterval
    private let deliver: @Sendable (DesktopTransportDelivery) -> Void
    private let lock = NSLock()
    private var pairing: TransportReceiverPairingStore?
    private var state = DesktopTransportReceiverStatus.State.off
    private var run: Run?
    private var advertisedName: String?
    private var links: [ObjectIdentifier: Link] = [:]
    private var changeHandler: (@Sendable (DesktopTransportReceiverStatus) -> Void)?

    package init(
        storage: DesktopTransportReceiverStorage,
        endpoints: DesktopTransportEndpoints,
        serviceName: String = DesktopTransportReceiver.defaultServiceName(),
        serviceType: String = SpeakTransportServiceType,
        unauthenticatedTimeout: TimeInterval = 10,
        deliver: @escaping @Sendable (DesktopTransportDelivery) -> Void
    ) {
        self.storage = storage
        self.endpoints = endpoints
        self.serviceName = serviceName
        self.serviceType = serviceType
        self.unauthenticatedTimeout = unauthenticatedTimeout
        self.deliver = deliver
    }

    /// This computer's short host name, which the phone lists.
    package static func defaultServiceName() -> String {
        let host = ProcessInfo.processInfo.hostName
        let short = host.split(separator: ".").first.map { String($0) } ?? host
        return short.isEmpty || short == "localhost" ? "Desktop" : short
    }

    /// Called on a background thread whenever the status changes.
    package func setChangeHandler(_ handler: (@Sendable (DesktopTransportReceiverStatus) -> Void)?) {
        lock.withLock { changeHandler = handler }
    }

    package var status: DesktopTransportReceiverStatus {
        let (pairing, state, connected) = lock.withLock {
            (self.pairing, self.state, links.values.compactMap(\.deviceName).sorted())
        }
        let enabled = storage.current.enabled
        // A receiver that is off shows no code, so it never creates (and saves) one.
        let code = enabled ? pairing?.pairingCode : pairing?.storedPairingCode
        return DesktopTransportReceiverStatus(
            enabled: enabled, state: state,
            pairingCode: code ?? "", devices: pairing?.pairedDevices ?? [],
            connected: connected, serviceName: lock.withLock { advertisedName } ?? serviceName
        )
    }

    /// Loads the saved state and starts listening when the user left it on.
    package func start() {
        let loaded: DesktopTransportReceiverState
        do {
            loaded = try storage.load()
        } catch {
            let reason = "the system keyring could not be read (\(error.localizedDescription))."
            lock.withLock { state = .unavailable(reason) }
            notify()
            return
        }
        let storage = storage
        let store = TransportReceiverPairingStore(state: loaded.pairing) { pairing in
            try? storage.update { $0.pairing = pairing }
        }
        store.setChangeHandler { [weak self] in self?.notify() }
        lock.withLock { pairing = store }
        if loaded.enabled { listen() } else { notify() }
    }

    /// Turns the receiver on or off and remembers the choice on this computer.
    package func setEnabled(_ enabled: Bool) {
        guard lock.withLock({ pairing != nil }) else { return notify() }
        do {
            try storage.update { $0.enabled = enabled }
        } catch {
            lock.withLock { state = .unavailable("the setting could not be saved (\(error.localizedDescription)).") }
            return notify()
        }
        if enabled { listen() } else { stopListening(wait: false) }
    }

    /// A new pairing code, which also forgets every paired phone.
    package func newPairingCode() {
        lock.withLock { pairing }?.regeneratePairingCode()
    }

    /// Forgets one phone and revokes its credential.
    package func forgetDevice(id: String) {
        lock.withLock { pairing }?.removePairedDevice(id: id)
    }

    /// Stops listening and waits briefly for every connection to close.
    package func shutDown() {
        stopListening(wait: true)
    }

    private func listen() {
        guard lock.withLock({ run == nil }) else { return notify() }
        let listener: any DesktopTransportListener
        do {
            listener = try endpoints.makeListener()
        } catch {
            lock.withLock { state = .unavailable("could not listen for phones (\(error.localizedDescription)).") }
            return notify()
        }
        let advertiser = endpoints.makeAdvertiser()
        let announced: String
        do {
            announced = try advertiser.start(name: serviceName, type: serviceType, port: listener.port)
        } catch {
            listener.close()
            lock.withLock { state = .unavailable("phones cannot find this computer (\(error.localizedDescription)).") }
            return notify()
        }
        let started = Run(listener: listener, advertiser: advertiser)
        lock.withLock {
            run = started
            advertisedName = announced
            state = .listening
        }
        started.threads.enter()
        Thread { [self] in
            acceptLoop(started)
            started.threads.leave()
        }.start()
        notify()
    }

    private func stopListening(wait: Bool) {
        let stopping = lock.withLock { () -> Run? in
            let current = run
            run = nil
            advertisedName = nil
            state = .off
            return current
        }
        if let stopping {
            stopping.stop()
            stopping.advertiser.stop()
            if wait { _ = stopping.threads.wait(timeout: .now() + 2) }
        }
        notify()
    }

    private func acceptLoop(_ run: Run) {
        defer { run.listener.close() }
        while !run.isStopped {
            switch run.listener.accept(timeoutMilliseconds: Self.pollMilliseconds) {
            case .timedOut: continue
            case .closed: return
            case .connection(let connection):
                let link = Link()
                let admitted = lock.withLock { () -> Bool in
                    guard links.count < Self.maximumConnections else { return false }
                    links[ObjectIdentifier(link)] = link
                    return true
                }
                guard admitted else {
                    connection.close()
                    continue
                }
                run.threads.enter()
                Thread { [self] in
                    serve(connection, link: link, run: run)
                    run.threads.leave()
                }.start()
            }
        }
    }

    private func serve(_ connection: any DesktopTransportConnection, link: Link, run: Run) {
        defer {
            connection.close()
            let wasNamed = lock.withLock { links.removeValue(forKey: ObjectIdentifier(link))?.deviceName != nil }
            if wasNamed { notify() }
        }
        let deadline = Date().addingTimeInterval(unauthenticatedTimeout)
        guard let pairing = lock.withLock({ self.pairing }),
              let leftover = upgrade(connection, deadline: deadline, run: run) else { return }
        let session = TransportReceiverSession(pairing: pairing)
        var decoder = DesktopWebSocketDecoder()
        decoder.append(leftover)
        while true {
            guard drain(&decoder, session: session, connection: connection, link: link) else { return }
            if run.isStopped {
                _ = connection.write(DesktopWebSocketEncoder.close(code: 1001))
                return
            }
            if !session.isAuthenticated, Date() >= deadline { return }
            switch connection.read(maxBytes: Self.readChunk, timeoutMilliseconds: Self.pollMilliseconds) {
            case .data(let data): decoder.append(data)
            case .timedOut: continue
            case .closed: return
            }
        }
    }

    private func notify() {
        guard let handler = lock.withLock({ changeHandler }) else { return }
        handler(status)
    }
}

// MARK: - One connection

extension DesktopTransportReceiver {
    /// Handles every complete WebSocket event buffered; `false` ends the connection.
    private func drain(
        _ decoder: inout DesktopWebSocketDecoder, session: TransportReceiverSession,
        connection: any DesktopTransportConnection, link: Link
    ) -> Bool {
        do {
            while let event = try decoder.next(maxMessageBytes: session.frameLimit.maximumBytes) {
                guard handle(event, session: session, connection: connection, link: link) else { return false }
            }
            return true
        } catch {
            let code: UInt16 = error as? DesktopWebSocketDecoder.Failure == .messageTooLarge ? 1009 : 1002
            _ = connection.write(DesktopWebSocketEncoder.close(code: code))
            return false
        }
    }

    /// Completes the WebSocket upgrade and returns any bytes after it.
    private func upgrade(_ connection: any DesktopTransportConnection, deadline: Date, run: Run) -> Data? {
        var buffer = Data()
        while !run.isStopped, Date() < deadline {
            switch connection.read(maxBytes: Self.readChunk, timeoutMilliseconds: Self.pollMilliseconds) {
            case .data(let data): buffer.append(data)
            case .timedOut: continue
            case .closed: return nil
            }
            do {
                guard let request = try DesktopWebSocketHandshake.parse(buffer) else { continue }
                guard connection.write(DesktopWebSocketHandshake.response(for: request)) else { return nil }
                return Data(buffer.dropFirst(request.consumed))
            } catch {
                _ = connection.write(DesktopWebSocketHandshake.badRequest)
                return nil
            }
        }
        return nil
    }

    /// Runs one event; `false` ends the connection.
    private func handle(
        _ event: DesktopWebSocketEvent, session: TransportReceiverSession,
        connection: any DesktopTransportConnection, link: Link
    ) -> Bool {
        switch event {
        case .ping(let payload):
            return connection.write(DesktopWebSocketEncoder.pong(payload))
        case .pong:
            return true
        case .close:
            _ = connection.write(DesktopWebSocketEncoder.close())
            return false
        case .message(let message):
            for action in session.receive(message) {
                guard perform(action, session: session, connection: connection, link: link) else { return false }
            }
            return !session.isClosed
        }
    }

    private func perform(
        _ action: TransportReceiverAction, session: TransportReceiverSession,
        connection: any DesktopTransportConnection, link: Link
    ) -> Bool {
        switch action {
        case .send(let frame):
            return connection.write(DesktopWebSocketEncoder.binary(frame))
        case .deliver(_, let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            deliver(DesktopTransportDelivery(text: text, deviceName: session.deviceName ?? "your phone"))
            return true
        case .paired(_, let deviceName):
            lock.withLock { link.deviceName = deviceName }
            notify()
            return true
        case .close:
            _ = connection.write(DesktopWebSocketEncoder.close())
            return false
        }
    }
}
