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

package com.yunx.app.util

import com.yunx.app.platform.*
import com.yunx.app.data.network.crc32
import kotlinx.datetime.Clock
import okio.Buffer
import okio.FileSystem
import okio.Path
import okio.Path.Companion.toPath

/** App-owned diagnostic files replace Android logcat/MediaStore/FileProvider. */
object LogExporter {
    suspend fun export(): Path? {
        DiagnosticLog.flush()
        return runCatching {
            val fs = FileSystem.SYSTEM
            val files = fs.list(DiagnosticLog.dirOf()).filter { it.name.endsWith(".log") }
            if (files.isEmpty()) return null
            val target = (appCacheDir() + "/yunx_logs_${Clock.System.now().toEpochMilliseconds()}.txt").toPath()
            fs.write(target) {
                for (file in files) { writeUtf8("=== ${file.name} ===\n"); fs.source(file).use { source -> writeAll(source) } }
            }
            target
        }.getOrNull()
    }
    suspend fun saveToDownloads(): Boolean = runCatching {
        val source = export() ?: return false
        val target = (appDownloadDir() + "/${source.name}").toPath()
        FileSystem.SYSTEM.copy(source, target); true
    }.getOrDefault(false)
    suspend fun exportDiagnosticZip(): Path? = DiagnosticLog.exportZip()
    // No system logcat on iOS. App log deletion is explicit and limited to this directory.
    fun clearLogcat(): Boolean = runCatching {
        FileSystem.SYSTEM.list(DiagnosticLog.dirOf()).forEach { FileSystem.SYSTEM.delete(it) }; true
    }.getOrDefault(false)
    /** Stage 4 will present the native share sheet; for now use the platform URL opener. */
    fun share(file: Path): Boolean = openUrl("file://$file")
}
/** Portable ZIP using stored entries (bounded diagnostic logs do not need compression). */
internal fun writeLogZip(files: List<Path>, target: Path) {
    val output = Buffer(); val directory = Buffer()
    for (file in files) {
        val name = file.name.encodeToByteArray()
        val data = FileSystem.SYSTEM.read(file) { readByteArray() }
        val crc = crc32(data).toInt(); val offset = output.size.toInt()
        output.writeIntLe(0x04034b50).writeShortLe(20).writeShortLe(0x800).writeShortLe(0)
            .writeShortLe(0).writeShortLe(33).writeIntLe(crc).writeIntLe(data.size).writeIntLe(data.size)
            .writeShortLe(name.size).writeShortLe(0).write(name).write(data)
        directory.writeIntLe(0x02014b50).writeShortLe(20).writeShortLe(20).writeShortLe(0x800).writeShortLe(0)
            .writeShortLe(0).writeShortLe(33).writeIntLe(crc).writeIntLe(data.size).writeIntLe(data.size)
            .writeShortLe(name.size).writeShortLe(0).writeShortLe(0).writeShortLe(0).writeShortLe(0)
            .writeIntLe(0).writeIntLe(offset).write(name)
    }
    val directoryOffset = output.size.toInt(); val directorySize = directory.size.toInt()
    output.writeAll(directory)
    output.writeIntLe(0x06054b50).writeShortLe(0).writeShortLe(0).writeShortLe(files.size).writeShortLe(files.size)
        .writeIntLe(directorySize).writeIntLe(directoryOffset).writeShortLe(0)
    FileSystem.SYSTEM.write(target) { writeAll(output) }
}
