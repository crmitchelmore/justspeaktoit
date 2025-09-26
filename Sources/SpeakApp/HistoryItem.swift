//@Implement This represents the full details of an item to write to the history, and it includes:
// - What models were used
// - The raw transcription
// - Any post-processing transcription
// - The duration of the recording
// - The cost of the model
// - A link to the persisted audio file
// - Any raw network requests and responses? In sequence.
// Timestamps for each step
// The events that started and stopped the recording, where the output was pasted to (if possible) and how it was pasted using accessibility or clipboard. Which hotkey and hotkey type of event started the recording.
// History items should also be able to store errors to any of the above data whilst retaining all useful information so that it can be presented as part of the history view.
import Foundation

struct HistoryEvent: Codable, Identifiable, Hashable {
  enum Kind: String, Codable {
    case recordingStarted
    case recordingStopped
    case transcriptionSubmitted
    case transcriptionReceived
    case postProcessingSubmitted
    case postProcessingReceived
    case outputDelivered
    case error
  }

  let id: UUID
  let kind: Kind
  let timestamp: Date
  let description: String

  init(id: UUID = UUID(), kind: Kind, timestamp: Date = .init(), description: String) {
    self.id = id
    self.kind = kind
    self.timestamp = timestamp
    self.description = description
  }
}

struct HistoryNetworkExchange: Codable, Identifiable, Hashable {
  let id: UUID
  let url: URL
  let method: String
  let requestHeaders: [String: String]
  let requestBodyPreview: String
  let responseCode: Int
  let responseHeaders: [String: String]
  let responseBodyPreview: String

  init(
    id: UUID = UUID(), url: URL, method: String, requestHeaders: [String: String],
    requestBodyPreview: String, responseCode: Int, responseHeaders: [String: String],
    responseBodyPreview: String
  ) {
    self.id = id
    self.url = url
    self.method = method
    self.requestHeaders = requestHeaders
    self.requestBodyPreview = requestBodyPreview
    self.responseCode = responseCode
    self.responseHeaders = responseHeaders
    self.responseBodyPreview = responseBodyPreview
  }
}

struct HistoryError: Codable, Identifiable, Hashable {
  enum Phase: String, Codable {
    case recording
    case transcription
    case postProcessing
    case output
    case storage
  }

  let id: UUID
  let phase: Phase
  let message: String
  let debugDescription: String?
  let occurredAt: Date

  init(
    id: UUID = UUID(), phase: Phase, message: String, debugDescription: String? = nil,
    occurredAt: Date = .init()
  ) {
    self.id = id
    self.phase = phase
    self.message = message
    self.debugDescription = debugDescription
    self.occurredAt = occurredAt
  }
}

struct HistoryTrigger: Codable, Hashable {
  enum HotKeyGesture: String, Codable {
    case singleTap
    case doubleTap
    case hold
    case uiButton
  }

  enum OutputMethod: String, Codable {
    case accessibility
    case clipboard
    case none
  }

  let gesture: HotKeyGesture
  let hotKeyDescription: String
  let outputMethod: OutputMethod
  let destinationApplication: String?
}

struct HistoryCost: Codable, Hashable {
  let total: Decimal
  let currency: String
  let breakdown: ChatCostBreakdown?
}

struct PhaseTimestamps: Codable, Hashable {
  let recordingStarted: Date?
  let recordingEnded: Date?
  let transcriptionStarted: Date?
  let transcriptionEnded: Date?
  let postProcessingStarted: Date?
  let postProcessingEnded: Date?
  let outputDelivered: Date?
}

struct HistoryItem: Codable, Identifiable, Hashable {
  let id: UUID
  let createdAt: Date
  let updatedAt: Date
  let modelsUsed: [String]
  let rawTranscription: String?
  let postProcessedTranscription: String?
  let recordingDuration: TimeInterval
  let cost: HistoryCost?
  let audioFileURL: URL?
  let networkExchanges: [HistoryNetworkExchange]
  let events: [HistoryEvent]
  let phaseTimestamps: PhaseTimestamps
  let trigger: HistoryTrigger
  let errors: [HistoryError]

  init(
    id: UUID = UUID(), createdAt: Date = .init(), updatedAt: Date = .init(), modelsUsed: [String],
    rawTranscription: String?, postProcessedTranscription: String?, recordingDuration: TimeInterval,
    cost: HistoryCost?, audioFileURL: URL?, networkExchanges: [HistoryNetworkExchange],
    events: [HistoryEvent], phaseTimestamps: PhaseTimestamps, trigger: HistoryTrigger,
    errors: [HistoryError]
  ) {
    self.id = id
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.modelsUsed = modelsUsed
    self.rawTranscription = rawTranscription
    self.postProcessedTranscription = postProcessedTranscription
    self.recordingDuration = recordingDuration
    self.cost = cost
    self.audioFileURL = audioFileURL
    self.networkExchanges = networkExchanges
    self.events = events
    self.phaseTimestamps = phaseTimestamps
    self.trigger = trigger
    self.errors = errors
  }

  static let placeholder: HistoryItem = .init(
    modelsUsed: ["apple/local/SFSpeechRecognizer"],
    rawTranscription: "Hello world, this is a placeholder recording.",
    postProcessedTranscription: "Hello world — this is a placeholder recording.",
    recordingDuration: 32.5,
    cost: .init(total: 0.002, currency: "USD", breakdown: nil),
    audioFileURL: nil,
    networkExchanges: [],
    events: [
      .init(kind: .recordingStarted, description: "Recording began"),
      .init(kind: .recordingStopped, description: "Recording finished"),
      .init(kind: .transcriptionReceived, description: "Transcription succeeded"),
    ],
    phaseTimestamps: .init(
      recordingStarted: Date().addingTimeInterval(-40),
      recordingEnded: Date().addingTimeInterval(-8),
      transcriptionStarted: Date().addingTimeInterval(-8),
      transcriptionEnded: Date().addingTimeInterval(-2),
      postProcessingStarted: nil,
      postProcessingEnded: nil,
      outputDelivered: Date().addingTimeInterval(-1)
    ),
    trigger: .init(
      gesture: .doubleTap,
      hotKeyDescription: "Fn",
      outputMethod: .accessibility,
      destinationApplication: "Notes"
    ),
    errors: []
  )
}
