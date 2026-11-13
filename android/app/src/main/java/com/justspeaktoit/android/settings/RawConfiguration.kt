package com.justspeaktoit.android.settings

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener
import kotlin.math.abs

/** One setting the raw editor reads and writes, from SpeakCore's `SettingsSchema` via `assets/settings_schema.json`. */
data class RawConfigurationField(
    val key: String,
    val type: String,
    /** The fresh-install value as a plain Kotlin value (see [RawConfiguration.plain]). */
    val default: Any?,
    val allowedValues: List<String>?,
    val minimum: Double?,
    val maximum: Double?,
    val readOnly: Boolean,
)

/** The Android raw-configuration schema SpeakCore exports; the app never keeps its own copy. */
class RawConfigurationSchema(
    val version: Int,
    val fields: List<RawConfigurationField>,
    /** Keys another platform owns: a document keeps them with a warning rather than an error. */
    val otherPlatformKeys: Set<String>,
) {
    private val byKey = fields.associateBy { it.key }

    val keys: List<String> get() = fields.map { it.key }

    fun field(key: String): RawConfigurationField? = byKey[key]

    val defaults: Map<String, Any?> get() = fields.associate { it.key to it.default }

    companion object {
        const val ASSET = "settings_schema.json"

        fun fromJson(text: String): RawConfigurationSchema {
            val root = JSONObject(text)
            val fields = root.getJSONArray("fields")
            return RawConfigurationSchema(
                version = root.getInt("schemaVersion"),
                fields = (0 until fields.length()).map { index ->
                    val field = fields.getJSONObject(index)
                    val allowed = field.optJSONArray("allowedValues")
                    RawConfigurationField(
                        key = field.getString("key"),
                        type = field.getString("type"),
                        default = if (field.has("default")) RawConfiguration.plain(field.get("default")) else null,
                        allowedValues = allowed?.let { array -> (0 until array.length()).map(array::getString) },
                        minimum = if (field.has("minimum")) field.getDouble("minimum") else null,
                        maximum = if (field.has("maximum")) field.getDouble("maximum") else null,
                        readOnly = field.optBoolean("readOnly"),
                    )
                },
                otherPlatformKeys = root.getJSONArray("otherPlatformKeys").let { array ->
                    (0 until array.length()).mapTo(mutableSetOf(), array::getString)
                },
            )
        }
    }
}

/** A problem at a JSON path such as `settings.cloud_model`. */
data class RawConfigurationIssue(val path: String, val message: String) {
    override fun toString(): String = if (path.isEmpty()) message else "$path: $message"
}

/**
 * The outcome of validating a document. The app applies [changes] only when [errors] is empty, and
 * applies all of them or none.
 */
data class RawConfigurationReport(
    val errors: List<RawConfigurationIssue> = emptyList(),
    val warnings: List<RawConfigurationIssue> = emptyList(),
    /** Values that differ from the current ones, as plain Kotlin values. */
    val changes: Map<String, Any?> = emptyMap(),
    /** Settings another platform owns; kept for the next export, never applied here. */
    val otherPlatformSettings: Map<String, Any?> = emptyMap(),
) {
    val isValid: Boolean get() = errors.isEmpty()
}

/**
 * The versioned raw-configuration document SpeakCore's `SettingsDocument` defines, checked with the
 * rules of its `SettingsValidator`:
 *
 * ```json
 * {"schemaVersion": 1, "platform": "android",
 *  "settings": {"cleanup_enabled": true}, "apiKeys": {"openai": {"isSet": true}}}
 * ```
 *
 * A missing setting means "unchanged". `apiKeys` only says whether a key is stored: secrets are never
 * written, and the section is ignored when a document is applied.
 *
 * Values are plain Kotlin: null, Boolean, Long, Double, String, List and Map.
 */
object RawConfiguration {
    const val PLATFORM = "android"
    private val TOP_LEVEL_KEYS = setOf("schemaVersion", "platform", "settings", "apiKeys")

