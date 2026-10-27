import Foundation
@testable import SpeakCore
import XCTest

final class ProductAnalyticsCatalogueTests: XCTestCase {
    func testEventCatalogue_MapsEveryCaseToNameAndAllowlistedPropertyKeys() {
        XCTAssertEqual(Self.catalogue.count, 25)
        XCTAssertEqual(Set(Self.catalogue.map(\.name)).count, Self.catalogue.count)
        for entry in Self.catalogue {
            XCTAssertEqual(entry.event.name, entry.name)
            XCTAssertEqual(Set(entry.event.properties.keys), entry.keys, entry.name)
            XCTAssertTrue(entry.event.properties.values.allSatisfy { !$0.isEmpty }, entry.name)
            XCTAssertTrue(entry.keys.isDisjoint(with: Self.contextKeys), entry.name)
            XCTAssertEqual(entry.event.privacyClass, entry.privacyClass, entry.name)
        }
    }

    private static let contextKeys: Set<String> = [
        "platform", "app_version", "build", "os_major_minor", "distribution_channel", "locale_language_code",
        "architecture", "analytics_schema_version"
    ]

    private static let dimensionKeys: Set<String> = [
        "mode", "engine_type", "provider_type", "model_family", "language_code", "trigger"
    ]

    private static let dimensions = AnalyticsTranscriptionDimensions(
        mode: .live,
        engine: .cloud,
        provider: .deepgram,
        modelFamily: .nova,
        languageCode: "en-GB",
        trigger: .hotkey
    )

    private struct CatalogueEntry {
        let event: ProductAnalyticsEvent
        let name: String
        let keys: Set<String>
        let privacyClass: AnalyticsPrivacyClass
    }

