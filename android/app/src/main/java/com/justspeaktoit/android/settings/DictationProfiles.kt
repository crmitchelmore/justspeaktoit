package com.justspeaktoit.android.settings

import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudCatalog
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.GeneratedCloudCatalog
import com.justspeaktoit.android.dictation.DictationLanguages
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.util.UUID

/**
 * A named set of session settings: SpeakCore's `DictationProfile`, stored in the same JSON shape so a
 * profile means the same thing on every platform. Each null field keeps the user's own setting.
 *
 * A profile never changes the recognition mode: its cloud model applies only to Cloud sessions, so
 * choosing a profile can never send audio off the phone.
 */
data class DictationProfile(
    /** An uppercase UUID, as Swift's `UUID` encodes it. */
    val id: String,
    val name: String,
    /** SpeakCore's `transcriptionModelID`; it may name a model only another platform runs. */
    val transcriptionModelId: String? = null,
    /** SpeakCore's `transcriptionRouting` raw value. */
    val transcriptionRouting: String? = null,
    /** A `DictationLanguages` identifier. */
    val languageId: String? = null,
    val cleanupEnabled: Boolean? = null,
    val cleanupModelId: String? = null,
    /** Replaces the base cleanup prompt for this profile's sessions. */
    val cleanupPrompt: String? = null,
    /** The stored JSON, so fields Android does not edit (matchers, output language) survive a save. */
    internal val source: String? = null,
) {
    /** The profile's cloud model when Android can run it as an uploaded recording; null otherwise. */
    val cloudModel: CloudModel?
        get() {
            val id = transcriptionModelId?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            if (transcriptionRouting != null && transcriptionRouting != REMOTE_BATCH) return null
            return CloudCatalog.transcriptionModels.firstOrNull { it.catalogId == id }
        }

    /** The profile's language, or null to keep the user's own. */
    val language: String?
        get() = languageId?.trim()?.takeIf { it.isNotEmpty() }?.let(DictationLanguages::normalized)

    /** The profile's cleanup model when Android offers it, after the shared successor mapping. */
    val cleanupModel: CleanupModel?
        get() {
            val id = cleanupModelId?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val current = GeneratedCloudCatalog.cleanupModelSuccessors[id] ?: id
            return CloudCatalog.cleanupModels.firstOrNull { it.selectionId == current }
        }

    /** The profile's base cleanup prompt, or null to keep the user's own. */
    val prompt: String? get() = cleanupPrompt?.takeIf { it.isNotBlank() }

    /** Sets [model] as the profile's cloud model, or clears it with null. */
    fun withCloudModel(model: CloudModel?): DictationProfile = copy(
        transcriptionModelId = model?.catalogId,
        transcriptionRouting = model?.let { REMOTE_BATCH },
    )

    companion object {
        /** The routing Android runs: it uploads finished recordings. */
        const val REMOTE_BATCH = GeneratedCloudCatalog.PROFILE_CLOUD_TRANSCRIPTION_ROUTING

        fun create(name: String): DictationProfile =
            DictationProfile(id = UUID.randomUUID().toString().uppercase(), name = name)
    }
}

/** Reads and writes [DictationProfile]s as SpeakCore's JSON array. */
object DictationProfiles {
    /** Every field SpeakCore's `DictationProfile` encodes; generated from the shared catalogue. */
    val fields: List<String> = GeneratedCloudCatalog.PROFILE_FIELDS

    /** Profiles without an id or a name are dropped, as SpeakCore drops ones it cannot decode. */
    fun decode(json: String?): List<DictationProfile> {
        if (json.isNullOrBlank()) return emptyList()
        val array = try {
            JSONArray(json)
        } catch (_: JSONException) {
            return emptyList()
        }
        return (0 until array.length()).mapNotNull { index ->
            val item = array.optJSONObject(index) ?: return@mapNotNull null
            val id = item.optString(ID).trim()
            val name = item.optNullableString(NAME)
            if (id.isEmpty() || name == null) return@mapNotNull null
            DictationProfile(
                id = id,
                name = name,
                transcriptionModelId = item.optNullableString(TRANSCRIPTION_MODEL),
                transcriptionRouting = item.optNullableString(TRANSCRIPTION_ROUTING),
                languageId = item.optNullableString(LANGUAGE),
                cleanupEnabled = if (item.opt(CLEANUP_ENABLED) is Boolean) item.getBoolean(CLEANUP_ENABLED) else null,
                cleanupModelId = item.optNullableString(CLEANUP_MODEL),
                cleanupPrompt = item.optNullableString(CLEANUP_PROMPT),
                source = item.toString(),
            )
        }
    }

    fun encode(profiles: List<DictationProfile>): String = JSONArray().apply {
        profiles.forEach { profile ->
            val item = profile.source?.let { runCatching { JSONObject(it) }.getOrNull() } ?: JSONObject()
            item.put(ID, profile.id)
            item.put(NAME, profile.name)
            if (!item.has(MATCHERS)) item.put(MATCHERS, JSONArray())
            item.putOrRemove(TRANSCRIPTION_MODEL, profile.transcriptionModelId)
            item.putOrRemove(TRANSCRIPTION_ROUTING, profile.transcriptionRouting)
            item.putOrRemove(LANGUAGE, profile.languageId)
            item.putOrRemove(CLEANUP_ENABLED, profile.cleanupEnabled)
            item.putOrRemove(CLEANUP_MODEL, profile.cleanupModelId)
            item.putOrRemove(CLEANUP_PROMPT, profile.cleanupPrompt?.takeIf { it.isNotBlank() })
            put(item)
        }
    }.toString()

    /** The active profile, or null when none is chosen or the chosen one was deleted. */
    fun active(prefs: DictationPreferences): DictationProfile? {
        val id = prefs.activeProfileId ?: return null
        return prefs.profiles.firstOrNull { it.id == id }
    }

    private fun JSONObject.optNullableString(key: String): String? =
        if (has(key) && !isNull(key)) optString(key) else null

    private fun JSONObject.putOrRemove(key: String, value: Any?) {
        if (value == null) remove(key) else put(key, value)
    }

    // SpeakCore's `DictationProfile.CodingKeys`; DictationProfilesTest checks them against the export.
    internal const val ID = "id"
    internal const val NAME = "name"
    internal const val MATCHERS = "matchers"
    internal const val TRANSCRIPTION_MODEL = "transcriptionModelID"
    internal const val TRANSCRIPTION_ROUTING = "transcriptionRouting"
    internal const val LANGUAGE = "languageIdentifier"
    internal const val CLEANUP_ENABLED = "polishEnabled"
    internal const val CLEANUP_MODEL = "polishModelID"
    internal const val CLEANUP_PROMPT = "polishPrompt"
    internal val written = listOf(
        ID, NAME, MATCHERS, TRANSCRIPTION_MODEL, TRANSCRIPTION_ROUTING, LANGUAGE,
        CLEANUP_ENABLED, CLEANUP_MODEL, CLEANUP_PROMPT,
    )
}
