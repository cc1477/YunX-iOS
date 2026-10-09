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

import java.awt.Toolkit
import java.awt.datatransfer.DataFlavor
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** JVM 实现：轮询系统剪贴板，发现文本变化时回调（由调用方判断是否为分享链接）。仅用于 JVM 编译验证。 */
actual class ClipboardMonitor {
    private val scheduler = Executors.newSingleThreadScheduledExecutor { r ->
        Thread(r, "yunx-clipboard-monitor").apply { isDaemon = true }
    }
    private var future: ScheduledFuture<*>? = null
    @Volatile private var lastSeen: String? = null

    actual fun startMonitoring(onLinkFound: (String) -> Unit) {
        stopMonitoring()
        future = scheduler.scheduleAtFixedRate({
            val text = runCatching {
                val t = Toolkit.getDefaultToolkit().systemClipboard.getData(DataFlavor.stringFlavor) as? String
                t?.trim()?.takeIf { it.isNotEmpty() }
            }.getOrNull()
            if (text != null && text != lastSeen) {
                lastSeen = text
                runCatching { onLinkFound(text) }
            }
        }, 0, 2, TimeUnit.SECONDS)
    }

    actual fun stopMonitoring() {
        future?.cancel(false)
        future = null
    }
}
