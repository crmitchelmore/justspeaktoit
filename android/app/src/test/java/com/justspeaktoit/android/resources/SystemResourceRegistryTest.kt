package com.justspeaktoit.android.resources

import com.justspeaktoit.android.cloud.RepoSources
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SystemResourceRegistryTest {
    private var clock = 1_000L
    private val registry = SystemResourceRegistry { clock }

    @Test
    fun testReleaseAsksOwnerAndKeepsHoldUntilOwnerEndsIt() {
        var releases = 0
        lateinit var token: SystemResourceToken
        token = registry.acquire(SystemResourceKind.Microphone, "Dictation recording", "Listening", "test") {
            releases++
            assertTrue(registry.holds.value.first { it.id == token.id }.isReleasing)
        }
        val ignored = registry.acquire(SystemResourceKind.Microphone, "Stuck", "Listening", "test") { releases++ }

        assertTrue(registry.release(token.id))
        token.end()
        assertTrue(registry.release(ignored.id))

        assertEquals(2, releases)
        // A release that did not end the hold leaves it listed, ready to retry.
        val remaining = registry.holds.value.single()
        assertEquals(ignored.id, remaining.id)
        assertFalse(remaining.isReleasing)
    }

    @Test
    fun testReleaseEverythingSkipsStandingListenersAndUnreleasableHolds() {
        val released = mutableListOf<String>()
        listOf(SystemResourceKind.Microphone, SystemResourceKind.ProviderConnection, SystemResourceKind.HotKey)
            .forEach { kind ->
                lateinit var token: SystemResourceToken
                token = registry.acquire(kind, kind.displayName, "why", "test") {
                    released += kind.rawValue
                    token.end()
                }
            }
        registry.acquire(SystemResourceKind.KeyboardSession, "Keyboard", "why", "test")

        assertEquals(2, registry.releaseAll())
        assertEquals(listOf("microphone", "providerConnection"), released)
        assertEquals(
            listOf(SystemResourceKind.HotKey, SystemResourceKind.KeyboardSession),
            registry.holds.value.map { it.kind },
        )
        assertEquals(null, registry.holds.value.last().releaseTitle)
    }

    @Test
    fun testSummaryMatchesSharedWording() {
        assertEquals("Not holding any system resources", SystemResourceSummary.headline(emptyList()))
        registry.acquire(SystemResourceKind.ProviderConnection, "Cloud request", "why", "test")
        clock = 2_000L
        registry.acquire(SystemResourceKind.Microphone, "Dictation recording", "why", "test")
        registry.acquire(SystemResourceKind.Microphone, "Keyboard dictation", "why", "test")
        assertEquals(
            "Microphone in use: Dictation recording (+1)",
            SystemResourceSummary.headline(registry.holds.value),
        )
        assertEquals("for 12 s", SystemResourceSummary.duration(0, 12_000))
        assertEquals("for 2 h 5 min", SystemResourceSummary.duration(0, 125 * 60_000L))
    }

    @Test
    fun testKinds_matchSpeakCore() {
        val swift = RepoSources.speakCore("SystemResources/SystemResourceRegistry.swift")
        val cases = Regex("""^\s+case (\w+)$""", RegexOption.MULTILINE).findAll(swift)
            .map { it.groupValues[1] }.toList()
        assertEquals(cases, SystemResourceKind.entries.map { it.rawValue })
        SystemResourceKind.entries.forEach { kind ->
            val line = "case .${kind.rawValue}: return \"${kind.displayName}\""
            assertTrue("${kind.rawValue} name drifted", swift.contains(line))
        }
        val summary = RepoSources.speakCore("SystemResources/MicrophoneUseAuditor.swift")
        assertTrue(summary.contains("\"Not holding any system resources\""))
        assertTrue(summary.contains("\"Microphone in use: \\(first.title)\\(extra)\""))
    }
}
