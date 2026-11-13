package com.justspeaktoit.android.dictation

import android.net.Uri
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.ViewModelStore
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import com.justspeaktoit.android.cloud.AudioRecorder
import com.justspeaktoit.android.cloud.CallHandle
import com.justspeaktoit.android.cloud.CleanupModel
import com.justspeaktoit.android.cloud.CloudModel
import com.justspeaktoit.android.cloud.CloudService
import com.justspeaktoit.android.cloud.RecorderFactory
import com.justspeaktoit.android.cloud.SharedAudio
import com.justspeaktoit.android.cloud.WavFormat
import com.justspeaktoit.android.corrections.CorrectionRule
import com.justspeaktoit.android.history.HistoryFile
import com.justspeaktoit.android.history.HistoryStore
import com.justspeaktoit.android.history.Retention
import com.justspeaktoit.android.resources.SystemResourceRegistry
import com.justspeaktoit.android.security.SecretStore
import com.justspeaktoit.android.settings.DictationPreferences
import com.justspeaktoit.android.settings.DictationProfile
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** A speech engine driven by the test. Callbacks arrive on the ViewModel's main thread. */
internal class FakeEngine : SpeechEngine {
    var caps = RecognizerCapabilities(sdkInt = 36, speechServiceAvailable = true, onDeviceAvailable = false)

    /** When false, availability checks wait until [answerCheck]. */
    var answerChecks = true
    private var pendingCheck: Pair<String, (LanguageResolution) -> Unit>? = null
    val started = CopyOnWriteArrayList<RecognitionMode>()
    val startedLanguages = CopyOnWriteArrayList<String>()
    var onEvent: ((DictationEvent) -> Unit)? = null
    @Volatile var stops = 0
    @Volatile var cancels = 0
    @Volatile var closed = false

    override fun capabilities() = caps

    override fun checkOnDeviceLanguage(languageTag: String, onResult: (LanguageResolution) -> Unit) {
        if (answerChecks) {
            onResult(LanguageResolution(LanguageSupport.Unknown, languageTag))
        } else {
            pendingCheck = languageTag to onResult
        }
    }

    /** Like the real engine, a closed engine never answers an outstanding check. */
    fun answerCheck() {
        val (tag, onResult) = pendingCheck ?: return
        pendingCheck = null
        if (!closed) onResult(LanguageResolution(LanguageSupport.Unknown, tag))
    }

    override fun requestOnDeviceModel(languageTag: String) = Unit

    override fun start(
        mode: RecognitionMode,
        languageTag: String,
        onEvent: (DictationEvent) -> Unit,
        onLevel: (Float) -> Unit,
    ) {
        started += mode
        startedLanguages += languageTag
        this.onEvent = onEvent
    }

    override fun stop() {
        stops++
    }

    override fun cancel() {
        cancels++
        onEvent = null
    }

    override fun close() {
        closed = true
        cancel()
    }
}

/** Writes a WAV-sized file on start and reports [bytes] on stop. */
internal class FakeRecorder(
    val file: File,
    val onLimitReached: () -> Unit,
    val onCaptureFailed: () -> Unit,
    private val bytes: Long,
    private val opens: Boolean,
    /** When set, stop blocks until it opens, like a recorder whose capture thread is stuck. */
    private val stopGate: CountDownLatch? = null,
) : AudioRecorder {
    val stopEntered = CountDownLatch(1)
    val stopped = CountDownLatch(1)
    @Volatile var stops = 0
    @Volatile var startedCapture = false

    override fun start(): Boolean {
        if (!opens) return false
        file.writeBytes(ByteArray(WavFormat.HEADER_BYTES + bytes.coerceAtLeast(0).toInt()))
        startedCapture = true
        return true
    }

    override fun stop(): Long {
        stops++
        stopEntered.countDown()
        stopGate?.await()
        stopped.countDown()
        return bytes
    }
}

internal class FakeRecorders : RecorderFactory {
    /** One second of audio: long enough to transcribe. */
    var bytes: Long = WavFormat.BYTES_PER_SECOND.toLong()
    var opens = true
    var stopGate: CountDownLatch? = null
    val created = CopyOnWriteArrayList<FakeRecorder>()

    override fun create(
        file: File,
        onLevel: (Float) -> Unit,
        onLimitReached: () -> Unit,
        onCaptureFailed: () -> Unit,
    ): AudioRecorder = FakeRecorder(file, onLimitReached, onCaptureFailed, bytes, opens, stopGate).also { created += it }

    val last: FakeRecorder get() = created.last()
}

internal class FakeCloud : CloudService {
    data class Transcription(
        val model: String,
        val languageTag: String?,
        val call: CallHandle,
        val prompt: String? = null,
    )

    val transcriptions = CopyOnWriteArrayList<Transcription>()
    val cleanups = CopyOnWriteArrayList<String>()
    val cleanupPrompts = CopyOnWriteArrayList<String>()

