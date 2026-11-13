package com.justspeaktoit.android.ui

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import com.justspeaktoit.android.R
import kotlinx.coroutines.launch

/**
 * Reads a finished transcript aloud with the phone's text-to-speech engine, the Android
 * counterpart of the Mac's voice output. The engine starts lazily on first use and is released
 * when the button leaves the screen.
 */
@Composable
internal fun ReadAloudButton(text: String, snackbar: SnackbarHostState) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val unavailable = stringResource(R.string.read_aloud_unavailable)
    var speaking by remember { mutableStateOf(false) }
    val engine = remember { ReadAloudEngine(context.applicationContext) { speaking = it } }
    DisposableEffect(engine) { onDispose(engine::release) }
    OutlinedButton(
        onClick = {
            if (speaking) {
                engine.stop()
            } else {
                engine.speak(text) { scope.launch { snackbar.showSnackbar(unavailable) } }
            }
        },
        modifier = Modifier.testTag(AutomationIds.READ_ALOUD),
    ) {
        Text(stringResource(if (speaking) R.string.action_stop_reading else R.string.action_read_aloud))
    }
}

private class ReadAloudEngine(
    private val context: Context,
    private val onSpeaking: (Boolean) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private var tts: TextToSpeech? = null
    private var ready = false
    private var pending: String? = null
    private var onUnavailable: (() -> Unit)? = null
    @Volatile private var lastUtterance: String? = null

    fun speak(text: String, unavailable: () -> Unit) {
        onUnavailable = unavailable
        val engine = tts
        if (engine == null) {
            pending = text
            tts = TextToSpeech(context) { status -> main.post { onInit(status) } }
        } else if (ready) {
            say(engine, text)
        } else {
            pending = text
        }
    }

    fun stop() {
        tts?.stop()
        onSpeaking(false)
    }

    fun release() {
        tts?.shutdown()
        tts = null
        ready = false
    }

    private fun onInit(status: Int) {
        val engine = tts ?: return
        if (status != TextToSpeech.SUCCESS) {
            release()
            onUnavailable?.invoke()
            return
        }
        ready = true
        engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String?) {
                main.post { onSpeaking(true) }
            }

            override fun onDone(utteranceId: String?) {
                // Long text is queued as several utterances; only the last one ends the reading.
                if (utteranceId == lastUtterance) main.post { onSpeaking(false) }
            }

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String?) {
                main.post { onSpeaking(false) }
            }
        })
        pending?.let { say(engine, it) }
        pending = null
    }

    private fun say(engine: TextToSpeech, text: String) {
        val chunks = speechChunks(text, TextToSpeech.getMaxSpeechInputLength())
        if (chunks.isEmpty()) return
        lastUtterance = "$UTTERANCE_PREFIX${chunks.lastIndex}"
        val failed = chunks.withIndex().any { (index, chunk) ->
            val queue = if (index == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD
            engine.speak(chunk, queue, null, "$UTTERANCE_PREFIX$index") == TextToSpeech.ERROR
        }
        if (failed) {
            engine.stop()
            onUnavailable?.invoke()
        } else {
            onSpeaking(true)
        }
    }

    private companion object {
        const val UTTERANCE_PREFIX = "jsti.readAloud."
    }
}

/**
 * Splits [text] into pieces of at most [maxLength] characters for `TextToSpeech.speak`, which
 * rejects longer input. Breaks after a sentence end or space where it can, so words stay whole.
 */
internal fun speechChunks(text: String, maxLength: Int): List<String> {
    require(maxLength > 0)
    val chunks = mutableListOf<String>()
    var rest = text.trim()
    while (rest.length > maxLength) {
        val window = rest.substring(0, maxLength + 1)
        val sentence = window.lastIndexOfAny(charArrayOf('.', '!', '?', '\n')).takeIf { it > 0 && it < maxLength }
        val cut = sentence?.plus(1) ?: window.lastIndexOf(' ').takeIf { it > 0 } ?: maxLength
        chunks += rest.substring(0, cut).trim()
        rest = rest.substring(cut).trim()
    }
    if (rest.isNotEmpty()) chunks += rest
    return chunks.filter { it.isNotEmpty() }
}
