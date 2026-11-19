package com.justspeaktoit.android.sync

import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import kotlin.math.abs

// JSON shapes from Apple's CloudKit Web Services Reference, as the desktop client
// (Sources/SpeakSync/CloudKitWebServicesWire.swift) reads and writes them.

/** A field value History sync writes. */
sealed interface FieldValue {
    data class Text(val value: String) : FieldValue

    data class Int64(val value: Long) : FieldValue

    data class Real(val value: Double) : FieldValue

    data class Timestamp(val epochMs: Long) : FieldValue
}

/** A field as CloudKit returned it. Untyped values are accepted, as the desktop client does. */
sealed interface WireField {
    data class Typed(val value: FieldValue) : WireField

    data class UntypedString(val value: String) : WireField

    data class UntypedNumber(val value: Double) : WireField

    data object Null : WireField

    data class Unsupported(val type: String) : WireField
}

/** A record read from CloudKit; [deleted] marks a tombstone in a change feed. */
data class CloudKitRecord(
    val recordName: String,
    val recordType: String?,
    val recordChangeTag: String?,
    val deleted: Boolean = false,
    val fields: Map<String, WireField> = emptyMap(),
) {
    fun hasValue(key: String): Boolean = fields[key].let { it != null && it != WireField.Null }

    fun string(key: String): String? = when (val field = fields[key]) {
        is WireField.Typed -> (field.value as? FieldValue.Text)?.value
        is WireField.UntypedString -> field.value
        else -> null
    }

    fun long(key: String): Long? = when (val field = fields[key]) {
        is WireField.Typed -> when (val value = field.value) {
            is FieldValue.Int64 -> value.value
            is FieldValue.Real -> CloudKitWire.exactLong(value.value)
            else -> null
        }
        is WireField.UntypedNumber -> CloudKitWire.exactLong(field.value)
        else -> null
    }

    fun double(key: String): Double? = when (val field = fields[key]) {
        is WireField.Typed -> when (val value = field.value) {
            is FieldValue.Real -> value.value
            is FieldValue.Int64 -> value.value.toDouble()
            else -> null
        }
        is WireField.UntypedNumber -> field.value
        else -> null
    }

    fun timestamp(key: String): Long? = when (val field = fields[key]) {
        is WireField.Typed -> (field.value as? FieldValue.Timestamp)?.epochMs
        is WireField.UntypedNumber -> CloudKitWire.milliseconds(field.value)
        else -> null
    }
}

/** A `serverErrorCode` dictionary, for a whole request or one record or zone in it. */
data class CloudKitServerError(
    val code: String,
    val reason: String? = null,
    val recordName: String? = null,
    val retryAfterSeconds: Double? = null,
    val redirectUrl: String? = null,
) {
    companion object {
        const val AUTHENTICATION_FAILED = "AUTHENTICATION_FAILED"
        const val AUTHENTICATION_REQUIRED = "AUTHENTICATION_REQUIRED"
        const val EXISTS = "EXISTS"
        const val NOT_FOUND = "NOT_FOUND"
        const val THROTTLED = "THROTTLED"
        const val TRY_AGAIN_LATER = "TRY_AGAIN_LATER"
    }
}

/** One record's result in a lookup, modify or change response. */
sealed interface RecordResult {
    val recordName: String?

    data class Found(val record: CloudKitRecord) : RecordResult {
        override val recordName: String get() = record.recordName
    }

    data class Failed(val error: CloudKitServerError) : RecordResult {
        override val recordName: String? get() = error.recordName
    }
}

/** One page of a zone's change feed. */
data class ZoneChanges(val records: List<RecordResult>, val syncToken: String?, val moreComing: Boolean)

/** A write in a `records/modify` request. */
data class RecordOperation(
    val type: String,
    val recordName: String,
    val recordType: String?,
    val recordChangeTag: String?,
    /** Null for a delete; a null value inside clears a field the server holds. */
    val fields: Map<String, FieldValue?>?,
) {
    companion object {
        const val CREATE = "create"
        const val UPDATE = "update"
        const val FORCE_DELETE = "forceDelete"
    }
}

/** Why a CloudKit Web Services request failed. */
sealed class CloudKitException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    /** The web auth token is missing or expired; [redirectUrl] is Apple's sign-in page, if offered. */
    class AuthenticationRequired(val redirectUrl: String?) : CloudKitException("iCloud sign-in is required.")

    class AuthenticationFailed : CloudKitException("iCloud rejected this sign-in.")

    class Server(val error: CloudKitServerError) : CloudKitException("CloudKit error ${error.code}.")

    class InvalidResponse(detail: String) : CloudKitException(detail)

    class Network(cause: Throwable) : CloudKitException("Could not reach iCloud.", cause)

    /** A sign-in or sign-out happened while an operation was running, so it stopped. */
    class SessionChanged : CloudKitException("The iCloud session changed.")

    /** A local write field was out of range (for example a non-finite duration). */
    class Encoding : CloudKitException("A History entry could not be encoded.")
}

