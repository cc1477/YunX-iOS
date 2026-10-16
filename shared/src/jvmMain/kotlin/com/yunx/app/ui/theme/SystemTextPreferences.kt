package com.yunx.app.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.ui.platform.LocalDensity

@Composable
internal actual fun rememberSystemTextPreferences() = SystemTextPreferences(LocalDensity.current.fontScale)