    // swiftlint:disable:next function_body_length
    private static func makeCatalogue() -> [CatalogueEntry] {
        [
            CatalogueEntry(event: .appActiveDaily, name: "app_active_daily", keys: [], privacyClass: .pseudonymous),
            CatalogueEntry(
                event: .onboardingStarted(entryPoint: .freshInstall),
                name: "onboarding_started",
                keys: ["entry_point"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .onboardingStepCompleted(step: .welcome),
                name: "onboarding_step_completed",
                keys: ["step"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .onboardingPermissionResult(permission: .microphone, state: .granted),
                name: "onboarding_permission_result",
                keys: ["permission", "state"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .onboardingCompleted(stepsSkipped: .zero),
                name: "onboarding_completed",
                keys: ["steps_skipped_bucket"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .firstTranscriptionSucceeded(provider: .deepgram, engine: .cloud, daysSinceInstall: .one),
                name: "first_transcription_succeeded",
                keys: ["provider_type", "engine_type", "days_since_install_bucket"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .transcriptionStarted(dimensions),
                name: "transcription_started",
                keys: dimensionKeys,
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .transcriptionCompleted(
                    dimensions,
                    duration: .underFiveSeconds,
                    wordCount: .oneToTen,
                    latency: .under250Milliseconds,
                    output: .paste
                ),
                name: "transcription_completed",
                keys: dimensionKeys.union([
                    "duration_bucket", "word_count_bucket", "latency_bucket", "output_method"
                ]),
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .transcriptionFailed(dimensions, error: .timeout, stage: .provider),
                name: "transcription_failed",
                keys: dimensionKeys.union(["error_category", "pipeline_stage"]),
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .transcriptionCancelled(dimensions, duration: .underFiveSeconds),
                name: "transcription_cancelled",
                keys: dimensionKeys.union(["duration_bucket"]),
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .polishCompleted(
                    engine: .cloud,
                    provider: .openAI,
                    latency: .oneToThreeSeconds,
                    preset: .concise
                ),
                name: "polish_completed",
                keys: ["engine_type", "provider_type", "latency_bucket", "preset"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .polishFailed(
                    engine: .cloud,
                    provider: .openAI,
                    latency: .oneToThreeSeconds,
                    preset: .concise,
                    error: .rateLimited
                ),
                name: "polish_failed",
                keys: ["engine_type", "provider_type", "latency_bucket", "preset", "error_category"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .correctionApplied(rulesMatched: .one),
                name: "correction_applied",
                keys: ["rules_matched_bucket"],
                privacyClass: .anonymousCounter
            ),
            CatalogueEntry(
                event: .correctionRuleCreated(totalRules: .one),
                name: "correction_rule_created",
                keys: ["total_rules_bucket"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .profileActivated(profileCount: .one, isDefault: true),
                name: "profile_activated",
                keys: ["profile_count_bucket", "is_default"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .insightsViewed(surface: .insights),
                name: "insights_viewed",
                keys: ["surface"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .historyAction(.copy),
                name: "history_action",
                keys: ["action"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .voiceOutputUsed(engine: .cloud, provider: .elevenLabs),
                name: "voice_output_used",
                keys: ["engine_type", "provider_type"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .sendToMacCompleted(success: true, latency: .under250Milliseconds),
                name: "send_to_mac_completed",
                keys: ["success", "latency_bucket"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .modelDownloadCompleted(modelFamily: .parakeet, size: .oneToFiveGB, success: true),
                name: "model_download_completed",
                keys: ["model_family", "size_bucket", "success"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .keyboardEnabledState(enabled: true),
                name: "keyboard_enabled_state",
                keys: ["enabled"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .providerConfigured(provider: .openAI, method: .manual),
                name: "provider_configured",
                keys: ["provider_type", "method"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .settingsChanged(setting: .language, category: .transcription),
                name: "settings_changed",
                keys: ["setting_id", "category"],
                privacyClass: .pseudonymous
            ),
            CatalogueEntry(
                event: .errorDisplayed(error: .connectivity, surface: .recording),
                name: "error_displayed",
                keys: ["error_category", "surface"],
                privacyClass: .anonymousCounter
            ),
            CatalogueEntry(
                event: .analyticsOptIn(surface: .onboarding),
                name: "analytics_opt_in",
                keys: ["surface"],
                privacyClass: .pseudonymous
            )
        ]
    }

    private static let catalogue = makeCatalogue()
}

extension ProductAnalyticsCatalogueTests {
    func testDocumentedCatalogue_MatchesActualEventPropertiesAndPrivacyClasses() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let document = try String(contentsOf: root.appendingPathComponent("Docs/analytics-plan.md"), encoding: .utf8)
        let heading = try XCTUnwrap(document.range(of: "### Catalogue\n"))
        let remainder = String(document[heading.upperBound...])
        let table = remainder.components(separatedBy: "\n## ")[0]
        let rows = try documentedCatalogue(table)
        XCTAssertEqual(Set(rows.keys), Set(Self.catalogue.map(\.name)))
        for entry in Self.catalogue {
            let row = try XCTUnwrap(rows[entry.event.name], entry.name)
            XCTAssertEqual(row.keys, Set(entry.event.properties.keys), entry.name)
            XCTAssertEqual(row.privacy, entry.event.privacyClass, entry.name)
        }
    }

    private struct DocumentedEntry {
        let keys: Set<String>
        let privacy: AnalyticsPrivacyClass
    }

    private enum DocumentationError: Error {
        case malformedRow, unknownReference, unbalancedExplanation
    }

    func testDocumentedCatalogue_ExcludesInlineValuesAndResolvesReferencedKeys() throws {
        let rows = try documentedCatalogue("""
        | 11 | `polish_completed` | `preset` (built-in enum; custom reports `custom`), `engine_type` | P | Adoption |
        | 12 | `polish_failed` | as #11 + `error_category` (bounded enum) | A | Reliability |
        """)
        XCTAssertEqual(rows["polish_completed"]?.keys, ["preset", "engine_type"])
        XCTAssertEqual(rows["polish_failed"]?.keys, ["preset", "engine_type", "error_category"])
        XCTAssertEqual(rows["polish_failed"]?.privacy, .anonymousCounter)
    }

    func testDocumentedCatalogue_RejectsMalformedNewRowsAndUnknownReferences() {
        XCTAssertThrowsError(try documentedCatalogue("| 26 | `new_event` | `key` | X | Reason |"))
        XCTAssertThrowsError(try documentedCatalogue("| 26 | `new_event` | as #99 + `key` | P | Reason |"))
    }

    private func excludingExplanations(_ properties: String) throws -> String {
        var depth = 0
        var result = ""
        for character in properties {
            if character == "(" {
                depth += 1
            } else if character == ")" {
                guard depth > 0 else { throw DocumentationError.unbalancedExplanation }
                depth -= 1
            } else if depth == 0 { result.append(character) }
        }
        guard depth == 0 else { throw DocumentationError.unbalancedExplanation }
        return result
    }

    private func documentedCatalogue(_ document: String) throws -> [String: DocumentedEntry] {
        let rowPattern = try NSRegularExpression(pattern: #"^\| (\d+) \| `([^`]+)` \| (.+) \| ([AP]) \| .+\|$"#)
        let candidatePattern = try NSRegularExpression(pattern: #"^\|\s*\d+\s*\|"#)
        let keyPattern = try NSRegularExpression(pattern: #"`([a-z][a-z0-9_]*)`"#)
        let referencePattern = try NSRegularExpression(pattern: #"^(?:same as|as) #(\d+)"#)
        var numberedKeys: [String: Set<String>] = [:]
        var result: [String: DocumentedEntry] = [:]
        for line in document.components(separatedBy: .newlines) {
            let text = line as NSString
            let range = NSRange(location: 0, length: text.length)
            guard candidatePattern.firstMatch(in: line, range: range) != nil else { continue }
            guard let row = rowPattern.firstMatch(in: line, range: range) else {
                throw DocumentationError.malformedRow
            }
            let number = text.substring(with: row.range(at: 1))
            let name = text.substring(with: row.range(at: 2))
            let properties = try excludingExplanations(text.substring(with: row.range(at: 3)))
            let propertyText = properties as NSString
            let propertyRange = NSRange(location: 0, length: propertyText.length)
            var keys = Set(keyPattern.matches(in: properties, range: propertyRange).map {
                propertyText.substring(with: $0.range(at: 1))
            })
            if let reference = referencePattern.firstMatch(in: properties, range: propertyRange) {
                let referenced = propertyText.substring(with: reference.range(at: 1))
                guard let inherited = numberedKeys[referenced] else { throw DocumentationError.unknownReference }
                keys.formUnion(inherited)
            }
            XCTAssertNil(numberedKeys.updateValue(keys, forKey: number), "Duplicate catalogue row #\(number)")
            let privacy: AnalyticsPrivacyClass = text.substring(with: row.range(at: 4)) == "A"
                ? .anonymousCounter : .pseudonymous
            XCTAssertNil(result.updateValue(DocumentedEntry(keys: keys, privacy: privacy), forKey: name), name)
        }
        return result
    }

}
