import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SpeakCore
@testable import SpeakDesktop
import XCTest

/// Selected-language parity for every desktop live route, whichever provider
/// it is. A route whose canonical capability accepts a hint carries the
/// selection's provider code in what it sends upstream: its socket query, the
/// frames it sends once the socket opens, or Gladia's session request. A route
/// without the capability sends exactly what it sends with no selection. No
/// route sends the stored locale or the Automatic marker, and a profile's
/// language either reaches its route or is reported as unavailable.
final class DesktopLiveLanguageParityTests: XCTestCase {
    /// A catalogue language whose code is not this machine's: Speechmatics
    /// resolves Automatic to the system language, by design.
    private let selection: String = {
        let system = Locale.current.identifier.localeLanguageCode
        return ["ja_JP", "de_DE", "fr_FR"].first { $0.localeLanguageCode != system } ?? "ja_JP"
    }()

    func testSelectedLanguageReachesExactlyTheRoutesWhoseCapabilityAcceptsIt() throws {
        let code = selection.localeLanguageCode
        for model in DesktopLiveTranscription.liveModels {
            let sent = try upstream(model.id, language: selection)
            if ModelCatalog.liveCapabilities(for: model.id).supportsLanguageHint {
                XCTAssertTrue(sent.contains(code), "\(model.id) dropped the selection: \(sent.sorted())")
            } else {
                let baseline = try upstream(model.id, language: nil)
                XCTAssertEqual(sent, baseline, "\(model.id) has no language field to change")
            }
            for stored in [selection, selection.replacingOccurrences(of: "_", with: "-")] {
                XCTAssertFalse(sent.contains(stored), "\(model.id) sent the stored locale \(stored)")
            }
        }
    }

    func testAutomaticSendsNoLanguageAndNoMarker() throws {
        let code = selection.localeLanguageCode
        for model in DesktopLiveTranscription.liveModels {
            for automatic in [TranscriptionLanguageCatalog.automaticIdentifier, "Automatic", "auto", " "] {
                let sent = try upstream(model.id, language: automatic)
                XCTAssertFalse(sent.contains(code), "\(model.id) with \(automatic)")
                XCTAssertFalse(sent.contains { $0.lowercased() == "automatic" }, "\(model.id) sent the marker")
            }
        }
    }

    func testProfileLanguageReachesItsRouteOrIsReportedUnavailable() {
        for model in DesktopLiveTranscription.liveModels {
            let profile = DictationProfile(
                name: "Language", transcriptionModelID: model.id, languageIdentifier: selection,
                transcriptionRouting: .remoteStreaming
            )
            let session = DesktopProfileSessionResolver.resolve(
                profile: profile, defaultModel: model.id, defaultPostProcessing: .init(mode: .disabled),
                capabilities: .shared
            )
            XCTAssertEqual(session.modelIdentifier, model.id)
            if ModelCatalog.liveCapabilities(for: model.id).supportsLanguageHint {
                XCTAssertEqual(session.language, selection, model.id)
                XCTAssertTrue(session.limitations.isEmpty, model.id)
            } else {
                XCTAssertNil(session.language, model.id)
                XCTAssertEqual(session.limitations, [.languageUnavailableForLiveModel(languageIdentifier: selection)],
                               "\(model.id) must say its language is not sent")
            }
        }
        let accepted = Set(DesktopLiveTranscription.languageHintModelIDs.compactMap {
            DesktopLiveTranscription.route(forID: $0)?.provider
        })
        XCTAssertTrue(accepted.contains(.gladia), "Gladia's session request pins the language")
        XCTAssertTrue(accepted.contains(.revai), "Rev.ai's socket query carries its own language code")
        XCTAssertFalse(accepted.contains(.cartesia), "Cartesia Ink-2 is English only, with no language field")
    }
}

private extension DesktopLiveLanguageParityTests {
    /// Every string the route's client sends before any audio: its socket
    /// query values, the JSON of frames sent once the socket opens and the
    /// JSON of Gladia's session request, which is held unanswered.
    func upstream(_ model: String, language: String?) throws -> Set<String> {
        let sockets = AssemblyAISocketFactory()
        let sessions = LanguageParitySessions()
        // A host supplies its saved Azure resource; every other route ignores it.
        let client = try XCTUnwrap(DesktopLiveTranscription.makeClient(
            model: model, apiKey: "synthetic", language: language,
            azureEndpoint: "https://synthetic.services.ai.azure.com", initiateGladiaSession: sessions.initiator,
            makeConnection: { sockets.make($0) }
        ), model)
        client.start(onTranscript: { _, _ in }, onError: { XCTFail("\(model) reported \($0)") })
        defer { client.cancel() }
        sockets.sockets.first?.open()
        var sent = Set<String>()
        for request in sockets.requests {
            let url = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
            sent.formUnion(url?.queryItems?.compactMap(\.value) ?? [])
        }
        let payloads = sockets.sockets.flatMap(\.controls).map { Data($0.utf8) } + sessions.bodies
        for payload in payloads {
            guard let object = try? JSONSerialization.jsonObject(with: payload) else { continue }
            sent.formUnion(Self.strings(in: object))
        }
        return sent
    }

    /// Client event identities are generated per session and carry no language.
    static func strings(in object: Any) -> [String] {
        switch object {
        case let text as String: return [text]
        case let array as [Any]: return array.flatMap { strings(in: $0) }
        case let dictionary as [String: Any]:
            return dictionary.filter { $0.key != "event_id" }.values.flatMap { strings(in: $0) }
        default: return []
        }
    }
}

/// Records Gladia's session requests and never answers one, so no socket opens.
private final class LanguageParitySessions: @unchecked Sendable {
    private final class Held: GladiaLiveSessionRequest {
        func cancel() {}
    }

    private let lock = NSLock()
    private var requests: [URLRequest] = []

    var bodies: [Data] { lock.withLock { requests.compactMap(\.httpBody) } }

    var initiator: GladiaLiveClient.SessionInitiator {
        { [self] request, _ in
            lock.withLock { requests.append(request) }
            return Held()
        }
    }
}
