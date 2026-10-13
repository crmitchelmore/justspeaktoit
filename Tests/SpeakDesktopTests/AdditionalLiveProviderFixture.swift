import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SpeakCore

enum AdditionalLiveProvider: CaseIterable, Sendable {
    case gemini, meta, modulate, grok

    var sampleRate: Int { self == .meta || self == .grok ? 24_000 : 16_000 }
    var finishBudget: TimeInterval { self == .gemini ? 4 : 5 }
    var end: String {
        switch self {
        case .gemini: return GeminiLiveClient.audioStreamEndJSON()
        case .meta: return #"{"type":"endStream"}"#
        case .modulate: return ""
        case .grok: return #"{"type":"input_audio_buffer.commit"}"#
        }
    }
    var ready: String {
        switch self {
        case .gemini: return #"{"setupComplete":{}}"#
        case .meta: return #"{"sessionId":"synthetic"}"#
        case .modulate: return ""
        case .grok: return #"{"type":"session.updated"}"#
        }
    }
    func final(_ text: String, id: Int = 1) -> String {
        switch self {
        case .gemini: return #"{"serverContent":{"inputTranscription":{"text":"\#(text)"}}}"#
        case .meta: return #"{"type":"speechComplete","turnId":\#(id),"transcript":"\#(text)"}"#
        case .modulate:
            return #"{"type":"utterance","utterance":{"utterance_uuid":"\#(id)","text":"\#(text)"}}"#
        case .grok:
            return #"{"type":"conversation.item.input_audio_transcription.completed","transcript":"\#(text)"}"#
        }
    }
    var completion: String {
        self == .modulate ? #"{"type":"done","duration_ms":300}"# : final("Tail.", id: 2)
    }

    func make(
        factory: AssemblyAISocketFactory, clock: AssemblyAITestClock
    ) -> any FinalizingStreamingTranscriptionClient {
        switch self {
        case .gemini:
            return GeminiLiveClient(
                apiKey: "synthetic", makeConnection: { factory.make($0) },
                schedule: { clock.schedule($0, action: $1) }
            )
        case .meta:
            return MetaMuseLiveClient(
                apiKey: "synthetic", makeConnection: { factory.make($0) },
                schedule: { clock.schedule($0, action: $1) }
            )
        case .modulate:
            return ModulateLiveClient(
                apiKey: "synthetic", makeConnection: { factory.make($0) },
                schedule: { clock.schedule($0, action: $1) }
            )
        case .grok:
            return XAILiveClient(
                apiKey: "synthetic", makeConnection: { factory.make($0) },
                schedule: { clock.schedule($0, action: $1) }
            )
        }
    }
}

final class AdditionalLiveProviderFixture {
    let factory = AssemblyAISocketFactory()
    let clock = AssemblyAITestClock()
    let events = AssemblyAITestEvents()
    let provider: AdditionalLiveProvider
    let client: any FinalizingStreamingTranscriptionClient
    var socket: AssemblyAITestSocket { factory.sockets.last! }

    init(_ provider: AdditionalLiveProvider) {
        self.provider = provider
        client = provider.make(factory: factory, clock: clock)
    }
    func start() {
        client.start(
            onTranscript: { [events] in events.transcript($0, final: $1) },
            onError: { [events] in events.fail($0) }
        )
    }
    func becomeReady() {
        socket.open()
        if provider != .modulate {
            socket.completeSend()
            socket.emit(provider.ready)
        }
    }
    func frame(_ byte: UInt8 = 1) -> Data { Data(repeating: byte, count: provider.sampleRate / 5) }
}
