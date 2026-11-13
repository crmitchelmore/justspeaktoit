package com.justspeaktoit.android.transfer

import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.GeneratedCloudCatalog
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.corrections.PersonalCorrections
import com.justspeaktoit.android.dictation.DictationLanguages
import com.justspeaktoit.android.dictation.RecognitionMode
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.history.HistoryStatus
import com.justspeaktoit.android.settings.DictationProfile
import com.justspeaktoit.android.settings.DictationProfiles
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.UUID
import kotlin.math.abs

/** The record kinds Android reads and writes; every other kind is left to the platforms that use it. */
internal object RecordKinds {
    const val SETTING = "default"
    const val SECRET = "secret"
    const val PROFILE = "profile"
    const val LEXICON = "lexicon"
    const val HISTORY = "history"
    const val AUDIO = "audio"
}

private val uuidPattern = Regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")

internal fun isUuid(text: String): Boolean = uuidPattern.matches(text)

private fun nameUuid(name: String): String =
    UUID.nameUUIDFromBytes(name.toByteArray(Charsets.UTF_8)).toString().uppercase()

private fun JSONObject.stringOrNull(key: String): String? = if (isNull(key)) null else opt(key) as? String

/**
 * The SpeakCore preference keys (`DataMigrationPreferenceCatalog`, kind `default`) that Android has
 * a setting for. Every other key in an archive is not used on Android.
 */
internal object SharedSettings {
    const val KEEP_AUDIO = "keepAudioOnCancel"
    const val CLEANUP_ENABLED = "postProcessingEnabled"
    const val LANGUAGE = "preferredLocale"
    const val CLEANUP_MODEL = "postProcessingModel"
    const val CLOUD_MODEL = "batchTranscriptionModel"

    val keys = setOf(KEEP_AUDIO, CLEANUP_ENABLED, LANGUAGE, CLEANUP_MODEL, CLOUD_MODEL)

    /** A language the shared catalogue knows, or null. */
    fun language(value: Any): String? = (value as? String)?.takeIf { id -> DictationLanguages.all.any { it.id == id } }

    /** A cleanup route Android offers, after the catalogue's successor mapping, or null. */
    fun cleanupModel(value: Any): String? {
        val id = value as? String ?: return null
        val current = GeneratedCloudCatalog.cleanupModelSuccessors[id] ?: id
        return CloudCatalog.cleanupModels.firstOrNull { it.selectionId == current }?.selectionId
    }

    /** A transcription model Android offers, or null. */
    fun cloudModel(value: Any): String? =
        (value as? String)?.takeIf { id -> CloudCatalog.transcriptionModels.any { it.catalogId == id } }
}

/**
 * Android's own preferences that no shared key covers, in the archive's `android-settings.json`.
 * Other platforms ignore the entry, as every reader ignores unknown archive entries.
 */
internal object AndroidSettings {
    const val VERSION = 1
    const val MODE = "chosenMode"
    const val RETENTION = "historyRetention"
    const val PROMPT = "postProcessingSystemPrompt"
    const val PROFILE = "activeDictationProfileID"
}

/** `ApplicationHistoryItem` values for Android's History, and back. */
internal object HistoryRecords {
    private const val ANDROID = "androidHistory"
    private const val TRIGGER = "Android dictation"
    private const val CLOCK_SKEW_MS = 1000L

    /** The archive identity of an entry: its UUID in the Mac's upper case. */
    fun exportId(id: String): String = if (isUuid(id)) id.uppercase() else nameUuid("android-history:$id")

    fun record(entry: HistoryEntry): ArchiveRecord {
        val id = exportId(entry.id)
        val value = value(entry, id, audioOnly = false)
        return ArchiveRecord(
            id = id,
            kind = RecordKinds.HISTORY,
            value = value,
            dateMs = entry.createdAtMs,
            revision = sha256Hex(value.toString().toByteArray(Charsets.UTF_8)),
        )
    }

    /** A recording's value carries no text, as SpeakCore's `DataMigrationHistoryValue` audio-only form. */
    fun value(entry: HistoryEntry, id: String, audioOnly: Boolean): JSONObject {
        val created = ArchiveDates.format(entry.createdAtMs)
        val local = entry.mode == RecognitionMode.OnDevice.name
        val usages = JSONArray()
        entry.model?.let { usages.put(JSONObject().put("modelIdentifier", it).put("phase", if (local) "local" else "batch")) }
        val errors = JSONArray()
        if (entry.status == HistoryStatus.Failed && !audioOnly) {
            errors.put(
                JSONObject()
                    .put("id", nameUuid("android-history-error:$id"))
                    .put("phase", "transcription")
                    .put("message", entry.failure ?: "Failed")
                    .put("occurredAt", created),
            )
        }
        val android = JSONObject()
            .put("mode", entry.mode)
            .put("status", entry.status.name)
            .put("cleanedUp", entry.cleanedUp)
            .put("createdAtMs", entry.createdAtMs)
        if (!audioOnly) entry.failure?.let { android.put("failure", it) }
        return JSONObject()
            .put("id", id)
            .put("createdAt", created)
            .put("updatedAt", created)
            .put("modelsUsed", JSONArray().apply { entry.model?.let { put(it) } })
            .put("modelUsages", usages)
            .put("recordingDuration", 0)
            .put("networkExchanges", JSONArray())
            .put("events", JSONArray())
            .put("phaseTimestamps", JSONObject())
            .put(
                "trigger",
                JSONObject().put("gesture", "uiButton").put("hotKeyDescription", TRIGGER).put("outputMethod", "none"),
            )
            .put("errors", errors)
            .put(ANDROID, android)
            .apply {
                if (!audioOnly) put(if (entry.cleanedUp) "postProcessedTranscription" else "rawTranscription", entry.text)
            }
    }

