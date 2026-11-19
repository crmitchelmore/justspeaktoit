import Foundation

/// A client-local, callback-scoped projection; never shared across clients.
struct GladiaCallbackSnapshot {
    let token = UUID()
    let runID: ObjectIdentifier
    let snapshot: StreamingTranscriptSnapshot
}

extension GladiaLiveClient {
    /// During an ordinary transcript callback, this is that event's immutable
    /// projection. Elsewhere it describes the current (or last closed) run.
    /// Capture duration is host-owned; Gladia supplies no invented timing,
    /// cost or raw payload metadata.
    public func transcriptSnapshot(captureDuration _: TimeInterval) -> StreamingTranscriptSnapshot {
        let thread = ObjectIdentifier(Thread.current)
        return perform { _ in callbackSnapshots[thread]?.last?.snapshot ?? run.snapshot }
    }

    /// No state lock spans user code. A stack also preserves the outer event
    /// if its callback starts and synchronously receives from a replacement.
    func withTranscriptSnapshot(
        _ snapshot: StreamingTranscriptSnapshot, for active: GladiaLiveRun, callback: () -> Void
    ) {
        defer { transcriptCallbackReturned(active) }
        let thread = ObjectIdentifier(Thread.current)
        let context = GladiaCallbackSnapshot(runID: ObjectIdentifier(active), snapshot: snapshot)
        let admitted = perform { _ in
            guard run === active else { return false }
            callbackSnapshots[thread, default: []].append(context)
            return true
        }
        guard admitted else { return }
        defer {
            perform { _ in
                guard callbackSnapshots[thread]?.last?.token == context.token,
                      callbackSnapshots[thread]?.last?.runID == context.runID else { return }
                callbackSnapshots[thread]?.removeLast()
                if callbackSnapshots[thread]?.isEmpty == true { callbackSnapshots.removeValue(forKey: thread) }
            }
        }
        callback()
    }
}

extension GladiaLiveRun {
    /// Caller holds the client state lock. The raw finish return remains
    /// confirmed-only; consumers may opt into this confirmed-plus-draft view.
    var snapshot: StreamingTranscriptSnapshot {
        let mean = finalConfidenceCount == 0 ? nil : finalConfidenceTotal / Double(finalConfidenceCount)
        return StreamingTranscriptSnapshot(
            confirmedText: accumulator.text, pendingInterim: pendingInterim, segments: segments,
            latestUpdateConfidence: latestUpdateConfidence, confidence: mean, isTerminal: stage == .closed
        )
    }
}
