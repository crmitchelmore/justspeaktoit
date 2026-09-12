import XCTest
@testable import SpeakCore

/// Issue #1015. A gallery entry that does not work is worse than no entry, so
/// these are the structural guarantees: no recipe is empty, no recipe chains a
/// value out of an action that returns none, and no recipe claims a system
/// action is one of ours. The other half — that every action named here is
/// actually shipped as an App Intent — is `AutomationGalleryIntentTests`,
/// which has to run where AppIntents exists.
final class AutomationGalleryTests: XCTestCase {
    func testEveryRecipeHasAnIdentityAndSomethingToDo() {
        for recipe in AutomationGallery.recipes {
            XCTAssertFalse(recipe.id.isEmpty)
            XCTAssertFalse(recipe.title.isEmpty, recipe.id)
            XCTAssertFalse(recipe.summary.isEmpty, recipe.id)
            XCTAssertGreaterThanOrEqual(recipe.steps.count, 2, recipe.id)
            XCTAssertFalse(recipe.systemImage.isEmpty, recipe.id)
        }
    }

    func testRecipeIdentifiersAreUnique() {
        let ids = AutomationGallery.recipes.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate recipe id in \(ids)")
    }

    func testEveryStepNamesExactlyOneAction() {
        for recipe in AutomationGallery.recipes {
            for step in recipe.steps {
                XCTAssertFalse(step.title.isEmpty, recipe.id)
                // Either ours or the system's, never both and never neither:
                // the badge in the gallery tells the user which app to blame,
                // and it has to be telling the truth.
                XCTAssertEqual(step.isAppAction, step.action != nil, recipe.id)
                if step.isAppAction {
                    XCTAssertNil(step.systemAction, recipe.id)
                }
            }
        }
    }

    func testEveryRecipeUsesAtLeastOneOfThisAppsActions() {
        for recipe in AutomationGallery.recipes {
            XCTAssertFalse(
                recipe.appActions.isEmpty,
                "\(recipe.id) is entirely built from other apps' actions and does not belong here"
            )
        }
    }

    /// The bug #1015 is really about: a chain is only worth suggesting when
    /// the step before it hands over a value. Any step of ours that is not
    /// last must return text.
    func testAnyActionFollowedByAnotherStepReturnsSomethingToChain() {
        for recipe in AutomationGallery.recipes {
            for (index, step) in recipe.steps.enumerated() where index < recipe.steps.count - 1 {
                guard let action = step.action else { continue }
                // A step that opens a second shortcut consumes nothing from
                // the one before it, so the rule does not apply across that
                // boundary — and the gallery says as much on the step.
                guard !recipe.steps[index + 1].startsNewShortcut else { continue }
                XCTAssertTrue(
                    action.returnsText,
                    "\(recipe.id) chains out of \(action.title), which returns nothing"
                )
            }
        }
    }

    func testTheOnlyStepsAllowedToReturnNothingMidRecipeAreTheOnesThatSplitShortcuts() {
        for recipe in AutomationGallery.recipes {
            for (index, step) in recipe.steps.enumerated()
            where index < recipe.steps.count - 1 && recipe.steps[index + 1].startsNewShortcut {
                XCTAssertNotNil(
                    step.action,
                    "\(recipe.id) splits shortcuts after a step this app does not own"
                )
            }
        }
    }

    func testTheActionsThatReturnTextAreExactlyTheOnesWorthChaining() {
        // Pinned rather than derived, so adding a returning intent is a
        // deliberate edit here too.
        XCTAssertEqual(
            Set(AutomationAction.allCases.filter(\.returnsText)),
            [.dictate, .stopDictationAndGetText, .transcribeAudioFile, .polishText, .getLastTranscription]
        )
    }

    func testReferencedActionsAreASubsetOfTheShippedVocabulary() {
        XCTAssertTrue(
            AutomationGallery.referencedActions.isSubset(of: Set(AutomationAction.allCases))
        )
    }

    func testTheShareSheetRecipeIsPresentBecauseIssue1020NeedsARecipeNotJustAnExtension() {
        let recipe = AutomationGallery.recipes.first { $0.id == "share-sheet-transcribe" }
        XCTAssertNotNil(recipe)
        XCTAssertEqual(recipe?.appActions.first, .transcribeAudioFile)
    }
}