    /**
     * The entry a `history` or `audio` record describes, validated as `DataMigrationHistorySchema`
     * does (a UUID id matching the value's, a date within a second of `createdAt`, no negative
     * duration). Null when the record is not one Android can keep. Ids are stored in lower case,
     * as Android creates them.
     */
    fun entry(record: ArchiveRecord): HistoryEntry? = try {
        decode(record)
    } catch (_: JSONException) {
        null
    }

    private fun decode(record: ArchiveRecord): HistoryEntry? {
        val value = record.value as? JSONObject ?: return null
        if (!isUuid(record.id)) return null
        val valueId = value.opt("id") as? String ?: return null
        if (!valueId.equals(record.id, ignoreCase = true)) return null
        val created = (value.opt("createdAt") as? String)?.let(ArchiveDates::parse) ?: return null
        val date = record.dateMs ?: return null
        if (abs(created - date) >= CLOCK_SKEW_MS) return null
        val duration = value.opt("recordingDuration") as? Number ?: return null
        if (duration.toDouble() < 0) return null
        val android = value.optJSONObject(ANDROID)
        val usages = value.optJSONArray("modelUsages") ?: JSONArray()
        val local = (0 until usages.length()).any { usages.optJSONObject(it)?.opt("phase") == "local" }
        val models = value.optJSONArray("modelsUsed") ?: JSONArray()
        val errors = value.optJSONArray("errors") ?: JSONArray()
        val processed = value.stringOrNull("postProcessedTranscription")
        val text = processed ?: value.stringOrNull("rawTranscription") ?: ""
        val failure = android?.stringOrNull("failure")
            ?: errors.optJSONObject(0)?.stringOrNull("message")
        val androidCreated = (android?.opt("createdAtMs") as? Number)?.toLong()
        return HistoryEntry(
            id = record.id.lowercase(),
            // Archive dates are whole seconds; Android's own exports keep the exact time.
            createdAtMs = androidCreated?.takeIf { abs(it - created) < CLOCK_SKEW_MS } ?: created,
            mode = android?.stringOrNull("mode")?.takeIf { mode -> RecognitionMode.entries.any { it.name == mode } }
                ?: if (local) RecognitionMode.OnDevice.name else RecognitionMode.Cloud.name,
            model = (0 until models.length()).firstNotNullOfOrNull { models.opt(it) as? String },
            status = HistoryStatus.entries.firstOrNull { it.name == android?.opt("status") }
                ?: if (errors.length() > 0) HistoryStatus.Failed else HistoryStatus.Completed,
            text = text,
            failure = failure,
            cleanedUp = android?.opt("cleanedUp") as? Boolean ?: (processed != null),
        )
    }
}

/** SpeakCore `DictationProfile` records, as the Mac writes them. */
internal object ProfileRecords {
    /** Null for a profile whose id is not a UUID, which SpeakCore cannot decode. */
    fun record(profile: DictationProfile): ArchiveRecord? {
        if (!isUuid(profile.id)) return null
        val id = profile.id.uppercase()
        val value = JSONArray(DictationProfiles.encode(listOf(profile.copy(id = id)))).getJSONObject(0)
        return ArchiveRecord(id = id, kind = RecordKinds.PROFILE, value = value)
    }

    fun profile(record: ArchiveRecord): DictationProfile? {
        val value = record.value as? JSONObject ?: return null
        if (!isUuid(record.id) || (value.opt("id") as? String)?.equals(record.id, ignoreCase = true) != true) return null
        return DictationProfiles.decode(JSONArray().put(value).toString()).singleOrNull()
    }
}

/** Personal corrections as SpeakCore `PersonalLexiconRule` records. */
internal object LexiconRecords {
    fun record(rule: CorrectionRule, nowMs: Long): ArchiveRecord {
        // Stable per spelling, so exporting twice gives the same identity.
        val id = nameUuid("android-correction:${rule.writeAs.lowercase()}")
        val date = ArchiveDates.format(nowMs)
        val value = JSONObject()
            .put("id", id)
            .put("displayName", rule.writeAs)
            .put("canonical", rule.writeAs)
            .put("aliases", JSONArray(rule.heardAs))
            .put("activation", "automatic")
            .put("contextTags", JSONArray())
            .put("confidence", "high")
            .put("source", "manual")
            .put("createdAt", date)
            .put("updatedAt", date)
        return ArchiveRecord(id = id, kind = RecordKinds.LEXICON, value = value)
    }

    fun rule(record: ArchiveRecord): CorrectionRule? {
        val value = record.value as? JSONObject ?: return null
        val canonical = value.opt("canonical") as? String ?: return null
        val aliases = value.optJSONArray("aliases") ?: JSONArray()
        return PersonalCorrections.rule(canonical, (0 until aliases.length()).mapNotNull { aliases.opt(it) as? String })
    }
}
