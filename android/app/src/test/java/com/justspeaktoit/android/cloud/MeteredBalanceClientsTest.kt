package com.justspeaktoit.android.cloud

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigDecimal

class MeteredBalanceClientsTest {
    private val key = "metered-secret-456"

    private class RoutedHttp(private val routes: Map<String, BalanceReply>) : BalanceHttp {
        val calls = mutableListOf<Pair<String, Map<String, String>>>()

        override fun get(url: String, headers: Map<String, String>): BalanceReply {
            calls += url to headers
            return routes[url] ?: BalanceReply(404, "")
        }
    }

    private fun deepgram(vararg projects: Pair<String, String>): Map<String, BalanceReply> {
        val ids = projects.joinToString(",") { """{"project_id":"${it.first}"}""" }
        return mapOf("https://api.deepgram.com/v1/projects" to BalanceReply(200, """{"projects":[$ids]}""")) +
            projects.associate {
                "https://api.deepgram.com/v1/projects/${it.first}/balances" to BalanceReply(200, it.second)
            }
    }

    @Test
    fun testDeepgram_sumsDollarsAcrossProjects() {
        val http = RoutedHttp(
            deepgram(
                "a" to """{"balances":[{"amount":10.5,"units":"USD"}]}""",
                "b" to """{"balances":[{"amount":2,"units":"usd"}]}""",
            ),
        )
        val state = DeepgramBalanceClient(http).fetch(key)
        assertEquals(BalanceState.Cash(BigDecimal.valueOf(12.5), "USD"), state)
        http.calls.forEach { (url, headers) ->
            assertFalse(url.contains(key))
            assertEquals(mapOf("Authorization" to "Token $key"), headers)
        }
    }

    @Test
    fun testDeepgram_neverGuessesAFigure() {
        assertEquals(
            BalanceState.Unknown(DeepgramBalanceClient.NO_PROJECTS),
            DeepgramBalanceClient(RoutedHttp(deepgram())).fetch(key),
        )
        val many = (1..11).map { "p$it" to """{"balances":[]}""" }.toTypedArray()
        val tooMany = DeepgramBalanceClient(RoutedHttp(deepgram(*many))).fetch(key)
        assertTrue((tooMany as BalanceState.Unknown).reason.startsWith("This Deepgram key bills 11 projects"))
        val oneFailsRoutes = deepgram("a" to """{"balances":[{"amount":1,"units":"usd"}]}""", "b" to "") +
            ("https://api.deepgram.com/v1/projects/b/balances" to BalanceReply(500, ""))
        val oneFails = DeepgramBalanceClient(RoutedHttp(oneFailsRoutes)).fetch(key)
        assertEquals(BalanceState.Unknown(BalanceTransport.message(500)), oneFails)
        assertEquals(BalanceState.Unknown(DeepgramBalanceClient.NO_BALANCE_ONE), DeepgramBalanceClient.state(emptyList(), 1))
        assertEquals(BalanceState.Unknown(DeepgramBalanceClient.NO_BALANCE_MANY), DeepgramBalanceClient.state(emptyList(), 2))
        assertEquals(
            BalanceState.Unknown(DeepgramBalanceClient.MIXED_UNITS),
            DeepgramBalanceClient.state(listOf(1.0 to "usd", 2.0 to "hour"), 2),
        )
        assertEquals(BalanceState.Unknown(DeepgramBalanceClient.NO_UNIT), DeepgramBalanceClient.state(listOf(1.0 to ""), 1))
        assertEquals(BalanceState.Allowance(3.0, null, "hour"), DeepgramBalanceClient.state(listOf(3.0 to "hour"), 1))
        assertNull(DeepgramBalanceClient.parseBalances("""{"balances":[{"units":"usd"}]}"""))
    }

