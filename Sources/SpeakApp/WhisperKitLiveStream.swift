import Foundation
import SpeakCore
import WhisperKit

/// One spoken segment as WhisperKit reports it, timed from the start of the
/// recording.
struct WhisperKitSegment: Equatable, Sendable {
    let start: Float
    let end: Float
    let text: String
}

/// The transcript-bearing part of WhisperKit's streaming state.
struct WhisperKitTranscriptState: Equatable, Sendable {
    /// Segments WhisperKit will not revise again.
    var confirmedSegments: [WhisperKitSegment] = []
    /// The latest complete decode of the audio after the confirmed segments;
    /// replaced wholesale by the next decode.
    var unconfirmedSegments: [WhisperKitSegment] = []
    /// The hypothesis of the decode in progress. It covers the same audio as
    /// `unconfirmedSegments` because every decode restarts at the end of the
    /// last confirmed segment. WhisperKit parks a placeholder here while it
    /// waits for speech.
    var currentText: String = ""
}

/// What the streaming transcriber reports to the controller.
enum WhisperKitStreamEvent: Equatable, Sendable {
    /// Microphone audio reached the transcriber, so capture is live.
    case audioArrived
    case transcript(WhisperKitTranscriptState)
}

typealias WhisperKitStreamEventHandler = @Sendable (WhisperKitStreamEvent) -> Void

struct WhisperKitStreamRequest: Equatable, Sendable {
    let batchModelID: String
    /// Two-letter language code, or nil to let the model detect it.
    let language: String?
}

/// Boundary between `WhisperKitLiveController` and WhisperKit's streaming
/// machinery. The controller's lifecycle, transcript projection and
/// finalisation policy are written against this protocol so they can be
/// exercised with deterministic events; `WhisperKitLiveStream` is the only
/// production conformance.
@MainActor
protocol WhisperKitLiveStreaming: AnyObject {
    /// Starts microphone capture and runs the realtime decode loop. Returns
    /// only once `stopStream()` or a failure ends the loop.
    func startStream() async throws
    /// Stops capture. The decode loop notices after its in-flight iteration,
    /// so callers drain `startStream()` before reading final state.
    func stopStream() async
    /// Decodes every captured sample after `confirmedEndSeconds` in one batch
    /// pass, unconstrained by the streaming loop's one-second minimum.
    func decodeTail(after confirmedEndSeconds: Float) async throws -> String
}

/// Replacement-semantic projection of WhisperKit streaming state into
/// transcript text (issue #713).
///
/// Every streaming decode restarts at the end of the last confirmed segment,
/// so the in-progress hypothesis re-covers the audio behind the unconfirmed
/// segments: the two are alternatives, never neighbours. Unconfirmed segments
/// are additionally checked against confirmed timing because WhisperKit
/// publishes the confirmed and unconfirmed arrays in separate state changes,
/// and one observation can hold the same segment in both.
enum WhisperKitTranscriptProjection {
    static let waitingPlaceholder = "Waiting for speech..."
    /// Tails shorter than this cannot hold a word; decoding them only delays
    /// the stop.
    static let minimumTailSeconds: Float = 0.1

    static func displayText(for state: WhisperKitTranscriptState) -> String {
        let confirmed = state.confirmedSegments.map(\.text)
        let hypothesis = state.currentText == waitingPlaceholder ? "" : clean(state.currentText)
        let window: [String]
        if hypothesis.isEmpty {
            let confirmedEnd = state.confirmedSegments.last?.end
            window = state.unconfirmedSegments
                .filter { segment in confirmedEnd.map { segment.start >= $0 } ?? true }
                .map(\.text)
        } else {
            window = [hypothesis]
        }
        return clean((confirmed + window).joined(separator: " "))
    }

    /// Where the stop-time tail decode starts: the confirmed text is kept
    /// verbatim and everything after it is decoded again in full.
    static func tailStart(for state: WhisperKitTranscriptState) -> Float {
        state.confirmedSegments.last?.end ?? 0
    }

    /// The final transcript once capture has stopped. A non-empty tail decode
    /// is authoritative for the audio after the confirmed segments; an empty
    /// one keeps whatever the stream already displayed, so words the user saw
    /// are never dropped by a silent final pass.
    static func finalText(
        for state: WhisperKitTranscriptState,
        tailText: String,
        displayedText: String
    ) -> String {
        let tail = clean(tailText)
        guard !tail.isEmpty else { return displayedText }
        return clean((state.confirmedSegments.map(\.text) + [tail]).joined(separator: " "))
    }

