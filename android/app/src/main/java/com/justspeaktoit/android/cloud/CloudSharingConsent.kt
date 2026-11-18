package com.justspeaktoit.android.cloud

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

/**
 * What a cloud provider is allowed to receive. Consent for one kind does not cover the others.
 * Raw values match SpeakCore's `CloudSharedDataKind`.
 */
enum class CloudSharedDataKind(val wire: String, val phrase: String, val title: String) {
    Audio("audio", "your audio", "Audio"),
    Transcript("transcript", "your transcript text", "Transcript text"),
    TextToSpeak("textToSpeak", "the text to speak", "Text to speak"),
    ;

    companion object {
        fun fromWire(value: String): CloudSharedDataKind? = entries.firstOrNull { it.wire == value }
    }
}

/** A provider row of `cloud_sharing_providers.json`, exported from SpeakCore. */
data class CloudSharingProvider(val id: String, val displayName: String, val privacyPolicyUrl: String)

/** One ask: a provider and the data kinds a send would give it. */
data class CloudSharingRequest(
    val provider: CloudSharingProvider,
    val kinds: List<CloudSharedDataKind>,
    val canUseOnDevice: Boolean,
) {
    val title: String get() = "Allow ${provider.displayName} to receive $kindsPhrase?"

    val message: String get() =
        "Just Speak to It is about to send $kindsPhrase to ${provider.displayName}. " +
            "${provider.displayName}'s privacy policy explains how they handle it. " +
            "Nothing is sent until you allow it, and you can withdraw this later in Privacy settings."

    /** Same order and wording as `CloudSharingRequest.kindsPhrase` in SpeakCore. */
    val kindsPhrase: String get() = when (kinds.size) {
        0 -> "this data"
        1 -> kinds[0].phrase
        else -> kinds.dropLast().joinToString(", ") { it.phrase } + " and " + kinds.last().phrase
    }
}

/**
 * Per-provider, per-kind permission. JSON is `{"grants":{id:[kinds]},"version":1}`, the same
 * document SpeakCore stores. It is never exported or imported. Unreadable data grants nothing.
 */
class CloudSharingConsent(val grants: Map<String, Set<CloudSharedDataKind>> = emptyMap()) {
    fun allows(providerId: String, kind: CloudSharedDataKind): Boolean = grants[providerId]?.contains(kind) == true

    fun allows(request: CloudSharingRequest): Boolean =
        request.kinds.isNotEmpty() && request.kinds.all { allows(request.provider.id, it) }

    fun granting(request: CloudSharingRequest): CloudSharingConsent {
        val next = grants.toMutableMap()
        next[request.provider.id] = (next[request.provider.id].orEmpty() + request.kinds)
        return CloudSharingConsent(next.filterValues { it.isNotEmpty() })
    }

    fun withdrawing(providerId: String): CloudSharingConsent =
        CloudSharingConsent(grants.filterKeys { it != providerId })

    fun grantedProviderIds(): List<String> = grants.filterValues { it.isNotEmpty() }.keys.sorted()

    fun grantedKinds(providerId: String): List<CloudSharedDataKind> =
        CloudSharedDataKind.entries.filter { grants[providerId]?.contains(it) == true }

    /** Stable key order, kinds in catalogue order. */
    fun encoded(): String {
        val grantsJson = JSONObject()
        for (id in grants.keys.sorted()) {
            val kinds = JSONArray()
            CloudSharedDataKind.entries.filter { grants[id]?.contains(it) == true }.forEach { kinds.put(it.wire) }
            if (kinds.length() > 0) grantsJson.put(id, kinds)
        }
        return JSONObject().put("grants", grantsJson).put("version", VERSION).toString()
    }