    @Test
    fun testElevenLabs_reportsCharactersLeft() {
        val http = RoutedHttp(
            mapOf(
                "https://api.elevenlabs.io/v1/user/subscription" to
                    BalanceReply(200, """{"tier":"creator","character_limit":100000,"character_count":12345}"""),
            ),
        )
        val state = ElevenLabsBalanceClient(http).fetch(key)
        assertEquals(BalanceState.Allowance(87655.0, 100000.0, "characters"), state)
        assertEquals(mapOf("xi-api-key" to key), http.calls.single().second)
        assertEquals("87,655 of 100,000 characters left", BalanceFormatter.summary(state))
        assertNull(BalanceFormatter.detail(state))
    }

    @Test
    fun testElevenLabs_freeTierAndMissingFields() {
        assertEquals(
            BalanceState.FreeQuota(0.0, 10000.0, "characters"),
            ElevenLabsBalanceClient.parse("""{"tier":"Free","character_limit":10000,"character_count":12000}"""),
        )
        assertEquals(
            BalanceState.Unknown(ElevenLabsBalanceClient.NO_LIMIT),
            ElevenLabsBalanceClient.parse("""{"character_count":1}"""),
        )
        assertEquals(
            BalanceState.Unknown(ElevenLabsBalanceClient.NO_USAGE),
            ElevenLabsBalanceClient.parse("""{"character_limit":1}"""),
        )
        assertEquals(
            BalanceState.Unknown(BalanceTransport.MALFORMED),
            ElevenLabsBalanceClient.parse("""{"character_limit":"lots","character_count":1}"""),
        )
    }

    @Test
    fun testRevAI_reportsSecondsWithoutATotal() {
        val http = RoutedHttp(
            mapOf("https://api.rev.ai/speechtotext/v1/account" to BalanceReply(200, """{"balance_seconds":3600.5}""")),
        )
        val state = RevAIBalanceClient(http).fetch(key)
        assertEquals(BalanceState.Allowance(3600.5, null, "seconds"), state)
        assertEquals(mapOf("Authorization" to "Bearer $key"), http.calls.single().second)
        assertEquals("3,600.5 seconds left (limit unknown)", BalanceFormatter.summary(state))
        assertEquals(BalanceFormatter.NO_LIMIT, BalanceFormatter.detail(state))
        assertEquals(BalanceState.Unknown(RevAIBalanceClient.NO_BALANCE), RevAIBalanceClient.parse("{}"))
    }

    @Test
    fun testFreeQuotaWording_matchesSpeakCore() {
        assertEquals(
            "1,234.57 characters left on the free tier (limit unknown)",
            BalanceFormatter.summary(BalanceState.FreeQuota(1234.567, null, "characters")),
        )
        assertEquals(BalanceFormatter.NO_QUOTA, BalanceFormatter.detail(BalanceState.FreeQuota(1.0, null, "characters")))
        val formatter = RepoSources.speakCore("Balance/ProviderBalance.swift")
        listOf(BalanceFormatter.NO_LIMIT, BalanceFormatter.NO_QUOTA, "left on the free tier", "(limit unknown)")
            .forEach { assertTrue(it, formatter.contains(it)) }
    }

    @Test
    fun testMessages_matchSpeakCore() {
        val deepgram = RepoSources.speakCore("Balance/DeepgramBalanceClient.swift")
        listOf(
            DeepgramBalanceClient.NO_PROJECTS,
            DeepgramBalanceClient.NO_BALANCE_ONE,
            DeepgramBalanceClient.NO_BALANCE_MANY,
            DeepgramBalanceClient.MIXED_UNITS,
            DeepgramBalanceClient.NO_UNIT,
        ).forEach { assertTrue(it, deepgram.contains("\"$it\"")) }
        assertTrue(deepgram.contains("maximumProjects = ${DeepgramBalanceClient.MAXIMUM_PROJECTS}"))
        val elevenLabs = RepoSources.speakCore("Balance/ElevenLabsBalanceClient.swift")
        listOf(ElevenLabsBalanceClient.NO_LIMIT, ElevenLabsBalanceClient.NO_USAGE)
            .forEach { assertTrue(it, elevenLabs.contains("\"$it\"")) }
        val revAI = RepoSources.speakCore("Balance/RevAIBalanceClient.swift")
        assertTrue(revAI.contains("\"${RevAIBalanceClient.NO_BALANCE}\""))
    }
}
