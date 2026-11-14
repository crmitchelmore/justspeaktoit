package com.justspeaktoit.android.settings

/** Light, dark or follow the phone. Raw values match the Mac, iOS and Linux `appearance` setting. */
enum class AppAppearance(val rawValue: String) {
    System("system"),
    Light("light"),
    Dark("dark"),
    ;

    fun isDark(systemIsDark: Boolean): Boolean = when (this) {
        System -> systemIsDark
        Light -> false
        Dark -> true
    }

    companion object {
        fun fromRawValue(rawValue: String?): AppAppearance = entries.firstOrNull { it.rawValue == rawValue } ?: System
    }
}
