package com.justspeaktoit.android.transfer

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.time.Instant
import java.time.OffsetDateTime
import java.time.format.DateTimeParseException

/**
 * SpeakCore's `DataMigrationCategory`, in its order. [title] is the shared English title the Mac,
 * iPhone and desktop apps use in their notices, so a notice reads the same on every platform.
 */
enum class TransferCategory(val raw: String, val title: String) {
    Settings("settings", "Settings & shortcuts"),
    History("history", "History text & speech usage"),
    Recordings("recordings", "Recordings"),
    Credentials("credentials", "API keys & credentials"),
    Profiles("profiles", "Dictation profiles"),
    Vocabulary("vocabulary", "Vocabulary, pronunciation & corrections"),
    Connections("connections", "Connections"),
    Models("models", "Model references"),
    ;

    companion object {
        fun forRaw(raw: String): TransferCategory? = entries.firstOrNull { it.raw == raw }
    }
}

/** The import or export could not go ahead; nothing was changed. */
class ConfigArchiveException(message: String, cause: Throwable? = null) : Exception(message, cause)

/**
 * SpeakCore's `DataMigrationFormat` and `DataMigrationArchivePolicy`: the archive identity, the
 * readable versions and the limits every platform enforces before staging anything.
 */
internal object ArchiveFormat {
    const val IDENTIFIER = "JustSpeakToIt"
    const val VERSION = 2
    const val MINIMUM_READABLE_VERSION = 1
    const val MANIFEST = "manifest.json"

    /** Android-only preferences no shared settings key covers; other platforms ignore the entry. */
    const val ANDROID_SETTINGS = "android-settings.json"
    const val RECORDINGS_DIRECTORY = "recordings"

    const val MAX_ENTRIES = 100_000
    const val MAX_ENTRY_BYTES = 20_000_000_000L
    const val MAX_ARCHIVE_BYTES = 50_000_000_000L
    const val MAX_JSON_BYTES = 128_000_000L
    const val STAGING_RESERVE_BYTES = 64_000_000L

    private const val MAX_SELECTED_KINDS = 100
    private const val MAX_KIND_BYTES = 128
    private val audioExtensions = setOf("wav", "m4a", "mp3", "flac", "ogg", "aiff", "aif", "aac", "caf", "audio")

    fun categoryEntry(category: TransferCategory) = category.raw + ".json"

    /** `DataMigrationArchivePolicy.safeAudioPath`: `recordings/<name>.<audio extension>`, nothing else. */
    fun safeAudioPath(path: String): Boolean {
        val parts = path.split('/')
        if (parts.size != 2 || parts[0] != RECORDINGS_DIRECTORY || parts[1].isEmpty()) return false
        if (".." in path || '\\' in path || '\u0000' in path) return false
        return extension(path) in audioExtensions
    }

    fun extension(path: String): String {
        val name = path.substringAfterLast('/')
        val dot = name.lastIndexOf('.')
        return if (dot < 0) "" else name.substring(dot + 1).lowercase()
    }

    fun validKinds(kinds: Set<String>, version: Int): Boolean =
        version >= 2 && kinds.size <= MAX_SELECTED_KINDS &&
            kinds.all { it.isNotEmpty() && it.toByteArray(Charsets.UTF_8).size <= MAX_KIND_BYTES && '\u0000' !in it }
}

/** Swift's `.iso8601` dates: whole seconds in UTC on write, any offset accepted on read. */
internal object ArchiveDates {
    fun format(ms: Long): String = Instant.ofEpochSecond(Math.floorDiv(ms, 1000L)).toString()

    fun parse(text: String): Long? = try {
        OffsetDateTime.parse(text).toInstant().toEpochMilli()
    } catch (e: DateTimeParseException) {
        null
    }
}

internal fun sha256Hex(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).hex()

internal fun ByteArray.hex(): String = joinToString("") { (it.toInt() and 0xff).toString(16).padStart(2, '0') }

/** SpeakCore's `DataMigrationScope`: an export that holds only part of a category. */
data class ArchiveScope(
    val startMs: Long? = null,
    val endMs: Long? = null,
    val selectedIds: Set<String>? = null,
    val selectedKinds: Set<String>? = null,
) {
    fun containsKind(kind: String): Boolean = selectedKinds?.contains(kind) ?: true

    fun contains(id: String, dateMs: Long?, kind: String): Boolean {
        if (selectedKinds != null && kind !in selectedKinds) return false
        if (selectedIds != null && id !in selectedIds) return false
        if (startMs != null && (dateMs == null || dateMs < startMs)) return false
        if (endMs != null && (dateMs == null || dateMs >= endMs)) return false
        return true
    }
}

