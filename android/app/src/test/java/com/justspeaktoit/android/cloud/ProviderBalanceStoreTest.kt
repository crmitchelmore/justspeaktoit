package com.justspeaktoit.android.cloud

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.math.BigDecimal
import kotlin.coroutines.CoroutineContext

class ProviderBalanceStoreTest {
    /** Runs nothing until [drain], so each test steps the main and io lanes itself. */
    private class QueueDispatcher : CoroutineDispatcher() {
        private val queue = ArrayDeque<Runnable>()

        override fun dispatch(context: CoroutineContext, block: Runnable) {
            queue.addLast(block)
        }

        fun drain() {
            while (queue.isNotEmpty()) queue.removeFirst().run()
        }
    }

    private class FakeClient(override val accountId: String) : ProviderBalanceClient {
        val keys = mutableListOf<String>()
        var state: BalanceState = BalanceState.Cash(BigDecimal("4.10"), "USD")

        override fun fetch(apiKey: String): BalanceState {
            keys += apiKey
            return state
        }
    }

    private val openRouter = BalanceAccount(
        "openrouter", "OpenRouter", listOf("openrouter.apiKey"), "openrouter.apiKey", true, null, null,
    )
    private val openAI = BalanceAccount(
        "openai", "OpenAI", listOf("openai.apiKey"), "openai.apiKey", false, "No key-scoped balance.",
        "https://platform.openai.com/settings/organization/billing/overview",
    )
    private val main = QueueDispatcher()
    private val io = QueueDispatcher()
    private val client = FakeClient("openrouter")
    private val keys = mutableMapOf("openrouter.apiKey" to " sk-or-1 ")
    private val published = mutableListOf<Map<String, BalanceEntry>>()
    private val store = ProviderBalanceStore(
        directory = BalanceDirectory(listOf(openAI, openRouter), requestTimeoutSeconds = 15),
        clients = listOf(client),
        readKey = { keys[it] },
        scope = CoroutineScope(SupervisorJob() + main),
        io = io,
        clock = { 42L },
        publish = { published += it },
    )

    private fun drain() {
        repeat(3) {
            main.drain()
            io.drain()
        }
    }

    @Test
    fun testRefreshSaved_checksOnlySavedReadableAccounts() {
        store.refreshSaved(setOf("openai.apiKey", "openrouter.apiKey"))
        assertEquals(mapOf("openrouter" to BalanceEntry.Checking), published.last())
        drain()
        assertEquals(listOf("sk-or-1"), client.keys)
        assertEquals(
            mapOf("openrouter" to BalanceEntry.Loaded(BalanceState.Cash(BigDecimal("4.10"), "USD"), 42L)),
            published.last(),
        )
        assertTrue(store.canCheck(openRouter))
        assertTrue(!store.canCheck(openAI))
    }

    @Test
    fun testRefreshSaved_skipsUnsavedKeys() {
        store.refreshSaved(setOf("openai.apiKey"))
        drain()
        assertTrue(published.isEmpty())
        assertTrue(client.keys.isEmpty())
    }

    @Test
    fun testMissingOrUnreadableKey_isUnknownWithoutARequest() {
        keys.clear()
        store.refresh("openrouter.apiKey")
        drain()
        assertEquals(
            BalanceEntry.Loaded(BalanceState.Unknown(ProviderBalanceStore.NO_KEY), 42L),
            published.last()["openrouter"],
        )
        val failing = ProviderBalanceStore(
            BalanceDirectory(listOf(openRouter), 15), listOf(client), { error("keystore") },
            CoroutineScope(SupervisorJob() + main), io, { 1L }, { published += it },
        )
        failing.refresh("openrouter.apiKey")
        drain()
        assertEquals(
            BalanceEntry.Loaded(BalanceState.Unknown(ProviderBalanceStore.UNREADABLE), 1L),
            published.last()["openrouter"],
        )
        assertTrue(client.keys.isEmpty())
    }

    @Test
    fun testCredentialChanged_dropsAnInFlightCheckAndForgetsTheFigure() {
        store.refresh("openrouter.apiKey")
        main.drain()
        store.credentialChanged("openrouter.apiKey")
        drain()
        assertEquals(emptyMap<String, BalanceEntry>(), published.last())

        store.refresh("openrouter.apiKey")
        drain()
        store.credentialChanged("openrouter.apiKey")
        assertEquals(emptyMap<String, BalanceEntry>(), published.last())
    }

    @Test
    fun testPublishedEntries_neverHoldTheKey() {
        client.state = BalanceState.Unknown("The saved key is not authorised to read billing (HTTP 401).")
        store.refresh("openrouter.apiKey")
        drain()
        assertTrue(published.none { it.toString().contains("sk-or-1") })
    }
}
