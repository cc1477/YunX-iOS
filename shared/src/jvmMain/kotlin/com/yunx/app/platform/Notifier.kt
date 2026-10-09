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

/** JVM 桩：通知打到控制台。仅用于 JVM 编译验证。 */
actual fun clearLoginWebData() = Unit

actual fun setDownloadIdleTimerDisabled(disabled: Boolean) = Unit

actual class Notifier {
    actual fun progress(taskId: Long, title: String, percent: Int, speed: String) {
        if (percent % 10 == 0) println("[download#$taskId] $title $percent% $speed")
    }

    actual fun result(taskId: Long, title: String, success: Boolean, error: String) {
        println("[download#$taskId] $title ${if (success) "完成" else "失败: $error"}")
    }

    actual fun clear(taskId: Long) = Unit
}
