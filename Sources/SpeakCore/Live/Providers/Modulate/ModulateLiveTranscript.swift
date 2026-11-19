import Foundation

/// One Velma stream's structured utterances: the speaker-labelled text, timed
/// segments, `done` duration and raw payload a host keeps in History, plus the
/// utterance boundaries still owed to the host. Fed from the decoder, read
/// from host callbacks; the lock is never held across a callback.
final class ModulateLiveTranscript: @unchecked Sendable {
    private let features: ModulateTranscriptionFeatures
    private let lock = NSLock()
    private var utterances: [ModulateBatchUtterance] = []
    private var seenIDs: Set<String> = []
    /// A final whose utterance did not decode leaves the session text authoritative.
    private var unstructured = false
    private var durationMs: Int?
    private var owedBoundaries: [String] = []
    private var boundary: ((String) -> Void)?

    init(options: ModulateLiveOptions) {
        features = ModulateTranscriptionFeatures(
            speakerDiarization: options.speakerDiarization, emotionSignal: options.emotionSignal,
            accentSignal: options.accentSignal, piiPhiTagging: options.piiPhiTagging
        )
    }

    var onBoundary: ((String) -> Void)? {
        get { lock.withLock { boundary } }
        set { lock.withLock { boundary = newValue } }
    }

    func reset() {
        lock.withLock {
            utterances = []
            seenIDs = []
            unstructured = false
            durationMs = nil
            owedBoundaries = []
        }
    }

    /// Records what `events` decoded from `text`, dropping a repeated utterance
    /// exactly as the session does.
    func record(_ text: String, events: [StreamingProviderSession.Event]) {
        for event in events {
            switch event {
            case .final(let final, let id):
                let message = try? JSONDecoder().decode(ModulateLiveMessage.self, from: Data(text.utf8))
                lock.withLock {
                    if let id, !seenIDs.insert(id).inserted { return }
                    if let utterance = message?.utterance { utterances.append(utterance) } else { unstructured = true }
                    owedBoundaries.append(final)
                }
            case .complete:
                let message = try? JSONDecoder().decode(ModulateLiveMessage.self, from: Data(text.utf8))
                lock.withLock { durationMs = message?.durationMs ?? durationMs }
            default:
                continue
            }
        }
    }

    /// Announces each utterance once, after the transcript update carrying it.
    func announceBoundaries() {
        let (owed, announce) = lock.withLock {
            defer { owedBoundaries = [] }
            return (owedBoundaries, boundary)
        }
        guard let announce else { return }
        owed.forEach(announce)
    }

    func snapshot(captureDuration: TimeInterval) -> StreamingTranscriptSnapshot {
        lock.withLock {
            let duration = durationMs.map { TimeInterval($0) / 1000 }
            guard !unstructured, !utterances.isEmpty || durationMs != nil else {
                return StreamingTranscriptSnapshot(duration: duration)
            }
            let payload = try? JSONEncoder().encode(ModulateLiveCapture(
                durationMs: durationMs ?? Int(captureDuration * 1000), utterances: utterances
            ))
            return StreamingTranscriptSnapshot(
                displayText: utterances.isEmpty ? nil : features.formattedTranscript(
                    from: utterances, fallbackText: utterances.map(\.text).joined(separator: " ")
                ),
                segments: utterances.map { utterance in
                    TranscriptionSegment(
                        startTime: TimeInterval(utterance.startMs) / 1000,
                        endTime: TimeInterval(utterance.startMs + utterance.durationMs) / 1000,
                        text: features.segmentText(for: utterance, within: utterances)
                    )
                },
                duration: duration,
                rawPayload: payload.flatMap { String(data: $0, encoding: .utf8) }
            )
        }
    }
}

private struct ModulateLiveMessage: Decodable {
    let utterance: ModulateBatchUtterance?
    let durationMs: Int?

    enum CodingKeys: String, CodingKey {
        case utterance
        case durationMs = "duration_ms"
    }
}

private struct ModulateLiveCapture: Encodable {
    let durationMs: Int
    let utterances: [ModulateBatchUtterance]

    enum CodingKeys: String, CodingKey {
        case durationMs = "duration_ms"
        case utterances
    }
}
