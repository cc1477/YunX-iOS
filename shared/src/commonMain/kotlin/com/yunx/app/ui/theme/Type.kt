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

package com.yunx.app.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** UIKit supplies Dynamic Type scale; the default family resolves to the platform system font. */
private fun systemTextStyle(size: Int, height: Int, weight: FontWeight = FontWeight.Normal) = TextStyle(
    fontFamily = FontFamily.Default, fontWeight = weight,
    fontSize = size.sp, lineHeight = height.sp, letterSpacing = 0.sp
)

val Typography = Typography(
    displayLarge = systemTextStyle(40, 48, FontWeight.Bold),
    displayMedium = systemTextStyle(36, 44, FontWeight.Bold),
    displaySmall = systemTextStyle(32, 40, FontWeight.Bold),
    headlineLarge = systemTextStyle(34, 41, FontWeight.Bold),
    headlineMedium = systemTextStyle(28, 34, FontWeight.SemiBold),
    headlineSmall = systemTextStyle(24, 30, FontWeight.SemiBold),
    titleLarge = systemTextStyle(22, 28, FontWeight.SemiBold),
    titleMedium = systemTextStyle(17, 24, FontWeight.SemiBold),
    titleSmall = systemTextStyle(15, 21, FontWeight.SemiBold),
    bodyLarge = systemTextStyle(17, 24),
    bodyMedium = systemTextStyle(15, 21),
    bodySmall = systemTextStyle(13, 18),
    labelLarge = systemTextStyle(15, 20, FontWeight.Medium),
    labelMedium = systemTextStyle(12, 16, FontWeight.Medium),
    labelSmall = systemTextStyle(11, 14, FontWeight.Medium)
)

internal fun Typography.withSystemBoldText(enabled: Boolean): Typography {
    if (!enabled) return this
    fun TextStyle.emphasized() = copy(fontWeight =
        if ((fontWeight ?: FontWeight.Normal) >= FontWeight.SemiBold) FontWeight.Bold else FontWeight.SemiBold)
    return copy(
        displayLarge = displayLarge.emphasized(), displayMedium = displayMedium.emphasized(), displaySmall = displaySmall.emphasized(),
        headlineLarge = headlineLarge.emphasized(), headlineMedium = headlineMedium.emphasized(), headlineSmall = headlineSmall.emphasized(),
        titleLarge = titleLarge.emphasized(), titleMedium = titleMedium.emphasized(), titleSmall = titleSmall.emphasized(),
        bodyLarge = bodyLarge.emphasized(), bodyMedium = bodyMedium.emphasized(), bodySmall = bodySmall.emphasized(),
        labelLarge = labelLarge.emphasized(), labelMedium = labelMedium.emphasized(), labelSmall = labelSmall.emphasized()
    )
}