internal object CloudKitWire {
    fun zoneId(zone: String): JSONObject = JSONObject().put("zoneName", zone)

    fun exactLong(value: Double): Long? =
        if (value.isFinite() && value == Math.rint(value) && abs(value) < 9.2e18) value.toLong() else null

    /** Milliseconds as a whole number, or null when out of the range a date can hold. */
    fun milliseconds(value: Double): Long? =
        if (value.isFinite() && abs(value) < 9.0e15) Math.round(value) else null

    fun field(o: JSONObject): WireField {
        val typeValue = o.opt("type")
        if (typeValue != null && typeValue != JSONObject.NULL && typeValue !is String) {
            return WireField.Unsupported("")
        }
        val type = typeValue as? String
        val value = o.opt("value")
        if (value == null || value == JSONObject.NULL) return WireField.Null
        if (type == null) {
            return when {
                value is String -> WireField.UntypedString(value)
                value is Number -> WireField.UntypedNumber(value.toDouble())
                else -> WireField.Unsupported("")
            }
        }
        val typed: FieldValue? = when (type) {
            "STRING" -> (value as? String)?.let { FieldValue.Text(it) }
            "INT64" -> integer(value)?.let { FieldValue.Int64(it) }
            "DOUBLE" -> number(value)?.let { FieldValue.Real(it) }
            "TIMESTAMP" -> number(value)?.let(::milliseconds)?.let { FieldValue.Timestamp(it) }
            else -> null
        }
        return typed?.let { WireField.Typed(it) } ?: WireField.Unsupported(type)
    }

    private fun integer(value: Any): Long? = when (value) {
        is Int -> value.toLong()
        is Long -> value
        else -> number(value)?.let(::exactLong)
    }

    private fun number(value: Any): Double? = when (value) {
        is Number -> value.toDouble()
        is String -> value.toDoubleOrNull()
        else -> null
    }

    fun record(o: JSONObject): CloudKitRecord {
        val name = o.opt("recordName") as? String ?: throw CloudKitException.InvalidResponse("A record had no name.")
        val fields = mutableMapOf<String, WireField>()
        o.optJSONObject("fields")?.let { raw ->
            raw.keys().forEach { key -> raw.optJSONObject(key)?.let { fields[key] = field(it) } }
        }
        return CloudKitRecord(
            recordName = name,
            recordType = o.opt("recordType") as? String,
            recordChangeTag = o.opt("recordChangeTag") as? String,
            deleted = o.opt("deleted") == true,
            fields = fields,
        )
    }

    fun serverError(o: JSONObject): CloudKitServerError? {
        val code = o.opt("serverErrorCode") as? String ?: return null
        return CloudKitServerError(
            code = code,
            reason = o.opt("reason") as? String,
            recordName = o.opt("recordName") as? String,
            retryAfterSeconds = (o.opt("retryAfter") as? Number)?.toDouble(),
            redirectUrl = o.opt("redirectURL") as? String,
        )
    }

    /** A whole-request error body, or null when the body is not one. */
    fun serverError(body: String): CloudKitServerError? = try {
        serverError(JSONObject(body))
    } catch (e: JSONException) {
        null
    }

    fun recordResults(array: JSONArray?): List<RecordResult> {
        if (array == null) return emptyList()
        return (0 until array.length()).map { i ->
            val o = array.optJSONObject(i) ?: throw CloudKitException.InvalidResponse("A record result was not an object.")
            serverError(o)?.let { RecordResult.Failed(it) } ?: RecordResult.Found(record(o))
        }
    }

    fun payload(value: FieldValue?): JSONObject = when (value) {
        null -> JSONObject().put("value", JSONObject.NULL)
        is FieldValue.Text -> JSONObject().put("value", value.value).put("type", "STRING")
        is FieldValue.Int64 -> JSONObject().put("value", value.value).put("type", "INT64")
        is FieldValue.Real -> {
            if (!value.value.isFinite()) throw CloudKitException.Encoding()
            JSONObject().put("value", value.value).put("type", "DOUBLE")
        }
        is FieldValue.Timestamp -> JSONObject().put("value", value.epochMs).put("type", "TIMESTAMP")
    }

    fun operation(op: RecordOperation): JSONObject {
        val record = JSONObject().put("recordName", op.recordName)
        op.recordType?.let { record.put("recordType", it) }
        op.recordChangeTag?.let { record.put("recordChangeTag", it) }
        op.fields?.let { fields ->
            val encoded = JSONObject()
            fields.forEach { (key, value) -> encoded.put(key, payload(value)) }
            record.put("fields", encoded)
        }
        return JSONObject().put("operationType", op.type).put("record", record)
    }
}
