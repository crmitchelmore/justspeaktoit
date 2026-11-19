package com.justspeaktoit.android.readaloud

import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.security.MessageDigest
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** A voice an account lists: its API identifier and the name to show. */
data class AccountVoice(val apiId: String, val name: String)

/**
 * Lists the voices of a Mistral, xAI or Soniox account with the saved key, with the limits and
 * validation of SpeakCore's account inventories. An invalid, oversized or late listing is a failure;
 * it never shows part of a list. A successful listing is kept in memory for the key that fetched it.
 */
class AccountVoiceDirectory(
    private val http: SpeechHttp,
    private val cache: MutableMap<String, List<CloudVoice>> = sharedCache,
) {
    /** The voices already listed for [credential], without a request. */
    fun cached(provider: AccountVoiceProvider, credential: String): List<CloudVoice>? =
        cache[cacheKey(provider, credential.trim())]

    /** The account's voices, newest listing wins; throws [ReadAloudException] with why it failed. */
    suspend fun voices(provider: AccountVoiceProvider, credential: String): List<CloudVoice> {
        val key = credential.trim()
        if (key.isEmpty()) throw ReadAloudException(ReadAloudFailure.MissingKey(provider.providerName))
        val listed = try {
            withTimeout(provider.list.timeoutSeconds * MILLIS) { list(provider, key) }
        } catch (_: TimeoutCancellationException) {
            throw ReadAloudException(ReadAloudFailure.TimedOut(provider.providerName))
        }
        val voices = listed.map { provider.voice(it.apiId, it.name) }
        cache[cacheKey(provider, key)] = voices
        return voices
    }

    private suspend fun list(provider: AccountVoiceProvider, key: String): List<AccountVoice> {
        val voices = mutableListOf<AccountVoice>()
        val identifiers = mutableSetOf<String>()
        var listed = 0
        fun accept(list: AccountListRequest, body: ByteArray): AccountVoiceListing.ParsedPage {
            val parsed = AccountVoiceListing.parse(provider, body) ?: throw invalid(provider)
            val entries = parsed.entries
            val pageSize = list.pageSize
            if (entries.size > provider.maxVoices - listed || (pageSize != null && entries.size > pageSize)) {
                throw invalid(provider)
            }
            listed += entries.size
            entries.forEach { entry ->
                // xAI identifiers are distinct as written; Mistral and Soniox ignore case.
                val id = if (provider.listing == XAI) entry.voice.apiId else entry.voice.apiId.lowercase(Locale.ROOT)
                if (!identifiers.add(id)) throw invalid(provider)
            }
            voices += entries.filter { it.usable }.map { it.voice }
            return parsed
        }
        // xAI: built-ins beyond the fixed presets come first, then the team's custom voices.
        provider.builtInList?.let { builtIn -> fetch(provider, builtIn, key, builtIn.url)?.let { accept(builtIn, it) } }
        val list = provider.list
        val cursors = mutableSetOf<String>()
        var cursor: String? = null
        for (page in 0 until list.maxPages) {
            // Only the first page may say the account has no library; a later refusal fails the listing.
            val body = fetch(provider, list, key, pageUrl(list, page, cursor), absentAllowed = page == 0) ?: return voices
            val parsed = accept(list, body)
            when (list.pageParameter) {
                OFFSET -> if (parsed.entries.size < checkNotNull(list.pageSize)) return voices
                null -> return voices
                else -> {
                    val next = parsed.nextCursor?.takeIf { it.isNotEmpty() } ?: return voices
                    if (!AccountVoiceListing.validText(next, MAX_CURSOR_BYTES) || !cursors.add(next)) {
                        throw invalid(provider)
                    }
                    cursor = next
                }
            }
        }
        // Every page was full: the account holds more than this bounded listing reads.
        throw invalid(provider)
    }

    private fun pageUrl(list: AccountListRequest, page: Int, cursor: String?) = when {
        list.pageParameter == OFFSET && page > 0 -> "${list.url}&$OFFSET=${page * checkNotNull(list.pageSize)}"
        list.pageParameter != null && cursor != null -> "${list.url}&${list.pageParameter}=${queryValue(cursor)}"
        else -> list.url
    }

    /** The body at [url], or null when the status says the account has no such library. */
    private suspend fun fetch(
        provider: AccountVoiceProvider,
        list: AccountListRequest,
        key: String,
        url: String,
        absentAllowed: Boolean = true,
    ): ByteArray? {
        val values = mapOf("key" to key)
        val request = SpeechHttpRequest(
            method = list.method,
            url = fill(url, values),
            headers = list.headers.mapValues { fill(it.value, values) },
            body = ByteArray(0),
            maxResponseBytes = list.maxResponseBytes.toLong(),
        )
        val response = try {
            http.send(request)
        } catch (_: SpeechResponseTooLarge) {
            throw invalid(provider)
        } catch (_: IOException) {
            throw ReadAloudException(ReadAloudFailure.Unreachable(provider.providerName))
        }
        if (absentAllowed && response.status in list.absentStatuses) return null
        if (response.status !in 200..299) {
            throw ReadAloudException(
                when (response.status) {
                    401, 403 -> ReadAloudFailure.KeyRejected(provider.providerName)
                    402 -> ReadAloudFailure.OutOfCredit(provider.providerName)
                    429 -> ReadAloudFailure.RateLimited(provider.providerName)
                    else -> ReadAloudFailure.ServiceError(provider.providerName, response.status)
                },
            )
        }
        if (response.body.size > list.maxResponseBytes) throw invalid(provider)
        return response.body
    }

    private fun invalid(provider: AccountVoiceProvider) =
        ReadAloudException(ReadAloudFailure.InvalidVoiceList(provider.providerName))

    companion object {
        private const val MILLIS = 1000L
        private const val OFFSET = "offset"
        private const val XAI = "xai"
        private const val MAX_CURSOR_BYTES = 4096
        private val PLACEHOLDER = Regex("""\{key\}""")

        /** Listings for the life of the process, so a chosen voice keeps its listed name. */
        val sharedCache: MutableMap<String, List<CloudVoice>> = ConcurrentHashMap()

        /** The voice saved as [key] in the listing made with [credential], so another key's names never show. */
        fun cachedVoice(provider: AccountVoiceProvider, credential: String, key: String): CloudVoice? =
            sharedCache[cacheKey(provider, credential.trim())]?.firstOrNull { it.key == key }

        private fun fill(text: String, values: Map<String, String>) =
            PLACEHOLDER.replace(text) { values.getValue("key") }

        /** Keyed by a digest, so the key itself is never held as a map key. */
        private fun cacheKey(provider: AccountVoiceProvider, credential: String): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(credential.toByteArray(Charsets.UTF_8))
            return provider.provider + ":" + digest.joinToString("") { "%02x".format(it) }
        }

        /** Percent-encodes everything but RFC 3986 unreserved characters. */
        fun queryValue(value: String): String = buildString {
            value.toByteArray(Charsets.UTF_8).forEach { byte ->
                val char = (byte.toInt() and 0xFF).toChar()
                if (char.isLetterOrDigit() && char.code < 0x80 || char in "-._~") append(char) else append("%%%02X".format(byte))
            }
        }
    }
}

