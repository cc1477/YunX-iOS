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

package com.yunx.app.ui.components
import androidx.compose.ui.graphics.ImageBitmap
import com.yunx.app.platform.PlatformLock
import com.yunx.app.platform.locked
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
/** Shared bounded cache for Markdown raster images. Desktop returns placeholders. */
object RemoteImageLoader {
    var mirrorPrefix: String? = null
    private val lock = PlatformLock()
    private val cache = linkedMapOf<String, ImageBitmap>()
    private val permits = Semaphore(4)
    fun cached(url: String): ImageBitmap? = locked(lock) { cache[url.trim()] }
    suspend fun load(url: String): ImageBitmap? {
        val key = url.trim()
        if (key.isBlank()) return null
        cached(key)?.let { return it }
        return permits.withPermit {
            cached(key) ?: loadRemoteBitmap(imageUrl(key))?.also { bitmap ->
                locked(lock) {
                    cache[key] = bitmap
                    // Bound memory by pixels as well as entry count.
                    while (cache.size > 32 || cache.values.sumOf { it.width.toLong() * it.height * 4 } > 32L * 1024 * 1024) {
                        cache.remove(cache.keys.first())
                    }
                }
            }
        }
    }
    fun imageUrl(url: String): String = mirrorPrefix?.takeIf { it.isNotBlank() &&
        (url.startsWith("https://raw.githubusercontent.com/") || url.startsWith("https://github.com/"))
    }?.let { it.trimEnd('/') + "/" + url } ?: url
}
