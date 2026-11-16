package com.justspeaktoit.android.local

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** Where one downloadable model stands on this phone. */
sealed interface ModelInstallState {
    /** [partialBytes] is a stopped download that the next attempt resumes. */
    data class NotDownloaded(val partialBytes: Long = 0L) : ModelInstallState

    data class Downloading(val bytes: Long) : ModelInstallState

    /** Downloads use Wi-Fi only unless mobile data is allowed, and no unmetered network is connected. */
    data object WaitingForWifi : ModelInstallState

    data class Failed(val reason: DownloadFailure, val partialBytes: Long) : ModelInstallState

    /** Downloaded and verified against the pinned size and SHA-256. */
    data object Installed : ModelInstallState
}

data class LocalModelItem(val model: WhisperModel, val state: ModelInstallState)

/** Downloaded models as Settings shows them. */
data class LocalModelsState(
    /** False when the whisper.cpp runtime is missing; Downloaded mode is then unavailable. */
    val runtimeAvailable: Boolean = false,
    /** The models this phone offers, with their state. */
    val models: List<LocalModelItem> = emptyList(),
    /** The chosen model's catalogue ID, even when it is not offered or downloaded. */
    val selectedId: String? = null,
    val downloadOnMobileData: Boolean = false,
    /** Display names for every catalogue ID, including models this phone does not offer. */
    val names: Map<String, String> = emptyMap(),
) {
    /** The friendly name for a model ID, or null when it is not a downloaded-model ID. */
    fun displayName(id: String?): String? = id?.let(names::get)

    val selected: LocalModelItem?
        get() = models.firstOrNull { it.model.catalogId == selectedId }

    /** Catalogue IDs of the models downloaded and verified on this phone. */
    val installedIds: Set<String>
        get() = models.filter { it.state == ModelInstallState.Installed }.mapTo(mutableSetOf()) { it.model.catalogId }
}

/** Everything [LocalModelManager] and Downloaded mode need, so tests can pass fakes. */
class LocalModelSetup(
    val catalog: List<WhisperModel>,
    val store: WhisperModelStore,
    val downloader: ModelDownloader,
    val totalMemoryBytes: Long,
    val network: NetworkGate,
    val transcriber: LocalTranscriber,
) {
    val names: Map<String, String>
        get() = catalog.associate { it.catalogId to it.displayName }

    fun manager(scope: CoroutineScope, io: CoroutineDispatcher) =
        LocalModelManager(catalog, store, downloader, totalMemoryBytes, network, scope, io)
}

/** Whether a model download may start now. */
fun interface NetworkGate {
    fun canDownload(allowMobileData: Boolean): Boolean
}

/**
 * Downloads, verifies and removes the pinned Whisper models. Each download runs in [scope] on [io]
 * while the app is open; a stopped one resumes from its partial file next time. State is published
 * through [models].
 */
class LocalModelManager(
    private val catalog: List<WhisperModel>,
    private val store: WhisperModelStore,
    private val downloader: ModelDownloader,
    private val totalMemoryBytes: Long,
    private val network: NetworkGate,
    private val scope: CoroutineScope,
    private val io: CoroutineDispatcher,
) {
    private val jobs = mutableMapOf<String, Job>()
    private val _models = MutableStateFlow<List<LocalModelItem>>(emptyList())
    val models: StateFlow<List<LocalModelItem>> = _models.asStateFlow()

    /** Reads which models are on disk, off the main thread. */
    fun refresh(): Job = scope.launch {
        val states = withContext(io) { catalog.associate { it.catalogId to diskState(it) } }
        val installed = states.filterValues { it == ModelInstallState.Installed }.keys
        _models.value = WhisperCatalog.offered(catalog, totalMemoryBytes, installed).map { model ->
            // A download under way keeps the state it is reporting.
            val running = _models.value.firstOrNull { it.model.catalogId == model.catalogId }
                ?.takeIf { jobs[model.catalogId]?.isActive == true }
            running ?: LocalModelItem(model, states.getValue(model.catalogId))
        }
    }

    fun find(id: String?): WhisperModel? = WhisperCatalog.find(catalog, id)

    /** The verified file for [id], or null when that model is not downloaded. Reads the disk. */
    fun installedFile(id: String): File? = find(id)?.takeIf(store::isInstalled)?.let(store::file)

    fun isInstalled(id: String?): Boolean = find(id)?.let(store::isInstalled) == true

    /** Starts or resumes [id]'s download, unless one is running or the network does not allow it. */
    fun download(id: String, allowMobileData: Boolean) {
        val model = find(id) ?: return
        if (jobs[id]?.isActive == true) return
        if (!network.canDownload(allowMobileData)) {
            set(id, ModelInstallState.WaitingForWifi)
            return
        }
        set(id, ModelInstallState.Downloading(0L))
        // A cancelled download may still be finishing its last write to the partial file.
        val previous = jobs[id]
        jobs[id] = scope.launch {
            previous?.join()
            val failure = withContext(io) {
                set(id, ModelInstallState.Downloading(store.partialBytes(model)))
                val context = currentCoroutineContext()
                var reported = 0L
                downloader.download(
                    model,
                    store,
                    progress = { bytes ->
                        if (bytes - reported >= PROGRESS_STEP_BYTES || bytes == model.bytes) {
                            reported = bytes
                            set(id, ModelInstallState.Downloading(bytes))
                        }
                    },
                    cancelled = { !context.isActive },
                )
            }
            set(
                id,
                when (failure) {
                    null -> ModelInstallState.Installed
                    DownloadFailure.Cancelled -> ModelInstallState.NotDownloaded(store.partialBytes(model))
                    else -> ModelInstallState.Failed(failure, store.partialBytes(model))
                },
            )
        }
    }

    /** Stops [id]'s download, keeping what has arrived so the next attempt resumes. */
    fun cancel(id: String) {
        val model = find(id) ?: return
        jobs[id]?.cancel()
        set(id, ModelInstallState.NotDownloaded(store.partialBytes(model)))
    }

    /** Stops any download and deletes the model and its partial file. */
    fun remove(id: String): Job? {
        val model = find(id) ?: return null
        val running = jobs.remove(id)
        running?.cancel()
        return scope.launch {
            running?.join()
            withContext(io) { store.remove(model) }
            refresh().join()
        }
    }

    private fun diskState(model: WhisperModel): ModelInstallState = when {
        store.isInstalled(model) -> ModelInstallState.Installed
        else -> ModelInstallState.NotDownloaded(store.partialBytes(model))
    }

    private fun set(id: String, state: ModelInstallState) {
        _models.update { items -> items.map { if (it.model.catalogId == id) it.copy(state = state) else it } }
    }

    private companion object {
        /** Progress is published about every megabyte, not for every read. */
        const val PROGRESS_STEP_BYTES = 1L shl 20
    }
}
