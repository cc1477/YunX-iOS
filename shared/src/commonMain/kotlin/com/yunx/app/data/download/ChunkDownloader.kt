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
import io.ktor.client.HttpClient
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.utils.io.*
import com.yunx.app.platform.PlatformLock
import com.yunx.app.platform.locked
import kotlinx.coroutines.*
import kotlinx.coroutines.CancellationException
import okio.*
import kotlin.coroutines.coroutineContext
internal const val BUFFER_SIZE = 64 * 1024
internal fun ByteArray.toHexDigest() = okio.ByteString.of(*this).hex()
enum class ChunkResult { OK, RANGE_IGNORED, FAILED }
/** Shared preemption flag guarded across platform threads. */
class ChunkPreemption {
    private val lock = PlatformLock(); private var value = false
    fun get(): Boolean = locked(lock) { value }
    fun set(value: Boolean) = locked(lock) { this.value = value }
}
class ChunkDownloader(private val clientProvider: () -> HttpClient) {
    private val lock = PlatformLock()
    private val active = mutableMapOf<Long, MutableSet<Job>>()
    fun cancelCalls(taskId: Long) { locked(lock) { active.remove(taskId)?.toList() }.orEmpty().forEach { it.cancel() } }
    private suspend fun <T> registered(id: Long, block: suspend () -> T): T = coroutineScope {
        val job = coroutineContext[Job]!!
        locked(lock) { active.getOrPut(id) { mutableSetOf() }.add(job) }
        try { block() } finally { locked(lock) { active[id]?.let { it.remove(job); if (it.isEmpty()) active.remove(id) } } }
    }
    suspend fun getTotalSize(url: String, headers: Map<String, String>): Long? {
        for (range in listOf(true, false)) {
            val result = try {
                clientProvider().prepareGet(url) {
                    headers.forEach { (key, value) -> header(key, value) }
                    header("Accept-Encoding", "identity")
                    if (range) header("Range", "bytes=0-0")
                }.execute { response ->
                    if (response.status.value !in 200..299 || response.headers["Content-Type"].orEmpty().contains("text/html", true)) null
                    else if (range) HttpRangePolicy.parse(response.headers["Content-Range"])?.takeIf { response.status.value == 206 && it.start == 0L && it.end == 0L }?.total
                    else response.headers["Content-Length"]?.toLongOrNull()?.takeIf { it > 0 }
                }
            } catch (error: CancellationException) { throw error } catch (error: Exception) { null }
            if (result != null) return result
        }
        return null
    }
    suspend fun downloadChunk(taskId: Long, url: String, start: Long, end: Long, partFile: Path,
        headers: Map<String, String>, preempt: ChunkPreemption? = null,
        contentDigest: ((ByteArray, Int) -> Unit)? = null, onBytes: suspend (Long) -> Unit
    ): ChunkResult = registered(taskId) {
        val fs = FileSystem.SYSTEM; val expected = end - start + 1
        require(start >= 0 && end >= start && end != Long.MAX_VALUE)
        partFile.parent?.let { fs.createDirectories(it) }
        var preemptions = 0; var failures = 0; var ignored = 0
        while (failures < 3 && ignored <= 4) {
            coroutineContext.ensureActive()
            val existing = fs.metadataOrNull(partFile)?.size ?: 0L
            if (existing == expected) return@registered ChunkResult.OK
            if (existing > expected) { fs.delete(partFile); return@registered ChunkResult.FAILED }
            try {
                var wasPreempted = false
                val result = clientProvider().prepareGet(url) {
                    headers.forEach { (key, value) -> header(key, value) }
                    header("Accept-Encoding", "identity"); header("Range", "bytes=${start + existing}-$end")
                }.execute { response ->
                    if (response.status.value == 200) return@execute ChunkResult.RANGE_IGNORED
                    if (response.status.value != 206 || !HttpRangePolicy.matches(response.headers["Content-Range"], start + existing, end) || response.headers["Content-Type"].orEmpty().contains("text/html", true)) return@execute ChunkResult.FAILED
                    val channel = response.bodyAsChannel(); val buffer = ByteArray(BUFFER_SIZE); var written = existing
                    fs.appendingSink(partFile).buffer().use { output ->
                        while (true) {
                            coroutineContext.ensureActive()
                            if (preempt?.get() == true && preemptions < 3) { preempt.set(false); wasPreempted = true; break }
                            val count = channel.readAvailable(buffer, 0, minOf(BUFFER_SIZE.toLong(), expected - written + 1).toInt())
                            if (count < 0) break
                            if (count == 0) continue
                            check(written + count <= expected) { "Range 响应超出分片边界" }
                            output.write(buffer, 0, count); contentDigest?.invoke(buffer, count); written += count; onBytes(count.toLong())
                        }
                    }
                    if (written == expected) ChunkResult.OK else ChunkResult.FAILED
                }
                if (wasPreempted) { preemptions++; continue }
                if (result == ChunkResult.OK) return@registered result
                if (result == ChunkResult.RANGE_IGNORED) { ignored++; if (ignored > 4) return@registered result } else failures++
            } catch (error: CancellationException) { throw error } catch (error: Exception) { failures++ }
            delay((250L shl minOf(failures + ignored, 4)))
        }
        ChunkResult.FAILED
    }
    suspend fun downloadFull(taskId: Long, url: String, partFile: Path, headers: Map<String, String>, total: Long = -1L,
        onBytes: suspend (Long) -> Unit): Boolean = registered(taskId) {
        val fs = FileSystem.SYSTEM; partFile.parent?.let { fs.createDirectories(it) }
        try {
            clientProvider().prepareGet(url) {
                headers.forEach { (key, value) -> header(key, value) }; header("Accept-Encoding", "identity")
            }.execute { response ->
                if (response.status.value != 200 || response.headers["Content-Type"].orEmpty().contains("text/html", true)) return@execute false
                val channel = response.bodyAsChannel(); val buffer = ByteArray(BUFFER_SIZE); var written = 0L
                fs.sink(partFile).buffer().use { output ->
                    while (true) {
                        coroutineContext.ensureActive(); val count = channel.readAvailable(buffer, 0, buffer.size)
                        if (count < 0) break
                        if (count == 0) continue
                        check(total <= 0 || written + count <= total) { "响应超过文件大小" }
                        output.write(buffer, 0, count); written += count; onBytes(count.toLong())
                    }
                }
                val declared = response.headers["Content-Length"]?.toLongOrNull()
                (total <= 0 || written == total) && (declared == null || written == declared)
            }
        } catch (error: CancellationException) { throw error } catch (error: Exception) { false }
    }
    suspend fun mergeChunksToStream(chunkFiles: List<Path>, out: BufferedSink, onProgress: ((Long) -> Unit)? = null,
        onPartDigest: ((Path, String) -> Unit)? = null): Long {
        var written = 0L; val buffer = Buffer()
        for (file in chunkFiles) {
            val input = HashingSource.sha256(FileSystem.SYSTEM.source(file))
            input.use {
                while (true) { coroutineContext.ensureActive(); val count = it.read(buffer, BUFFER_SIZE.toLong()); if (count < 0) break; out.write(buffer, count); written += count; onProgress?.invoke(written) }
                onPartDigest?.invoke(file, it.hash.hex())
            }
        }
        out.flush(); return written
    }
}
