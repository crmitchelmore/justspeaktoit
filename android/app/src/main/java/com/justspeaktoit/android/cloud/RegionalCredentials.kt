package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.dictation.DictationFailure
import org.json.JSONException
import org.json.JSONObject
import java.net.URI
import java.net.URISyntaxException
import java.util.Locale

/**
 * Azure Speech keys, as `AzureSpeechConfiguration` stores them: `key:region` under the provider's
 * credential, so a key moves between devices in the same format. The optional resource endpoint is
 * stored beside it, under [ENDPOINT_SECRET], and stays on this device as it does on Apple devices.
 */
object AzureSpeechCredential {
    /** `AzureSpeechConfiguration.endpointDefaultsKey`. */
    const val ENDPOINT_SECRET = "azureSpeechResourceEndpoint"

    /** The region a key saved without one uses. */
    const val DEFAULT_REGION = "eastus"

    /** `AzureSpeechConfiguration.proxyCredentialPrefix`: Android has no local proxy, so such keys are refused. */
    private const val PROXY_PREFIX = "local-proxy/"

    private val RESOURCE_HOST_SUFFIXES = listOf(".cognitiveservices.azure.com", ".services.ai.azure.com")

    data class Parsed(val apiKey: String, val region: String)

    /** Where a recording goes and the key it is sent with. */
    data class Connection(val origin: String, val apiKey: String)

    /** `AzureSpeechEndpoint`'s region check: lowercase ASCII letters and digits, at most 63 bytes. */
    fun isValidRegion(region: String): Boolean =
        region.isNotEmpty() && region.length <= 63 && region.all { it in 'a'..'z' || it in '0'..'9' }

    /** Splits on the first `:`; a key without one uses [DEFAULT_REGION]. Null when either part is invalid. */
    fun parse(credentials: String): Parsed? {
        val value = credentials.trim()
        val colon = value.indexOf(':')
        val key = (if (colon < 0) value else value.substring(0, colon)).trim()
        val region = if (colon < 0) DEFAULT_REGION else value.substring(colon + 1).trim().lowercase(Locale.ROOT)
        if (key.isEmpty() || !isValidRegion(region)) return null
        return Parsed(key, region)
    }

    /**
     * What Save stores. A key that already carries its region (`key:region`, pasted from another
     * device) keeps it; otherwise [region] is added. Null when the result would not parse.
     */
    fun credentialsForSaving(entered: String, region: String): String? {
        val value = entered.trim()
        if (value.isEmpty() || value.any { it == '\n' || it == '\r' } || value.startsWith(PROXY_PREFIX)) return null
        val combined = if (':' in value) value else "$value:${region.trim().lowercase(Locale.ROOT)}"
        return parse(combined)?.let { "${it.apiKey}:${it.region}" }
    }

    /**
     * `AzureSpeechConfiguration.resourceURL`: only an HTTPS Speech resource origin, with no path,
     * port, credentials, query or fragment. Returns `https://<host>`, or null for anything else.
     */
    fun resourceOrigin(endpoint: String): String? {
        val uri = try {
            URI(endpoint.trim())
        } catch (e: URISyntaxException) {
            return null
        }
        val host = uri.host?.lowercase(Locale.ROOT) ?: return null
        val path = uri.rawPath.orEmpty()
        val valid = uri.scheme == "https" && RESOURCE_HOST_SUFFIXES.any { host.endsWith(it) } &&
            uri.rawUserInfo == null && uri.port == -1 && uri.rawQuery == null && uri.rawFragment == null &&
            (path.isEmpty() || path == "/")
        return if (valid) "https://$host" else null
    }

    /**
     * `AzureSpeechConfiguration.batchConnection` for HTTPS: the resource endpoint when one is saved,
     * else the key's regional Speech origin.
     * @throws CloudException [DictationFailure.InvalidKey] for a malformed key, a local-proxy token
     *   or an endpoint that is not a Speech resource origin.
     */
    fun connection(credentials: String, endpoint: String): Connection {
        val parsed = parse(credentials)
            ?: throw CloudException(DictationFailure.InvalidKey, "Enter your Azure key and region as key:region.")
        if (parsed.apiKey.startsWith(PROXY_PREFIX)) {
            throw CloudException(DictationFailure.InvalidKey, "Android cannot use an Azure local proxy token.")
        }
        val origin = if (endpoint.isBlank()) {
            "https://${parsed.region}.api.cognitive.microsoft.com"
        } else {
            resourceOrigin(endpoint) ?: throw CloudException(
                DictationFailure.InvalidKey,
                "Add the HTTPS resource endpoint from Azure in API Keys settings.",
            )
        }
        return Connection(origin, parsed.apiKey)
    }
}

