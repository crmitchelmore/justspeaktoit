import Foundation
import XCTest
@testable import SpeakCore
@testable import SpeakDesktopHost

/// The Windows and Linux balance lines beside API keys: what each row says
/// before and after a check, that only a saved key is ever read or sent, and
/// that a replaced key cannot inherit the previous key's figure.
final class DesktopProviderBalancesTests: XCTestCase {
    private let openRouter = ProviderCredentialCatalogue.apiKeyIdentifier(for: "openrouter")
    private let openAI = ProviderCredentialCatalogue.apiKeyIdentifier(for: "openai")
    private let openAITTS = ProviderCredentialCatalogue.apiKeyIdentifier(for: "openai.tts")
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    func testShowPublishesOnePrimaryLinePerAccountWithoutChecking() async {
        let harness = Harness(keys: [:])
        await harness.store.show([row(openRouter, saved: false), row(openAI, saved: true), row(openAITTS, saved: true)])

        let lines = harness.log.lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(Set(lines.map(\.identifier)), [openAI, openRouter])
        XCTAssertFalse(lines.contains { $0.identifier == openAITTS }, "A secondary card must not repeat the account")
        let openAILine = try? XCTUnwrap(lines.first { $0.identifier == openAI })
        XCTAssertEqual(openAILine?.canRefresh, false)
        XCTAssertTrue(openAILine?.text.hasPrefix("Balance: not shown here.") == true)
        XCTAssertTrue(openAILine?.text.contains("https://platform.openai.com/") == true)
        XCTAssertEqual(
            lines.first { $0.identifier == openRouter }?.text,
            "Balance: save a OpenRouter key to see the account balance."
        )
        XCTAssertEqual(harness.source.calls, 0)
        XCTAssertEqual(harness.reads.count, 0, "Opening the page must not read a key until a check")
    }

    func testRefreshSavedChecksThenPublishesTheResult() async {
        let harness = Harness(keys: [openRouter: " sk-or-1 "])
        await harness.store.show([row(openRouter, saved: true)])
        XCTAssertEqual(harness.log.lines.last?.text, "Balance: not checked yet. Choose Check balance.")
        XCTAssertEqual(harness.log.lines.last?.canRefresh, true)

        await harness.store.refreshSaved()
        XCTAssertEqual(harness.log.lines.last?.text, "Balance: checking…")
        XCTAssertEqual(harness.log.lines.last?.isResult, false)

        let result = await harness.waitForResult()
        XCTAssertEqual(harness.source.keys, ["sk-or-1"], "The key reaches the source trimmed, and only once")
        XCTAssertTrue(result.text.hasPrefix("Balance: $12.50 credit. Checked "), result.text)
        XCTAssertTrue(result.canRefresh)
        XCTAssertFalse(result.text.contains("sk-or-1"))
    }

    func testCheckOnAnUnsavedOrUnreadableRowNeverFetches() async {
        let harness = Harness(keys: [:])
        await harness.store.show([row(openRouter, saved: false), row(openAI, saved: true)])
        let before = harness.log.lines.count

        await harness.store.refresh(credentialIdentifier: openRouter)
        await harness.store.refresh(credentialIdentifier: openAI)
        await harness.store.refresh(credentialIdentifier: "unknown.apiKey")

        XCTAssertEqual(harness.source.calls, 0)
        XCTAssertEqual(harness.reads.count, 0)
        XCTAssertEqual(harness.log.lines.count, before + 2, "Each known row gets its line again, not silence")
    }

    func testSavedKeyThatCannotBeReadReportsUnknownWithoutFetching() async {
        let harness = Harness(keys: [:])
        await harness.store.show([row(openRouter, saved: true)])
        await harness.store.refresh(credentialIdentifier: openRouter)

        let result = await harness.waitForResult()
        XCTAssertEqual(harness.source.calls, 0)
        XCTAssertTrue(result.text.hasPrefix("Balance unknown."), result.text)
    }

    func testChangedKeyDropsTheInFlightAndShownFigure() async {
        let harness = Harness(keys: [openRouter: "old-key"], gated: true)
        await harness.store.show([row(openRouter, saved: true)])
        await harness.store.refresh(credentialIdentifier: openRouter)
        await harness.source.waitForCall()

        await harness.store.credentialChanged(openRouter)
        harness.source.release()
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(harness.log.lines.contains(where: \.isResult), "The old key's figure must not land")
        XCTAssertEqual(harness.log.lines.last?.text, "Balance: not checked yet. Choose Check balance.")
        let line = await harness.store.line(forCredentialIdentifier: openRouter)
        XCTAssertEqual(line?.isResult, false)
    }

