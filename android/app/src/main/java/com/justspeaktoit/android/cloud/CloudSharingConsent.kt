package com.justspeaktoit.android.cloud

import org.json.JSONArray
import org.json.JSONObject

/** The generated row of one kind of shared content (SpeakCore's `CloudSharedDataKind`). */
internal data class CloudSharingKindSpec(val id: String, val title: String, val purpose: String)

/** The generated row of a provider that can receive content, with its privacy policy. */
internal data class CloudSharingProviderSpec(val id: String, val displayName: String, val privacyPolicyUrl: String?)

/**
 * A kind of personal data a cloud AI provider can receive. Google Play's User Data policy and App Store
 * guideline 5.1.2(i) need explicit permission per recipient, so consent is kept per provider and per kind.
 */
enum class CloudSharedDataKind(val id: String) {
    Audio("audio"),
    TranscriptText("transcriptText"),
    TextToSpeak("textToSpeak"),
    ;

    private val spec: CloudSharingKindSpec
        get() = GeneratedCloudCatalog.cloudSharingKinds.first { it.id == id }

    val title: String get() = spec.title
    val purpose: String get() = spec.purpose

    companion object {
        fun forId(id: String): CloudSharedDataKind? = entries.firstOrNull { it.id == id }
    }
}

/** A provider that can receive content; [privacyPolicyUrl] is null only for an uncatalogued one. */
data class CloudSharingProvider(val id: String, val displayName: String, val privacyPolicyUrl: String?)

/** What one provider would receive, kinds in [CloudSharedDataKind] order without duplicates. */
data class CloudSharingRequest(val provider: CloudSharingProvider, val kinds: List<CloudSharedDataKind>) {
    /** "Your audio recordings, to transcribe what you say." */
    val kindLines: List<String> get() = kinds.map { "${it.title}, ${it.purpose}." }

    companion object {
        fun of(provider: CloudSharingProvider, kinds: Collection<CloudSharedDataKind>) =
            CloudSharingRequest(provider, kinds.toSortedSet().toList())
    }
}

/**
 * Which providers the user allowed to receive which kinds of content: SpeakCore's `CloudSharingConsent`,
 * stored as the same JSON under the same key ([GeneratedCloudCatalog.CLOUD_SHARING_STORAGE_KEY]). Kept on
 * this phone only; consent given on another device does not count here.
 */
data class CloudSharingConsent(val grants: Map<String, Set<CloudSharedDataKind>> = emptyMap()) {
    fun allows(providerId: String, kind: CloudSharedDataKind): Boolean = grants[providerId]?.contains(kind) == true

    /** The part of each request not allowed yet; fully allowed requests are dropped. */
    fun missing(requests: List<CloudSharingRequest>): List<CloudSharingRequest> = requests.mapNotNull { request ->
        val kinds = request.kinds.filterNot { allows(request.provider.id, it) }
        if (kinds.isEmpty()) null else CloudSharingRequest(request.provider, kinds)
    }

    fun granting(requests: List<CloudSharingRequest>): CloudSharingConsent {
        val updated = grants.toMutableMap()
        for (request in requests) updated[request.provider.id] = updated[request.provider.id].orEmpty() + request.kinds
        return CloudSharingConsent(updated)
    }

    fun withdrawing(providerId: String): CloudSharingConsent = CloudSharingConsent(grants - providerId)

    /** Allowed providers with their kinds, by display name. */
    val allowed: List<CloudSharingRequest>
        get() = grants.filterValues { it.isNotEmpty() }
            .map { (id, kinds) -> CloudSharingRequest.of(provider(id, id), kinds) }
            .sortedBy { it.provider.displayName.lowercase() }

    /** `{"grants":{"openai":["audio"]},"version":1}`, keys sorted as the Apple store writes them. */
    fun encode(): String {
        val providers = grants.filterValues { it.isNotEmpty() }.toSortedMap().entries.joinToString(",") { (id, kinds) ->
            val ids = kinds.sorted().joinToString(",") { JSONObject.quote(it.id) }
            "${JSONObject.quote(id)}:[$ids]"
        }
        return """{"grants":{$providers},"version":1}"""
    }

    companion object {
        /** Unreadable or missing JSON is no consent, so nothing is sent until the user allows it again. */
        fun decode(json: String?): CloudSharingConsent {
            if (json.isNullOrBlank()) return CloudSharingConsent()
            return try {
                val grants = JSONObject(json).getJSONObject("grants")
                CloudSharingConsent(
                    grants.keys().asSequence().associateWith { id ->
                        val kinds: JSONArray = grants.getJSONArray(id)
                        (0 until kinds.length()).mapNotNull { CloudSharedDataKind.forId(kinds.getString(it)) }.toSet()
                    }.filterValues { it.isNotEmpty() },
                )
            } catch (_: org.json.JSONException) {
                CloudSharingConsent()
            }
        }

        /** The catalogued provider, or one named [fallbackName] without a policy link. */
        fun provider(id: String, fallbackName: String): CloudSharingProvider =
            GeneratedCloudCatalog.cloudSharingProviders.firstOrNull { it.id == id }
                ?.let { CloudSharingProvider(it.id, it.displayName, it.privacyPolicyUrl) }
                ?: CloudSharingProvider(id, fallbackName, null)

        fun request(provider: CloudProvider, kind: CloudSharedDataKind): CloudSharingRequest =
            CloudSharingRequest(provider(provider.id, provider.displayName), listOf(kind))

        /** One request per provider with the kinds combined, in first-seen order. */
        fun merged(requests: List<CloudSharingRequest>): List<CloudSharingRequest> =
            requests.groupBy { it.provider.id }.values.map { same ->
                CloudSharingRequest.of(same.first().provider, same.flatMap { it.kinds })
            }

        fun sheetIntro(requests: List<CloudSharingRequest>): String =
            GeneratedCloudCatalog.CLOUD_SHARING_INTRO_TEMPLATE
                .replace("{providers}", providerNames(requests))
                .replace(
                    "{service}",
                    if (requests.size == 1) {
                        GeneratedCloudCatalog.CLOUD_SHARING_SINGLE_SERVICE
                    } else {
                        GeneratedCloudCatalog.CLOUD_SHARING_PLURAL_SERVICE
                    },
                )

        /** The one-line reason a surface that cannot ask (the keyboard) shows instead of sending. */
        fun blockedMessage(requests: List<CloudSharingRequest>): String =
            GeneratedCloudCatalog.CLOUD_SHARING_BLOCKED_TEMPLATE.replace("{providers}", providerNames(requests))

        /** "A", "A and B", "A, B and C", as SpeakCore's `PrivacyWorkflowSummary.formattedList`. */
        fun formattedList(items: List<String>): String = when (items.size) {
            0 -> ""
            1 -> items[0]
            else -> items.dropLast(1).joinToString(", ") + " and " + items.last()
        }

        private fun providerNames(requests: List<CloudSharingRequest>) =
            formattedList(requests.map { it.provider.displayName })
    }
}
