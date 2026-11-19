package com.justspeaktoit.android.cloud

import org.json.JSONException
import org.json.JSONObject
import java.math.BigDecimal
import java.net.URLEncoder

/** A number field that may be missing or null; any other type is a malformed reply, as SpeakCore decodes it. */
private fun JSONObject.numberOrNull(name: String): Double? {
    if (!has(name) || isNull(name)) return null
    return (get(name) as? Number)?.toDouble() ?: throw JSONException("$name is not a number")
}

/** Deepgram's `GET /v1/projects` then each project's balances, as SpeakCore's `DeepgramBalanceClient` reads them. */
class DeepgramBalanceClient(
    private val http: BalanceHttp,
    private val baseUrl: String = "https://api.deepgram.com",
) : ProviderBalanceClient {
    override val accountId = "deepgram"

    override fun fetch(apiKey: String): BalanceState {
        val headers = mapOf("Authorization" to "Token $apiKey")
        val (projectsBody, failure) = BalanceTransport.get(http, "$baseUrl/v1/projects", headers)
        if (failure != null) return failure
        val projectIds = try {
            val projects = JSONObject(projectsBody.orEmpty()).getJSONArray("projects")
            List(projects.length()) { projects.getJSONObject(it).getString("project_id") }
        } catch (e: JSONException) {
            return BalanceState.Unknown(BalanceTransport.MALFORMED)
        }
        if (projectIds.isEmpty()) return BalanceState.Unknown(NO_PROJECTS)
        // Either every billable project is counted or no figure is claimed: response order picks no wallet.
        if (projectIds.size > MAXIMUM_PROJECTS) {
            return BalanceState.Unknown(
                "This Deepgram key bills ${projectIds.size} projects, more than Speak " +
                    "totals. Check the balance in the Deepgram console.",
            )
        }
        val entries = mutableListOf<Pair<Double, String>>()
        for (projectId in projectIds) {
            val path = URLEncoder.encode(projectId, "UTF-8").replace("+", "%20")
            val (body, projectFailure) = BalanceTransport.get(http, "$baseUrl/v1/projects/$path/balances", headers)
            // One unreadable project makes the total wrong, so nothing is claimed.
            if (projectFailure != null) return projectFailure
            entries += parseBalances(body.orEmpty()) ?: return BalanceState.Unknown(BalanceTransport.MALFORMED)
        }
        return state(entries, projectIds.size)
    }

    companion object {
        const val MAXIMUM_PROJECTS = 10
        const val NO_PROJECTS = "This Deepgram key has no projects to bill."
        const val NO_BALANCE_ONE = "Deepgram reported no balance for this project."
        const val NO_BALANCE_MANY = "Deepgram reported no balance for any of this key's projects."
        const val MIXED_UNITS = "Deepgram reported balances in more than one unit for this key."
        const val NO_UNIT = "Deepgram did not say what this balance is measured in."

        /** Each balance's amount and lower-cased unit, or null when the reply is malformed. */
        fun parseBalances(body: String): List<Pair<Double, String>>? = try {
            val balances = JSONObject(body).getJSONArray("balances")
            List(balances.length()) { index ->
                val entry = balances.getJSONObject(index)
                val amount = entry.numberOrNull("amount") ?: throw JSONException("amount is missing")
                val units = if (entry.isNull("units")) "" else entry.optString("units")
                amount to units.lowercase()
            }
        } catch (e: JSONException) {
            null
        }

        fun state(entries: List<Pair<Double, String>>, projectCount: Int): BalanceState {
            // No balance record is neither zero nor unlimited credit.
            if (entries.isEmpty()) {
                return BalanceState.Unknown(if (projectCount == 1) NO_BALANCE_ONE else NO_BALANCE_MANY)
            }
            val units = entries.map { it.second }.toSet()
            // Mixing dollars with anything else would invent a figure Deepgram never published.
            val unit = units.singleOrNull() ?: return BalanceState.Unknown(MIXED_UNITS)
            val total = entries.sumOf { it.first }
            return when {
                unit == "usd" -> BalanceState.Cash(BigDecimal.valueOf(total), "USD")
                unit.isEmpty() -> BalanceState.Unknown(NO_UNIT)
                else -> BalanceState.Allowance(total, null, unit)
            }
        }
    }
}

/** ElevenLabs' `GET /v1/user/subscription` character allowance, as SpeakCore's `ElevenLabsBalanceClient` reads it. */
class ElevenLabsBalanceClient(
    private val http: BalanceHttp,
    private val baseUrl: String = "https://api.elevenlabs.io",
) : ProviderBalanceClient {
    override val accountId = "elevenlabs"

    override fun fetch(apiKey: String): BalanceState {
        val (body, failure) = BalanceTransport.get(http, "$baseUrl/v1/user/subscription", mapOf("xi-api-key" to apiKey))
        if (failure != null) return failure
        return parse(body.orEmpty())
    }

    companion object {
        const val NO_LIMIT = "ElevenLabs did not report a character limit for this plan."
        const val NO_USAGE = "ElevenLabs did not report how many characters this plan has used."

        fun parse(body: String): BalanceState {
            val (limit, used, tier) = try {
                val subscription = JSONObject(body)
                Triple(
                    subscription.numberOrNull("character_limit"),
                    subscription.numberOrNull("character_count"),
                    if (subscription.isNull("tier")) "" else subscription.optString("tier"),
                )
            } catch (e: JSONException) {
                return BalanceState.Unknown(BalanceTransport.MALFORMED)
            }
            // No limit is not an unlimited plan, and an omitted counter is not zero usage.
            if (limit == null) return BalanceState.Unknown(NO_LIMIT)
            if (used == null) return BalanceState.Unknown(NO_USAGE)
            val remaining = maxOf(0.0, limit - used)
            return if (tier.lowercase().contains("free")) {
                BalanceState.FreeQuota(remaining, limit, "characters")
            } else {
                BalanceState.Allowance(remaining, limit, "characters")
            }
        }
    }
}

/** Rev AI's `GET /speechtotext/v1/account` seconds left, as SpeakCore's `RevAIBalanceClient` reads it. */
class RevAIBalanceClient(
    private val http: BalanceHttp,
    private val baseUrl: String = "https://api.rev.ai",
) : ProviderBalanceClient {
    override val accountId = "revai"

    override fun fetch(apiKey: String): BalanceState {
        val (body, failure) = BalanceTransport.get(
            http,
            "$baseUrl/speechtotext/v1/account",
            mapOf("Authorization" to "Bearer $apiKey"),
        )
        if (failure != null) return failure
        return parse(body.orEmpty())
    }

    companion object {
        const val NO_BALANCE = "Rev.ai did not report a remaining balance."

        fun parse(body: String): BalanceState {
            val seconds = try {
                JSONObject(body).numberOrNull("balance_seconds")
            } catch (e: JSONException) {
                return BalanceState.Unknown(BalanceTransport.MALFORMED)
            } ?: return BalanceState.Unknown(NO_BALANCE)
            // Rev AI meters audio seconds and publishes no ceiling, so the total stays unknown.
            return BalanceState.Allowance(seconds, null, "seconds")
        }
    }
}
