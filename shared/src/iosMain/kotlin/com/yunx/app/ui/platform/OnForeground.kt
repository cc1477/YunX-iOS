/*
 * YunX (云析) - A network drive share-link parser and high-speed downloader for Android.
 * Copyright (C) 2026 CYQawa
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

package com.yunx.app.ui.platform
import androidx.compose.runtime.*
import platform.Foundation.NSNotificationCenter
import platform.Foundation.NSOperationQueue
import platform.UIKit.UIApplicationDidBecomeActiveNotification
@Composable
actual fun OnForeground(enabled: Boolean, action: () -> Unit) {
    val currentAction = rememberUpdatedState(action)
    DisposableEffect(enabled) {
        val monitor = if (enabled) com.yunx.app.platform.ClipboardMonitor().also {
            it.startMonitoring { currentAction.value() }
        } else null
        currentAction.value()
        val token = if (enabled) NSNotificationCenter.defaultCenter.addObserverForName(
            UIApplicationDidBecomeActiveNotification, null, NSOperationQueue.mainQueue
        ) { currentAction.value() } else null
        onDispose {
            monitor?.stopMonitoring()
            token?.let { NSNotificationCenter.defaultCenter.removeObserver(it) }
        }
    }
}
