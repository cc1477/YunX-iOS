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

/** Callbacks are suspending so background wake completion can wait for durable DB writes. */
interface BackgroundDownloadListener {
    suspend fun onProgress(id: Long, received: Long, total: Long)
    suspend fun onComplete(id: Long, destPath: String)
    suspend fun onError(id: Long, message: String)
}

/** OS-owned single-connection downloads; never continues the common Range worker pool. */
expect class BackgroundDownloader() {
    fun enqueue(id: Long, url: String, destPath: String, headers: Map<String, String>)
    fun cancel(id: Long)
    fun setListener(listener: BackgroundDownloadListener)
    fun isEnqueued(id: Long): Boolean
}