    companion object {
        const val VERSION = 1
        const val STORAGE_KEY = "cloudSharingConsent"

        fun decode(json: String?): CloudSharingConsent {
            if (json.isNullOrBlank()) return CloudSharingConsent()
            return try {
                val root = JSONObject(json)
                if (root.optInt("version") != VERSION) return CloudSharingConsent()
                val grantsJson = root.optJSONObject("grants") ?: return CloudSharingConsent()
                val grants = mutableMapOf<String, Set<CloudSharedDataKind>>()
                for (id in grantsJson.keys()) {
                    val array = grantsJson.optJSONArray(id) ?: continue
                    val kinds = (0 until array.length()).mapNotNull { CloudSharedDataKind.fromWire(array.optString(it)) }.toSet()
                    if (id.isNotEmpty() && kinds.isNotEmpty()) grants[id] = kinds
                }
                CloudSharingConsent(grants)
            } catch (e: Exception) {
                CloudSharingConsent()
            }
        }

        /** Same sentence as `CloudSharingConsent.blockedMessage` in SpeakCore. */
        fun blockedMessage(request: CloudSharingRequest): String =
            "Nothing was sent to ${request.provider.displayName}. Open Just Speak to It and allow " +
                "${request.kindsPhrase} to be sent to ${request.provider.displayName}, " +
                "or choose an on-device option."
    }
}

/** The catalogue exported from SpeakCore. A missing file yields no providers, so nothing is named. */
object CloudSharingProviders {
    fun load(json: String): List<CloudSharingProvider> = try {
        val array = JSONObject(json).getJSONArray("providers")
        (0 until array.length()).map { index ->
            val row = array.getJSONObject(index)
            CloudSharingProvider(row.getString("id"), row.getString("displayName"), row.getString("privacyPolicyURL"))
        }
    } catch (e: Exception) {
        emptyList()
    }

    fun provider(id: String, catalogue: List<CloudSharingProvider>): CloudSharingProvider? =
        catalogue.firstOrNull { it.id == id }

    fun request(
        providerId: String,
        kind: CloudSharedDataKind,
        canUseOnDevice: Boolean,
        catalogue: List<CloudSharingProvider>,
    ): CloudSharingRequest? {
        val provider = provider(providerId, catalogue) ?: return null
        return CloudSharingRequest(provider, listOf(kind), canUseOnDevice)
    }
}

/**
 * Device-local consent. [allowing] is for tests that are not about this gate; the app passes
 * [preferences], which starts empty.
 */
class CloudSharingConsentStore(
    private val read: () -> String?,
    private val write: (String) -> Unit,
) {
    fun consent(): CloudSharingConsent = CloudSharingConsent.decode(read())

    fun allows(providerId: String, kind: CloudSharedDataKind): Boolean = consent().allows(providerId, kind)

    fun grant(request: CloudSharingRequest) {
        write(consent().granting(request).encoded())
    }

    fun withdraw(providerId: String) {
        write(consent().withdrawing(providerId).encoded())
    }

    companion object {
        /** Every send is allowed. Tests of unrelated cloud behaviour pass this. */
        val allowing = CloudSharingConsentStore(read = { allowingDocument() }, write = {})

        fun preferences(context: Context): CloudSharingConsentStore {
            val prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            return CloudSharingConsentStore(
                read = { prefs.getString(CloudSharingConsent.STORAGE_KEY, null) },
                write = { prefs.edit().putString(CloudSharingConsent.STORAGE_KEY, it).apply() },
            )
        }

        private fun allowingDocument(): String {
            val grants = JSONObject()
            // The catalogue ids the app can send to. A test that needs a refusal uses its own store.
            listOf(
                "openai", "groq", "openrouter", "anthropic", "google", "mistral", "assemblyai", "deepgram",
                "elevenlabs", "modulate", "reson8", "revai", "soniox", "speechmatics", "cartesia", "gladia",
                "meta", "smallest", "xai", "azure", "alibaba", "stepfun",
            ).forEach { id ->
                grants.put(id, JSONArray().put("audio").put("transcript").put("textToSpeak"))
            }
            return JSONObject().put("grants", grants).put("version", 1).toString()
        }

        private const val PREFS = "jsti_cloud_sharing_consent"
    }
}

/** A cloud call that stopped before any bytes were sent. */
class CloudSharingBlockedException(
    val providerId: String,
    val kind: CloudSharedDataKind,
    message: String,
) : Exception(message)
