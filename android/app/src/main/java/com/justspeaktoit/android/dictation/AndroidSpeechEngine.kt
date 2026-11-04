package com.justspeaktoit.android.dictation

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.annotation.MainThread
import androidx.annotation.RequiresApi

/**
 * Thin wrapper over the platform [SpeechRecognizer]. All calls must be made on the main thread,
 * which is also where callbacks arrive. Each session gets a fresh recogniser, and callbacks from a
 * replaced or cancelled session are dropped so a late result can never complete the wrong session.
 */
@MainThread
class AndroidSpeechEngine(context: Context) {
    private val context = context.applicationContext
    private var recognizer: SpeechRecognizer? = null
    private var modelDownloader: SpeechRecognizer? = null
    private var supportProbe: SpeechRecognizer? = null
    private var probeGeneration = 0L
    private val handler = Handler(Looper.getMainLooper())
    private var session = 0L

    fun capabilities(): RecognizerCapabilities = RecognizerCapabilities(
        sdkInt = Build.VERSION.SDK_INT,
        speechServiceAvailable = SpeechRecognizer.isRecognitionAvailable(context),
        onDeviceAvailable = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context),
    )

    /**
     * Reports on-device support for [languageTag] exactly once; before API 33 the answer is always
     * unknown. A newer check supersedes an outstanding one, and a service that does not answer
     * within [SUPPORT_TIMEOUT_MS] is reported as unknown so the other modes stay usable.
     */
    fun checkOnDeviceLanguage(languageTag: String, onResult: (LanguageResolution) -> Unit) {
        releaseProbe()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || !capabilities().onDeviceAvailable) {
            onResult(LanguageResolution(LanguageSupport.Unknown, languageTag))
            return
        }
        checkSupport(languageTag, onResult)
    }

    @RequiresApi(Build.VERSION_CODES.TIRAMISU)
    private fun checkSupport(languageTag: String, onResult: (LanguageResolution) -> Unit) {
        val generation = probeGeneration
        val unknown = LanguageResolution(LanguageSupport.Unknown, languageTag)
        fun deliver(result: LanguageResolution) {
            if (generation != probeGeneration) return
            releaseProbe()
            onResult(result)
        }
        val probe = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } catch (e: UnsupportedOperationException) {
            onResult(unknown)
            return
        }
        supportProbe = probe
        handler.postDelayed({ deliver(unknown) }, SUPPORT_TIMEOUT_MS)
        probe.checkRecognitionSupport(
            recognitionIntent(languageTag, RecognitionMode.OnDevice),
            context.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) = deliver(
                    RecognizerAvailability.resolveLanguage(
                        languageTag,
                        installed = support.installedOnDeviceLanguages,
                        pending = support.pendingOnDeviceLanguages,
                        supported = support.supportedOnDeviceLanguages,
                    ),
                )

                override fun onError(error: Int) = deliver(unknown)
            },
        )
    }

    private fun releaseProbe() {
        probeGeneration++
        handler.removeCallbacksAndMessages(null)
        supportProbe?.destroy()
        supportProbe = null
    }

    /** Asks the system to download the on-device model; progress is shown by the system. */
    fun requestOnDeviceModel(languageTag: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
        // Kept alive until close() so the request is not dropped when the service unbinds.
        modelDownloader?.destroy()
        modelDownloader = try {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context).also {
                it.triggerModelDownload(recognitionIntent(languageTag, RecognitionMode.OnDevice))
            }
        } catch (e: UnsupportedOperationException) {
            null
        }
    }

    fun start(mode: RecognitionMode, languageTag: String, onEvent: (DictationEvent) -> Unit, onLevel: (Float) -> Unit) {
        release()
        val id = ++session
        // Availability can change after it was checked; the factories then throw rather than return.
        val created = try {
            when (mode) {
                RecognitionMode.OnDevice ->
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
                    } else {
                        null
                    }
                RecognitionMode.SpeechService -> SpeechRecognizer.createSpeechRecognizer(context)
            }
        } catch (e: UnsupportedOperationException) {
            null
        }
        if (created == null) {
            onEvent(DictationEvent.Error(DictationFailure.Unavailable))
            return
        }
        recognizer = created
        created.setRecognitionListener(Listener(id, onEvent, onLevel))
        created.startListening(recognitionIntent(languageTag, mode))
    }

    /** Stops capturing audio; the recogniser then delivers its final result or an error. */
    fun stop() {
        recognizer?.stopListening()
    }

    /** Abandons the session; no further events are delivered for it. */
    fun cancel() {
        session++
        release()
    }

    fun close() {
        cancel()
        releaseProbe()
        modelDownloader?.destroy()
        modelDownloader = null
    }

    private fun release() {
        recognizer?.let {
            it.cancel()
            it.destroy()
        }
        recognizer = null
    }

    private fun recognitionIntent(languageTag: String, mode: RecognitionMode) =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, languageTag)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            putExtra(RecognizerIntent.EXTRA_CALLING_PACKAGE, context.packageName)
            if (mode == RecognitionMode.OnDevice) {
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
        }

    private companion object {
        const val SUPPORT_TIMEOUT_MS = 3_000L
    }

    private inner class Listener(
        private val id: Long,
        private val onEvent: (DictationEvent) -> Unit,
        private val onLevel: (Float) -> Unit,
    ) : RecognitionListener {
        private val current get() = id == session

        private fun emit(event: DictationEvent) {
            if (current) onEvent(event)
        }

        private fun finish(event: DictationEvent) {
            if (!current) return
            release()
            onEvent(event)
        }

        override fun onReadyForSpeech(params: Bundle?) = emit(DictationEvent.Ready)

        override fun onBeginningOfSpeech() = Unit

        override fun onRmsChanged(rmsdB: Float) {
            if (current) onLevel(rmsdB)
        }

        override fun onBufferReceived(buffer: ByteArray?) = Unit

        override fun onEndOfSpeech() = Unit

        override fun onError(error: Int) = finish(DictationEvent.Error(RecognizerErrors.failureFor(error)))

        override fun onResults(results: Bundle?) = finish(DictationEvent.Final(results.bestText()))

        override fun onPartialResults(partialResults: Bundle?) =
            emit(DictationEvent.Partial(partialResults.bestText()))

        override fun onEvent(eventType: Int, params: Bundle?) = Unit

        private fun Bundle?.bestText(): String =
            this?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
    }
}
