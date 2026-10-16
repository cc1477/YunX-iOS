@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app.ui.theme

import androidx.compose.runtime.*
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSOperationQueue
import platform.UIKit.*

private fun readSystemTextPreferences() = SystemTextPreferences(
    scale = (UIFont.preferredFontForTextStyle(UIFontTextStyleBody).pointSize / 17.0).toFloat(),
    bold = UIAccessibilityIsBoldTextEnabled()
)

@Composable
internal actual fun rememberSystemTextPreferences(): SystemTextPreferences {
    var preferences by remember { mutableStateOf(readSystemTextPreferences()) }
    DisposableEffect(Unit) {
        val center = NSNotificationCenter.defaultCenter
        val observers = listOf(UIContentSizeCategoryDidChangeNotification,
            UIAccessibilityBoldTextStatusDidChangeNotification, UIApplicationDidBecomeActiveNotification).map { name ->
            center.addObserverForName(name, null, NSOperationQueue.mainQueue) {
                preferences = readSystemTextPreferences()
            }
        }
        onDispose { observers.forEach(center::removeObserver) }
    }
    return preferences
}
