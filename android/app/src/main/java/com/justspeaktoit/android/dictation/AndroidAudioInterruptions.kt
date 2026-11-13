package com.justspeaktoit.android.dictation

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi

/** A microphone as [InputRoutes] sees it. */
internal data class InputDevice(val id: Int, val type: Int)

/** Which input device changes end a session. */
internal object InputRoutes {
    /** Headset microphones; built-in and virtual inputs (telephony, remote submix) are not route changes. */
    @SuppressLint("InlinedApi") // Plain ints: the newer types simply never appear on older releases.
    val HEADSET_TYPES = setOf(
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
    )

    /**
     * True when [changed] adds a headset microphone that was not there when watching began ([known]),
     * or removes one that was. The callback reports every existing device once on registration, which
     * this ignores.
     */
    fun isRouteChange(known: Set<Int>, changed: List<InputDevice>, added: Boolean): Boolean =
        changed.any { it.type in HEADSET_TYPES && (it.id in known) != added }
}

/** Audio focus, call and microphone route signals from [AudioManager], on the main thread. */
internal class AndroidAudioInterruptions(private val context: Context) : AudioInterruptions {
    private val audio: AudioManager = checkNotNull(context.getSystemService(AudioManager::class.java))
    private val main = Handler(Looper.getMainLooper())

    // Each start gets a new generation, so a callback queued before stop() never reaches a later session.
    private var generation = 0
    private var focus: AudioFocusRequest? = null
    private var devices: AudioDeviceCallback? = null
    private var mode: Any? = null

    override fun start(requestFocus: Boolean, onSignal: (InterruptionSignal) -> Unit) {
        stop()
        val current = ++generation
        val emit: (InterruptionSignal) -> Unit = { if (generation == current) onSignal(it) }
        watchInputs(emit)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) watchCalls(emit)
        if (requestFocus) requestFocus(emit)
    }

    override fun stop() {
        generation++
        focus?.let(audio::abandonAudioFocusRequest)
        focus = null
        devices?.let(audio::unregisterAudioDeviceCallback)
        devices = null
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) stopWatchingCalls()
    }

    private fun watchInputs(emit: (InterruptionSignal) -> Unit) {
        val known = audio.getDevices(AudioManager.GET_DEVICES_INPUTS).map { it.id }.toSet()
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = report(added, added = true)

            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = report(removed, added = false)

            private fun report(changed: Array<out AudioDeviceInfo>, added: Boolean) {
                val inputs = changed.filter { it.isSource }.map { InputDevice(it.id, it.type) }
                if (InputRoutes.isRouteChange(known, inputs, added)) emit(InterruptionSignal.InputDeviceChanged)
            }
        }
        audio.registerAudioDeviceCallback(callback, main)
        devices = callback
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun watchCalls(emit: (InterruptionSignal) -> Unit) {
        val listener = AudioManager.OnModeChangedListener { mode ->
            if (isCallMode(mode)) emit(InterruptionSignal.CallStarted)
        }
        audio.addOnModeChangedListener(context.mainExecutor, listener)
        mode = listener
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun stopWatchingCalls() {
        (mode as? AudioManager.OnModeChangedListener)?.let(audio::removeOnModeChangedListener)
        mode = null
    }

    private fun requestFocus(emit: (InterruptionSignal) -> Unit) {
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ASSISTANT)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
            )
            .setOnAudioFocusChangeListener({ change ->
                when (change) {
                    AudioManager.AUDIOFOCUS_LOSS -> emit(InterruptionSignal.FocusLost)
                    AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> emit(InterruptionSignal.FocusLostTransient)
                    AudioManager.AUDIOFOCUS_GAIN -> emit(InterruptionSignal.FocusGained)
                    // Ducking only affects playback, so a recording carries on.
                    else -> Unit
                }
            }, main)
            .build()
        if (audio.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) {
            focus = request
        } else {
            // Refused focus usually means a call is under way; posted so start() returns first.
            val signal = if (isCallMode(audio.mode)) InterruptionSignal.CallStarted else InterruptionSignal.FocusLost
            main.post { emit(signal) }
        }
    }

    private fun isCallMode(mode: Int) = mode == AudioManager.MODE_RINGTONE ||
        mode == AudioManager.MODE_IN_CALL ||
        mode == AudioManager.MODE_IN_COMMUNICATION
}
