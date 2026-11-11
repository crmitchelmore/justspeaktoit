import Foundation

struct AssemblyAIEnvelope: Decodable {
    let type: String?
    let turn_order: Int? // swiftlint:disable:this identifier_name
}

struct AssemblyAIStreamingTurn: Decodable {
    let turn_order: Int // swiftlint:disable:this identifier_name
    let turn_is_formatted: Bool // swiftlint:disable:this identifier_name
    let end_of_turn: Bool // swiftlint:disable:this identifier_name
    let transcript: String
    /// The provider's closed utterance, when it reports one; the client's
    /// explicit utterance boundary.
    let utterance: String?
}

struct AssemblyAIStreamingTranscriptUpdate: Equatable {
    let displayText: String
    let finalizedTurn: Bool
}

/// Folds `Turn` events by `turn_order`: a formatted end-of-turn replaces that
/// turn's text, and each turn keeps its own interim, so a later turn's draft
/// survives an earlier turn's late final.
struct AssemblyAIStreamingTranscriptAssembler {
    private var finalTextByTurnOrder: [Int: String] = [:]
    private var interims: [Int: String] = [:]

    private var finalTexts: [String] {
        finalTextByTurnOrder.keys.sorted().compactMap { finalTextByTurnOrder[$0] }
    }
    var confirmedText: String { finalTexts.filter { !$0.isEmpty }.joined(separator: " ") }
    var latestInterim: String {
        guard let order = interims.keys.max() else { return "" }
        return interims[order] ?? ""
    }
    var confirmedWithLatestInterim: String {
        [confirmedText, latestInterim].filter { !$0.isEmpty }.joined(separator: " ")
    }
    /// The whole session so far: confirmed turns and the latest draft.
    var transcript: String { confirmedWithLatestInterim }

    mutating func consume(_ turn: AssemblyAIStreamingTurn) -> AssemblyAIStreamingTranscriptUpdate? {
        guard !turn.transcript.isEmpty || turn.end_of_turn else { return nil }
        let finalized = turn.end_of_turn && turn.turn_is_formatted
        if finalized {
            finalTextByTurnOrder[turn.turn_order] = turn.transcript
            interims.removeValue(forKey: turn.turn_order)
        } else {
            interims[turn.turn_order] = turn.transcript
        }
        return AssemblyAIStreamingTranscriptUpdate(
            displayText: confirmedWithLatestInterim,
            finalizedTurn: finalized
        )
    }

    func snapshot(terminal: Bool) -> StreamingTranscriptSnapshot {
        StreamingTranscriptSnapshot(
            confirmedText: confirmedText,
            pendingInterim: latestInterim,
            displayText: confirmedWithLatestInterim,
            segments: finalTexts.filter { !$0.isEmpty }.map {
                TranscriptionSegment(startTime: 0, endTime: 0, text: $0)
            },
            isTerminal: terminal
        )
    }
}