    func testRemovedKeyForgetsItsFigure() async {
        let harness = Harness(keys: [openRouter: "sk-or-1"])
        await harness.store.show([row(openRouter, saved: true)])
        await harness.store.refresh(credentialIdentifier: openRouter)
        _ = await harness.waitForResult()

        await harness.store.show([row(openRouter, saved: false)])

        XCTAssertEqual(
            harness.log.lines.last?.text, "Balance: save a OpenRouter key to see the account balance."
        )
        let line = await harness.store.line(forCredentialIdentifier: openRouter)
        XCTAssertEqual(line?.canRefresh, false)
    }

    func testTextStacksFigureDetailScheduleAndCheckTime() {
        let snapshot = ProviderBalanceSnapshot(
            accountID: "elevenlabs", providerDisplayName: "ElevenLabs",
            state: .allowance(remaining: 4000, total: 5000, unit: .characters),
            refreshedAt: fixedNow.addingTimeInterval(-30),
            resetsAt: fixedNow.addingTimeInterval(86_400 * 3)
        )

        let text = DesktopProviderBalances.text(for: snapshot, now: fixedNow)

        XCTAssertTrue(text.hasPrefix("Balance: 4,000 of 5,000 characters left. Resets "), text)
        XCTAssertTrue(text.contains(". Checked "), text)
        XCTAssertTrue(text.hasSuffix("."), text)
        let unknown = DesktopProviderBalances.text(
            for: ProviderBalanceSnapshot(
                accountID: "openrouter", providerDisplayName: "OpenRouter",
                state: .unknown(reason: "OpenRouter did not authorise this key."), refreshedAt: fixedNow
            ),
            now: fixedNow
        )
        XCTAssertTrue(unknown.hasPrefix("Balance unknown. OpenRouter did not authorise this key."), unknown)
    }

    // MARK: - Helpers

    private func row(_ identifier: String, saved: Bool) -> DesktopAPIKeyRow {
        DesktopAPIKeyRow(
            identifier: identifier, label: identifier, uses: "Test", status: saved ? "Saved" : "Not set",
            isSaved: saved, hasError: false, keyPageURL: "https://example.test", entryHint: ""
        )
    }
}

private final class Harness: @unchecked Sendable {
    let log = LineLog()
    let reads = LineLog.Strings()
    let source: FakeOpenRouterSource
    let store: DesktopProviderBalances

    init(keys: [String: String], gated: Bool = false) {
        let source = FakeOpenRouterSource(gated: gated)
        let log = log, reads = reads
        self.source = source
        store = DesktopProviderBalances(
            sources: [source],
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            readKey: { identifier in reads.append(identifier); return keys[identifier] },
            publish: { log.append($0) }
        )
    }

    func waitForResult(file: StaticString = #filePath, line: UInt = #line) async -> DesktopProviderBalanceLine {
        for _ in 0..<200 {
            if let result = log.lines.last(where: \.isResult) { return result }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("No balance result was published", file: file, line: line)
        return DesktopProviderBalanceLine(identifier: "", text: "", canRefresh: false, isResult: false)
    }
}

private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DesktopProviderBalanceLine] = []
    var lines: [DesktopProviderBalanceLine] { lock.withLock { stored } }
    func append(_ line: DesktopProviderBalanceLine) { lock.withLock { stored.append(line) } }

    final class Strings: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var count: Int { lock.withLock { stored.count } }
        func append(_ value: String) { lock.withLock { stored.append(value) } }
    }
}

private final class FakeOpenRouterSource: ProviderBalanceSource, @unchecked Sendable {
    let accountID = "openrouter"
    private let lock = NSLock()
    private let gated: Bool
    private var received: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(gated: Bool) { self.gated = gated }

    var calls: Int { lock.withLock { received.count } }
    var keys: [String] { lock.withLock { received } }

    func fetchBalance(apiKey: String) async -> ProviderBalanceSnapshot {
        lock.withLock { received.append(apiKey) }
        if gated {
            await withCheckedContinuation { continuation in
                let resume = lock.withLock { () -> Bool in
                    if isReleased { return true }
                    gate = continuation
                    return false
                }
                if resume { continuation.resume() }
            }
        }
        return ProviderBalanceSnapshot(
            accountID: accountID, providerDisplayName: "OpenRouter",
            state: .cash(ProviderBalanceMoney(amount: Decimal(12.5), currencyCode: "USD")),
            refreshedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    func waitForCall() async {
        for _ in 0..<200 where calls == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    func release() {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            isReleased = true
            defer { gate = nil }
            return gate
        }
        continuation?.resume()
    }
}
