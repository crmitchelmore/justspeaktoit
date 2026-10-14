import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopComparisonReadinessTests: XCTestCase {
    override func setUp() {
        FakeLog.shared.reset()
        ComparisonPresentations.shared.reset()
        DesktopHostModels.configure(streamingQualified: true, local: [])
    }

    func testReadyPickerUsesCanonicalRequirementsAndRefreshesAfterKeyWrites() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.openComparison()
        XCTAssertEqual(ComparisonPresentations.shared.latest?.models, "")
        XCTAssertTrue(ComparisonPresentations.shared.latest?.detail.contains("No OpenAI API key") == true)
        let option = try XCTUnwrap(DesktopHostModels.visible.first { $0.id == "openai/whisper-1" })
        let slot = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == option.id })
        await controller.saveKey("synthetic-key", modelIndex: slot)
        let ready = try XCTUnwrap(ComparisonPresentations.shared.latest)
        for candidate in DesktopHostModels.visible {
            let purpose: ModelCredentialPurpose = DesktopHostModels.isLive(candidate.id)
                ? .liveTranscription : .batchTranscription
            let requirement = ModelCredentialResolver.requirement(for: candidate.id, purpose: purpose)
            if case .apiKey(let identifier, _) = requirement {
                XCTAssertEqual(
                    DesktopHostModels.provider(for: candidate.id)?.apiKeyIdentifier, identifier, candidate.id
                )
            }
            let expected = requirement == .apiKey(identifier: "openai.apiKey", providerName: "OpenAI")
            XCTAssertEqual(ready.models.split(separator: "\n").contains {
                $0.hasPrefix(candidate.id + "\t")
            }, expected, candidate.id)
        }
        await controller.saveKey("", modelIndex: slot)
        XCTAssertEqual(ComparisonPresentations.shared.latest?.models, "")
        await controller.close()
    }

    func testUnavailableSavedSelectionsSurviveReadyOnlyEditsAndRelaunch() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.openComparison()
        let states = await controller.comparisonModelStates()
        let file = try XCTUnwrap(states.first { $0.option.id == "openai/whisper-1" }).option
        let live = try XCTUnwrap(DesktopHostModels.live.first).id
        let other = try XCTUnwrap(states.first {
            !DesktopHostModels.isLive($0.option.id)
                && DesktopHostModels.provider(for: $0.option.id)?.apiKeyIdentifier != "openai.apiKey"
        }).option.id
        let store = try await controller.loadComparisonStore()
        try await store.selectModels([file.id, live, other], replacing: [file.id, live, other])
        await controller.refreshComparison()
        XCTAssertTrue(ComparisonPresentations.shared.latest?.detail.contains("saved selection retained") == true)
        await controller.comparisonEvent(125, text: file.id, index: 0)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("selection was not saved") })
        await controller.comparisonEvent(125, text: "", index: 0)
        let retained = await store.selectedModelIDs()
        XCTAssertEqual(retained, [file.id, live, other])
        FakeLog.shared.setKey("synthetic-key", name: "openai.apiKey")
        await controller.refreshComparison()
        XCTAssertTrue(ComparisonPresentations.shared.latest?.models.contains(
            file.id + "\t" + DesktopHostModels.uiText(file.displayName) + "\t0\t1"
        ) == true)
        await controller.comparisonEvent(125, text: "", index: 0)
        let readyCleared = await store.selectedModelIDs()
        XCTAssertFalse(readyCleared.contains(file.id))
        XCTAssertTrue(readyCleared.contains(other))
        let relaunched = try DesktopComparisonStore(directory: store.directory)
        let persisted = await relaunched.selectedModelIDs()
        XCTAssertEqual(persisted, readyCleared)
        await controller.close()
    }

    func testPostProcessingKeyWriteRefreshesComparisonEvenWhenSettingsWriteFails() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(
            directory: root, effects: ReadinessEffects(credentialReadFails: false)
        )
        await controller.openComparison()
        XCTAssertEqual(ComparisonPresentations.shared.latest?.models, "")
        await controller.savePostProcessing(enabled: true, modelIndex: 0, prompt: "", key: "synthetic-key")
        let presentation = try XCTUnwrap(ComparisonPresentations.shared.latest)
        let expected = DesktopHostModels.visible.filter {
            ModelCredentialResolver.requirement(for: $0.id, purpose: .batchTranscription)
                == .apiKey(identifier: "openrouter.apiKey", providerName: "OpenRouter")
                && !DesktopHostModels.isLive($0.id)
        }
        XCTAssertFalse(expected.isEmpty)
        for option in expected { XCTAssertTrue(presentation.models.contains(option.id + "\t")) }
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Could not save post-processing settings") == true)
        await controller.close()
    }

    func testFreshAdmissionRejectsRevokedKeysAfterPlaybackSuspensionBeforeAnyWork() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        FakeLog.shared.setKey("synthetic-key", name: "openai.apiKey")
        await controller.openComparison()
        let ids = DesktopHostModels.visible.filter {
            !DesktopHostModels.isLive($0.id)
                && DesktopHostModels.provider(for: $0.id)?.apiKeyIdentifier == "openai.apiKey"
        }.prefix(2).map(\.id)
        XCTAssertEqual(ids.count, 2)
        let gate = Gate(open: false)
        let playback = await controller.suspendComparisonPlayback(gate)
        let start = Task {
            await controller.comparisonEvent(
                102, text: "\n" + ids.joined(separator: "\t") + "\nnot-user-audio.wav", index: 0
            )
        }
        await playback.stopping.pass()
        FakeLog.shared.setKey("", name: "openai.apiKey")
        gate.release()
        await start.value
        XCTAssertTrue(FakeLog.shared.allStatuses.contains {
            $0.contains("could not start") && $0.contains("No OpenAI")
        })
        let task = await controller.comparisonTask
        XCTAssertNil(task)
        let store = try await controller.loadComparisonStore()
        let rounds = await store.rounds()
        XCTAssertTrue(rounds.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.appendingPathComponent("Samples").path))
        await controller.close()
    }

    func testAzureSettingsAndCredentialReadFailuresAreExplicitAndCannotAdmit() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        FakeLog.shared.setKey("synthetic-key:uksouth", name: AzureSpeechConfiguration.credentialIdentifier)
        await controller.openComparison()
        let azure = try XCTUnwrap(DesktopHostModels.live.first {
            LiveTranscriptionRouting.route(for: $0.id)?.provider == .azure
        })
        XCTAssertFalse(ComparisonPresentations.shared.latest?.models.contains(azure.id + "\t") == true)
        XCTAssertTrue(
            ComparisonPresentations.shared.latest?.detail.contains("needs your Azure Speech resource") == true
        )
        await controller.saveAzureResourceEndpoint("http://127.0.0.1:9999")
        XCTAssertTrue(ComparisonPresentations.shared.latest?.models.contains(azure.id + "\t") == true)
        await controller.saveAzureResourceEndpoint("")
        XCTAssertFalse(ComparisonPresentations.shared.latest?.models.contains(azure.id + "\t") == true)
        await controller.close()
        let failing = try DesktopHostController<FakePlatform>(directory: root, effects: ReadinessEffects())
        await failing.openComparison()
        XCTAssertEqual(ComparisonPresentations.shared.latest?.models, "")
        XCTAssertTrue(
            ComparisonPresentations.shared.latest?.detail.contains("Could not read the OpenAI API key") == true
        )
        await failing.comparisonEvent(
            103, text: "\n" + DesktopHostModels.live.prefix(2).map(\.id).joined(separator: "\t"), index: 0
        )
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("could not start") == true)
        await failing.close()
    }

    func testFreshAdmissionRejectsAzureEndpointClearedDuringPlaybackSuspension() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        FakeLog.shared.setKey("synthetic-key:uksouth", name: AzureSpeechConfiguration.credentialIdentifier)
        FakeLog.shared.setKey("synthetic-key", name: "openai.apiKey")
        await controller.saveAzureResourceEndpoint("http://127.0.0.1:9999")
        let azure = try XCTUnwrap(DesktopHostModels.live.first {
            LiveTranscriptionRouting.route(for: $0.id)?.provider == .azure
        })
        let openai = try XCTUnwrap(DesktopHostModels.live.first {
            LiveTranscriptionRouting.route(for: $0.id)?.provider == .openai
        })
        let gate = Gate(open: false)
        let playback = await controller.suspendComparisonPlayback(gate)
        let start = Task {
            await controller.comparisonEvent(103, text: "\n\(azure.id)\t\(openai.id)", index: 0)
        }
        await playback.stopping.pass()
        await controller.saveAzureResourceEndpoint("")
        gate.release()
        await start.value
        XCTAssertTrue(FakeLog.shared.allStatuses.contains {
            $0.contains("could not start") && $0.contains("needs your Azure Speech resource")
        })
        let task = await controller.comparisonTask
        XCTAssertNil(task)
        await controller.close()
    }

    func testClosingDuringPlaybackSuspensionCannotAdmitLateComparison() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        FakeLog.shared.setKey("synthetic-key", name: "openai.apiKey")
        let ids = DesktopHostModels.visible.filter {
            !DesktopHostModels.isLive($0.id)
                && DesktopHostModels.provider(for: $0.id)?.apiKeyIdentifier == "openai.apiKey"
        }.prefix(2).map(\.id)
        let gate = Gate(open: false)
        let playback = await controller.suspendComparisonPlayback(gate)
        let start = Task {
            await controller.comparisonEvent(
                102, text: "\n" + ids.joined(separator: "\t") + "\nsynthetic.wav", index: 0
            )
        }
        await playback.stopping.pass()
        let closing = Task { await controller.close() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await controller.closed), ContinuousClock.now < deadline { await Task.yield() }
        let closed = await controller.closed
        XCTAssertTrue(closed)
        gate.release()
        await start.value
        _ = await closing.value
        let task = await controller.comparisonTask
        XCTAssertNil(task)
        let capture = await controller.comparisonCapture
        XCTAssertNil(capture)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private final class ComparisonPresentations: @unchecked Sendable {
    static let shared = ComparisonPresentations()
    private let lock = NSLock()
    private var value: DesktopComparisonPresentation?
    var latest: DesktopComparisonPresentation? { lock.withLock { value } }
    func reset() { lock.withLock { value = nil } }
    func receive(_ presentation: DesktopComparisonPresentation) { lock.withLock { value = presentation } }
}

