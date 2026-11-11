import XCTest

import SpeakCore
@testable import SpeakApp

/// Pure logic extracted from the Corrections and Pronunciation Dictionary pages.
final class SettingsEditorLogicTests: XCTestCase {
    func testRuleDraft_tokenizesCommaAndNewlineSeparatedFields() {
        var draft = PersonalCorrectionRuleDraft()
        draft.canonical = "  Susy "
        draft.aliasesText = "Susie, ,Suzie\n Soozy "
        draft.contextTagsText = "partner, partner,\nproject"

        XCTAssertEqual(draft.aliases, ["Susie", "Suzie", "Soozy"])
        XCTAssertEqual(draft.tags, ["partner", "project"])
        XCTAssertEqual(draft.generatedDisplayName, "Susy (Susie)")
        XCTAssertTrue(draft.isSavable)
    }

    func testRuleDraft_requiresCanonicalAndAliasToSave() {
        var draft = PersonalCorrectionRuleDraft()
        draft.canonical = "Susy"
        XCTAssertFalse(draft.isSavable)
        draft.aliasesText = " , "
        XCTAssertFalse(draft.isSavable)
        draft.canonical = "   "
        draft.aliasesText = "Susie"
        XCTAssertFalse(draft.isSavable)
    }

    func testRuleDraft_advancedOptionsOnlyForNonDefaultFields() {
        var draft = PersonalCorrectionRuleDraft()
        draft.notes = "   "
        XCTAssertFalse(draft.requiresAdvancedOptions)
        XCTAssertNil(draft.trimmedNotes)
        draft.notes = " partner "
        XCTAssertTrue(draft.requiresAdvancedOptions)
        XCTAssertEqual(draft.trimmedNotes, "partner")
    }

    func testRuleDraft_updatedRuleKeepsIdentityAndCreationDate() {
        let created = Date(timeIntervalSince1970: 1_000)
        let existing = PersonalLexiconRule(
            displayName: "Old",
            canonical: "Old",
            aliases: ["Olde"],
            activation: .manual,
            contextTags: ["work"],
            confidence: .low,
            notes: "note",
            createdAt: created,
            updatedAt: created
        )
        var draft = PersonalCorrectionRuleDraft(rule: existing)
        XCTAssertTrue(draft.isEditing)
        XCTAssertTrue(draft.requiresAdvancedOptions)
        draft.canonical = "New"
        draft.notes = ""

        let updatedAt = Date(timeIntervalSince1970: 2_000)
        let updated = draft.updatedRule(from: existing, updatedAt: updatedAt)

        XCTAssertEqual(updated.id, existing.id)
        XCTAssertEqual(updated.createdAt, created)
        XCTAssertEqual(updated.updatedAt, updatedAt)
        XCTAssertEqual(updated.canonical, "New")
        XCTAssertEqual(updated.displayName, "New (Olde)")
        XCTAssertEqual(updated.contextTags, ["work"])
        XCTAssertNil(updated.notes)
    }

    func testPronunciationFilter_matchesCategoryAndCaseInsensitiveQuery() {
        let kubectl = PronunciationEntry(word: "kubectl", pronunciation: "cube control", category: "Technical")
        let nginx = PronunciationEntry(
            word: "nginx", pronunciation: "engine x", replacement: "Engine-X", category: "Technical"
        )
        let siobhan = PronunciationEntry(word: "Siobhan", pronunciation: "shiv-awn", category: "Names")
        let entries = [kubectl, nginx, siobhan]

        XCTAssertEqual(PronunciationEntryFilter.entries(entries, category: nil, searchText: ""), entries)
        XCTAssertEqual(
            PronunciationEntryFilter.entries(entries, category: .names, searchText: ""),
            [siobhan]
        )
        XCTAssertEqual(
            PronunciationEntryFilter.entries(entries, category: nil, searchText: "ENGINE-x"),
            [nginx]
        )
        XCTAssertEqual(
            PronunciationEntryFilter.entries(entries, category: .technical, searchText: "CUBE"),
            [kubectl]
        )
        XCTAssertTrue(PronunciationEntryFilter.entries(entries, category: .names, searchText: "cube").isEmpty)
    }
}
