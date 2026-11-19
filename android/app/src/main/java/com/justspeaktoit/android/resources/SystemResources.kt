package com.justspeaktoit.android.resources

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

/**
 * Mirrors `SystemResourceKind` in SpeakCore (`SystemResourceRegistry.swift`); `SystemResourcesParityTest`
 * fails when the two drift. Android holds only the kinds it really takes.
 */
enum class SystemResourceKind(val rawValue: String, val displayName: String) {
    Microphone("microphone", "Microphone"),
    AudioOutput("audioOutput", "Audio output"),
    ProviderConnection("providerConnection", "Provider connection"),
    LocalModel("localModel", "On-device model"),
    HotKey("hotKey", "Hotkey listener"),
    Accessibility("accessibility", "Accessibility"),
    KeyboardSession("keyboardSession", "Keyboard session"),
    BackgroundTask("backgroundTask", "Background task"),
    LiveActivity("liveActivity", "Live Activity"),
}

/** One resource the app holds: what, why and since when. */
data class SystemResourceHold(
    val id: String,
    val kind: SystemResourceKind,
    val title: String,
    val reason: String,
    val owner: String,
    val sinceMs: Long,
    /** The release button's label; null when the hold cannot be released on its own. */
    val releaseTitle: String?,
    /** A release was requested and the owner has not ended the hold yet. */
    val isReleasing: Boolean = false,
) {
    val isReleasable: Boolean get() = releaseTitle != null
}

/** Ends a hold. Ending twice is harmless. */
class SystemResourceToken internal constructor(val id: String, private val registry: SystemResourceRegistry) {
    fun end() = registry.end(id)
}

/**
 * The one place Android components record the system resources they hold (#1471, #1473), so Settings can
 * show what the app holds, why and since when, and release it. A release only asks the owner to stop: the
 * hold stays listed until the owner ends its token, so a release that does not work stays visible.
 */
class SystemResourceRegistry(private val now: () -> Long = System::currentTimeMillis) {
    private class Entry(val hold: SystemResourceHold, val release: (() -> Unit)?)

    private val lock = Any()
    private val entries = LinkedHashMap<String, Entry>()
    private val _holds = MutableStateFlow<List<SystemResourceHold>>(emptyList())

    /** Every current hold, oldest first. */
    val holds: StateFlow<List<SystemResourceHold>> = _holds.asStateFlow()

    fun acquire(
        kind: SystemResourceKind,
        title: String,
        reason: String,
        owner: String,
        releaseTitle: String = DEFAULT_RELEASE_TITLE,
        release: (() -> Unit)? = null,
    ): SystemResourceToken {
        val id = UUID.randomUUID().toString()
        val hold = SystemResourceHold(
            id = id,
            kind = kind,
            title = title,
            reason = reason,
            owner = owner,
            sinceMs = now(),
            releaseTitle = if (release == null) null else releaseTitle,
        )
        mutate { it[id] = Entry(hold, release) }
        return SystemResourceToken(id, this)
    }

    fun end(id: String) = mutate { it.remove(id) }

    /** Asks the owner of [id] to release it. Returns false when it is gone, not releasable or already releasing. */
    fun release(id: String): Boolean {
        var action: (() -> Unit)? = null
        mutate { map ->
            val entry = map[id] ?: return@mutate
            val release = entry.release ?: return@mutate
            if (entry.hold.isReleasing) return@mutate
            map[id] = Entry(entry.hold.copy(isReleasing = true), release)
            action = release
        }
        val run = action ?: return false
        try {
            run()
        } finally {
            // The owner normally ended the hold; if not, show the button again so the user can retry.
            mutate { map ->
                val entry = map[id] ?: return@mutate
                map[id] = Entry(entry.hold.copy(isReleasing = false), entry.release)
            }
        }
        return true
    }

    /** Releases every releasable hold of [kinds]. Returns how many releases ran. */
    fun releaseAll(kinds: Set<SystemResourceKind> = RELEASE_EVERYTHING_KINDS): Int =
        holds.value.filter { it.isReleasable && it.kind in kinds }.count { release(it.id) }

    private inline fun mutate(change: (MutableMap<String, Entry>) -> Unit) {
        synchronized(lock) {
            change(entries)
            _holds.value = entries.values.map { it.hold }.sortedBy { it.sinceMs }
        }
    }

    companion object {
        const val DEFAULT_RELEASE_TITLE = "Release"

        /** The app's process-wide registry, shared by the dictation screen and the keyboard. */
        val shared = SystemResourceRegistry()

        /** Standing listeners stay up through Release everything, as on the desktop hosts. */
        val RELEASE_EVERYTHING_KINDS: Set<SystemResourceKind> =
            SystemResourceKind.entries.toSet() - setOf(SystemResourceKind.HotKey, SystemResourceKind.Accessibility)
    }
}

/** Short text for the Settings section, matching `SystemResourceSummary` in SpeakCore. */
object SystemResourceSummary {
    fun headline(holds: List<SystemResourceHold>): String {
        val microphone = holds.filter { it.kind == SystemResourceKind.Microphone }
        microphone.firstOrNull()?.let { first ->
            val extra = if (microphone.size > 1) " (+${microphone.size - 1})" else ""
            return "Microphone in use: ${first.title}$extra"
        }
        if (holds.isEmpty()) return "Not holding any system resources"
        return if (holds.size == 1) "Holding 1 resource" else "Holding ${holds.size} resources"
    }

    /** "for 3 min", "for 12 s", "for 2 h 5 min". */
    fun duration(sinceMs: Long, nowMs: Long): String {
        val seconds = maxOf(0L, (nowMs - sinceMs) / 1000)
        if (seconds < 60) return "for $seconds s"
        val minutes = seconds / 60
        if (minutes < 60) return "for $minutes min"
        val hours = minutes / 60
        val remainder = minutes % 60
        return if (remainder == 0L) "for $hours h" else "for $hours h $remainder min"
    }
}
