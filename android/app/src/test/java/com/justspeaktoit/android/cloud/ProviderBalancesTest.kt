package com.justspeaktoit.android.cloud

import com.justspeaktoit.android.settings.SettingsSearchAsset
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.IOException
import java.math.BigDecimal

class ProviderBalancesTest {
    private val key = "sk-or-secret-123"
    private val directory = BalanceDirectory.parse(
        SettingsSearchAsset.locate("app/src/main/assets/${BalanceDirectory.ASSET}").readText(),
    )

    private class RecordingHttp(private val reply: () -> BalanceReply) : BalanceHttp {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()

        override fun get(url: String, headers: Map<String, String>): BalanceReply {
            calls += url to headers
            return reply()
        }
    }

    @Test
    fun testAsset_coversEveryProviderCardOnce() {
        val primaries = directory.accounts.map { it.primaryCredentialId }
        assertEquals(CloudCatalog.providers.map { it.credentialId }, primaries)
        directory.accounts.filterNot { it.readable }.forEach {
            assertNotNull("${it.id} needs a reason", it.reason)
            assertTrue("${it.id} billing link", it.billingUrl.orEmpty().startsWith("https://"))
        }
    }

    @Test
    fun testEveryReadableAccount_hasAnAndroidClient() {
        val clients = ProviderBalanceClients.defaults(directory).map { it.accountId }.toSet()
        assertEquals(directory.accounts.filter { it.readable }.map { it.id }.toSet(), clients)
    }

    @Test
    fun testOpenRouter_sendsKeyOnlyInAuthorizationHeader() {
        val http = RecordingHttp { BalanceReply(200, """{"data":{"total_credits":20.5,"total_usage":8.25}}""") }
        val state = OpenRouterBalanceClient(http).fetch(key)
        assertEquals(BalanceState.Cash(BigDecimal.valueOf(12.25), "USD"), state)
        val (url, headers) = http.calls.single()
        assertEquals("https://openrouter.ai/api/v1/credits", url)
        assertFalse(url.contains(key))
        assertEquals(mapOf("Authorization" to "Bearer $key"), headers)
        assertEquals("Balance: $12.25 credit.", BalanceFormatter.line(state))
    }

    @Test
    fun testOpenRouter_overdrawnReportsUsage() {
        val state = OpenRouterBalanceClient.parse("""{"data":{"total_credits":5,"total_usage":7.125}}""")
        assertEquals(BalanceState.Usage(BigDecimal.valueOf(7.125), "USD", OpenRouterBalanceClient.OVERDRAWN), state)
        assertEquals("$7.13 used", BalanceFormatter.summary(state))
    }

    @Test
    fun testOpenRouter_missingOrMalformedFieldsAreUnknown() {
        assertEquals(
            BalanceState.Unknown(OpenRouterBalanceClient.MISSING),
            OpenRouterBalanceClient.parse("""{"data":{"total_credits":5}}"""),
        )
        assertEquals(BalanceState.Unknown(BalanceTransport.MALFORMED), OpenRouterBalanceClient.parse("<html>"))
    }

    @Test
    fun testFailures_neverContainTheKey() {
        val states = listOf(401, 403, 404, 429, 500).map { status ->
            OpenRouterBalanceClient(RecordingHttp { BalanceReply(status, key) }).fetch(key)
        } + OpenRouterBalanceClient(RecordingHttp { throw IOException("failed for $key") }).fetch(key)
        states.forEach { state ->
            assertTrue(state is BalanceState.Unknown)
            assertFalse(BalanceFormatter.line(state).contains(key))
        }
        assertEquals(
            BalanceState.Unknown("The saved key is not authorised to read billing (HTTP 401)."),
            states.first(),
        )
        assertEquals(BalanceState.Unknown(BalanceTransport.UNREACHABLE), states.last())
    }

    @Test
    fun testMessages_matchSpeakCore() {
        val transport = RepoSources.speakCore("Balance/ProviderBalanceTransport.swift")
        listOf(404, 429).forEach { assertTrue(transport.contains("\"${BalanceTransport.message(it)}\"")) }
        assertTrue(transport.contains("The saved key is not authorised to read billing (HTTP \\(status))."))
        assertTrue(transport.contains("\"${BalanceTransport.MALFORMED}\""))
        assertTrue(transport.contains("Could not reach the billing endpoint"))
        val openRouter = RepoSources.speakCore("Balance/OpenRouterBalanceClient.swift")
        assertTrue(openRouter.contains("\"${OpenRouterBalanceClient.MISSING}\""))
        assertTrue(openRouter.contains("https://openrouter.ai"))
        assertTrue(openRouter.contains("api/v1/credits"))
        assertTrue(transport.contains("requestTimeout: TimeInterval = ${directory.requestTimeoutSeconds}"))
    }

    @Test
    fun testMoney_matchesSpeakCoreFormatting() {
        assertEquals("$0.01", BalanceFormatter.money(BigDecimal("0.005"), "USD"))
        assertEquals("£3.00", BalanceFormatter.money(BigDecimal("3"), "GBP"))
        assertEquals("€1.25", BalanceFormatter.money(BigDecimal("1.25"), "EUR"))
        assertEquals("4.50 CHF", BalanceFormatter.money(BigDecimal("4.5"), "CHF"))
    }
}
