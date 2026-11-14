package com.justspeaktoit.android.cloud

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Where one account's balance check stands; no entry means it has not been checked since the key changed. */
sealed interface BalanceEntry {
    data object Checking : BalanceEntry

    data class Loaded(val state: BalanceState, val checkedAtMillis: Long) : BalanceEntry
}

/**
 * Android's balances beside API keys, matching `ProviderBalanceStore` on macOS and iOS and the desktop
 * host's store: keyed by account, read only for a saved key, never throwing, and never on a key-entry or
 * transcription path. Every call comes from [scope]'s thread; the key read and the request run on [io].
 *
 * The key is read here and handed only to the client, which puts it in the auth header; it is never
 * published, logged or kept.
 */
class ProviderBalanceStore(
    private val directory: BalanceDirectory,
    clients: List<ProviderBalanceClient>,
    private val readKey: (String) -> String?,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
    private val clock: () -> Long = System::currentTimeMillis,
    private val publish: (Map<String, BalanceEntry>) -> Unit,
) {
    private val clients = clients.associateBy { it.accountId }
    private val entries = mutableMapOf<String, BalanceEntry>()
    private val jobs = mutableMapOf<String, Job>()

    /** Whether the account's card offers Check balance once its key is saved. */
    fun canCheck(account: BalanceAccount): Boolean = account.readable && account.id in clients

    /** Checks every readable account whose primary key is saved, as the Apple pages do when they open. */
    fun refreshSaved(savedCredentialIds: Set<String>) {
        directory.accounts
            .filter { canCheck(it) && it.primaryCredentialId in savedCredentialIds }
            .forEach(::refresh)
    }

    /** Check balance on one card; a card with nothing to read is left as it is. */
    fun refresh(credentialId: String) {
        val account = directory.account(credentialId) ?: return
        if (canCheck(account)) refresh(account)
    }

    /** A key was saved, replaced or removed: forget its figure and drop any check of the old key. */
    fun credentialChanged(credentialId: String) {
        val account = directory.account(credentialId) ?: return
        jobs.remove(account.id)?.cancel()
        if (entries.remove(account.id) != null) publish(entries.toMap())
    }

    private fun refresh(account: BalanceAccount) {
        val client = clients[account.id] ?: return
        jobs.remove(account.id)?.cancel()
        entries[account.id] = BalanceEntry.Checking
        publish(entries.toMap())
        // Lazy, so the job is registered before it can finish on an immediate dispatcher.
        val job = scope.launch(start = CoroutineStart.LAZY) {
            // withContext rethrows cancellation on return, so a superseded check never lands.
            val state = withContext(io) { fetchBalance(client, account.primaryCredentialId) }
            if (jobs[account.id] !== coroutineContext[Job]) return@launch
            jobs.remove(account.id)
            entries[account.id] = BalanceEntry.Loaded(state, clock())
            publish(entries.toMap())
        }
        jobs[account.id] = job
        job.start()
    }

    private fun fetchBalance(client: ProviderBalanceClient, credentialId: String): BalanceState {
        val key = try {
            readKey(credentialId)?.trim()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Keystore failures (GeneralSecurityException, ProviderException) surface here.
            return BalanceState.Unknown(UNREADABLE)
        }
        if (key.isNullOrEmpty()) return BalanceState.Unknown(NO_KEY)
        return try {
            client.fetch(key)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            BalanceState.Unknown(BalanceTransport.UNREACHABLE)
        }
    }

    companion object {
        const val NO_KEY = "Save a key to check this account's balance."
        const val UNREADABLE = "The saved key could not be read from secure storage."
    }
}
