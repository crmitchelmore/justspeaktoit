package com.justspeaktoit.android.dictation

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Stops the recordings whose owner went away mid-recording, for every owner in the process, and
 * counts every stop that outlives its owner.
 *
 * - **One lane.** Orphans are stopped one at a time on a single process-wide dispatcher view, so a
 *   recorder whose stop never returns holds one IO thread however many times the owner (the
 *   ViewModel) is recreated. Per-owner lanes would hold one thread per recreated owner.
 * - **Bounded admission.** While [maxPendingOrphans] orphans are unsettled, [admitsNewRecording] is
 *   false and owners refuse to open another microphone they might not be able to release. An orphan
 *   is either retired on the lane ([retire]) or a stop its owner had already started before going
 *   away ([adopt]); that stop keeps its own thread, so at most [maxPendingOrphans] such threads can
 *   be held across recreated owners.
 * - **Stop, then keep.** An orphan's audio is never deleted: once its recorder has stopped, the
 *   file is listed by [recoverable] so the next History load saves it ([abandon]). Only the path
 *   that stopped a recorder decides its file ([CloudCapture.Recording.claimStop]).
 * - **Process token.** Recordings are named with [processToken], so files left by an earlier
 *   process (one that died mid-recording) are recoverable too, while this process's live ones are not.
 *
 * Nothing here blocks the main thread or forces a native release: a stalled stop stays stalled
 * until the recorder returns, and admission reopens when it does.
 */
@OptIn(ExperimentalCoroutinesApi::class)
internal class RecorderRetirement(
    io: CoroutineDispatcher,
    private val maxPendingOrphans: Int = DEFAULT_MAX_PENDING_ORPHANS,
) {
    private val lane =
        CoroutineScope(SupervisorJob() + io.limitedParallelism(1) + CoroutineName("jsti-recorder-teardown"))
    private val pending = AtomicInteger(0)
    private val abandoned = ConcurrentHashMap.newKeySet<String>()

    /** Names this process's recordings; see [recordingFile]. */
    val processToken: String = UUID.randomUUID().toString().substringBefore('-')

    /** A new recording's file in [dir]. */
    fun recordingFile(dir: File): File = File(dir, "$PREFIX$processToken-${System.nanoTime()}.wav")

    /** Hands a stopped recording that no session will finish to the next History load. */
    fun abandon(file: File) {
        abandoned += file.absolutePath
    }

    /**
     * Recordings in [dir] that no session owns: those [abandon]ed in this process and any left by an
     * earlier one. Each is returned once; the caller moves or deletes it.
     */
    fun recoverable(dir: File): List<File> = dir.listFiles().orEmpty().filter { file ->
        val name = file.name
        name.startsWith(PREFIX) && name.endsWith(".wav") &&
            (abandoned.remove(file.absolutePath) || !name.startsWith("$PREFIX$processToken-"))
    }

    /** Orphans queued, stopping on the lane, or adopted and still stopping. */
    val pendingOrphans: Int get() = pending.get()

    fun admitsNewRecording(): Boolean = pending.get() < maxPendingOrphans

    /** Stops [recording], which the caller has claimed, then keeps its file for recovery. */
    fun retire(recording: CloudCapture.Recording): Job {
        pending.incrementAndGet()
        return lane.launch {
            try {
                recording.stopClaimed()
                abandon(recording.file)
            } finally {
                pending.decrementAndGet()
            }
        }
    }

    /**
     * Counts a stop that [recording]'s owner started before going away until it settles. The stop
     * keeps running where it started and its caller still decides what happens to the file.
     */
    fun adopt(recording: CloudCapture.Recording): Job {
        val stopped = recording.stopped
        pending.incrementAndGet()
        stopped.invokeOnCompletion { pending.decrementAndGet() }
        return stopped
    }

    companion object {
        private const val DEFAULT_MAX_PENDING_ORPHANS = 2
        private const val PREFIX = "dictation-"

        /** The process-wide lane every production owner shares. */
        val shared: RecorderRetirement by lazy { RecorderRetirement(Dispatchers.IO) }
    }
}
