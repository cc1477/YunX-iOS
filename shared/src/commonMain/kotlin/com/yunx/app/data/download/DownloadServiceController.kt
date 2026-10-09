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

package com.yunx.app.data.download
import com.yunx.app.platform.*
/** Reference counted idle prevention. iOS suspension still stops foreground downloads. */
class DownloadServiceController {
    private val lock = PlatformLock()
    private val active = mutableSetOf<Long>()
    private val notifier = Notifier()
    fun acquire(taskId: Long, title: String, keepAwake: Boolean = true) = locked(lock) {
        if (keepAwake) active.add(taskId)
        setDownloadIdleTimerDisabled(active.isNotEmpty())
        notifier.progress(taskId, title, 0, "")
    }
    fun update(taskId: Long, title: String, progress: Int, speed: String, showSpeed: Boolean) = notifier.progress(taskId, title, progress, if (showSpeed) speed else "")
    fun release(taskId: Long) = locked(lock) { active.remove(taskId); setDownloadIdleTimerDisabled(active.isNotEmpty()); notifier.clear(taskId) }
    fun notifyResult(taskId: Long, fileName: String, success: Boolean, error: String = "", promote: Boolean = true) = notifier.result(taskId, fileName, success, error)
}
