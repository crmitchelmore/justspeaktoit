package com.justspeaktoit.android

import android.app.Application
import com.justspeaktoit.android.telemetry.Telemetry

class JustSpeakApplication : Application() {
    /** Created at launch so crash reporting, when the user allowed it, covers startup. */
    lateinit var telemetry: Telemetry
        private set

    override fun onCreate() {
        super.onCreate()
        telemetry = Telemetry.create(this)
        telemetry.crashes.applyConsent()
    }
}
