package com.justspeaktoit.android.sendtomac

import android.app.Application
import android.os.Build
import android.provider.Settings
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.justspeaktoit.android.history.HistoryEntry
import com.justspeaktoit.android.security.KeystoreSecretStore
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.IOException

/** What Send to Mac is doing, as SpeakCore's `SendToMacSender.Activity` reports it on iOS. */
sealed interface SendToMacActivity {
    data object Idle : SendToMacActivity

    data class Pairing(val macName: String) : SendToMacActivity

    data class PairingFailed(val failure: SendToMacFailure) : SendToMacActivity

    data class Sending(val macName: String, val entryId: String) : SendToMacActivity

    data class Sent(val macName: String, val entryId: String) : SendToMacActivity

    data class SendFailed(val failure: SendToMacFailure, val entryId: String?) : SendToMacActivity
}

/** Send to Mac's state for Settings and History. */
data class SendToMacState(
    /** The paired Mac; null until the phone pairs. */
    val pairedMacName: String? = null,
    val activity: SendToMacActivity = SendToMacActivity.Idle,
    /** Macs advertising Send to Mac on this network while Settings is browsing. */
    val nearbyMacs: List<String> = emptyList(),
    val searching: Boolean = false,
    val discoveryFailed: Boolean = false,
) {
    val isPaired: Boolean get() = pairedMacName != null

    val isBusy: Boolean
        get() = activity is SendToMacActivity.Pairing || activity is SendToMacActivity.Sending
}

/** Browses for Macs and resolves one by name; [MacDiscovery] in the app. */
internal interface MacBrowser {
    fun start(onChange: (List<String>) -> Unit, onFailure: () -> Unit)

    fun stop()

    fun connector(macName: String, protocol: SendToMacProtocol): SendToMacClient.Connector
}

/**
 * Pairs with a Mac and sends finished History transcripts to it, as iOS's `SendToMacSender` does.
 * Pairing again drops the earlier pairing first; sending uses only the stored credential.
 */
