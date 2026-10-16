package com.yunx.app.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalDensity

@Composable
internal actual fun rememberSystemTextPreferences() = SystemTextPreferences(LocalDensity.current.fontScale)

internal actual fun recordSystemTextMetrics(scale: Float, density: Float, lineHeight: Int) {}
internal actual fun isSystemTextTest(): Boolean = false
