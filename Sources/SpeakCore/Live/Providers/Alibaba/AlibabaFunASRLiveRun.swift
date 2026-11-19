import Foundation

final class AlibabaFunASRLiveRun: @unchecked Sendable {
    enum Phase { case idle, connecting, active, finishing, closed }
    struct Sentence {
        let text: String
        let final: Bool
        let start: Double
        let end: Double?
    }
    let taskID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var phase = Phase.idle
    var connection: (any StreamingWebSocketConnection)?
    var ready = false
    var opened = false
    var finishSent = false
    var sending = false
    var sendID = 0
    var queuedBytes = 0
    var overflowed = false
    var outgoing: [Data] = []
    var sentences: [Int: Sentence] = [:]
    var waiters: [CheckedContinuation<String?, Never>] = []
    var onTranscript: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?

    var orderedSentences: [Sentence] { sentences.sorted { $0.key < $1.key }.map(\.value) }
    var confirmed: String { orderedSentences.filter(\.final).map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    var interim: String {
        orderedSentences.filter { !$0.final }.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }
    var display: String { orderedSentences.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    var transcript: String? { confirmed.isEmpty ? nil : confirmed }
}
