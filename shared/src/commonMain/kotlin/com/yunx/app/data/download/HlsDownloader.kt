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
import com.yunx.app.data.network.HttpClients
import com.yunx.app.platform.PlatformLog
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.client.plugins.cookies.HttpCookies
import io.ktor.http.Url
import io.ktor.utils.io.*
import kotlinx.coroutines.*
import okio.*
import kotlin.coroutines.coroutineContext
/** HTTPS-only HLS, bounded playlists/segments, explicit redirects and origin-scoped credentials. */
object HlsDownloader {
    private const val MAX_PLAYLIST_BYTES = 1024 * 1024L
    private const val MAX_SEGMENT_BYTES = 512L * 1024 * 1024
    private const val MAX_TOTAL_BYTES = 100L * 1024 * 1024 * 1024
    suspend fun download(url: String, headers: Map<String, String>, destFile: Path, onBytes: suspend (Long) -> Unit): Boolean {
        val origin = HlsRequestPolicy.initialUrl(url) ?: return false
        // A private empty cookie jar prevents global cookies from bypassing the cross-origin header policy.
        val client = HttpClients.newSessionClient(follow = false, storage = io.ktor.client.plugins.cookies.AcceptAllCookiesStorage())
        suspend fun fetch(start: Url, out: BufferedSink, maximum: Long, notify: suspend (Long) -> Unit): Url {
            var current = start
            repeat(6) { hop ->
                var redirect: Url? = null
                client.prepareGet(current) {
                    HlsRequestPolicy.headersFor(current, origin, headers).forEach { (key, value) -> header(key, value) }
                }.execute { response ->
                    if (response.status.value in 300..399) {
                        check(hop < 5) { "HLS 重定向过多" }
                        redirect = HlsRequestPolicy.resolve(current, response.headers["Location"] ?: error("重定向缺少 Location")) ?: error("拒绝非 HTTPS 重定向")
                    } else {
                        check(response.status.value in 200..299) { "HLS HTTP ${response.status.value}" }
                        val declared = response.headers["Content-Length"]?.toLongOrNull()
                        check(declared == null || declared <= maximum) { "HLS 响应超过限制" }
                        val input = response.bodyAsChannel(); val buffer = ByteArray(BUFFER_SIZE); var written = 0L
                        while (true) {
                            coroutineContext.ensureActive(); val n = input.readAvailable(buffer, 0, buffer.size)
                            if (n < 0) break
                            if (n == 0) continue
                            written += n; check(written <= maximum) { "HLS 响应超过限制" }; out.write(buffer, 0, n); notify(n.toLong())
                        }
                        check(declared == null || declared == written) { "HLS 响应截断" }
                        check(written > 0) { "HLS 响应为空" }
                    }
                }
                if (redirect == null) return current
                current = redirect!!
            }
            error("HLS 重定向过多")
        }
        suspend fun playlist(url: Url): Pair<Url, String> { val buffer = Buffer(); val final = fetch(url, buffer, MAX_PLAYLIST_BYTES) {}; return final to buffer.readUtf8() }
        try {
            var (finalUrl, text) = playlist(origin)
            check(text.trimStart().startsWith("#EXTM3U")) { "不是 HLS 播放列表" }
            val lines = text.lines(); val variant = lines.indexOfFirst { it.startsWith("#EXT-X-STREAM-INF") }
            if (variant >= 0) {
                val next = lines.drop(variant + 1).firstOrNull { it.isNotBlank() && !it.startsWith('#') } ?: error("缺少 HLS 清晰度地址")
                val media = playlist(HlsRequestPolicy.resolve(finalUrl, next.trim()) ?: error("HLS 地址无效")); finalUrl = media.first; text = media.second
            }
            check(!text.contains("#EXT-X-KEY") && !text.contains("#EXT-X-BYTERANGE")) { "HLS 暂不支持加密或 BYTERANGE" }
            val segments = text.lineSequence().map { it.trim() }.filter { it.isNotEmpty() && !it.startsWith('#') }.toList()
            check(segments.isNotEmpty() && segments.size <= 20_000) { "HLS 分片数量无效" }
            val map = text.lines().firstOrNull { it.startsWith("#EXT-X-MAP") }?.let { Regex("URI=\"([^\"]+)\"").find(it)?.groupValues?.get(1) }
            destFile.parent?.let { FileSystem.SYSTEM.createDirectories(it) }
            var total = 0L
            FileSystem.SYSTEM.sink(destFile).buffer().use { out ->
                for (raw in listOfNotNull(map) + segments) {
                    val segment = HlsRequestPolicy.resolve(finalUrl, raw) ?: error("HLS 分片地址无效")
                    fetch(segment, out, MAX_SEGMENT_BYTES) { bytes ->
                        total += bytes; check(total <= MAX_TOTAL_BYTES) { "HLS 总下载量超过限制" }; onBytes(bytes)
                    }
                }
            }
            return true
        } catch (error: CancellationException) { FileSystem.SYSTEM.delete(destFile, false); throw error }
        catch (error: Exception) { PlatformLog.w("YunX-HLS", "HLS 下载失败", error); FileSystem.SYSTEM.delete(destFile, false); return false }
        finally { client.close() }
    }
}
