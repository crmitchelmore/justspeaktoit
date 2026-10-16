import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopHostLivePolishTests: XCTestCase {
    func testInstantActualCapture_HasNoCleanupCredentialReadRequestOrMetadata() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(enabled: false)
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        fixture.effects.client.emit("draft")
        await fixture.toggle()
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "authoritative raw")
        XCTAssertNil(record.livePolishResult)
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
    }

    func testLegacyAndOwnedCapture_FinalUsesCapturedKeyAndKeepsRawAndPolishedHistorySeparate() async throws {
        for owned in [false, true] {
            let fixture = AutoCleanHostFixture()
            try await fixture.prepare(owned: owned)
            await fixture.toggle()
            XCTAssertTrue(fixture.effects.outputs.isEmpty, "Preview must never insert into another application")
            fixture.effects.setKey("changed-after-start")
            await fixture.toggle()
            let record = try await fixture.record()
            XCTAssertEqual(record.originalText, "authoritative raw")
            XCTAssertEqual(record.displayText, "Clean: authoritative raw")
            XCTAssertEqual(record.livePolishResult?.input, "authoritative raw")
            XCTAssertEqual(record.livePolishResult?.text, "Clean: authoritative raw")
            XCTAssertEqual(record.postProcessingModelIdentifier, ModelCatalog.defaultFastTextModel)
            XCTAssertEqual(fixture.effects.cleanups, [.init(
                text: "authoritative raw", model: ModelCatalog.defaultFastTextModel, key: "cleanup-key-at-start"
            )])
            XCTAssertEqual(fixture.effects.keyReads, ["openrouter.apiKey"])
            XCTAssertTrue(fixture.effects.postProcesses.isEmpty)
            let reloaded = try await fixture.host.store.record(id: record.id)
            XCTAssertEqual(reloaded.livePolishResult, record.livePolishResult)
            try await fixture.cleanup()
        }
    }

    func testFinalPolishThenOrdinaryCleanup_UsesCleanedTextOnlyWhenSkipIsFalse() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(skip: false)
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.host.autoCleanFixtureSettings(options: .init(
            mode: .local, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID
        ))
        await fixture.toggle()
        await fixture.toggle()
        let record = try await fixture.record()
        XCTAssertEqual(fixture.effects.postProcesses, ["Clean: authoritative raw"])
        XCTAssertTrue(record.livePolishResult?.succeeded == true)
        XCTAssertEqual(record.originalText, "authoritative raw")
    }

    func testFailedPolish_DoesNotSuppressOrdinaryCleanupOrClaimSuccess() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        fixture.effects.failPolish()
        await fixture.host.autoCleanFixtureSettings(options: .init(
            mode: .local, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID
        ))
        await fixture.toggle()
        await fixture.toggle()
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "authoritative raw")
        XCTAssertFalse(record.livePolishResult?.succeeded ?? true)
        XCTAssertNil(record.livePolishResult?.text)
        XCTAssertTrue(record.postProcessingFailure?.contains("Injected Auto-Clean failure") == true)
        XCTAssertEqual(fixture.effects.postProcesses, ["authoritative raw"])
        XCTAssertTrue(fixture.effects.outputs.isEmpty, "An explicitly failed cleanup is not silently inserted")
    }

    func testMissingCredentialAndUnsupportedCleanupModel_RetainRawAndNeverInvokeClient() async throws {
        for missing in [true, false] {
            let fixture = AutoCleanHostFixture()
            try await fixture.prepare()
            if missing {
                fixture.effects.setKey(" \n ")
            } else {
                let configuration = try DesktopConfiguration(values: [
                    "speedMode": AnyCodable(.string("livePolish")),
                    "livePolishModel": AnyCodable(.string("unknown/model")),
                    "postRecordingTailDuration": AnyCodable(.int(0))
                ])
                await fixture.host.autoCleanFixtureSettings(configuration: configuration)
            }
            await fixture.toggle()
            await fixture.toggle()
            let record = try await fixture.record()
            XCTAssertEqual(record.originalText, "authoritative raw")
            XCTAssertNil(record.livePolishResult?.text)
            XCTAssertNotNil(record.postProcessingFailure)
            XCTAssertTrue(fixture.effects.cleanups.isEmpty)
            XCTAssertEqual(fixture.effects.keyReads.count, missing ? 1 : 0)
            try await fixture.cleanup()
        }
    }

    func testCloseDuringNonCooperativeFinalPolish_RetiresLaneAndDoesNotInsertLateResult() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let requested = expectation(description: "polish requested")
        fixture.effects.holdPolish { requested.fulfill() }
        await fixture.toggle()
        let stopping = Task { await fixture.toggle() }
        await fulfillment(of: [requested], timeout: 2)
        let report = await fixture.host.close()
        await stopping.value
        XCTAssertTrue(report.isComplete)
        let before = try await fixture.record()
        XCTAssertEqual(before.originalText, "authoritative raw")
        XCTAssertNil(before.processedText)
        fixture.effects.releasePolish()
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        XCTAssertNil(before.livePolishResult?.text)
    }
}
