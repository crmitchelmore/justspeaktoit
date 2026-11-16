package com.justspeaktoit.android.cloud

import android.content.Context
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.AudioRecord
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi

enum class AudioInputKind { BuiltIn, Wired, Usb, Bluetooth }

/**
 * A microphone the device offers. [id] is built from the device's type, address and product name, so
 * it survives reconnecting the device (Android's own device ids change on every connection).
 */
data class AudioInput(val id: String, val kind: AudioInputKind, val detail: String) {
    companion object {
        fun id(type: Int, address: String, productName: String): String = "$type|$address|$productName"
    }
}

/** Which microphone a Cloud recording uses for a saved preference. */
sealed interface AudioInputChoice {
    data object SystemDefault : AudioInputChoice

    data class Selected(val input: AudioInput) : AudioInputChoice

    /** The saved microphone is not connected, so recordings use the system default until it is back. */
    data class Unavailable(val id: String) : AudioInputChoice

    companion object {
        fun resolve(preferredId: String?, available: List<AudioInput>): AudioInputChoice {
            if (preferredId == null) return SystemDefault
            return available.firstOrNull { it.id == preferredId }?.let(::Selected) ?: Unavailable(preferredId)
        }
    }
}

/** Routes one recording to a chosen microphone, and undoes any system routing when it ends. */
interface InputRoute {
    fun applyTo(record: AudioRecord)

    fun release()
}

/** The microphones a recording can use; [AndroidAudioInputs] in production. */
interface AudioInputSource {
    fun inputs(): List<AudioInput>

    /** The route for [id], or null when that microphone is not connected. */
    fun route(id: String): InputRoute?

    /** Calls [onChange] on the main thread when a microphone connects or disconnects, until closed. */
    fun watch(onChange: () -> Unit): AutoCloseable
}

object NoAudioInputs : AudioInputSource {
    override fun inputs(): List<AudioInput> = emptyList()

    override fun route(id: String): InputRoute? = null

    override fun watch(onChange: () -> Unit): AutoCloseable = AutoCloseable {}
}

/**
 * Lists the built-in, wired, USB and Bluetooth microphones from [AudioManager]. Bluetooth headsets only
 * carry microphone audio over a communication link, which apps can request from Android 12; earlier
 * versions list no Bluetooth microphones.
 */
class AndroidAudioInputs(context: Context) : AudioInputSource {
    private val audio = context.getSystemService(AudioManager::class.java)

    override fun inputs(): List<AudioInput> = devices().map { it.second }.distinctBy { it.id }

    override fun route(id: String): InputRoute? =
        devices().firstOrNull { it.second.id == id }?.let { (device, input) -> DeviceRoute(device, input.kind) }

    override fun watch(onChange: () -> Unit): AutoCloseable {
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>) = onChange()

            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>) = onChange()
        }
        audio.registerAudioDeviceCallback(callback, Handler(Looper.getMainLooper()))
        return AutoCloseable { audio.unregisterAudioDeviceCallback(callback) }
    }

    private fun devices(): List<Pair<AudioDeviceInfo, AudioInput>> =
        audio.getDevices(AudioManager.GET_DEVICES_INPUTS).mapNotNull { device ->
            val kind = kind(device.type) ?: return@mapNotNull null
            val address = device.address
            val product = device.productName.toString()
            val detail = if (kind == AudioInputKind.BuiltIn) address else product
            device to AudioInput(AudioInput.id(device.type, address, product), kind, detail)
        }

    private fun kind(type: Int): AudioInputKind? = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_MIC -> AudioInputKind.BuiltIn
        AudioDeviceInfo.TYPE_WIRED_HEADSET -> AudioInputKind.Wired
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_HEADSET -> AudioInputKind.Usb
        else -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && isBluetoothHeadset(type)) {
            AudioInputKind.Bluetooth
        } else {
            null
        }
    }

    @RequiresApi(Build.VERSION_CODES.S)
    private fun isBluetoothHeadset(type: Int) =
        type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO || type == AudioDeviceInfo.TYPE_BLE_HEADSET

    private inner class DeviceRoute(
        private val device: AudioDeviceInfo,
        private val kind: AudioInputKind,
    ) : InputRoute {
        private var communication = false

        override fun applyTo(record: AudioRecord) {
            if (kind == AudioInputKind.Bluetooth && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                // The headset's microphone only carries audio while it is the communication device.
                val link = audio.availableCommunicationDevices
                    .firstOrNull { it.type == device.type && it.address == device.address }
                communication = link != null && audio.setCommunicationDevice(link)
            }
            record.setPreferredDevice(device)
        }

        override fun release() {
            if (communication && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) audio.clearCommunicationDevice()
            communication = false
        }
    }
}
