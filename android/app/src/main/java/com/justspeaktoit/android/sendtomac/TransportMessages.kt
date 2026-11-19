package com.justspeaktoit.android.sendtomac

import org.json.JSONException
import org.json.JSONObject
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit
import java.util.Base64
import java.util.UUID

/**
 * The JSON the phone sends, written field by field so the bytes match `messages.phone` in
 * `send_to_mac_protocol.json`, which SpeakCore's tests prove the Mac decodes.
 */
internal object PhoneMessages {
    const val LANGUAGE = "en-US"

    /** The phone's plaintext key share: asks for a credential when pairing, names it afterwards. */
    fun keyShare(protocolVersion: Int, publicKey: ByteArray, secret: PairingSecret): String {
        val share = Base64.getEncoder().encodeToString(publicKey)
        val prefix = """{"protocolVersion":$protocolVersion,"keyShare":${quote(share)}"""
        return when (secret) {
            is PairingSecret.Code -> """$prefix,"requestsCredential":true}"""
            is PairingSecret.Credential -> """$prefix,"credentialID":${quote(uuid(secret.credential.id))}}"""
        }
    }

    fun hello(protocolVersion: Int, deviceName: String, deviceId: String, releaseTrain: String): String =
        message(
            "hello",
            """{"protocolVersion":$protocolVersion,"deviceName":${quote(deviceName)},""" +
                """"deviceId":${quote(deviceId)},"releaseTrain":${quote(releaseTrain)}}""",
        )

    /** A credential session sends an empty code: the handshake already proved the credential. */
    fun authenticate(pairingCode: String, timestamp: Instant): String =
        message("authenticate", """{"pairingCode":${quote(pairingCode)},"timestamp":${quote(date(timestamp))}}""")

    fun sessionStart(sessionId: String, model: String): String = message(
        "sessionStart",
        """{"sessionId":${quote(sessionId)},"model":${quote(model)},"language":${quote(LANGUAGE)}}""",
    )

    fun transcriptChunk(
        sessionId: String,
        sequenceNumber: Int,
        text: String,
        isFinal: Boolean,
        timestamp: Instant,
    ): String = message(
        "transcriptChunk",
        """{"sessionId":${quote(sessionId)},"sequenceNumber":$sequenceNumber,"text":${quote(text)},""" +
            """"isFinal":$isFinal,"timestamp":${quote(date(timestamp))}}""",
    )

    fun sessionEnd(sessionId: String, finalText: String, durationSeconds: Double, wordCount: Int): String = message(
        "sessionEnd",
        """{"sessionId":${quote(sessionId)},"finalText":${quote(finalText)},""" +
            """"duration":${number(durationSeconds)},"wordCount":$wordCount}""",
    )

    const val PONG = """{"type":"pong"}"""

    /** Words as the Mac counts them: runs of characters that are not Unicode whitespace. */
    fun wordCount(text: String): Int {
        var count = 0
        var inWord = false
        for (char in text) {
            val space = char.isWhitespace()
            if (!space && !inWord) count++
            inWord = !space
        }
        return count
    }

    /** Upper case, as Swift's `UUID.uuidString`. */
    fun uuid(id: UUID): String = id.toString().uppercase(java.util.Locale.ROOT)

    /** ISO 8601 in UTC to the second, as Swift's `.iso8601` date strategy. */
    fun date(instant: Instant): String = DateTimeFormatter.ISO_INSTANT.format(instant.truncatedTo(ChronoUnit.SECONDS))

    private fun message(type: String, payload: String) = """{"type":${quote(type)},"payload":$payload}"""

    /** A JSON number; whole values without a fraction, as Swift writes them. */
    private fun number(value: Double): String = when {
        !value.isFinite() || value < 0 -> "0"
        value == Math.floor(value) && value < WHOLE_NUMBER_LIMIT -> value.toLong().toString()
        else -> value.toString()
    }

    private const val WHOLE_NUMBER_LIMIT = 1e15

    /** A JSON string. Slashes and non-ASCII text are written as they are. */
    fun quote(value: String): String {
        val out = StringBuilder(value.length + 2).append('"')
        for (char in value) {
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                char == '\n' -> out.append("\\n")
                char == '\r' -> out.append("\\r")
                char == '\t' -> out.append("\\t")
                char == '\b' -> out.append("\\b")
                char == '\u000C' -> out.append("\\f")
                char < ' ' -> out.append("\\u").append(String.format(java.util.Locale.ROOT, "%04x", char.code))
                else -> out.append(char)
            }
        }
        return out.append('"').toString()
    }
}

/** A message from the Mac. */
internal sealed interface MacMessage {
    data class AuthResult(
        val success: Boolean,
        val sessionToken: String?,
        val errorMessage: String?,
        val releaseTrain: String?,
    ) : MacMessage

    data class Ack(val sequenceNumber: Int) : MacMessage

    data class Error(val code: Int, val message: String) : MacMessage

    data object Ping : MacMessage

    /** A message a sender never acts on, such as another device's session traffic. */
    data class Other(val type: String) : MacMessage
}

internal object MacMessages {
    /** Decodes one message, or null when the frame is not a message the Mac could have sent. */
    fun parse(frame: ByteArray): MacMessage? = try {
        val root = JSONObject(String(frame, Charsets.UTF_8))
        val payload = root.optJSONObject("payload")
        when (val type = root.getString("type")) {
            "authResult" -> payload?.let {
                MacMessage.AuthResult(
                    success = it.getBoolean("success"),
                    sessionToken = it.optionalString("sessionToken"),
                    errorMessage = it.optionalString("errorMessage"),
                    releaseTrain = it.optionalString("releaseTrain"),
                )
            }
            "ack" -> payload?.let { MacMessage.Ack(it.getInt("sequenceNumber")) }
            "error" -> payload?.let { MacMessage.Error(it.getInt("code"), it.getString("message")) }
            "ping" -> MacMessage.Ping
            else -> MacMessage.Other(type)
        }
    } catch (_: JSONException) {
        null
    }

    /**
     * The Mac's X25519 public key from its plaintext key share, or null when the frame is not a key
     * share (for example a refusal).
     */
    fun keyShare(frame: ByteArray, protocol: SendToMacProtocol): ByteArray? = try {
        val root = JSONObject(String(frame, Charsets.UTF_8))
        root.getInt("protocolVersion")
        val key = Base64.getDecoder().decode(root.getString("keyShare"))
        key.takeIf { it.size == protocol.sizes.key }
    } catch (_: JSONException) {
        null
    } catch (_: IllegalArgumentException) {
        null
    }

    /** The reason in a plaintext refusal the Mac sent instead of a handshake frame. */
    fun rejection(frame: ByteArray): String? {
        val message = parse(frame)
        return when {
            message is MacMessage.AuthResult && !message.success -> message.errorMessage ?: AUTHENTICATION_FAILED
            message is MacMessage.Error -> message.message
            else -> null
        }
    }

    const val AUTHENTICATION_FAILED = "Authentication failed"

    private fun JSONObject.optionalString(key: String): String? =
        if (has(key) && !isNull(key)) getString(key) else null
}
