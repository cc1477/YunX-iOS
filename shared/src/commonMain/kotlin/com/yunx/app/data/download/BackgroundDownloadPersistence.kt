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

import com.yunx.app.data.db.DownloadTaskDao
import com.yunx.app.data.db.DownloadTaskEntity
import com.yunx.app.platform.BackgroundDownloadListener
import com.yunx.app.platform.Notifier
import okio.FileSystem
import okio.Path.Companion.toPath

/** Also usable on a background cold launch where no Compose DownloadManager exists yet. */
class BackgroundDownloadPersistence(private val dao: DownloadTaskDao) : BackgroundDownloadListener {
    private val notifier = Notifier()
    override suspend fun onProgress(id: Long, received: Long, total: Long) {
        val task = dao.get(id) ?: return
        if (task.status == DownloadTaskEntity.STATUS_COMPLETED) return
        dao.updateProgress(id, DownloadTaskEntity.STATUS_DOWNLOADING, received, total.coerceAtLeast(0))
        if (total > 0) notifier.progress(id, task.fileName, (received.toDouble() * 100 / total).toInt(), "")
    }
    override suspend fun onComplete(id: Long, destPath: String) {
        val task = dao.get(id) ?: return
        if (task.status == DownloadTaskEntity.STATUS_COMPLETED) return
        val size = FileSystem.SYSTEM.metadata(destPath.toPath()).size ?: task.totalSize
        dao.complete(id, DownloadTaskEntity.STATUS_COMPLETED, destPath)
        dao.updateProgress(id, DownloadTaskEntity.STATUS_COMPLETED, size, size)
        dao.updateError(id, "")
        notifier.result(id, task.fileName, true, "")
    }
    override suspend fun onError(id: Long, message: String) {
        val task = dao.get(id) ?: return
        if (task.status == DownloadTaskEntity.STATUS_COMPLETED) return
        notifier.clear(id)
        dao.updateStatus(id, DownloadTaskEntity.STATUS_PAUSED)
        dao.updateError(id, message)
    }
}
