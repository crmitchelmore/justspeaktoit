package com.justspeaktoit.android.settings

import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.dictation.DictationUiState

/**
 * The app's settings as the raw configuration names them: one value per `settings_schema.json` key, in
 * [RawConfiguration]'s plain form. Values are the effective ones, so a removed model reads as the one
 * the app now uses.
 */
object RawConfigurationValues {
    fun of(state: DictationUiState): Map<String, Any?> = mapOf(
        "chosen_mode" to state.chosenMode?.name,
        "cloud_model" to state.cloudModel.catalogId,
        "preferredLocale" to state.languageId,
        "personal_corrections" to corrections(state.corrections),
        "cleanup_enabled" to state.cleanupEnabled,
        "cleanup_model" to state.cleanupModel.selectionId,
        "keepAudioOnCancel" to state.keepAudioOnCancel,
        "handsFreeDictationEnabled" to state.handsFreeEnabled,
        "history_retention" to state.retention.name,
        "keepRecordingsInHistory" to state.keepRecordings,
        "silenceDetectionEnabled" to state.silence.enabled,
        "silenceThreshold" to state.silence.threshold,
        "silenceDuration" to state.silence.durationSeconds,
        "autoCorrectionsEnabled" to state.learnCorrections,
        "autoCorrectionsPromotionThreshold" to state.correctionPromotionThreshold.toLong(),
        "recordingSoundsEnabled" to state.recordingSounds.enabled,
        "recordingSoundProfile" to state.recordingSounds.profile.id,
        "recordingSoundVolume" to state.recordingSounds.volume.decimal(),
        "appearance" to state.appearance.rawValue,
        "dynamicColor" to state.dynamicColor,
    )

    /** Spelling to its comma-separated aliases; rules sharing a spelling are merged. */
    fun corrections(rules: List<CorrectionRule>): Map<String, String> =
        rules.groupBy { it.writeAs }
            .mapValues { (_, same) -> same.flatMap { it.heardAs }.distinct().joinToString(", ") }

    /**
     * The rules a document's map describes, keeping the order of spellings already in [current] and
     * adding new ones after them in document order.
     */
    fun corrections(value: Map<*, *>, current: List<CorrectionRule>): List<CorrectionRule> {
        val order = current.map { it.writeAs }
        return value
            .mapNotNull { (writeAs, heardAs) -> PersonalCorrections.rule(writeAs.toString(), heardAs.toString()) }
            .sortedBy { rule -> order.indexOf(rule.writeAs).let { if (it < 0) Int.MAX_VALUE else it } }
    }
}
