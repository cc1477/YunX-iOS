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
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
@Composable
fun RemoteImage(url: String?, contentDescription: String?, modifier: Modifier = Modifier,
    shape: Shape = RectangleShape, contentScale: ContentScale = ContentScale.Crop,
    fallback: ImageVector? = null, fallbackTint: Color = MaterialTheme.colorScheme.onSurfaceVariant,
    autoHeight: Boolean = false, placeholderRatio: Float = 16f / 9f,
    placeholderColor: Color = MaterialTheme.colorScheme.surfaceVariant) {
    val frame = modifier.clip(shape).background(placeholderColor)
    if (autoHeight) {
        BoxWithConstraints(frame, contentAlignment = Alignment.Center) {
            val width = if (constraints.hasBoundedWidth) maxWidth else 240.dp
            val natural = width / placeholderRatio.coerceAtLeast(0.1f)
            val height = if (constraints.hasBoundedHeight) minOf(natural, maxHeight) else natural
            ImageContent(url, contentDescription, Modifier.size(width, height), contentScale, fallback, fallbackTint)
        }
    } else Box(frame, contentAlignment = Alignment.Center) {
        ImageContent(url, contentDescription, Modifier.fillMaxSize(), contentScale, fallback, fallbackTint)
    }
}
@Composable
private fun ImageContent(url: String?, description: String?, modifier: Modifier, scale: ContentScale,
    fallback: ImageVector?, tint: Color) {
    if (!url.isNullOrBlank()) PlatformImage(RemoteImageLoader.imageUrl(url), description, modifier, scale)
    else if (fallback != null) Icon(fallback, description, tint = tint)
}
