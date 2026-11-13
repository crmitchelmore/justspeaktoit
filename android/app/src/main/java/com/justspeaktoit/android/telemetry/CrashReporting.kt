package com.justspeaktoit.android.telemetry

/** Starts and stops the crash-reporting SDK. */
interface CrashReporter {
    fun start()

    /** Stops reporting and deletes anything queued on disk. */
    fun stop()
}

/**
 * Crash reports run only after an explicit grant, mirroring the Mac and iOS `diagnosticsConsent`: undecided
 * and declined never start the SDK, and withdrawing stops it and deletes queued reports. Debug builds never
 * report, so development crashes don't reach the production project.
 */
class CrashReportingGate(
    private val store: TelemetryStore,
    private val reporter: CrashReporter,
    private val enabledInBuild: Boolean,
) {
    private var running = false

    val consent: DiagnosticsConsent get() = store.diagnosticsConsent

    /** Call once at launch. */
    fun applyConsent() {
        if (enabledInBuild && consent.permitsCollection) {
            if (!running) {
                reporter.start()
                running = true
            }
        } else if (running) {
            reporter.stop()
            running = false
        }
    }

    fun setGranted(granted: Boolean) {
        store.diagnosticsConsent = if (granted) DiagnosticsConsent.Granted else DiagnosticsConsent.Declined
        if (!granted && !running) {
            // Nothing is running, but clear anything an earlier session may have left queued.
            if (enabledInBuild) reporter.stop()
            return
        }
        applyConsent()
    }
}
