@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app.ui.theme

import androidx.compose.runtime.*
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSOperationQueue
import platform.UIKit.*
import okio.Path.Companion.toPath

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
        onDispose { observers.forEach { center.removeObserver(it) } }
    }
    return preferences
}

internal actual fun recordSystemTextMetrics(scale: Float, density: Float, lineHeight: Int) {
    if (!platform.Foundation.NSProcessInfo.processInfo.arguments.contains("--ui-test")) return
    val points = UIFont.preferredFontForTextStyle(UIFontTextStyleBody).pointSize
    val path = com.yunx.app.platform.appCacheDir() + "/system-text-test.json"
    okio.FileSystem.SYSTEM.write(path.toPath()) {
        writeUtf8("""{"scale":$scale,"density":$density,"lineHeight":$lineHeight,"nativePoints":$points}""")
    }
}