/** One page of an account listing, parsed and validated as SpeakCore's inventories do. */
internal object AccountVoiceListing {
    /** A listed voice; presets and Soniox clones that are not ready are listed but not [usable]. */
    data class Listed(val voice: AccountVoice, val usable: Boolean)

    /** Every entry of a page, with the cursor of the next one. */
    data class ParsedPage(val entries: List<Listed>, val nextCursor: String?)

    /** The page, or null when any entry is invalid. */
    fun parse(provider: AccountVoiceProvider, body: ByteArray): ParsedPage? = try {
        val text = String(body, Charsets.UTF_8)
        when (provider.listing) {
            "mistral" -> mistral(text)
            "xai" -> xai(provider, text)
            "soniox" -> soniox(provider, text)
            else -> null
        }
    } catch (_: JSONException) {
        null
    }

    private fun mistral(text: String): ParsedPage? {
        val trimmed = text.trimStart()
        val array = if (trimmed.startsWith("[")) {
            JSONArray(trimmed)
        } else {
            val root = JSONObject(trimmed)
            root.optJSONArray("items") ?: root.optJSONArray("data") ?: root.optJSONArray("voices") ?: return null
        }
        val entries = (0 until array.length()).map { index ->
            val item = array.optJSONObject(index) ?: return null
            val id = item.optStringOrNull("id") ?: return null
            val name = item.optStringOrNull("name") ?: return null
            val gender = item.optStringOrNull("gender")
            val valid = id.toByteArray().size == UUID_LENGTH && isUuid(id) && name.isNotEmpty() &&
                validText(name, MAX_NAME_BYTES) &&
                listOfNotNull(item.optStringOrNull("slug"), gender).all { validText(it, MAX_SHORT_BYTES) } &&
                (item.optStringOrNull("description")?.let { validText(it, MAX_DESCRIPTION_BYTES) } ?: true) &&
                languagesValid(item, "languages")
            if (!valid) return null
            val shown = if (gender.isNullOrEmpty()) name else "$name (${capitalized(gender)})"
            Listed(AccountVoice(id, shown), usable = true)
        }
        return ParsedPage(entries, null)
    }

