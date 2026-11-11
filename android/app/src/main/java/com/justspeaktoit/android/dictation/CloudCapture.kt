package com.justspeaktoit.android.dictation

import com.justspeaktoit.android.cloud.AudioRecorder
import com.justspeaktoit.android.cloud.CallHandle
import com.justspeaktoit.android.cloud.CloudException
import com.justspeaktoit.android.cloud.RecorderFactory
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.File

/**
 * Owns the Cloud recording and the session's blocking IO. Call from the main thread.
 *
 * A recording stays owned until its recorder has really stopped, so [close] can always release the
 * microphone, and callbacks from a recording that is no longer owned are ignored by the caller via
 * [owns]. Blocking IO runs under an overall deadline, and cancelling it aborts the blocked call.
 *
 * [teardown] runs the release of a recording still owned at [close]. It outlives the owner's scope on
 * purpose (the microphone must be released after the screen is gone) and runs one stop at a time, so
 * a stalled recorder holds at most one IO thread.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class CloudCapture(
    private val recorders: RecorderFactory,
    private val cacheDir: File,
    private val io: CoroutineDispatcher,
    private val teardown: CoroutineScope =
        CoroutineScope(SupervisorJob() + io.limitedParallelism(1) + CoroutineName("jsti-recorder-teardown")),
) {
    class Recording(val recorder: AudioRecorder, val file: File)

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
        val bytes = withContext(NonCancellable + io) { recording.recorder.stop() }
        release(recording)
        return bytes
    }

    /** Stops capture without a result and deletes its file. */
    suspend fun discard(recording: Recording) {
        withContext(NonCancellable + io) {
            recording.recorder.stop()
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
        // Stop before delete, off the main thread: joining the capture thread here could cause an ANR.
        return teardown.launch {
            recording.recorder.stop()
            recording.file.delete()
        }
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
