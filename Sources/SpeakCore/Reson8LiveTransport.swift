import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension Reson8LiveClient {
    func connect(_ active: Reson8LiveRun, request: URLRequest) {
        effects.async { [weak self] in
            guard let self else { return }
            let connection = self.makeConnection(request)
            self.state.async {
                guard self.isCurrent(active) else {
                    self.effects.async { connection.cancel() }
                    return
                }
                active.connection = connection
                self.effects.async {
                    guard self.state.sync(execute: { self.isCurrent(active) }) else { return }
                    connection.resume { [weak self] in
                        self?.state.async { [weak self] in
                            guard let self, self.isCurrent(active) else { return }
                            active.open = true
                            if active.phase == .connecting { active.phase = .streaming }
                            self.pump(active)
                        }
                    }
                }
                self.receive(active)
            }
        }
    }

    func pump(_ active: Reson8LiveRun) {
        guard isCurrent(active), active.open, active.inFlight == nil,
              !active.outgoing.isEmpty, let connection = active.connection else { return }
        let frame = active.outgoing.removeFirst()
        let token = UUID()
        active.inFlight = token
        if case .text = frame { active.flushHandedOff = true }
        deadline(5, active) { client, active in
            if active.inFlight == token {
                client.fail(StreamingClientError.transportStalled(provider: "Reson8"), active)
            }
        }
        effects.async { [weak self] in
            guard let self, self.state.sync(execute: { self.isCurrent(active) && active.inFlight == token }) else {
                return
            }
            connection.send(frame) { [weak self] error in
                self?.state.async { [weak self] in
                    guard let self, self.isCurrent(active), active.inFlight == token else { return }
                    if let error { self.fail(error, active); return }
                    active.inFlight = nil
                    if case .binary(let data) = frame { active.bufferedBytes -= data.count }
                    self.pump(active)
                }
            }
        }
    }

    func receive(_ active: Reson8LiveRun) {
        guard isCurrent(active), let connection = active.connection else { return }
        effects.async { [weak self] in
            guard let self, self.state.sync(execute: { self.isCurrent(active) }) else { return }
            connection.receive { [weak self] outcome in
                self?.state.async { [weak self] in
                    guard let self, self.isCurrent(active) else { return }
                    switch outcome {
                    case .failure(let error): self.fail(error, active)
                    case .success(let message):
                        do { try self.handle(message, active) } catch { self.fail(error, active) }
                        if self.isCurrent(active) { self.receive(active) }
                    }
                }
            }
        }
    }

    private struct Event: Decodable {
        let type: String
        let text: String?
        let isFinal: Bool?
        let startMs: Double?
        let durationMs: Double?
        let id: String?
    }

    private func handle(_ message: StreamingWebSocketMessage, _ active: Reson8LiveRun) throws {
        let data: Data
        switch message {
        case .text(let text): data = Data(text.utf8)
        case .binary(let bytes): data = bytes
        }
        guard data.count <= 1_024 * 1_024 else { throw TranscriptionProviderError.invalidResponse }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let event = try decoder.decode(Event.self, from: data)
        switch event.type {
        case "flush_confirmation":
            guard active.phase == .finishing, active.flushHandedOff, event.id == active.flushID else { return }
            active.interim = ""
            close(active)
        case "transcript":
            try receiveTranscript(event, active)
        default: break
        }
    }

    private func receiveTranscript(_ event: Event, _ active: Reson8LiveRun) throws {
        guard let text = event.text, let final = event.isFinal else {
            throw TranscriptionProviderError.invalidResponse
        }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if final {
            let start = (event.startMs ?? 0) / 1_000
            let segment = TranscriptionSegment(
                startTime: start, endTime: start + (event.durationMs ?? 0) / 1_000, text: value
            )
            if let timestamp = event.startMs,
               let index = active.finals.firstIndex(where: { $0.start == timestamp }) {
                active.finals[index] = (timestamp, segment)
            } else { active.finals.append((event.startMs, segment)) }
            active.interim = ""
        } else { active.interim = value }
        guard active.phase != .finishing else { return }
        let callback = active.onTranscript
        effects.async { [weak self] in
            guard let self, self.state.sync(execute: { self.isCurrent(active) }) else { return }
            callback?(value, final)
        }
    }
}
