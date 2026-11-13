package com.justspeaktoit.android.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.withContext
import java.io.IOException
import java.net.ServerSocket

enum class HistorySyncAvailability { Available, MissingToken, Misconfigured }

/** Why the last sign-in or sync did not finish; the UI words each one. */
enum class HistorySyncProblem {
    SignInNotOffered,
    UntrustedSignInPage,
    SignInTimedOut,
    CallbackUnavailable,
    BrowserUnavailable,
    SignedOut,
    Network,
    Server,
    ChangesNotSaved,
    Incomplete,
    Storage,
    Unknown,
}

data class HistorySyncStatus(
    val availability: HistorySyncAvailability,
    val signedIn: Boolean = false,
    val signingIn: Boolean = false,
    val syncing: Boolean = false,
    val lastSuccessfulSyncMs: Long? = null,
    val problem: HistorySyncProblem? = null,
)

class HistorySyncProblemException(val problem: HistorySyncProblem) : Exception(problem.name)

/**
 * Signs in to iCloud through CloudKit Web Services and runs History sync passes, as
 * `DesktopCloudSyncService` does on Windows and Linux. Sync is opt-in: nothing is sent until the
 * user signs in. Errors are reported in [status], never thrown, except cancellation.
 */
class HistorySyncService(
    private val client: CloudKitWebClient?,
    unavailable: CloudKitUnavailable?,
    private val store: AndroidHistorySyncStore,
    private val io: CoroutineDispatcher,
    private val now: () -> Long = System::currentTimeMillis,
    private val transportFor: (CloudKitWebClient, Long) -> HistorySyncTransport = ::CloudKitHistorySyncTransport,
    private val bindCallback: () -> ServerSocket = CloudKitSignIn::bind,
    private val awaitCallback: suspend (ServerSocket) -> String = { CloudKitSignIn.awaitCallback(it, io) },
) {
    private val _status = MutableStateFlow(
        HistorySyncStatus(
            availability = when (unavailable) {
                null -> if (client == null) HistorySyncAvailability.MissingToken else HistorySyncAvailability.Available
                CloudKitUnavailable.MissingToken -> HistorySyncAvailability.MissingToken
                CloudKitUnavailable.Misconfigured -> HistorySyncAvailability.Misconfigured
            },
        ),
    )
    val status: StateFlow<HistorySyncStatus> = _status.asStateFlow()

    private val guard = Any()
    private var syncing = false
    private var followUp = false

    /** Reads whether a session is stored, so Settings shows it before the first sync. */
    suspend fun prepare() = withContext(io) {
        val client = client ?: return@withContext
        try {
            val signedIn = client.hasWebAuthToken()
            val last = store.state().lastSuccessfulSyncMs
            _status.update { it.copy(signedIn = signedIn, lastSuccessfulSyncMs = last) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            _status.update { it.copy(problem = problem(e)) }
        }
    }

    /**
     * Opens Apple's sign-in page with [openBrowser] and waits for the browser to return to the
     * loopback callback, then syncs. Already signed in, it just syncs.
     */
    suspend fun signIn(openBrowser: (String) -> Boolean) {
        val client = client ?: return
        if (_status.value.signingIn) return
        _status.update { it.copy(signingIn = true, problem = null) }
        val signedIn = try {
            withContext(io) {
                signInPage(client)?.let { page ->
                    val server = try {
                        bindCallback()
                    } catch (e: IOException) {
                        throw HistorySyncProblemException(HistorySyncProblem.CallbackUnavailable)
                    }
                    val opened = try {
                        openBrowser(page)
                    } catch (e: RuntimeException) {
                        server.close()
                        throw e
                    }
                    if (!opened) {
                        server.close()
                        throw HistorySyncProblemException(HistorySyncProblem.BrowserUnavailable)
                    }
                    client.storeWebAuthToken(awaitCallback(server))
                }
                store.updateState { it.copy(enabled = true) }
            }
            true
        } catch (e: CancellationException) {
            _status.update { it.copy(signingIn = false) }
            throw e
        } catch (e: Exception) {
            _status.update { it.copy(signingIn = false, problem = problem(e)) }
            false
        }
        if (!signedIn) return
        _status.update { it.copy(signingIn = false, signedIn = true, problem = null) }
        sync()
    }

    /** Forgets the iCloud session. History and its sync state stay, so signing in again resumes. */
    suspend fun signOut() = withContext(io) {
        val client = client ?: return@withContext
        val problem = try {
            client.signOut()
            null
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            problem(e)
        }
        _status.update { it.copy(signedIn = false, signingIn = false, problem = problem) }
    }

    /** Records local deletions before History removes the entries, so iCloud deletes them too. */
    suspend fun recordDeletions(ids: Collection<String>) {
        if (client == null || ids.isEmpty()) return
        withContext(io) {
            try {
                store.recordDeletions(ids)
            } catch (e: IOException) {
                // The local deletion still happens; only its iCloud copy is left behind.
                _status.update { it.copy(problem = HistorySyncProblem.Storage) }
            }
        }
    }

    /**
     * Runs a pass, or asks the running one to run once more so a change made during it is not
     * missed. At most three passes run back to back.
     */
    suspend fun sync() {
        val client = client ?: return
        if (!claim()) return
        _status.update { it.copy(syncing = true) }
        try {
            withContext(io) {
                var passes = 0
                do {
                    if (_status.value.signedIn && store.state().enabled) {
                        runPass(client)
                        passes += 1
                    }
                } while (continueAfter(passes))
            }
        } finally {
            synchronized(guard) { syncing = false }
            _status.update { it.copy(syncing = false) }
        }
    }

    private suspend fun signInPage(client: CloudKitWebClient): String? = try {
        client.currentUserRecordName()
        null
    } catch (e: CloudKitException.AuthenticationRequired) {
        val redirect = e.redirectUrl ?: throw HistorySyncProblemException(HistorySyncProblem.SignInNotOffered)
        if (!CloudKitSignIn.isTrustedSignInUrl(redirect)) {
            throw HistorySyncProblemException(HistorySyncProblem.UntrustedSignInPage)
        }
        redirect
    }

    private suspend fun runPass(client: CloudKitWebClient) {
        try {
            val session = client.session()
            val admitted: suspend () -> Unit = { client.requireCurrent(session) }
            val account = client.currentUserRecordName(session)
            admitted()
            // Another Apple ID: this device's cursor and acknowledgements belong to the old one.
            store.updateState { if (it.account == account) it else it.forgetAccountData().copy(account = account) }
            client.createZone(HistorySchema.ZONE, session)
            val transport = transportFor(client, session)
            store.synchronizeDeletions(account, transport, admitted)
            store.beginPass()
            val failure = try {
                HistorySyncCoordinator(transport, store, admitted).runPass()
                null
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                e
            }
            // A deletion made while an upload was in flight must win after it.
            store.synchronizeDeletions(account, transport, admitted)
            if (failure != null) throw failure
            admitted()
            val state = store.updateState { it.copy(lastSuccessfulSyncMs = now()) }
            _status.update { it.copy(lastSuccessfulSyncMs = state.lastSuccessfulSyncMs, problem = null) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            if (e is CloudKitException.AuthenticationRequired || e is CloudKitException.AuthenticationFailed) {
                // The client says whether a session remains, so a sign-in that finished meanwhile still shows.
                val signedIn = client.hasWebAuthToken()
                _status.update { it.copy(signedIn = signedIn) }
            }
            _status.update { it.copy(problem = problem(e)) }
        }
    }

    private fun claim(): Boolean = synchronized(guard) {
        if (syncing) {
            followUp = true
            false
        } else {
            syncing = true
            followUp = false
            true
        }
    }

    private fun continueAfter(passes: Int): Boolean = synchronized(guard) {
        val again = followUp && passes < MAX_COALESCED_PASSES
        followUp = false
        again
    }

    companion object {
        const val MAX_COALESCED_PASSES = 3

        fun create(
            resolution: CloudKitResolution,
            http: CloudKitHttp,
            tokens: WebAuthTokenStore,
            store: AndroidHistorySyncStore,
            io: CoroutineDispatcher,
        ): HistorySyncService = when (resolution) {
            is CloudKitResolution.Available ->
                HistorySyncService(CloudKitWebClient(resolution.config, http, tokens, io), null, store, io)
            is CloudKitResolution.Unavailable -> HistorySyncService(null, resolution.reason, store, io)
        }

        fun problem(e: Exception): HistorySyncProblem? = when (e) {
            is HistorySyncProblemException -> e.problem
            is CloudKitSignInTimeoutException -> HistorySyncProblem.SignInTimedOut
            is CloudKitException.AuthenticationRequired, is CloudKitException.AuthenticationFailed ->
                HistorySyncProblem.SignedOut
            // A sign-in or sign-out replaced the session mid-pass; that is not a failure.
            is CloudKitException.SessionChanged -> null
            is CloudKitException.Network -> HistorySyncProblem.Network
            is CloudKitException -> HistorySyncProblem.Server
            is HistorySyncException.Unapplied -> HistorySyncProblem.ChangesNotSaved
            is HistorySyncException -> HistorySyncProblem.Incomplete
            is IOException -> HistorySyncProblem.Storage
            else -> HistorySyncProblem.Unknown
        }
    }
}
