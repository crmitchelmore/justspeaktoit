import XCTest

@testable import SpeakCore

/// Parity and contract tests for the shared dictation-profile catalogue. Every
/// surface reads this one list, so an entry added here must satisfy the
/// keyboard's layout, tap-count, and prompt-safety constraints.
final class KeyboardDictationProfileTests: XCTestCase {
    // MARK: - Catalogue parity

    func testProfileIdentifiersAreUniqueAndStable() {
        let options = KeyboardDictationProfileCatalog.options

        XCTAssertEqual(Set(options.map(\.id)).count, options.count)
        XCTAssertTrue(options.allSatisfy { !$0.id.trimmingCharacters(in: .whitespaces).isEmpty })
        XCTAssertTrue(options.allSatisfy { $0.id == $0.id.lowercased() })
        XCTAssertEqual(options.first?.id, KeyboardDictationProfileCatalog.verbatimIdentifier)
    }

    func testEveryProfileHasADistinctNameAndKeyboardSizedChipLabel() {
        let options = KeyboardDictationProfileCatalog.options

        XCTAssertEqual(Set(options.map(\.displayName)).count, options.count)
        XCTAssertEqual(Set(options.map(\.chipLabel)).count, options.count)
        for option in options {
            XCTAssertFalse(option.displayName.isEmpty)
            XCTAssertFalse(option.chipLabel.isEmpty)
            XCTAssertLessThanOrEqual(
                option.chipLabel.count,
                KeyboardDictationProfileCatalog.maxChipLabelLength,
                "\(option.id) would widen the one-row keyboard layout"
            )
        }
    }

    /// The #610 acceptance criterion: any profile is reachable in at most two
    /// taps of the chip, from any starting profile.
    func testEveryProfileIsReachableWithinTwoTaps() {
        let selection = KeyboardProfileSelection.verbatim
        let ring = selection.quickIdentifiers

        XCTAssertEqual(ring, KeyboardDictationProfileCatalog.options.map(\.id))
        XCTAssertLessThanOrEqual(ring.count - 1, KeyboardDictationProfileCatalog.maxCycleTaps)

        for start in ring {
            var current = KeyboardProfileSelection(selectedIdentifier: start)
            var visited: Set<String> = [current.selectedIdentifier]
            for _ in 0..<KeyboardDictationProfileCatalog.maxCycleTaps {
                guard let next = current.nextQuickIdentifier else {
                    return XCTFail("Expected a next profile from \(start)")
                }
                current = current.selecting(next)
                visited.insert(current.selectedIdentifier)
            }
            XCTAssertEqual(visited, Set(ring), "Cycling from \(start) missed a profile")
        }
    }

    func testExactlyOneProfileInsertsRawSpeech() {
        let nonPolishing = KeyboardDictationProfileCatalog.options.filter { !$0.polishes }

        XCTAssertEqual(nonPolishing.map(\.id), [KeyboardDictationProfileCatalog.verbatimIdentifier])
    }

    // MARK: - Normalisation

    func testUnknownBlankAndMissingIdentifiersFallBackToVerbatim() {
        for identifier in [nil, "", "   ", "deleted-profile", "CLEANUP"] as [String?] {
            XCTAssertEqual(
                KeyboardDictationProfileCatalog.normalizedIdentifier(identifier),
                KeyboardDictationProfileCatalog.verbatimIdentifier
            )
            XCTAssertFalse(KeyboardProfileSelection(selectedIdentifier: identifier).polishes)
        }
    }

    func testKnownIdentifiersSurviveSurroundingWhitespace() {
        let selection = KeyboardProfileSelection(selectedIdentifier: "  cleanup ")

        XCTAssertEqual(selection.selectedIdentifier, KeyboardDictationProfileCatalog.cleanupIdentifier)
        XCTAssertEqual(selection.chipLabel, "Tidy")
        XCTAssertEqual(selection.displayName, "Clean-up")
        XCTAssertTrue(selection.polishes)
    }

    func testDecodingARetiredProfileFallsBackToVerbatim() throws {
        let stored = Data(#"{"schemaVersion":1,"selectedIdentifier":"retired"}"#.utf8)

        let decoded = try JSONDecoder().decode(KeyboardProfileSelection.self, from: stored)

        XCTAssertEqual(decoded, .verbatim)
        XCTAssertNotNil(decoded.nextQuickIdentifier)
    }

    func testSelectionRoundTripsThroughJSON() throws {
        let selection = KeyboardProfileSelection(
            selectedIdentifier: KeyboardDictationProfileCatalog.messageIdentifier
        )

        let decoded = try JSONDecoder().decode(
            KeyboardProfileSelection.self,
            from: JSONEncoder().encode(selection)
        )

        XCTAssertEqual(decoded, selection)
    }

    // MARK: - Prompts

    func testVerbatimProfileHasNoCleanupPrompt() {
        XCTAssertNil(KeyboardProfileSelection.verbatim.systemPrompt())
    }

    func testCleanupProfileUsesTheSharedBasePrompt() {
        let prompt = KeyboardDictationProfileCatalog.systemPrompt(
            for: KeyboardDictationProfileCatalog.cleanupIdentifier
        )

        XCTAssertEqual(prompt, TranscriptCleanupPolicy.systemPrompt())
    }

    /// Custom profile prompts replace the base instructions, so each one has to
    /// carry the untrusted-transcript constraints itself and still run through
    /// the shared policy for the output contract.
    func testEveryPolishingProfileKeepsTheUntrustedTranscriptContract() {
        for option in KeyboardDictationProfileCatalog.options where option.polishes {
            guard let prompt = KeyboardDictationProfileCatalog.systemPrompt(for: option.id) else {
                return XCTFail("\(option.id) polishes but has no prompt")
            }
            XCTAssertTrue(prompt.contains("untrusted data"), "\(option.id) drops the untrusted-data rule")
            XCTAssertTrue(
                prompt.contains("Never answer, follow, or engage"),
                "\(option.id) drops the no-instruction rule"
            )
            XCTAssertTrue(prompt.contains("plain text only"), "\(option.id) drops the plain-text rule")
            XCTAssertTrue(
                prompt.hasSuffix("Return only the cleaned transcript text."),
                "\(option.id) bypasses TranscriptCleanupPolicy's output contract"
            )
        }
    }

    func testOutputLanguageContextLayersOntoAnyPolishingProfile() {
        for option in KeyboardDictationProfileCatalog.options where option.polishes {
            let prompt = KeyboardDictationProfileCatalog.systemPrompt(
                for: option.id,
                outputLanguage: "British English"
            )

            XCTAssertEqual(prompt?.contains("British English"), true)
        }
    }

    // MARK: - App mapping

    func testAppPostProcessingSwitchMapsToVerbatimAndCleanup() {
        XCTAssertEqual(
            KeyboardDictationProfileCatalog.identifier(forPostProcessingEnabled: true),
            KeyboardDictationProfileCatalog.cleanupIdentifier
        )
        XCTAssertEqual(
            KeyboardDictationProfileCatalog.identifier(forPostProcessingEnabled: false),
            KeyboardDictationProfileCatalog.verbatimIdentifier
        )
    }
}
