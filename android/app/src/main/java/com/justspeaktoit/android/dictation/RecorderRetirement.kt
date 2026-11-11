package com.justspeaktoit.android.dictation

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.util.concurrent.atomic.AtomicInteger

/**
 * Stops the recordings whose owner went away mid-recording, for every owner in the process.
 *
 * - **One lane.** Orphans are stopped one at a time on a single process-wide dispatcher view, so a
 *   recorder whose stop never returns holds one IO thread however many times the owner (the
 *   ViewModel) is recreated. Per-owner lanes would hold one thread per recreated owner.
 * - **Bounded admission.** While [maxPendingOrphans] orphans wait on that lane, [admitsNewRecording]
 *   is false and owners refuse to open another microphone they might not be able to release.
 * - **Stop before delete.** Each orphan's file is deleted only after its recorder has stopped, and
 *   only by the path that stopped it ([CloudCapture.Recording.claimStop]).
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

    /** Orphans queued or stopping. */
    val pendingOrphans: Int get() = pending.get()

    fun admitsNewRecording(): Boolean = pending.get() < maxPendingOrphans

    /** Stops [recording], which the caller has claimed, then deletes its file. */
    fun retire(recording: CloudCapture.Recording): Job {
        pending.incrementAndGet()
        return lane.launch {
            try {
                recording.stopClaimed()
                recording.file.delete()
            } finally {
                pending.decrementAndGet()
            }
        }
    }

    companion object {
        private const val DEFAULT_MAX_PENDING_ORPHANS = 2

        /** The process-wide lane every production owner shares. */
        val shared: RecorderRetirement by lazy { RecorderRetirement(Dispatchers.IO) }
    }
}