/**
 * Alibaba Model Studio keys, as `AlibabaSpeechConfiguration` stores them: the region and workspace
 * travel with the key as JSON, never as separate preferences.
 */
object AlibabaCredential {
    enum class Region(val id: String, val displayName: String) {
        Beijing("cn-beijing", "China (Beijing)"),
        Singapore("ap-southeast-1", "Singapore"),
        Frankfurt("eu-central-1", "Germany (Frankfurt)"),
        Tokyo("ap-northeast-1", "Japan (Tokyo)"),
        HongKong("cn-hongkong", "China (Hong Kong)"),
        Virginia("us-east-1", "US (Virginia)"),
        ;

        companion object {
            fun forId(id: String?): Region? = entries.firstOrNull { it.id == id }
        }
    }

    data class Parsed(val region: Region, val workspace: String, val apiKey: String) {
        /** One DNS label per part, both validated, so the key never follows a user-entered URL. */
        val origin: String get() = "https://$workspace.${region.id}.maas.aliyuncs.com"
    }

    /** A workspace ID such as `llm-abc123`: a lowercase DNS label, never the shared `trial` workspace. */
    fun isValidWorkspace(workspace: String): Boolean =
        workspace.isNotEmpty() && workspace.length <= 63 && !workspace.startsWith('-') &&
            !workspace.endsWith('-') && workspace != "trial" &&
            workspace.all { it in 'a'..'z' || it in '0'..'9' || it == '-' }

    private fun parsed(region: Region?, workspace: String, apiKey: String): Parsed? {
        val ws = workspace.trim().lowercase(Locale.ROOT)
        val key = apiKey.trim()
        if (region == null || !isValidWorkspace(ws) || key.isEmpty() || key.any { it == '\n' || it == '\r' }) {
            return null
        }
        return Parsed(region, ws, key)
    }

    fun parse(credentials: String): Parsed? = try {
        val json = JSONObject(credentials)
        parsed(
            Region.forId(json.opt("region") as? String),
            json.opt("workspace") as? String ?: return null,
            json.opt("apiKey") as? String ?: return null,
        )
    } catch (e: JSONException) {
        null
    }

    /** `AlibabaSpeechConfiguration.encodedCredentials`, in its field order; null when anything is invalid. */
    fun credentialsForSaving(apiKey: String, region: Region?, workspace: String): String? {
        val value = parsed(region, workspace, apiKey) ?: return null
        return "{\"region\":${JSONObject.quote(value.region.id)},\"workspace\":${JSONObject.quote(value.workspace)}," +
            "\"apiKey\":${JSONObject.quote(value.apiKey)}}"
    }
}

/**
 * StepFun keys, as `StepFunCredential` stores them: keys work only on the platform that issued them,
 * so the region travels with the key. A plain key predates regions and keeps the China endpoint.
 */
object StepFunCredential {
    enum class Region(val id: String, val displayName: String, val asrUrl: String) {
        International(
            "international",
            "International (platform.stepfun.ai)",
            "https://api.stepfun.ai/v1/audio/asr/sse",
        ),
        China("china", "China (platform.stepfun.com)", "https://api.stepfun.com/v1/audio/asr/sse"),
        ;

        companion object {
            /** `StepFunCredential.Region.defaultForNewKeys`. */
            val DEFAULT_FOR_NEW_KEYS = International

            fun forId(id: String?): Region? = entries.firstOrNull { it.id == id }
        }
    }

    data class Parsed(val region: Region, val apiKey: String)

    private fun parsed(region: Region?, apiKey: String): Parsed? {
        val key = apiKey.trim()
        if (region == null || key.isEmpty() || key.startsWith('{') || key.any { it == '\n' || it == '\r' }) {
            return null
        }
        return Parsed(region, key)
    }

    fun parse(credentials: String): Parsed? {
        val value = credentials.trim()
        if (!value.startsWith('{')) return parsed(Region.China, value)
        return try {
            val json = JSONObject(value)
            parsed(Region.forId(json.opt("region") as? String), json.opt("apiKey") as? String ?: return null)
        } catch (e: JSONException) {
            null
        }
    }

    /**
     * `StepFunCredential.credentialsForSaving`: tags a new key with [region]; a value that already
     * carries a region (pasted from a transfer) keeps its own. Sorted keys, as `encodedCredentials`.
     */
    fun credentialsForSaving(entered: String, region: Region): String? {
        val value = entered.trim()
        val credential = if (value.startsWith('{')) parse(value) else parsed(region, value)
        return credential?.let { "{\"apiKey\":${JSONObject.quote(it.apiKey)},\"region\":\"${it.region.id}\"}" }
    }
}
