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

@file:OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)

package com.yunx.app.ui.components
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
/** Stage 3: standard Material 3 equivalents; keep caller signatures stable. */
@Composable
fun YunXLoading(modifier: Modifier = Modifier) { CircularProgressIndicator(modifier = modifier) }
@Composable
fun YunXWavyProgress(progress: () -> Float, modifier: Modifier = Modifier,
    color: Color, trackColor: Color, waving: Boolean = true) {
    LinearProgressIndicator(progress = progress, modifier = modifier, color = color, trackColor = trackColor)
}
@Composable
fun YunXWavyLoading(modifier: Modifier = Modifier) { LinearProgressIndicator(modifier = modifier) }
