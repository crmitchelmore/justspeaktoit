package com.justspeaktoit.android.cloud

import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.math.BigDecimal
import java.math.RoundingMode
import java.net.HttpURLConnection
import java.net.URL
import java.text.DecimalFormat
import java.text.DecimalFormatSymbols
import java.util.Locale

/**
 * One provider account from `assets/provider_balances.json`, which SpeakCore's
 * `ProviderBalanceAndroidExport` writes from `ProviderBalanceDirectory`: whether its balance can be
 * read, and if not, why and where its billing page is. Android never keeps its own list.
 */
data class BalanceAccount(
    val id: String,
    val displayName: String,
    val credentialIds: List<String>,
    val primaryCredentialId: String,
    val readable: Boolean,
    /** Billing-link accounts only: why no figure is shown. */
    val reason: String?,
    val billingUrl: String?,
)

data class BalanceDirectory(val accounts: List<BalanceAccount>, val requestTimeoutSeconds: Int) {
    fun account(credentialId: String): BalanceAccount? = accounts.firstOrNull { credentialId in it.credentialIds }

    companion object {
        const val ASSET = "provider_balances.json"
        private const val VERSION = 1
        val EMPTY = BalanceDirectory(emptyList(), requestTimeoutSeconds = 15)

        fun parse(json: String): BalanceDirectory {
            val root = JSONObject(json)
            require(root.getInt("version") == VERSION) { "Unsupported provider balance version" }
            val accounts = root.getJSONArray("accounts")
            return BalanceDirectory(
                accounts = List(accounts.length()) { index ->
                    val account = accounts.getJSONObject(index)
                    val ids = account.getJSONArray("credentialIds")
                    BalanceAccount(
                        id = account.getString("id"),
                        displayName = account.getString("displayName"),
                        credentialIds = List(ids.length()) { ids.getString(it) },
                        primaryCredentialId = account.getString("primaryCredentialId"),
                        readable = account.getString("support") == "balance",
                        reason = account.optString("reason").ifEmpty { null },
                        billingUrl = account.optString("billingUrl").ifEmpty { null },
                    )
                },
                requestTimeoutSeconds = root.getInt("requestTimeoutSeconds"),
            )
        }
    }
}

/** SpeakCore's `ProviderBalanceState`, limited to what Android's transports report. */
sealed interface BalanceState {
    /** Spendable money left on the account. */
    data class Cash(val amount: BigDecimal, val currency: String) : BalanceState

    /** Metered units left, such as Rev AI seconds; a null [total] means the provider gave no limit. */
    data class Allowance(val remaining: Double, val total: Double?, val unit: String) : BalanceState

    /** Units left on a free plan, such as ElevenLabs characters. */
    data class FreeQuota(val remaining: Double, val total: Double?, val unit: String) : BalanceState

    /** Money spent with nothing spendable left, explained by [note]. */
    data class Usage(val spent: BigDecimal, val currency: String, val note: String) : BalanceState

    /** The figure could not be read; [reason] says why and never contains the key. */
    data class Unknown(val reason: String) : BalanceState
}

/** The same wording as SpeakCore's `ProviderBalanceFormatter`, so every platform reads alike. */
object BalanceFormatter {
    fun summary(state: BalanceState): String = when (state) {
        is BalanceState.Cash -> "${money(state.amount, state.currency)} credit"
        is BalanceState.Allowance -> allowance(state.remaining, state.total, state.unit, "left")
        is BalanceState.FreeQuota -> allowance(state.remaining, state.total, state.unit, "left on the free tier")
        is BalanceState.Usage -> "${money(state.spent, state.currency)} used"
        is BalanceState.Unknown -> "Balance unknown"
    }

    fun detail(state: BalanceState): String? = when (state) {
        is BalanceState.Cash -> null
        // A provider that omits the limit says nothing about the total, and silence must not read as unlimited.
        is BalanceState.Allowance -> if (state.total == null) NO_LIMIT else null
        is BalanceState.FreeQuota -> if (state.total == null) NO_QUOTA else null
        is BalanceState.Usage -> state.note
        is BalanceState.Unknown -> state.reason
    }

    /** The figure and its explanation, as the desktop pages print them: `Balance: $4.10 credit.` */
    fun line(state: BalanceState): String {
        val summary = summary(state)
        val parts = mutableListOf(if (summary.startsWith("Balance")) "$summary." else "Balance: $summary.")
        detail(state)?.let { parts += if (it.last() in ".!?") it else "$it." }
        return parts.joinToString(" ")
    }

    const val NO_LIMIT = "The provider did not report a limit, so the total is unknown."
    const val NO_QUOTA = "The provider did not report a quota, so the total is unknown."

    /** SpeakCore's `number`: grouped thousands, and two decimals only for a fractional value. */
    fun number(value: Double): String {
        val pattern = if (value == Math.rint(value)) "#,##0" else "#,##0.##"
        return DecimalFormat(pattern, DecimalFormatSymbols(Locale.US)).format(value)
    }

    private fun allowance(remaining: Double, total: Double?, unit: String, label: String): String =
        if (total == null) {
            "${number(remaining)} $unit $label (limit unknown)"
        } else {
            "${number(remaining)} of ${number(total)} $unit $label"
        }

