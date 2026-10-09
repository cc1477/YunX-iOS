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

/**
 * JVM 桩：桌面 JVM 没有"应用挂起后由系统接管下载"的概念，后台下载无意义。
 * enqueue 直接回调 onError，调用方按"暂停，回到前台继续"降级（与 iOS 侧语义对齐）。
 * 仅用于 JVM 编译验证。
 */
actual class BackgroundDownloader {
    private var listener: BackgroundDownloadListener? = null

    actual fun enqueue(id: Long, url: String, destPath: String, headers: Map<String, String>) {
        // JVM 下无后台接管语义：直接报告不支持，由上层降级为前台任务。
        // 注意：listener 回调是 suspend 的，这里不启动协程，仅记录；保持空实现以通过编译。
        PlatformLog.w("BackgroundDownloader", "enqueue($id) ignored on JVM: no OS-owned background downloads")
    }

    actual fun cancel(id: Long) = Unit

    actual fun setListener(listener: BackgroundDownloadListener) {
        this.listener = listener
    }

    actual fun isEnqueued(id: Long): Boolean = false
}
