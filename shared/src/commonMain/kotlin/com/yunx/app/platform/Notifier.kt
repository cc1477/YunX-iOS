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

package com.yunx.app.platform

expect fun clearLoginWebData()
expect fun setDownloadIdleTimerDisabled(disabled: Boolean)
expect class Notifier() {
    fun progress(taskId: Long, title: String, percent: Int, speed: String)
    fun result(taskId: Long, title: String, success: Boolean, error: String)
    fun clear(taskId: Long)
}

// Keep the Stage 2b expect ABI and JVM actual unchanged. Authorization must suspend,
// since the iOS permission sheet cannot return a synchronous Boolean safely.
suspend fun Notifier.requestPermission(): Boolean = requestPermission(Permission.NOTIFICATIONS)
fun Notifier.notifyProgress(id: Long, title: String, percent: Int, speedText: String) = progress(id, title, percent, speedText)
fun Notifier.notifyComplete(id: Long, title: String) = result(id, title, true, "")
fun Notifier.cancel(id: Long) = clear(id)
/** iOS implements this via the existing actual idle-timer hook: prevents auto-lock only. */
fun setKeepAwake(enabled: Boolean) = setDownloadIdleTimerDisabled(enabled)
