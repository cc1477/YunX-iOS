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

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app.platform

import com.yunx.app.data.network.ShareLinkParser
import platform.Foundation.NSTimer
import platform.UIKit.*
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

actual class ClipboardMonitor actual constructor() {
    private var timer: NSTimer? = null
    private var lastText: String? = null
    actual fun startMonitoring(onLinkFound: (String) -> Unit) {
        dispatch_async(dispatch_get_main_queue()) {
            timer?.invalidate()
            timer = NSTimer.scheduledTimerWithTimeInterval(2.0, true) {
                if (UIApplication.sharedApplication.applicationState != UIApplicationState.UIApplicationStateActive) return@scheduledTimerWithTimeInterval
                // iOS can show a paste permission prompt; polling isn't a bypass of that policy.
                val text = UIPasteboard.generalPasteboard.string?.trim() ?: return@scheduledTimerWithTimeInterval
                if (text == lastText) return@scheduledTimerWithTimeInterval
                lastText = text
                if (ShareLinkParser.parse(text) != null) onLinkFound(text)
            }
        }
    }
    actual fun stopMonitoring() {
        dispatch_async(dispatch_get_main_queue()) { timer?.invalidate(); timer = null }
    }
}
