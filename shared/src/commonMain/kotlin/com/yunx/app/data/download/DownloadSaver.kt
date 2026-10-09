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
import com.yunx.app.platform.appDownloadDir
import com.yunx.app.platform.secureRandomBytes
import okio.*
import okio.ByteString.Companion.toByteString
import okio.Path.Companion.toPath
class DownloadDestination internal constructor(val path: String, private val temporary: Path, private val target: Path) {
    fun open(): BufferedSink? = runCatching { FileSystem.SYSTEM.sink(temporary).buffer() }.getOrNull()
    fun commit() { FileSystem.SYSTEM.atomicMove(temporary, target) }
    fun abort() { FileSystem.SYSTEM.delete(temporary, mustExist = false) }
}
object DownloadSaver {
    fun openDestination(fileName: String, targetDirUri: String? = null): DownloadDestination? = runCatching {
        require(targetDirUri?.startsWith("content:") != true) { "SAF 目录不适用于 iOS，请重新选择下载目录" }
        val fs = FileSystem.SYSTEM
        val base = (targetDirUri?.takeIf { it.isNotBlank() } ?: appDownloadDir()).toPath()
        fs.createDirectories(base)
        val safe = DownloadPathPolicy.sanitize(fileName, "download") ?: return@runCatching null
        val directory = if (safe.relativeDirectory.isBlank()) base else base / safe.relativeDirectory
        var checkedDirectory = base
        if (safe.relativeDirectory.isNotBlank()) {
            for (component in safe.relativeDirectory.split('/')) {
                val next = checkedDirectory / component
                require(DownloadPathPolicy.isContained(base, next)) { "下载目录越界" }
                fs.createDirectories(next)
                checkedDirectory = next
            }
        }
        var target = directory / safe.fileName
        require(DownloadPathPolicy.isContained(base, target)) { "下载路径越界" }
        var suffix = 1
        while (fs.exists(target)) { target = directory / "${safe.fileName.substringBeforeLast('.', safe.fileName)} (${suffix++})${safe.fileName.substringAfterLast('.', "").let { if (it.isEmpty()) "" else ".$it" }}" }
        val nonce = secureRandomBytes(8).toByteString().hex()
        DownloadDestination(target.toString(), directory / ".yunx-pending-$nonce", target)
    }.getOrNull()
    fun save(fileName: String, source: Path, targetDirUri: String? = null): String? {
        val destination = openDestination(fileName, targetDirUri) ?: return null
        return try {
            val output = destination.open() ?: error("无法写入下载目录")
            output.use { FileSystem.SYSTEM.source(source).use { input -> it.writeAll(input) } }
            destination.commit(); destination.path
        } catch (error: Exception) { destination.abort(); null }
    }
    fun safDirDisplay(uriString: String) = uriString
    fun purgeOwnPendingFiles(): Int {
        val directory = appDownloadDir().toPath(); val fs = FileSystem.SYSTEM
        if (!fs.exists(directory)) return 0
        return fs.listRecursively(directory).filter { it.name.startsWith(".yunx-pending-") }.count { runCatching { fs.delete(it); true }.getOrDefault(false) }
    }
    fun delete(savePath: String): Boolean = runCatching { FileSystem.SYSTEM.delete(savePath.toPath()); true }.getOrDefault(false)
}