    /** Pretty-printed JSON with sorted keys, so exports diff cleanly. */
    fun document(
        schema: RawConfigurationSchema,
        values: Map<String, Any?>,
        apiKeys: Map<String, Boolean>,
        otherPlatformSettings: Map<String, Any?> = emptyMap(),
    ): String {
        val settings = otherPlatformSettings + schema.keys.associateWith { values[it] }
        return encode(
            mapOf(
                "schemaVersion" to schema.version.toLong(),
                "platform" to PLATFORM,
                "settings" to settings,
                "apiKeys" to apiKeys.mapValues { mapOf("isSet" to it.value) },
            ),
        ) + "\n"
    }

    fun validate(schema: RawConfigurationSchema, text: String, current: Map<String, Any?>): RawConfigurationReport {
        val root = try {
            val tokener = JSONTokener(text)
            val value = tokener.nextValue()
            if (tokener.nextClean() != 0.toChar()) throw JSONException("Unexpected text after the JSON value.")
            plain(value)
        } catch (e: JSONException) {
            return RawConfigurationReport(errors = listOf(RawConfigurationIssue("", "Not valid JSON: ${e.message}")))
        }
        if (root !is Map<*, *>) {
            return RawConfigurationReport(errors = listOf(RawConfigurationIssue("", "Expected a JSON object.")))
        }
        val errors = mutableListOf<RawConfigurationIssue>()
        val warnings = mutableListOf<RawConfigurationIssue>()
        root.keys.map { it.toString() }.sorted().filter { it !in TOP_LEVEL_KEYS }
            .forEach { errors += RawConfigurationIssue(it, "Unknown top-level key.") }
        when (val version = root["schemaVersion"]) {
            null -> errors += RawConfigurationIssue("schemaVersion", "Required.")
            is Long -> when {
                version > schema.version -> errors += RawConfigurationIssue(
                    "schemaVersion",
                    "Version $version is newer than this app supports (${schema.version}). Update the app first.",
                )
                version < 1 -> errors += RawConfigurationIssue("schemaVersion", "Must be 1 or later.")
            }
            else -> errors += RawConfigurationIssue("schemaVersion", "Expected an integer.")
        }
        when (val platform = root["platform"]) {
            null, PLATFORM -> Unit
            is String -> warnings += RawConfigurationIssue(
                "platform",
                "Written by $platform; settings it does not share are ignored.",
            )
            else -> errors += RawConfigurationIssue("platform", "Expected a string.")
        }
        when (val apiKeys = root["apiKeys"]) {
            null -> Unit
            is Map<*, *> -> apiKeys.forEach { (id, entry) ->
                if (!(entry is Map<*, *> && entry.size == 1 && entry["isSet"] is Boolean)) {
                    errors += RawConfigurationIssue(
                        "apiKeys.$id",
                        "Only {\"isSet\": true|false} is allowed; secrets are never imported.",
                    )
                }
            }
            else -> errors += RawConfigurationIssue("apiKeys", "Expected an object.")
        }
        val settings: Map<*, *> = when (val value = root["settings"]) {
            null -> emptyMap<String, Any?>()
            is Map<*, *> -> value
            else -> {
                errors += RawConfigurationIssue("settings", "Expected an object.")
                emptyMap<String, Any?>()
            }
        }
        if (errors.isNotEmpty()) return RawConfigurationReport(errors = errors, warnings = warnings)

        val changes = mutableMapOf<String, Any?>()
        val otherPlatform = mutableMapOf<String, Any?>()
        settings.keys.map { it.toString() }.sorted().forEach { key ->
            val value = settings[key]
            val path = "settings.$key"
            val field = schema.field(key)
            if (field == null) {
                if (key in schema.otherPlatformKeys) {
                    otherPlatform[key] = value
                    warnings += RawConfigurationIssue(path, "Not a setting on this platform; kept but ignored.")
                } else {
                    errors += RawConfigurationIssue(path, "Unknown setting.")
                }
                return@forEach
            }
            val canonical = typed(value, field.type)
            if (canonical === INVALID) {
                errors += RawConfigurationIssue(path, "Expected ${kindName(field.type)}.")
                return@forEach
            }
            val currentValue = current[key]
            val message = when {
                field.readOnly && canonical != currentValue -> "Read-only here; change it in the app's Settings."
                canonical is String && field.allowedValues != null && canonical !in field.allowedValues ->
                    "Must be one of: ${field.allowedValues.joinToString(", ")}."
                canonical is Number && field.minimum != null && field.maximum != null &&
                    canonical.toDouble() !in field.minimum..field.maximum ->
                    "Must be between ${format(field.minimum)} and ${format(field.maximum)}."
                else -> null
            }
            when {
                message != null -> errors += RawConfigurationIssue(path, message)
                canonical != currentValue -> changes[key] = canonical
            }
        }
        return RawConfigurationReport(errors, warnings, changes, otherPlatform)
    }

