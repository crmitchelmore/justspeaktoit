import Foundation

/// Observation at the owned HTTP boundary; it cannot prove server receipt or billing.
/// No source text, credentials, audio, provider response bodies or invented tokens are retained.
public enum VoiceSynthesisUsage {
    public enum Operation: String, Codable, Sendable { case read, generate, export }
    public enum Outcome: String, Codable, Sendable { case completed, failed, cancelled }

    public struct Record: Codable, Equatable, Sendable {
        public let id: UUID
        public let timestamp: Date
        public let operation: Operation
        public let source: VoiceOutputSource
        public let historyRecordID: UUID?
        public let modelID: String
        public let voiceID: String
        /// Unicode scalars supplied to this request after segmentation/pronunciation.
        /// SSML input includes user markup; providers may count billable characters differently.
        public let inputCharacters: Int
        public let usesSSML: Bool
        public let estimatedCostUSD: Decimal?
        public var outcome: Outcome
        /// Measured from validated PCM, not playback duration or a billing receipt.
        public var audioDuration: TimeInterval?
    }

    @TaskLocal public static var capture: Capture?

    public final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [Record] = []
        private let operation: Operation
        private let source: VoiceOutputSource
        private let historyRecordID: UUID?

        public init(operation: Operation, source: VoiceOutputSource, historyRecordID: UUID?) {
            self.operation = operation
            self.source = source
            self.historyRecordID = source == .history ? historyRecordID : nil
        }

        public var records: [Record] { lock.withLock { requests } }

        /// Called only after credentials and the request have been validated, immediately before transport.
        public func begin(voice: DesktopSpeechVoice, inputCharacters: Int, usesSSML: Bool) -> UUID {
            begin(voice: voice, inputCharacters: inputCharacters, usesSSML: usesSSML, xaiInventory: nil)
        }

        public func begin(
            voice: DesktopSpeechVoice, inputCharacters: Int, usesSSML: Bool, xaiInventory: XAIAccountVoiceInventory?
        ) -> UUID {
            begin(voice: voice, inputCharacters: inputCharacters, usesSSML: usesSSML,
                  pricingCharacters: inputCharacters, xaiInventory: xaiInventory)
        }

        func begin(
            voice: DesktopSpeechVoice, inputCharacters: Int, usesSSML: Bool, pricingCharacters: Int,
            xaiInventory: XAIAccountVoiceInventory? = nil, accountInventory: VoiceAccountInventory? = nil
        ) -> UUID {
            let request = Record(
                id: UUID(), timestamp: Date(), operation: operation, source: source, historyRecordID: historyRecordID,
                modelID: voice.modelID, voiceID: voice.id, inputCharacters: inputCharacters, usesSSML: usesSSML,
                estimatedCostUSD: VoiceSynthesisPricing.estimate(
                    for: voice, characterCount: pricingCharacters,
                    accountInventory: accountInventory ?? xaiInventory.map(VoiceAccountInventory.xai)),
                outcome: .failed, audioDuration: nil
            )
            lock.withLock { requests.append(request) }
            return request.id
        }

        public func finish(_ id: UUID, outcome: Outcome, audioDuration: TimeInterval? = nil) {
            lock.withLock {
                guard let index = requests.firstIndex(where: { $0.id == id }) else { return }
                requests[index].outcome = outcome
                requests[index].audioDuration = audioDuration
            }
        }
    }
}
