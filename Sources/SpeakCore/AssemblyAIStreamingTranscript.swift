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
}

struct AssemblyAIStreamingTranscriptUpdate: Equatable {
    let displayText: String
    let finalizedTurn: Bool
}

struct AssemblyAIStreamingTranscriptAssembler {
    private var finalTexts: [String] = []
    private var finalIndexByTurnOrder: [Int: Int] = [:]
    private var fullTranscript = ""
    private var currentInterim = ""

    var transcript: String {
        fullTranscript.isEmpty ? currentInterim
            : (currentInterim.isEmpty ? fullTranscript : fullTranscript + " " + currentInterim)
    }

    mutating func consume(_ turn: AssemblyAIStreamingTurn) -> AssemblyAIStreamingTranscriptUpdate? {
        guard !turn.transcript.isEmpty || turn.end_of_turn else { return nil }

        let finalized = turn.end_of_turn && turn.turn_is_formatted
        if finalized {
            if let existing = finalIndexByTurnOrder[turn.turn_order], finalTexts.indices.contains(existing) {
                finalTexts[existing] = turn.transcript
                fullTranscript = finalTexts.joined(separator: " ")
            } else {
                finalTexts.append(turn.transcript)
                finalIndexByTurnOrder[turn.turn_order] = finalTexts.count - 1
                fullTranscript = fullTranscript.isEmpty
                    ? turn.transcript
                    : fullTranscript + " " + turn.transcript
            }
            currentInterim = ""
        } else {
            currentInterim = turn.transcript
        }

        let display = fullTranscript.isEmpty ? currentInterim
            : (currentInterim.isEmpty ? fullTranscript : fullTranscript + " " + currentInterim)
        return AssemblyAIStreamingTranscriptUpdate(displayText: display, finalizedTurn: finalized)
    }
}
