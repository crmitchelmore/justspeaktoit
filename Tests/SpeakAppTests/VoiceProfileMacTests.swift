import AVFoundation
import Foundation
import SpeakCore
import XCTest

@testable import SpeakApp

final class VoiceProfileMacTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-profile-mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testAudioAdapter_DecodesWAVAndM4AToMonoPCM() throws {
        let rate48k = 48_000
        let duration = 8.0
        let mono48k = Self.makeSpeechBuffer(duration: duration, sampleRate: rate48k, withPauses: true)
        let stereoWAVURL = temporaryRoot.appendingPathComponent("stereo-48k.wav")
        try Self.writeStereoPCM16WAV(samples: mono48k.samples, sampleRate: rate48k, to: stereoWAVURL)

        let decodedWAV = try VoiceProfileAudioAdapter.decodeAudioFile(at: stereoWAVURL, targetFormat: .pcm24k)
        XCTAssertEqual(decodedWAV.sampleRate, 24_000)
        XCTAssertEqual(decodedWAV.durationSeconds, duration, accuracy: 0.1)
        XCTAssertTrue(VoiceProfileQualityGate().evaluate(decodedWAV).passed)

        let m4aURL = temporaryRoot.appendingPathComponent("imported.m4a")
        try Self.writeM4AFile(buffer: mono48k, to: m4aURL)
        let decodedM4A = try VoiceProfileAudioAdapter.decodeAudioFile(at: m4aURL, targetFormat: .pcm24k)
        XCTAssertEqual(decodedM4A.sampleRate, 24_000)
        XCTAssertEqual(decodedM4A.durationSeconds, duration, accuracy: 0.25)
    }

    @MainActor
    func testVoiceProfileManager_LifecycleConsentPickerAndDelete() throws {
        let storeRoot = VoiceProfileStore.defaultDirectory(in: temporaryRoot)
        let manager = VoiceProfileManager(store: VoiceProfileStore(directory: storeRoot))
        let clip = VoiceProfileStore.ClipInput(
            pcmBuffer: Self.makeSpeechBuffer(duration: 9.0, sampleRate: 24_000, withPauses: true),
            transcript: "Hello world.",
            source: .recorded
        )

        XCTAssertThrowsError(
            try manager.createProfile(name: "Test", language: "en", clips: [clip], consent: nil)
        ) { XCTAssertEqual($0 as? VoiceProfileStoreError, .consentRequired) }

        let created = try manager.createProfile(
            name: "Mac Narrator",
            language: "en-US",
            clips: [clip],
            consent: ConsentAttestation()
        )
        XCTAssertTrue(manager.myTTSVoices.isEmpty)

        _ = try manager.renameProfile(id: created.id, name: "Edited Mac Narrator")
        _ = try manager.updateClipTranscript(
            profileID: created.id,
            clipID: created.clips[0].id,
            transcript: "Edited transcript"
        )
        _ = try manager.upsertEngineBinding(
            VoiceProfileEngineBinding(
                engineID: "local/tts/demo",
                engineDisplayName: "Local Demo",
                target: .localEmbedding(relativePath: "embeddings/demo.bin")
            ),
            for: created.id
        )
        _ = try manager.upsertEngineBinding(
            VoiceProfileEngineBinding(
                engineID: "elevenlabs",
                engineDisplayName: "ElevenLabs",
                target: .remoteVoice(voiceID: "el-remote-1", providerDisplayName: "ElevenLabs")
            ),
            for: created.id
        )

        let reloaded = VoiceProfileManager(store: VoiceProfileStore(directory: storeRoot))
        XCTAssertEqual(reloaded.profiles.count, 1)
        XCTAssertEqual(reloaded.profiles[0].name, "Edited Mac Narrator")
        XCTAssertEqual(reloaded.profiles[0].clips[0].transcript, "Edited transcript")
        XCTAssertEqual(reloaded.myTTSVoices.count, 2)
        XCTAssertTrue(reloaded.myTTSVoices.allSatisfy { $0.pickerGroupTitle == VoiceProfilePickerCatalog.groupTitle })

        let deletion = try reloaded.deleteProfile(id: created.id)
        XCTAssertEqual(deletion.remoteBindings.map(\.remoteVoiceID), ["el-remote-1"])
        XCTAssertTrue(reloaded.profiles.isEmpty)
        XCTAssertTrue(reloaded.myTTSVoices.isEmpty)
    }

    @MainActor
    func testMigrationStoreExport_ExcludesPrivateVoiceProfiles() async throws {
        let support = temporaryRoot.appendingPathComponent("SpeakApp", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let suite = "voice-profile-migration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let history = HistoryManager(
            fileManager: IsolatedSupportFileManager(root: temporaryRoot),
            flushInterval: 3_600,
            batchSizeThreshold: 10_000
        )
        let migrationStore = MigrationStore(
            defaults: defaults,
            support: support,
            history: history,
            secrets: SecureStorage(configuration: .init(service: suite))
        )

        let store = VoiceProfileStore(directory: VoiceProfileStore.defaultDirectory(in: support))
        let profile = try store.createProfile(
            name: "Secret Personal Voice",
            language: "en",
            clips: [
                VoiceProfileStore.ClipInput(
                    pcmBuffer: Self.makeSpeechBuffer(duration: 8.0, sampleRate: 24_000, withPauses: true),
                    transcript: "Unique secret phrase never exported",
                    source: .recorded
                )
            ],
            consent: ConsentAttestation()
        )

        let snapshot = try await migrationStore.snapshot(categories: Set(MigrationCategory.allCases))
        let encoded = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(profile.id.uuidString))
        XCTAssertFalse(encoded.contains("Secret Personal Voice"))
        XCTAssertFalse(encoded.contains("Unique secret phrase never exported"))
        XCTAssertFalse(encoded.contains(profile.clips[0].filename))
    }

    @MainActor
    func testTextToSpeechManager_IncludesMyVoicesAndFailsClosedWithoutFallback() async throws {
        let suite = "voice-profile-tts-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.ttsAutoPlay = false
        settings.ttsSaveToDirectory = false
        settings.defaultTTSVoice = "openai/alloy"

        let storage = SecureAppStorage(
            permissionsManager: PermissionsManager(),
            appSettings: settings,
            keychainService: "com.justspeaktoit.tests.voice-profile-tts.\(UUID().uuidString)"
        )
        let systemSpy = SpyTTSClient(provider: .system)
        let openAISpy = SpyTTSClient(provider: .openai)
        let manager = TextToSpeechManager(
            appSettings: settings,
            secureStorage: storage,
            clients: [.system: systemSpy, .openai: openAISpy],
            defaults: defaults
        )

        let profileID = UUID()
        let customVoiceID = "local/tts/\(profileID.uuidString.lowercased())"
        manager.myVoicesProvider = {
            [
                TTSVoice(
                    id: customVoiceID,
                    name: "My Local Voice (Demo)",
                    provider: .system,
                    traits: [.builtin],
                    previewURL: nil,
                    customGroupTitle: VoiceProfilePickerCatalog.groupTitle
                )
            ]
        }

        let listed = await manager.availableVoices()
        XCTAssertEqual(listed.first?.id, customVoiceID)

        do {
            _ = try await manager.synthesize(text: "Testing fail closed.", voice: customVoiceID)
            XCTFail("Expected unavailable My voices engine to fail closed without fallback")
        } catch let error as TTSError {
            guard case .synthesisFailure = error else {
                return XCTFail("Unexpected TTSError: \(error)")
            }
        }

        do {
            _ = try await manager.synthesizeForAutomation(
                text: "Testing automation fail closed.",
                voice: customVoiceID,
                model: nil,
                overrides: AutomationSpeechSettings(),
                format: .macDefault
            )
            XCTFail("Expected automation synthesis to fail closed without fallback")
        } catch let error as TTSError {
            guard case .synthesisFailure = error else {
                return XCTFail("Unexpected TTSError: \(error)")
            }
        }

        let systemCalls = await systemSpy.callCount
        let openAICalls = await openAISpy.callCount
        XCTAssertEqual(systemCalls, 0)
        XCTAssertEqual(openAICalls, 0)
    }

    func testVoicePickerGroupingAndSearch_PrioritizesMyVoices() {
        let voices = [
            TTSVoice(id: "openai/alloy", name: "Alloy", provider: .openai, traits: [.neutral], previewURL: nil),
            TTSVoice(
                id: "local/tts/profile-1",
                name: "Narrator (Local Demo)",
                provider: .system,
                traits: [.builtin],
                previewURL: nil,
                customGroupTitle: VoiceProfilePickerCatalog.groupTitle
            ),
            TTSVoice(id: "system/default", name: "System Default", provider: .system, traits: [.builtin], previewURL: nil)
        ]

        let catalog = LongListPickerItems(items: VoiceChooserFilter.sortedVoices(voices), id: { $0.id })
        let groups = catalog.groups(
            selection: "openai/alloy",
            query: "",
            searchText: { [$0.name, $0.provider.displayName, $0.customGroupTitle ?? ""] },
            group: { $0.pickerGroupTitle },
            groupOrder: { lhs, rhs in
                if lhs == VoiceProfilePickerCatalog.groupTitle && rhs != VoiceProfilePickerCatalog.groupTitle {
                    return true
                }
                if rhs == VoiceProfilePickerCatalog.groupTitle && lhs != VoiceProfilePickerCatalog.groupTitle {
                    return false
                }
                return lhs.localizedStandardCompare(rhs) == .orderedAscending
            }
        )
        XCTAssertEqual(groups.first?.title, VoiceProfilePickerCatalog.groupTitle)

        let searched = catalog.groups(
            selection: "openai/alloy",
            query: "My voices narrator",
            searchText: { [$0.name, $0.provider.displayName, $0.customGroupTitle ?? ""] },
            group: { $0.pickerGroupTitle }
        )
        XCTAssertEqual(searched.flatMap { $0.items.map(\.id) }, ["local/tts/profile-1"])
    }

    // MARK: - Helpers

    private static func makeSpeechBuffer(duration: Double, sampleRate: Int, withPauses: Bool) -> VoiceProfilePCMBuffer {
        let count = Int((duration * Double(sampleRate)).rounded())
        var samples = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let seconds = Double(index) / Double(sampleRate)
            let env = !withPauses || seconds.truncatingRemainder(dividingBy: 1.5) < 1.2 ? 1.0 : 0.002
            let wave = 0.55 * sin(2.0 * .pi * 145.0 * seconds)
                + 0.30 * sin(2.0 * .pi * 290.0 * seconds)
                + 0.15 * sin(2.0 * .pi * 435.0 * seconds)
            samples[index] = Float(env * 0.35 * wave)
        }
        return VoiceProfilePCMBuffer(samples: samples, sampleRate: sampleRate)
    }

    private static func writeStereoPCM16WAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        var payload = Data(capacity: samples.count * 4)
        for sample in samples {
            let intSample = Int16(max(-1.0, min(1.0, sample)) * Float(Int16.max)).littleEndian
            var left = intSample
            var right = intSample
            withUnsafeBytes(of: &left) { payload.append(contentsOf: $0) }
            withUnsafeBytes(of: &right) { payload.append(contentsOf: $0) }
        }
        let blockAlign: UInt16 = 4
        let byteRate = UInt32(sampleRate) * UInt32(blockAlign)
        var body = Data("WAVEfmt ".utf8)
        appendLE(UInt32(16), to: &body)
        appendLE(UInt16(1), to: &body)
        appendLE(UInt16(2), to: &body)
        appendLE(UInt32(sampleRate), to: &body)
        appendLE(byteRate, to: &body)
        appendLE(blockAlign, to: &body)
        appendLE(UInt16(16), to: &body)
        body.append(Data("data".utf8))
        appendLE(UInt32(payload.count), to: &body)
        body.append(payload)

        var file = Data("RIFF".utf8)
        appendLE(UInt32(body.count), to: &file)
        file.append(body)
        try file.write(to: url, options: .atomic)
    }

    private static func writeM4AFile(buffer: VoiceProfilePCMBuffer, to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(buffer.sampleRate),
            channels: 1,
            interleaved: false
        ), let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(buffer.samples.count)),
        let channel = pcm.floatChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        pcm.frameLength = AVAudioFrameCount(buffer.samples.count)
        buffer.samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress {
                channel.update(from: base, count: buffer.samples.count)
            }
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(buffer.sampleRate),
            AVNumberOfChannelsKey: 1
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: pcm)
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}

private final class IsolatedSupportFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    init(root: URL) {
        self.root = root
        super.init()
    }
    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        directory == .applicationSupportDirectory ? [root] : super.urls(for: directory, in: domainMask)
    }
}

private actor SpyTTSClient: TextToSpeechClient {
    let provider: TTSProvider
    private(set) var callCount = 0

    init(provider: TTSProvider) {
        self.provider = provider
    }

    func synthesize(text: String, voice: String, settings: TTSSettings) async throws -> TTSResult {
        callCount += 1
        throw TTSError.synthesisFailure("Spy stopped request")
    }

    func listVoices() async throws -> [TTSVoice] { [] }

    func validateAPIKey(_ key: String) async -> APIKeyValidationResult {
        APIKeyValidationResult(outcome: .success(message: "ok"), debug: nil)
    }
}