    static func tailSampleRange(
        sampleCount: Int,
        confirmedEndSeconds: Float,
        sampleRate: Int
    ) -> Range<Int>? {
        let start = max(0, Int((max(0, confirmedEndSeconds) * Float(sampleRate)).rounded(.down)))
        let minimumSamples = Int(minimumTailSeconds * Float(sampleRate))
        guard start < sampleCount, sampleCount - start >= minimumSamples else { return nil }
        return start..<sampleCount
    }

    static func clean(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Production stream: WhisperKit's `AudioStreamTranscriber` for capture and
/// streaming decodes, and the owning pipeline for the stop-time tail decode.
@MainActor
final class WhisperKitLiveStream: WhisperKitLiveStreaming {
    private let pipeline: WhisperKit
    private let transcriber: AudioStreamTranscriber
    private let options: DecodingOptions

    init(
        pipeline: WhisperKit,
        request: WhisperKitStreamRequest,
        onEvent: @escaping WhisperKitStreamEventHandler
    ) throws {
        guard let tokenizer = pipeline.tokenizer else {
            throw TranscriptionManagerError.localLiveStreamingUnsupported
        }
        let options = Self.decodingOptions(language: request.language)
        self.pipeline = pipeline
        self.options = options
        self.transcriber = AudioStreamTranscriber(
            audioEncoder: pipeline.audioEncoder,
            featureExtractor: pipeline.featureExtractor,
            segmentSeeker: pipeline.segmentSeeker,
            textDecoder: pipeline.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipeline.audioProcessor,
            decodingOptions: options,
            stateChangeCallback: { oldState, newState in
                for event in Self.events(from: oldState, to: newState) {
                    onEvent(event)
                }
            }
        )
    }

    func startStream() async throws {
        try await transcriber.startStreamTranscription()
    }

    func stopStream() async {
        await transcriber.stopStreamTranscription()
    }

    func decodeTail(after confirmedEndSeconds: Float) async throws -> String {
        // The processor keeps the whole recording until the next capture
        // starts, so the tail is still addressable after `stopStream()`.
        let samples = pipeline.audioProcessor.audioSamples
        guard let range = WhisperKitTranscriptProjection.tailSampleRange(
            sampleCount: samples.count,
            confirmedEndSeconds: confirmedEndSeconds,
            sampleRate: WhisperKit.sampleRate
        ) else { return "" }
        var tailOptions = options
        tailOptions.clipTimestamps = []
        let results = try await pipeline.transcribe(
            audioArray: Array(samples[range]),
            decodeOptions: tailOptions
        )
        return results.map { $0.text }.joined(separator: " ")
    }

    nonisolated static func decodingOptions(language: String?) -> DecodingOptions {
        DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: language != nil,
            skipSpecialTokens: true,
            wordTimestamps: true
        )
    }

    /// Audio arrival is inferred from any buffer energy, buffer size or
    /// hypothesis change while recording: each of those needs microphone
    /// samples to have reached the transcriber.
    nonisolated static func events(
        from oldState: AudioStreamTranscriber.State,
        to newState: AudioStreamTranscriber.State
    ) -> [WhisperKitStreamEvent] {
        var events: [WhisperKitStreamEvent] = []
        let hypothesisChanged = oldState.currentText != newState.currentText
        if newState.isRecording,
            hypothesisChanged
                || oldState.bufferEnergy != newState.bufferEnergy
                || oldState.lastBufferSize != newState.lastBufferSize {
            events.append(.audioArrived)
        }
        if hypothesisChanged
            || oldState.confirmedSegments != newState.confirmedSegments
            || oldState.unconfirmedSegments != newState.unconfirmedSegments {
            // The segment type is named through inference: SpeakCore declares
            // its own `TranscriptionSegment`, and WhisperKit's cannot be
            // module-qualified because the module also exports a class of
            // the same name.
            events.append(
                .transcript(
                    WhisperKitTranscriptState(
                        confirmedSegments: newState.confirmedSegments.map {
                            WhisperKitSegment(start: $0.start, end: $0.end, text: $0.text)
                        },
                        unconfirmedSegments: newState.unconfirmedSegments.map {
                            WhisperKitSegment(start: $0.start, end: $0.end, text: $0.text)
                        },
                        currentText: newState.currentText
                    )
                )
            )
        }
        return events
    }
}