    /** Runs on an IO thread; may block until the call is cancelled. */
    @Volatile var onTranscribe: (CallHandle) -> String = { "hello world" }
    @Volatile var onCleanup: (String) -> String = { "Hello, world." }

    override fun transcribe(
        model: CloudModel,
        apiKey: String,
        audio: File,
        languageTag: String?,
        call: CallHandle,
        format: SharedAudio.Format,
        prompt: String?,
    ): String {
        transcriptions += Transcription(model.catalogId, languageTag, call, prompt)
        return onTranscribe(call)
    }

    override fun cleanup(
        model: CleanupModel,
        apiKey: String,
        transcript: String,
        systemPrompt: String,
        call: CallHandle,
    ): String {
        cleanups += transcript
        cleanupPrompts += systemPrompt
        return onCleanup(transcript)
    }
}

internal class MemorySecrets(vararg initial: Pair<String, String>) : SecretStore {
    private val values = ConcurrentHashMap(initial.toMap())

    override fun read(name: String): String? = values[name]

    override fun write(name: String, value: String) {
        values[name] = value
    }

    override fun remove(name: String) {
        values.remove(name)
    }

    override fun names(): Set<String> = values.keys.toSet()
}

internal class MemoryPrefs(
    override var chosenMode: RecognitionMode? = RecognitionMode.Cloud,
    override var cloudModelId: String? = null,
    override var cleanupModelId: String? = null,
    override var cleanupEnabled: Boolean = false,
    override var retention: Retention = Retention.Month,
    override var keepAudioOnCancel: Boolean = true,
    override var languageId: String? = null,
    override var corrections: List<CorrectionRule> = emptyList(),
    override var cleanupPrompt: String? = null,
    override var profiles: List<DictationProfile> = emptyList(),
    override var activeProfileId: String? = null,
) : DictationPreferences

internal class MemoryHistoryFile : HistoryFile {
    @Volatile var text: String? = null

    override fun read(): String? = text

    override fun write(text: String) {
        this.text = text
    }

    override fun delete() {
        text = null
    }
}

internal object NoSharedAudio : SharedAudioSource {
    override fun accepts(uri: Uri): Boolean = false

    override fun type(uri: Uri): String? = null

    override fun open(uri: Uri): InputStream? = null
}

/**
 * Builds a real [DictationViewModel] with fakes. Its main thread is a single test thread; the
 * ViewModel is owned by a [ViewModelStore] so [clear] runs the production `onCleared` path.
 */
internal class ViewModelHarness(root: File) {
    val engine = FakeEngine()
    val recorders = FakeRecorders()
    val cloud = FakeCloud()
    val secrets = MemorySecrets("openai.apiKey" to "sk-test")
    val prefs = MemoryPrefs()
    val historyFile = MemoryHistoryFile()
    val cacheDir = File(root, "cache").apply { mkdirs() }
    val recordingsDir = File(root, "recordings")
    var timings = DictationTimings()
    /** Each harness gets its own lane, so a stalled stop in one test never refuses another's recording. */
    val retirement = RecorderRetirement(Dispatchers.IO)
    /** Each harness lists its own holds, so tests never see another's microphone or request. */
    val resources = SystemResourceRegistry()

    private val executor = Executors.newSingleThreadExecutor { Thread(it, "test-main") }
    private val main = executor.asCoroutineDispatcher()
    private val store = ViewModelStore()

    val viewModel: DictationViewModel by lazy {
        val factory = viewModelFactory {
            initializer {
                DictationViewModel(
                    engine = engine,
                    recorders = recorders,
                    cloud = cloud,
                    secrets = secrets,
                    prefs = prefs,
                    history = HistoryStore(historyFile, deleteAudio = { File(it).delete() }),
                    sharedAudioSource = NoSharedAudio,
                    cacheDir = cacheDir,
                    recordingsDir = recordingsDir,
                    scope = CoroutineScope(SupervisorJob() + main),
                    io = Dispatchers.IO,
                    timings = timings,
                    retirement = retirement,
                    resources = resources,
                )
            }
        }
        ViewModelProvider(store, factory)[DictationViewModel::class.java]
    }

    /** Runs [block] on the ViewModel's main thread, after everything already queued there. Not re-entrant. */
    fun <T> onMain(block: () -> T): T = runBlocking { withContext(main) { block() } }

    fun awaitState(predicate: (DictationUiState) -> Boolean): DictationUiState =
        runBlocking { withTimeout(TIMEOUT_MS) { viewModel.state.first(predicate) } }

    /** Refreshes availability and waits until Start is possible. */
    fun ready(): DictationViewModel {
        onMain { viewModel.refreshAvailability() }
        awaitState { it.canStart }
        return viewModel
    }

    fun clear() = onMain { store.clear() }

    fun close() {
        runCatching { clear() }
        main.close()
    }

    companion object {
        const val TIMEOUT_MS = 5_000L

        fun await(latch: CountDownLatch) {
            check(latch.await(TIMEOUT_MS, TimeUnit.MILLISECONDS)) { "Timed out waiting" }
        }
    }
}