class SendToMacViewModel internal constructor(
    private val store: SendToMacPairingStore,
    private val client: SendToMacClient,
    private val browser: MacBrowser,
    private val protocol: SendToMacProtocol,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate),
    private val io: CoroutineDispatcher = Dispatchers.IO,
) : ViewModel(AutoCloseable { scope.cancel() }) {
    private val mutableState = MutableStateFlow(SendToMacState())
    val state: StateFlow<SendToMacState> = mutableState.asStateFlow()

    init {
        scope.launch {
            val paired = withContext(io) { store.pairing() }
            mutableState.update { it.copy(pairedMacName = paired?.macName) }
        }
    }

    /** Starts browsing for Macs while the Send to Mac settings are on screen. */
    fun startDiscovery() {
        mutableState.update { it.copy(searching = true, discoveryFailed = false) }
        browser.start(
            onChange = { names -> mutableState.update { it.copy(nearbyMacs = names) } },
            onFailure = { mutableState.update { it.copy(searching = false, discoveryFailed = true) } },
        )
    }

    fun stopDiscovery() {
        browser.stop()
        mutableState.update { it.copy(searching = false, nearbyMacs = emptyList()) }
    }

    /** Pairs with [macName] using the six-digit [code] it shows. */
    fun pair(macName: String, code: String) {
        if (mutableState.value.isBusy) return
        if (SendToMacClient.normalizedPairingCode(code) == null) {
            mutableState.update { it.copy(activity = SendToMacActivity.PairingFailed(SendToMacFailure.InvalidCode)) }
            return
        }
        mutableState.update { it.copy(activity = SendToMacActivity.Pairing(macName), pairedMacName = null) }
        scope.launch {
            val failure = withContext(io) {
                store.clear()
                try {
                    val credential = client.pair(macName, code, browser.connector(macName, protocol))
                    store.save(MacPairing(macName, credential))
                    null
                } catch (failure: SendToMacFailure) {
                    failure
                }
            }
            mutableState.update {
                if (failure == null) {
                    it.copy(pairedMacName = macName, activity = SendToMacActivity.Idle)
                } else {
                    it.copy(activity = SendToMacActivity.PairingFailed(failure))
                }
            }
        }
    }

    /** Sends [entry]'s transcript to the paired Mac and waits for it to confirm receipt. */
    fun send(entry: HistoryEntry) {
        if (mutableState.value.isBusy) return
        if (entry.text.isBlank()) {
            fail(SendToMacFailure.NothingToSend, entry.id)
            return
        }
        scope.launch {
            val pairing = withContext(io) { store.pairing() }
            if (pairing == null) {
                mutableState.update { it.copy(pairedMacName = null) }
                fail(SendToMacFailure.NotPaired, entry.id)
                return@launch
            }
            val name = pairing.macName
            mutableState.update { it.copy(activity = SendToMacActivity.Sending(name, entry.id)) }
            val failure = withContext(io) {
                try {
                    client.send(
                        macName = name,
                        credential = pairing.credential,
                        text = entry.text,
                        model = entry.model.orEmpty(),
                        durationSeconds = entry.durationSeconds ?: 0.0,
                        connector = browser.connector(name, protocol),
                    )
                    null
                } catch (failure: SendToMacFailure) {
                    failure
                }
            }
            mutableState.update {
                it.copy(
                    activity = if (failure == null) {
                        SendToMacActivity.Sent(name, entry.id)
                    } else {
                        SendToMacActivity.SendFailed(failure, entry.id)
                    },
                )
            }
        }
    }

    /** Forgets the paired Mac and deletes its credential. */
    fun forget() {
        if (mutableState.value.isBusy) return
        mutableState.update { it.copy(pairedMacName = null, activity = SendToMacActivity.Idle) }
        scope.launch { withContext(io) { store.clear() } }
    }

    /** Clears a finished send or a failure. */
    fun clearActivity() {
        if (mutableState.value.isBusy) return
        mutableState.update { it.copy(activity = SendToMacActivity.Idle) }
    }

    private fun fail(failure: SendToMacFailure, entryId: String?) {
        mutableState.update { it.copy(activity = SendToMacActivity.SendFailed(failure, entryId)) }
    }

    override fun onCleared() {
        browser.stop()
    }

    companion object {
        val Factory: ViewModelProvider.Factory = viewModelFactory {
            initializer {
                create(checkNotNull(this[ViewModelProvider.AndroidViewModelFactory.APPLICATION_KEY]))
            }
        }

        private fun create(application: Application): SendToMacViewModel {
            val protocol = SendToMacProtocol.load(application)
            val store = SendToMacPairingStore(KeystoreSecretStore.create(application), protocol)
            val client = SendToMacClient(protocol, { deviceName(application) }, store::deviceId)
            val browser = AndroidMacBrowser(MacDiscovery(application, protocol.serviceType))
            return SendToMacViewModel(store, client, browser, protocol)
        }

        /** The name the Mac lists this phone under: the device name from system settings. */
        private fun deviceName(application: Application): String =
            Settings.Global.getString(application.contentResolver, Settings.Global.DEVICE_NAME)
                ?.takeIf { it.isNotBlank() } ?: Build.MODEL
    }
}

/** Resolves the Mac over NSD, then opens the WebSocket to the first address that answers. */
internal class AndroidMacBrowser(private val discovery: MacDiscovery) : MacBrowser {
    override fun start(onChange: (List<String>) -> Unit, onFailure: () -> Unit) = discovery.start(onChange, onFailure)

    override fun stop() = discovery.stop()

    override fun connector(macName: String, protocol: SendToMacProtocol) =
        SendToMacClient.Connector { timeoutMs, maximumMessageBytes ->
            val started = System.nanoTime()
            fun remaining(): Int = (timeoutMs - (System.nanoTime() - started) / NANOS_PER_MILLI).toInt()
            val mac = discovery.resolve(macName, remaining().toLong())
            val addresses = MacDiscovery.dialOrder(mac.addresses)
            var lastError: IOException = IOException("$macName has no address")
            for ((index, address) in addresses.withIndex()) {
                val left = remaining()
                if (left <= 0) break
                // Leave time for the remaining addresses if this one does not answer.
                val budget = left / (addresses.size - index)
                try {
                    return@Connector WebSocketConnection.open(
                        address,
                        mac.port,
                        protocol.endpointPath,
                        budget,
                        maximumMessageBytes,
                    )
                } catch (error: IOException) {
                    lastError = error
                }
            }
            throw lastError
        }

    private companion object {
        const val NANOS_PER_MILLI = 1_000_000L
    }
}
