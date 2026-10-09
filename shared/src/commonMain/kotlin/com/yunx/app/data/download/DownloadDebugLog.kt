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
import com.yunx.app.data.db.DownloadTaskEntity
import com.yunx.app.platform.*
import com.yunx.app.util.LogRedactor
import kotlinx.datetime.Clock
import okio.FileSystem
import okio.Path
import okio.Path.Companion.toPath
object DownloadDebugLog {
    private val lock = PlatformLock()
    private var enabled = false
    private val logs = mutableMapOf<Long, MutableList<String>>()
    fun isEnabled() = locked(lock) { enabled }
    fun setEnabled(value: Boolean) = locked(lock) { enabled = value; if (!value) logs.clear() }
    fun install() = setEnabled(SettingsStore().getBoolean("download_debug", false))
    fun networkSignature(): String = "Ktor/platform engine"
    fun environmentSnapshot(): String = "KMP; inflight=${DownloadManager.MAX_INFLIGHT_CHUNKS}; buffer=$BUFFER_SIZE"
    fun record(taskId: Long, node: String, detail: String = "") = locked(lock) {
        if (enabled) {
            val entries = logs.getOrPut(taskId) { mutableListOf() }
            entries.add("${Clock.System.now()} ${LogRedactor.line(node)} ${LogRedactor.line(detail)}")
            if (entries.size > 2000) entries.removeAt(0)
        }
    }
    fun entries(taskId: Long): List<String> = locked(lock) { logs[taskId]?.toList().orEmpty() }
    fun drop(taskId: Long) = locked(lock) { logs.remove(taskId); Unit }
    fun clear() = locked(lock) { logs.clear() }
    fun buildExportText(task: DownloadTaskEntity): String = "${environmentSnapshot()}\nid=${task.id} status=${task.status}\n${entries(task.id).joinToString("\n")}"
    fun exportToFile(task: DownloadTaskEntity): Path? = runCatching {
        val directory = appCacheDir().toPath() / "download-debug"; FileSystem.SYSTEM.createDirectories(directory)
        val path = directory / "task-${task.id}.txt"; FileSystem.SYSTEM.write(path) { writeUtf8(buildExportText(task)) }; path
    }.getOrNull()
}
