package com.yunx.app.ui.theme

import androidx.compose.runtime.Composable

internal data class SystemTextPreferences(val scale: Float, val bold: Boolean = false)

@Composable
internal expect fun rememberSystemTextPreferences(): SystemTextPreferences

internal expect fun recordSystemTextMetrics(scale: Float, density: Float, lineHeight: Int)
internal expect fun isSystemTextTest(): Boolean