    private fun xai(provider: AccountVoiceProvider, text: String): ParsedPage? {
        val root = JSONObject(text)
        val array = root.optJSONArray("voices") ?: return null
        val fixed = provider.fixedVoiceIds.map { it.lowercase(Locale.ROOT) }.toSet()
        val entries = (0 until array.length()).map { index ->
            val item = array.optJSONObject(index) ?: return null
            val id = item.optStringOrNull("voice_id") ?: return null
            // A missing or null name falls back to the identifier; a name of another type is invalid.
            val name = if (item.isNull("name")) capitalized(id) else item.opt("name") as? String ?: return null
            if (!validText(id, MAX_NAME_BYTES) || id.isEmpty() || !validText(name, MAX_NAME_BYTES) || name.isEmpty() ||
                id.lowercase(Locale.ROOT).startsWith(XAI_PREFIX)
            ) {
                return null
            }
            Listed(AccountVoice(id, name), usable = id.lowercase(Locale.ROOT) !in fixed)
        }
        return cursor(root, "pagination_token")?.let { ParsedPage(entries, it.value) }
    }

    private fun soniox(provider: AccountVoiceProvider, text: String): ParsedPage? {
        val root = JSONObject(text)
        val array = root.optJSONArray("voices") ?: return null
        val fixed = provider.fixedVoiceIds.map { it.lowercase(Locale.ROOT) }.toSet()
        val entries = (0 until array.length()).map { index ->
            val item = array.optJSONObject(index) ?: return null
            val id = item.optStringOrNull("id") ?: return null
            val name = item.optStringOrNull("name") ?: return null
            val models = item.optJSONArray("models") ?: return null
            // Every model needs a string name and status, as SpeakCore's decoder requires.
            val modelNames = (0 until models.length()).map { index ->
                val model = models.optJSONObject(index) ?: return null
                model.optStringOrNull("status") ?: return null
                model.optStringOrNull("model") ?: return null
            }
            val valid = id.isNotEmpty() && id.toByteArray().size <= MAX_NAME_BYTES &&
                id.all { it.isLetterOrDigit() || it == '-' || it == '_' } &&
                id.lowercase(Locale.ROOT) !in fixed &&
                name.isNotEmpty() && validText(name, MAX_NAME_BYTES) &&
                models.length() <= MAX_MODELS && modelNames.toSet().size == modelNames.size
            if (!valid) return null
            val ready = (0 until models.length()).map(models::getJSONObject).firstOrNull {
                it.optString("model") == provider.readyModel
            }?.optString("status")?.lowercase(Locale.ROOT) == READY
            Listed(AccountVoice(id, name), usable = ready)
        }
        return cursor(root, "next_page_cursor")?.let { ParsedPage(entries, it.value) }
    }

    private class Cursor(val value: String?)

    /** The next page's cursor; null when it is present but not a string, as SpeakCore's decoder rejects it. */
    private fun cursor(root: JSONObject, field: String): Cursor? =
        if (root.isNull(field)) Cursor(null) else (root.opt(field) as? String)?.let(::Cursor)

    /** Missing or null, or an array of short language codes; any other type is invalid, as SpeakCore decodes it. */
    private fun languagesValid(item: JSONObject, field: String): Boolean {
        if (item.isNull(field)) return true
        val languages = item.opt(field) as? JSONArray ?: return false
        if (languages.length() > MAX_LANGUAGES) return false
        return (0 until languages.length()).all { index ->
            val language = languages.opt(index) as? String ?: return false
            language.isNotEmpty() && validText(language, MAX_LANGUAGE_BYTES)
        }
    }

    /** Trimmed, within [maximum] UTF-8 bytes and free of control characters. */
    fun validText(value: String, maximum: Int): Boolean =
        value.toByteArray(Charsets.UTF_8).size <= maximum && value == value.trim() && value.none { Character.isISOControl(it) }

    private fun isUuid(value: String): Boolean = try {
        UUID.fromString(value).toString().equals(value, ignoreCase = true)
    } catch (_: IllegalArgumentException) {
        false
    }

    /** Foundation's `capitalized`: each word's first letter upper case, the rest lower case. */
    fun capitalized(value: String): String = value.split(" ").joinToString(" ") { word ->
        word.lowercase(Locale.ROOT).replaceFirstChar { it.titlecase(Locale.ROOT) }
    }

    private fun JSONObject.optStringOrNull(key: String): String? = if (isNull(key)) null else opt(key) as? String

    private const val UUID_LENGTH = 36
    private const val MAX_NAME_BYTES = 256
    private const val MAX_SHORT_BYTES = 128
    private const val MAX_DESCRIPTION_BYTES = 4096
    private const val MAX_LANGUAGES = 64
    private const val MAX_LANGUAGE_BYTES = 32
    private const val MAX_MODELS = 32
    private const val XAI_PREFIX = "xai/"
    private const val READY = "ready"
}
