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

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app.ui.components
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Box
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import androidx.compose.ui.layout.ContentScale
import kotlinx.cinterop.*
import kotlinx.coroutines.suspendCancellableCoroutine
import platform.Foundation.*
import platform.UIKit.UIImage
import platform.posix.memcpy
import kotlin.coroutines.resume

/** URLSession -> UIImage validation -> Compose raster; request cancels with the composition. */
@Composable
private fun AsyncImage(url: String, contentDescription: String?, modifier: Modifier, contentScale: ContentScale) {
    var bitmap by remember(url) { mutableStateOf<ImageBitmap?>(null) }
    var loading by remember(url) { mutableStateOf(true) }
    LaunchedEffect(url) { try { bitmap = RemoteImageLoader.load(url) } finally { loading = false } }
    val loaded = bitmap
    if (loaded != null) Image(loaded, contentDescription, modifier, contentScale = contentScale)
    else Box(modifier, contentAlignment = Alignment.Center) {
        if (loading) CircularProgressIndicator() else Text(contentDescription ?: "图片加载失败")
    }
}
@Composable
actual fun PlatformImage(url: String, contentDescription: String?, modifier: Modifier, contentScale: ContentScale) {
    AsyncImage(url, contentDescription, modifier, contentScale)
}
internal actual suspend fun loadRemoteBitmap(url: String): ImageBitmap? {
    val nativeUrl = NSURL.URLWithString(url) ?: return null
    if (nativeUrl.scheme != "https" && nativeUrl.scheme != "http") return null
    val data = suspendCancellableCoroutine<NSData?> { continuation ->
        val request = NSURLRequest.requestWithURL(nativeUrl)
        val task = NSURLSession.sharedSession.dataTaskWithRequest(request) { data, response, error ->
            val status = (response as? NSHTTPURLResponse)?.statusCode ?: 0
            if (continuation.isActive) continuation.resume(if (error == null && status in 200L..299L) data else null)
        }
        continuation.invokeOnCancellation { task.cancel() }
        task.resume()
    } ?: return null
    if (data.length == 0uL || data.length > 8uL * 1024uL * 1024uL) return null
    return runCatching {
        // UIImage verifies the format; dimensions cap decoding of unusually large assets.
        val image = UIImage.imageWithData(data) ?: return null
        val pixels = image.size.useContents { width * height } * image.scale * image.scale
        if (pixels > 8_000_000) return null
        val bytes = ByteArray(data.length.toInt())
        bytes.usePinned { memcpy(it.addressOf(0), data.bytes, data.length) }
        org.jetbrains.skia.Image.makeFromEncoded(bytes).toComposeImageBitmap()
    }.getOrNull()
}
