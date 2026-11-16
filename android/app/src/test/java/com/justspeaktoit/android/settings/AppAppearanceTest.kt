package com.justspeaktoit.android.settings

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AppAppearanceTest {
    @Test
    fun storedValues_useTheCrossPlatformDomain() {
        assertEquals(listOf("system", "light", "dark"), AppAppearance.entries.map { it.rawValue })
        assertEquals(AppAppearance.Dark, AppAppearance.fromRawValue("dark"))
    }

    @Test
    fun missingOrUnknownValue_followsThePhone() {
        assertEquals(AppAppearance.System, AppAppearance.fromRawValue(null))
        assertEquals(AppAppearance.System, AppAppearance.fromRawValue("sepia"))
    }

    @Test
    fun explicitChoice_overridesThePhoneSetting() {
        assertTrue(AppAppearance.System.isDark(systemIsDark = true))
        assertFalse(AppAppearance.Light.isDark(systemIsDark = true))
        assertTrue(AppAppearance.Dark.isDark(systemIsDark = false))
    }
}