data class ArchiveManifest(
    val version: Int,
    val createdAtMs: Long,
    val categories: List<TransferCategory>,
    val scopes: Map<TransferCategory, ArchiveScope> = emptyMap(),
) {
    fun scope(category: TransferCategory): ArchiveScope = scopes[category] ?: ArchiveScope()

    fun toJson(): JSONObject = JSONObject()
        .put("format", ArchiveFormat.IDENTIFIER)
        .put("version", version)
        .put("createdAt", ArchiveDates.format(createdAtMs))
        .put("categories", JSONArray(categories.map { it.raw }))
        // Every reader requires it, even when nothing is scoped.
        .put("scopes", JSONObject())

    companion object {
        private const val UNSUPPORTED = "This export format is unsupported. Update the app before importing it."
        private const val DAMAGED = "The export manifest is damaged."

        /** Validates as `DataMigrationArchivePolicy.validateManifest` does; any problem rejects the archive. */
        fun parse(text: String): ArchiveManifest = try {
            val json = JSONObject(text)
            val number = json.get("version") as? Number ?: throw ConfigArchiveException(UNSUPPORTED)
            val version = number.toInt()
            if (number.toDouble() != version.toDouble() || json.get("format") != ArchiveFormat.IDENTIFIER ||
                version !in ArchiveFormat.MINIMUM_READABLE_VERSION..ArchiveFormat.VERSION
            ) {
                throw ConfigArchiveException(UNSUPPORTED)
            }
            val createdAt = (json.get("createdAt") as? String)?.let(ArchiveDates::parse)
                ?: throw ConfigArchiveException(DAMAGED)
            val raw = json.getJSONArray("categories")
            val categories = (0 until raw.length()).map {
                (raw.get(it) as? String)?.let(TransferCategory::forRaw) ?: throw ConfigArchiveException(UNSUPPORTED)
            }
            if (categories.toSet().size != categories.size) throw ConfigArchiveException(UNSUPPORTED)
            ArchiveManifest(version, createdAt, categories, scopes(json.getJSONObject("scopes"), version))
        } catch (e: JSONException) {
            throw ConfigArchiveException(DAMAGED, e)
        }

        private fun scopes(json: JSONObject, version: Int): Map<TransferCategory, ArchiveScope> {
            val result = mutableMapOf<TransferCategory, ArchiveScope>()
            json.keys().forEach { key ->
                val item = json.getJSONObject(key)
                val kinds = item.optStrings("selectedKinds")
                if (kinds != null && !ArchiveFormat.validKinds(kinds, version)) {
                    throw ConfigArchiveException("Record-kind selections require a supported version-2 export.")
                }
                val scope = ArchiveScope(
                    startMs = item.optDate("start"),
                    endMs = item.optDate("end"),
                    selectedIds = item.optStrings("selectedIDs"),
                    selectedKinds = kinds,
                )
                TransferCategory.forRaw(key)?.let { result[it] = scope }
            }
            return result
        }

        private fun JSONObject.optDate(key: String): Long? {
            if (!has(key) || isNull(key)) return null
            return (get(key) as? String)?.let(ArchiveDates::parse) ?: throw ConfigArchiveException(DAMAGED)
        }

        private fun JSONObject.optStrings(key: String): Set<String>? {
            if (!has(key) || isNull(key)) return null
            val array = getJSONArray(key)
            return (0 until array.length()).mapTo(mutableSetOf()) {
                array.get(it) as? String ?: throw ConfigArchiveException(DAMAGED)
            }
        }
    }
}

/**
 * SpeakCore's `DataMigrationRecord`. [value] is an org.json value: a [JSONObject], [JSONArray],
 * [String], [Number], [Boolean] or [JSONObject.NULL].
 */
data class ArchiveRecord(
    val id: String,
    val kind: String,
    val value: Any,
    val dateMs: Long? = null,
    val file: String? = null,
    val digest: String? = null,
    val revision: String? = null,
) {
    val identity: String get() = "$kind:$id"

    fun toJson(): JSONObject = JSONObject()
        .put("id", id)
        .put("kind", kind)
        .put("value", value)
        .apply {
            dateMs?.let { put("date", ArchiveDates.format(it)) }
            file?.let { put("file", it) }
            digest?.let { put("digest", it) }
            revision?.let { put("revision", it) }
        }

    companion object {
        private val optionalKeys = listOf("file", "digest", "revision")

        /** Null when the item is not a record, as Swift fails to decode it; unknown keys are ignored. */
        fun parse(item: Any?): ArchiveRecord? {
            val json = item as? JSONObject ?: return null
            val id = json.opt("id") as? String ?: return null
            val kind = json.opt("kind") as? String ?: return null
            if (!json.has("value")) return null
            val date = if (json.isNull("date")) {
                null
            } else {
                (json.get("date") as? String)?.let(ArchiveDates::parse) ?: return null
            }
            val optional = mutableMapOf<String, String?>()
            for (key in optionalKeys) {
                optional[key] = if (json.isNull(key)) null else json.get(key) as? String ?: return null
            }
            return ArchiveRecord(
                id = id,
                kind = kind,
                value = json.get("value"),
                dateMs = date,
                file = optional["file"],
                digest = optional["digest"],
                revision = optional["revision"],
            )
        }
    }
}

/** Everything read from an archive, with recordings already verified and copied to private staging. */
data class ArchiveContents(
    val manifest: ArchiveManifest,
    /** A category that could not be read is absent, so its existing data is kept. */
    val records: Map<TransferCategory, List<ArchiveRecord>>,
    /** Staged audio by archive path. */
    val files: Map<String, File>,
    val notices: List<String>,
    /** The Android-only preferences, when the archive came from Android. */
    val androidSettings: JSONObject? = null,
)
