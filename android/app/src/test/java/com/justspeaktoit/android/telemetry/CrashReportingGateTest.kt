package com.justspeaktoit.android.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CrashReportingGateTest {
    private val store = FakeTelemetryStore()
    private val reporter = RecordingCrashReporter()

    @Test
    fun testUndecided_neverStarts() {
        CrashReportingGate(store, reporter, enabledInBuild = true).applyConsent()

        assertTrue(reporter.calls.isEmpty())
    }

    @Test
    fun testGranted_startsOnceAndWithdrawingStops() {
        val gate = CrashReportingGate(store, reporter, enabledInBuild = true)
        gate.setGranted(true)
        gate.applyConsent()
        gate.setGranted(false)

        assertEquals(listOf("start", "stop"), reporter.calls)
        assertEquals(DiagnosticsConsent.Declined, store.diagnosticsConsent)
    }

    @Test
    fun testDebugBuild_neverStartsEvenWhenGranted() {
        store.diagnosticsConsent = DiagnosticsConsent.Granted
        CrashReportingGate(store, reporter, enabledInBuild = false).applyConsent()

        assertTrue(reporter.calls.isEmpty())
    }

    @Test
    fun testDeclined_clearsLeftoversWithoutStarting() {
        CrashReportingGate(store, reporter, enabledInBuild = true).setGranted(false)

        assertEquals(listOf("stop"), reporter.calls)
    }
}
