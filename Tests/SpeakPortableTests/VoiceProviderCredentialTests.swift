import Foundation
import XCTest
@testable import SpeakCore

final class VoiceProviderCredentialTests: XCTestCase {
    private let session = UUID(), epoch = UUID(), request = UUID()

    func testProviderProjection_UsesCanonicalMetadataAndPurposeWithoutRequiringADiscoveredVoice() throws {
        XCTAssertEqual(VoiceAccountProvider.all.map(\.id), [
            LiveTranscriptionProviderID.xai.rawValue, LiveTranscriptionProviderID.mistral.rawValue,
            LiveTranscriptionProviderID.soniox.rawValue
        ])
        for provider in VoiceAccountProvider.all {
            let metadata = try XCTUnwrap(LiveTranscriptionProviderID(rawValue: provider.id))
            XCTAssertEqual(provider.displayName, metadata.displayName)
            let slot = try VoiceOutputCredentialSlot(provider: provider)
            XCTAssertEqual(slot.purpose, .voiceOutput)
            XCTAssertEqual(ModelCredentialResolver.requirement(for: provider.id, purpose: .voiceOutput),
                           .apiKey(identifier: slot.identifier, providerName: slot.providerName))
        }
        XCTAssertTrue(VoiceAccountProvider.xai.hasDocumentedPresets)
        XCTAssertTrue(VoiceAccountProvider.soniox.hasDocumentedPresets)
        XCTAssertFalse(VoiceAccountProvider.mistral.hasDocumentedPresets)
        XCTAssertThrowsError(try VoiceAccountProvider(id: "openai"))
        XCTAssertThrowsError(try VoiceAccountProvider(id: " Mistral "))
        XCTAssertThrowsError(try VoiceAccountProvider(id: "mistral/foreign"))
    }

    func testOpenAndCancel_HaveIndependentSessionEpochAndNoSlotOrSecret() throws {
        let open = try message()
        guard case .open(let context, let id) = open else { return XCTFail("Expected open") }
        XCTAssertEqual(context.provider, .mistral)
        XCTAssertEqual(context.sessionID, session)
        XCTAssertEqual(context.epoch, epoch)
        XCTAssertEqual(id, request)
        guard case .cancel(let cancelled, let cancelID) = try message(operation: "cancel") else {
            return XCTFail("Expected cancel")
        }
        XCTAssertEqual(cancelled, context)
        XCTAssertEqual(cancelID, id)
        XCTAssertNotEqual(VoiceOutputCredentialDestination.explicitProvider(context),
                          .selectedVoice(selectionEpoch: epoch))
        XCTAssertThrowsError(try message(identifier: "mistral.apiKey"))
        XCTAssertThrowsError(try message(key: "synthetic-secret"))
        XCTAssertThrowsError(try message(operation: "cancel", identifier: "mistral.apiKey"))
        XCTAssertThrowsError(try message(operation: "cancel", key: "synthetic-secret"))
    }

    func testReplaceAndRemove_RequireExactCanonicalProviderSlotAndSanitizeDescription() throws {
        let replacement = try message(
            operation: "replace", identifier: "mistral.apiKey", key: " synthetic-private-key ")
        guard case .save(let key, let request) = replacement else { return XCTFail("Expected replace") }
        XCTAssertEqual(key, "synthetic-private-key")
        XCTAssertEqual(request.operation, .replace)
        XCTAssertEqual(request.context.provider, .mistral)
        XCTAssertEqual(request.identifier, "mistral.apiKey")
        XCTAssertFalse(String(describing: replacement).contains(key))
        XCTAssertFalse(String(reflecting: replacement).contains(key))
        guard case .save(let removed, let removal) = try message(
            operation: "remove", identifier: "mistral.apiKey") else { return XCTFail("Expected removal") }
        XCTAssertEqual(removed, "")
        XCTAssertEqual(removal.operation, .remove)
        XCTAssertThrowsError(try message(operation: "replace", identifier: "openai.apiKey", key: "synthetic"))
        XCTAssertThrowsError(try message(operation: "replace", identifier: "xai.apiKey", key: "synthetic"))
        XCTAssertThrowsError(try message(operation: "replace", identifier: "mistral.apiKey", key: " "))
        XCTAssertThrowsError(try message(operation: "replace", identifier: "mistral.apiKey", key: "bad\nkey"))
        XCTAssertThrowsError(try message(operation: "remove", identifier: "mistral.apiKey", key: "synthetic"))
    }

    func testMalformedOrOversizedNativeFields_RefuseBeforeCredentialAdmission() throws {
        XCTAssertThrowsError(try message(provider: "mistral\n"))
        XCTAssertThrowsError(try message(provider: String(repeating: "a", count: 33)))
        XCTAssertThrowsError(try message(operation: "unrecognized"))
        XCTAssertThrowsError(try message(purpose: "transcription"))
        XCTAssertThrowsError(try message(sessionID: "not-a-uuid"))
        XCTAssertThrowsError(try message(epochID: ""))
        XCTAssertThrowsError(try message(requestID: String(repeating: "a", count: 37)))
        XCTAssertThrowsError(try message(operation: "replace", identifier: String(repeating: "a", count: 129)))
        XCTAssertThrowsError(try message(
            operation: "replace", identifier: "mistral.apiKey", key: String(repeating: "a", count: 8_193)))
        guard case .open(let lower, _) = try message(epochID: epoch.uuidString.lowercased()) else {
            return XCTFail("Expected mixed-case UUID open")
        }
        XCTAssertEqual(lower.epoch, epoch)
    }

    private func message(
        operation: String = "open", purpose: String = "voice-output", provider: String = "mistral",
        identifier: String = "", key: String = "", sessionID: String? = nil,
        epochID: String? = nil, requestID: String? = nil
    ) throws -> VoiceProviderCredentialMessage {
        try .init(
            operation: operation, purpose: purpose, providerID: provider, identifier: identifier,
            sessionID: sessionID ?? session.uuidString, epoch: epochID ?? epoch.uuidString,
            requestID: requestID ?? request.uuidString, key: key)
    }
}