    fun money(amount: BigDecimal, currency: String): String {
        val digits = String.format(Locale.US, "%.2f", amount.setScale(2, RoundingMode.HALF_UP))
        return when (currency) {
            "USD" -> "$$digits"
            "GBP" -> "£$digits"
            "EUR" -> "€$digits"
            else -> "$digits $currency"
        }
    }
}

/** One billing GET's status and body. */
data class BalanceReply(val status: Int, val body: String)

/** The HTTP a balance check needs; swapped for a fake in tests. Throws [IOException] when unreachable. */
fun interface BalanceHttp {
    fun get(url: String, headers: Map<String, String>): BalanceReply
}

/** [HttpURLConnection] GET bounded by the shared balance deadline. */
class UrlConnectionBalanceHttp(private val timeoutMs: Int) : BalanceHttp {
    override fun get(url: String, headers: Map<String, String>): BalanceReply {
        val conn = URL(url).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "GET"
            conn.connectTimeout = timeoutMs
            conn.readTimeout = timeoutMs
            conn.setRequestProperty("Accept", "application/json")
            headers.forEach { (name, value) -> conn.setRequestProperty(name, value) }
            val status = conn.responseCode
            if (status !in 200..299) {
                conn.errorStream?.close()
                return BalanceReply(status, "")
            }
            return BalanceReply(status, conn.inputStream.use { CloudWire.readBody(it) })
        } finally {
            conn.disconnect()
        }
    }
}

/** Reads one account's balance. Blocking, so callers run it off the main thread; never throws. */
interface ProviderBalanceClient {
    val accountId: String

    fun fetch(apiKey: String): BalanceState
}

/** SpeakCore's `ProviderBalanceTransport` failure wording, so a failure reads the same everywhere. */
object BalanceTransport {
    const val UNREACHABLE = "Could not reach the billing endpoint."
    const val MALFORMED = "The billing endpoint returned an unexpected response."

    fun message(status: Int): String = when (status) {
        401, 403 -> "The saved key is not authorised to read billing (HTTP $status)."
        404 -> "The provider has no billing record for this key (HTTP 404)."
        429 -> "The provider rate-limited the balance check (HTTP 429). Try again shortly."
        else -> "The billing endpoint replied HTTP $status."
    }

    /** The body of a successful GET, or the state explaining why there is none. */
    fun get(http: BalanceHttp, url: String, headers: Map<String, String>): Pair<String?, BalanceState?> {
        val reply = try {
            http.get(url, headers)
        } catch (e: IOException) {
            // The exception text is not shown: it can echo connection details, and the key must never leak.
            return null to BalanceState.Unknown(UNREACHABLE)
        }
        if (reply.status !in 200..299) return null to BalanceState.Unknown(message(reply.status))
        return reply.body to null
    }
}

/** OpenRouter's `GET /api/v1/credits`, as SpeakCore's `OpenRouterBalanceClient` reads it. */
class OpenRouterBalanceClient(
    private val http: BalanceHttp,
    private val baseUrl: String = "https://openrouter.ai",
) : ProviderBalanceClient {
    override val accountId = "openrouter"

    override fun fetch(apiKey: String): BalanceState {
        val (body, failure) = BalanceTransport.get(
            http,
            "$baseUrl/api/v1/credits",
            mapOf("Authorization" to "Bearer $apiKey"),
        )
        if (failure != null) return failure
        return parse(body.orEmpty())
    }

    companion object {
        const val MISSING = "OpenRouter did not report both purchased and used credits."
        const val OVERDRAWN = "OpenRouter reports more usage than purchased credit on this account, " +
            "so there is no spendable balance to show."

        fun parse(body: String): BalanceState {
            val data = try {
                JSONObject(body).getJSONObject("data")
            } catch (e: JSONException) {
                return BalanceState.Unknown(BalanceTransport.MALFORMED)
            }
            val purchased = data.number("total_credits")
            val used = data.number("total_usage")
            if (purchased == null || used == null) return BalanceState.Unknown(MISSING)
            val remainder = purchased.subtract(used)
            // Usage above purchased credit is an overdrawn or postpaid account, not a negative wallet.
            if (remainder.signum() < 0) return BalanceState.Usage(used, "USD", OVERDRAWN)
            return BalanceState.Cash(remainder, "USD")
        }

        private fun JSONObject.number(name: String): BigDecimal? {
            if (!has(name) || isNull(name)) return null
            val value = optDouble(name)
            return if (value.isNaN()) null else BigDecimal.valueOf(value)
        }
    }
}

object ProviderBalanceClients {
    /** Android's transports, one per readable account it lists; the parity test keeps them in step. */
    fun defaults(directory: BalanceDirectory): List<ProviderBalanceClient> {
        val http = UrlConnectionBalanceHttp(directory.requestTimeoutSeconds * 1000)
        return listOf(
            DeepgramBalanceClient(http),
            ElevenLabsBalanceClient(http),
            RevAIBalanceClient(http),
            OpenRouterBalanceClient(http),
        )
    }
}
