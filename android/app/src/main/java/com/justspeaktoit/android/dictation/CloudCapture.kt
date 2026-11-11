package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.AudioRecorder
import com.justspeaktoit.android.cloud.CallHandle
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.RecorderFactory
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Owns the Cloud recording and the session's blocking IO. Call from the main thread.
 *
 * A recording stays owned until its recorder has really stopped, so [close] can always release the
 * microphone, and callbacks from a recording that is no longer owned are ignored by the caller via
 * [owns]. Blocking IO runs under an overall deadline, and cancelling it aborts the blocked call.
 *
 * Each recorder is stopped exactly once, by whichever path claims it first: [stop], [discard] or
 * [close]. A recording still owned at [close] is handed to [retirement], which outlives the owner on
 * purpose (the microphone must be released after the screen is gone) and is shared by every owner
 * in the process, so recreated owners cannot multiply stalled stops.
 */
internal class CloudCapture(
    private val recorders: RecorderFactory,
    private val cacheDir: File,
    private val io: CoroutineDispatcher,
    private val retirement: RecorderRetirement = RecorderRetirement.shared,
) {
    class Recording(val recorder: AudioRecorder, val file: File) {
        private val claimed = AtomicBoolean(false)
        private val result = CompletableDeferred<Long>()

        /** Completes once the recorder has stopped. */
        val stopped: Job get() = result

        /** True for the one caller that must then stop the recorder; later callers wait for it. */
        internal fun claimStop(): Boolean = claimed.compareAndSet(false, true)

        /** Blocking. Stops the recorder for the caller that claimed it. */
        internal fun stopClaimed(): Long {
            val bytes = try {
                recorder.stop()
            } catch (e: Throwable) {
                result.completeExceptionally(e)
                throw e
            }
            result.complete(bytes)
            return bytes
        }

        /** Stops the recorder if nobody has yet, otherwise waits for the stop under way. */
        internal suspend fun stopOnce(): Long = if (claimStop()) stopClaimed() else result.await()
    }

    /** The recording that has not yet been stopped, if any. */
    var current: Recording? = null
        private set

    fun owns(recording: Recording): Boolean = current === recording

    /**
     * Opens the microphone. The callbacks receive their own recording so the caller can ignore one
     * that has since been replaced or stopped. Returns false (and leaves nothing behind) on failure.
     */
    fun start(
        onLevel: (Float) -> Unit,
        onLimitReached: (Recording) -> Unit,
        onCaptureFailed: (Recording) -> Unit,
    ): Boolean {
        // Orphans are still holding microphones that have not been released.
        if (!retirement.admitsNewRecording()) return false
        val file = File(cacheDir, "dictation-${System.nanoTime()}.wav")
        lateinit var recording: Recording
        val recorder = recorders.create(
            file = file,
            onLevel = onLevel,
            onLimitReached = { onLimitReached(recording) },
            onCaptureFailed = { onCaptureFailed(recording) },
        )
        recording = Recording(recorder, file)
        if (!recorder.start()) {
            file.delete()
            return false
        }
        current = recording
        return true
    }

    /** Stops capture and returns the audio bytes, or -1 on a capture failure. The file is kept. */
    suspend fun stop(recording: Recording): Long {
        val bytes = withContext(NonCancellable + io) { recording.stopOnce() }
        release(recording)
        return bytes
    }

    /** Stops capture without a result and deletes its file. */
    suspend fun discard(recording: Recording) {
        withContext(NonCancellable + io) {
            recording.stopOnce()
            recording.file.delete()
        }
        release(recording)
    }

    suspend fun delete(file: File) {
        withContext(NonCancellable + io) { file.delete() }
    }

    fun release(recording: Recording) {
        if (current === recording) current = null
    }

    /**
     * Releases a recording still owned when its owner goes away, without blocking the caller. Returns
     * the teardown, or null when nothing was owned.
     */
    fun close(): Job? {
        val recording = current ?: return null
        current = null
        // A stop already under way owns the recording and decides what happens to its file; a second
        // stop or a delete here could race it. Otherwise retire it off the main thread: joining the
        // capture thread here could cause an ANR.
        if (!recording.claimStop()) return recording.stopped
        return retirement.retire(recording)
    }

    /**
     * Runs a blocking request with an overall [deadlineMs]. Cancelling the coroutine or reaching the
     * deadline disconnects the request, so no upload or response read outlives the session.
     */
    suspend fun <T> call(deadlineMs: Long, block: (CallHandle) -> T): T {
        val call = CallHandle()
        return bounded(deadlineMs, DictationFailure.NetworkTimeout, abort = call::cancel) { block(call) }
    }

    /**
     * Runs blocking IO with an overall deadline. On cancellation or timeout [abort] runs from another
     * coroutine (closing a socket or stream), so the blocked thread is released instead of leaking.
     */
    suspend fun <T> bounded(
        deadlineMs: Long,
        timeoutFailure: DictationFailure,
        abort: () -> Unit,
        block: () -> T,
    ): T = try {
        withTimeout(deadlineMs) {
            coroutineScope {
                val watchdog = launch {
                    try {
                        awaitCancellation()
                    } finally {
                        abort()
                    }
                }
                try {
                    withContext(io) { block() }
                } catch (e: Exception) {
                    // The aborted call fails with its own error (a closed socket reads as a network
                    // error), which would otherwise hide the deadline or cancellation that caused it.
                    ensureActive()
                    throw e
                } finally {
                    watchdog.cancel()
                }
            }
        }
    } catch (e: TimeoutCancellationException) {
        throw CloudException(timeoutFailure, "Deadline reached", e)
    }
}
