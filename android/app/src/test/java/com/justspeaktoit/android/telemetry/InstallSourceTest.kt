package com.justspeaktoit.android.telemetry

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InstallSourceTest {
    private fun installer(sdkInt: Int) =
        InstallSource.installer(sdkInt, current = { "current" }, legacy = { "legacy" })

    @Test
    fun testAndroid10_usesTheLegacyInstallerLookup() {
        assertEquals("legacy", installer(29))
    }

    @Test
    fun testAndroid11AndLater_useInstallSourceInfo() {
        assertEquals("current", installer(30))
        assertEquals("current", installer(36))
    }

    @Test
    fun testOnlyThePlayStoreCountsAsPlay() {
        assertTrue(InstallSource.isPlayStore("com.android.vending"))
        assertFalse(InstallSource.isPlayStore("com.google.android.packageinstaller"))
        assertFalse(InstallSource.isPlayStore(null))
    }
}
