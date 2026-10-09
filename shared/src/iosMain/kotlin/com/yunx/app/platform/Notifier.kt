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

import platform.UserNotifications.*
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import kotlin.math.abs

actual class Notifier actual constructor() {
    // Serialized on the main queue, including calls originating in download workers.
    private val lastPercent = mutableMapOf<Long, Int>()
    private val center = UNUserNotificationCenter.currentNotificationCenter()
    actual fun progress(taskId: Long, title: String, percent: Int, speed: String) {
        dispatch_async(dispatch_get_main_queue()) {
            val value = percent.coerceIn(0, 100)
            val previous = lastPercent[taskId]
            if (previous != null && abs(value - previous) <= 10) return@dispatch_async
            lastPercent[taskId] = value
            // iOS has no Android-style ongoing progress bar. Reusing the identifier replaces
            // the delivered notification; sound=nil and Swift suppresses foreground banners.
            // In background, the OS may still show an alert: true silent updates aren't promised.
            post("yunx.progress.$taskId", title, "$value% $speed", false)
        }
    }
    actual fun result(taskId: Long, title: String, success: Boolean, error: String) {
        dispatch_async(dispatch_get_main_queue()) {
            removeProgress(taskId)
            // Separate identifier: DownloadServiceController.release() must not erase completion.
            post("yunx.result.$taskId", title, if (success) "下载完成" else error, true)
        }
    }
    actual fun clear(taskId: Long) {
        dispatch_async(dispatch_get_main_queue()) { removeProgress(taskId) }
    }
    private fun removeProgress(id: Long) {
        lastPercent.remove(id)
        center.removePendingNotificationRequestsWithIdentifiers(listOf("yunx.progress.$id"))
        center.removeDeliveredNotificationsWithIdentifiers(listOf("yunx.progress.$id"))
    }
    private fun post(id: String, title: String, body: String, audible: Boolean) {
        val content = UNMutableNotificationContent().apply {
            setTitle(title)
            setBody(body)
            setSound(if (audible) UNNotificationSound.defaultSound() else null)
        }
        center.addNotificationRequest(UNNotificationRequest.requestWithIdentifier(id, content, null)) { error ->
            if (error != null) PlatformLog.w("Notifier", "通知未送达 code=${error.code}")
        }
    }
}