    private val INVALID = Any()

    /** The value in its canonical form, or [INVALID] when it has the wrong type. */
    private fun typed(value: Any?, type: String): Any? = when (type) {
        "boolean" -> value as? Boolean ?: INVALID
        "integer" -> when {
            value is Long -> value
            value is Double && value == Math.rint(value) && abs(value) < 1e15 -> value.toLong()
            else -> INVALID
        }
        "number" -> (value as? Number)?.toDouble() ?: INVALID
        "string", "enumeration" -> value as? String ?: INVALID
        "optionalString" -> if (value == null || value is String) value else INVALID
        "stringArray" -> if (value is List<*> && value.all { it is String }) value else INVALID
        "stringMap" -> if (value is Map<*, *> && value.values.all { it is String }) value else INVALID
        "object" -> if (value is Map<*, *>) value else INVALID
        else -> INVALID
    }

    private fun kindName(type: String): String = when (type) {
        "boolean" -> "true or false"
        "integer" -> "a whole number"
        "number" -> "a number"
        "optionalString" -> "a string or null"
        "stringArray" -> "an array of strings"
        "stringMap" -> "an object of strings"
        "object" -> "an object"
        else -> "a string"
    }

    private fun format(number: Double): String =
        if (number == Math.rint(number)) number.toLong().toString() else number.toString()

    /** An org.json value as a plain Kotlin value: integers become Long, other numbers Double. */
    fun plain(value: Any?): Any? = when (value) {
        null, JSONObject.NULL -> null
        is JSONObject -> value.keys().asSequence().associateWith { plain(value.get(it)) }
        is JSONArray -> (0 until value.length()).map { plain(value.get(it)) }
        is Number -> if (value is Double || value is Float || value is java.math.BigDecimal) {
            value.toDouble()
        } else {
            value.toLong()
        }
        else -> value
    }

    fun encode(value: Any?, indent: String = ""): String = when (value) {
        null -> "null"
        is Boolean, is Long, is Int -> value.toString()
        is Double -> if (value == Math.rint(value) && abs(value) < 1e15) value.toLong().toString() else value.toString()
        is String -> quote(value)
        is Map<*, *> -> if (value.isEmpty()) {
            "{}"
        } else {
            val inner = "$indent  "
            value.entries.sortedBy { it.key.toString() }.joinToString(",\n", "{\n", "\n$indent}") {
                "$inner${quote(it.key.toString())} : ${encode(it.value, inner)}"
            }
        }
        is List<*> -> if (value.isEmpty()) {
            "[]"
        } else {
            val inner = "$indent  "
            value.joinToString(",\n", "[\n", "\n$indent]") { "$inner${encode(it, inner)}" }
        }
        else -> quote(value.toString())
    }

    private fun quote(text: String): String = buildString {
        append('"')
        text.forEach { char ->
            when (char) {
                '"' -> append("\\\"")
                '\\' -> append("\\\\")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> if (char < ' ') append("\\u%04x".format(char.code)) else append(char)
            }
        }
        append('"')
    }
}
