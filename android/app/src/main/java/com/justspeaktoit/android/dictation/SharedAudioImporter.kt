package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.SharedAudio
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.atomic.AtomicReference

/**
 * Copies audio another app shared into a private file before upload. The format is resolved and at
 * most [SharedAudio.MAX_BYTES] are copied off the main thread, within [deadlineMs]; cancelling closes
 * the provider stream, so a stalled sender cannot hold a worker. [providerType] and [open] read the
 * shared item (a content URI in the app), and run off the main thread.
 */
internal class SharedAudioImporter(
    private val capture: CloudCapture,
    private val deadlineMs: Long,
) {
    suspend fun import(
        declaredType: String?,
        target: File,
        providerType: () -> String?,
        open: () -> InputStream?,
    ): SharedAudio.Format {
        val stream = AtomicReference<InputStream?>(null)
        val closeStream: () -> Unit = { runCatching { stream.get()?.close() } }
        return capture.bounded(deadlineMs, DictationFailure.Audio, closeStream) {
            // Senders often declare a generic type such as audio/*; the provider's type is more precise.
            val format = SharedAudio.format(declaredType) ?: SharedAudio.format(providerType())
                ?: throw CloudException(DictationFailure.UnsupportedAudio, "Unsupported audio")
            val input = open() ?: throw IOException("Unreadable audio")
            stream.set(input)
            copyLimited(input, target)
            format
        }
    }

    /** Fails early rather than uploading a file the provider would reject. */
    private fun copyLimited(input: InputStream, target: File) {
        input.use { from ->
            target.outputStream().use { out ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val read = from.read(buffer)
                    if (read < 0) break
                    total += read
                    if (total > SharedAudio.MAX_BYTES) {
                        throw CloudException(DictationFailure.AudioTooLarge, "Audio too large")
                    }
                    out.write(buffer, 0, read)
                }
            }
        }
    }
}
