package com.justspeaktoit.android.onboarding

/**
 * The Android first-run guide's steps, in order. The wording mirrors the desktop guide
 * (`Sources/SpeakCore/Desktop/DesktopOnboarding.swift`), adapted to the keyboard and tile.
 */
enum class OnboardingStep {
    Welcome,
    Microphone,
    Route,
    Keyboard,
    TestDictation,
    Done,
    ;

    val next: OnboardingStep? get() = entries.getOrNull(ordinal + 1)
    val previous: OnboardingStep? get() = entries.getOrNull(ordinal - 1)

    /** One-based position for "Step 2 of 6". */
    val position: Int get() = ordinal + 1

    companion object {
        val count: Int get() = entries.size
    }
}

object OnboardingGuide {
    /**
     * Whether launch should open the guide. Installs from before the guide existed never
     * stored a decision; a chosen mode or a granted microphone shows they are already set up.
     */
    fun shouldShow(completed: Boolean?, hasChosenMode: Boolean, micGranted: Boolean): Boolean =
        completed?.not() ?: !(hasChosenMode || micGranted)
}
