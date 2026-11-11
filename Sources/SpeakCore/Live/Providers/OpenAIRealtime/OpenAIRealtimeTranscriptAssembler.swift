import Foundation

/// Folds per-item transcription events into one session transcript.
///
/// Items keep the order in which they were first seen, preferring the commit
/// order the server reports, so late or duplicated completions can neither
/// reorder nor double text. Deltas append for the GPT transcription models; a
/// completed event carries the whole item transcript (Whisper sends nothing
/// else) and replaces the accumulated deltas for that item.
struct OpenAIRealtimeTranscriptAssembler: Equatable, Sendable {
    static let pendingItemKey = "_pending"

    private var itemOrder: [String] = []
    private var finals: [String: String] = [:]
    private var deltas: [String: String] = [:]
    private(set) var completedItemKeys: Set<String> = []

    /// Events without an item ID share one pending slot, as the Apple controllers do.
    static func key(forItemID itemID: String) -> String {
        itemID.isEmpty ? pendingItemKey : itemID
    }

    var transcript: String {
        itemOrder
            .compactMap { key -> String? in
                let text = finals[key] ?? deltas[key]
                return text?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var transcriptOrNil: String? {
        let text = transcript
        return text.isEmpty ? nil : text
    }

    /// `input_audio_buffer.committed` names the item before any text exists for it.
    mutating func noteCommitted(itemKey key: String) {
        register(key)
    }

    @discardableResult
    mutating func consume(delta: String, itemID: String) -> String {
        let key = Self.key(forItemID: itemID)
        register(key)
        if finals[key] == nil {
            deltas[key, default: ""].append(delta)
        }
        return transcript
    }

    @discardableResult
    mutating func consume(completed transcript: String, itemID: String) -> String {
        let key = Self.key(forItemID: itemID)
        register(key)
        finals[key] = transcript
        deltas.removeValue(forKey: key)
        completedItemKeys.insert(key)
        return self.transcript
    }

    private mutating func register(_ key: String) {
        guard !itemOrder.contains(key) else { return }
        itemOrder.append(key)
    }
}