extension FakePlatform {
    static func comparisonPresentation(_ presentation: DesktopComparisonPresentation) {
        ComparisonPresentations.shared.receive(presentation)
    }
}

private struct ReadinessEffects: DesktopHostEffects {
    typealias Platform = FakePlatform
    var credentialReadFails = true
    func apiKey(name: String) throws -> String {
        if credentialReadFails { throw CocoaError(.fileReadNoPermission) }
        return FakeLog.shared.key(name)
    }
    func makeCapture(
        context: DesktopCaptureContext, deviceID: String, sampleRate: Int, frameMilliseconds: Int
    ) throws -> any DesktopRecordingCapture {
        XCTFail("No capture without ready credentials.")
        return SyntheticCapture(context: context)
    }
    func makeLiveClient(
        model: String, key: String, language: String?, azureEndpoint: String
    ) -> (any FinalizingStreamingTranscriptionClient)? {
        XCTFail("No client without ready credentials.")
        return nil
    }
    func transcribe(
        _ request: DesktopHostTranscriptionRequest, with controller: DesktopHostController<FakePlatform>
    ) async throws -> TranscriptionResult { throw CocoaError(.featureUnsupported) }
    func perform(_ job: FakeJob, text: String) -> String { XCTFail("No output from comparison."); return "" }
    func writeSettings(_ data: Data, to url: URL) throws { throw CocoaError(.fileWriteNoPermission) }
}

private extension DesktopHostController where Platform == FakePlatform {
    func suspendComparisonPlayback(_ gate: Gate) -> FakePlayback {
        playback.stopGate = gate
        return playback
    }
}
