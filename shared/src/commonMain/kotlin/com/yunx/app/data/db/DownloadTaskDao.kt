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

package com.yunx.app.data.db

import kotlinx.coroutines.flow.Flow

interface DownloadTaskDao {

    fun observeAll(): Flow<List<DownloadTaskEntity>>

    suspend fun insert(task: DownloadTaskEntity): Long

    suspend fun get(id: Long): DownloadTaskEntity?

    suspend fun updateProgress(id: Long, status: Int, downloadedSize: Long, totalSize: Long)

    suspend fun updatePlan(id: Long, chunkCount: Int, totalSize: Long)

    suspend fun updateRequestHeaders(id: Long, encryptedHeaders: String)

    suspend fun markInterruptedAsPaused()

    suspend fun updateStatus(id: Long, status: Int)

    suspend fun updateError(id: Long, errorMsg: String)

    suspend fun complete(id: Long, status: Int, savePath: String, avgSpeed: Long = 0L)

    suspend fun delete(id: Long)

    /** 记下这条任务对应的 Gopeed 引擎任务 ID（走引擎下载时才写） */
    suspend fun updateEngineTaskId(id: Long, engineTaskId: String)

    /** 磁力任务完成时把占位显示名换成真正的种子名（种子名要等引擎解析出元数据才有） */
    suspend fun updateFileName(id: Long, name: String)

    /** 还在引擎里跑、需要同步进度的任务（已完成/失败的不再同步） */
    suspend fun listSyncableEngineTasks(): List<DownloadTaskEntity>
}
