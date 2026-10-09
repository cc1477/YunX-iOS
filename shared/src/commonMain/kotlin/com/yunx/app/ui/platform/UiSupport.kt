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

package com.yunx.app.ui.platform

import androidx.compose.runtime.*
import androidx.lifecycle.*
import androidx.lifecycle.viewmodel.CreationExtras
import com.yunx.app.platform.SettingsStore
import kotlinx.datetime.*
import kotlin.math.roundToLong
import kotlin.time.Duration.Companion.days


class UiPreferences {
    private val store = SettingsStore()
    fun getBoolean(key: String, default: Boolean) = store.getBoolean("ui.$key", default)
    fun getString(key: String, default: String?) = store.getString("ui.$key", default)
    fun edit() = this
    fun putBoolean(key: String, value: Boolean): UiPreferences = apply { store.putBoolean("ui.$key", value) }
    fun putString(key: String, value: String?): UiPreferences = apply { store.putString("ui.$key", value) }
    fun apply() = Unit
}

/** Owns a KMP ViewModel until the containing composition is removed. */
@Composable
inline fun <reified T : ViewModel> viewModel(factory: ViewModelProvider.Factory): T {
    val store = remember { ViewModelStore() }
    DisposableEffect(store) { onDispose { store.clear() } }
    return remember(store) {
        factory.create(T::class, CreationExtras.Empty).also { store.put("screen", it) }
    }
}

/** Native back gestures are wired in Stage 4; every overlay keeps its visible back button. */
@Composable
fun BackHandler(enabled: Boolean = true, onBack: () -> Unit) { }

@Composable
expect fun OnForeground(enabled: Boolean, action: () -> Unit)

fun oneDecimal(value: Double): String {
    val tenths = (value * 10).roundToLong()
    return "${tenths / 10}.${kotlin.math.abs(tenths % 10)}"
}
fun formatUiDate(millis: Long, compact: Boolean = false): String {
    val date = Instant.fromEpochMilliseconds(millis).toLocalDateTime(TimeZone.currentSystemDefault())
    fun two(n: Int) = n.toString().padStart(2, '0')
    val day = "${two(date.monthNumber)}-${two(date.dayOfMonth)}"
    val time = "${two(date.hour)}:${two(date.minute)}"
    val year = Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault()).year
    return if (compact) { if (date.year == year) "$day $time" else "${date.year}-$day" }
    else "${date.year}-$day $time"
}
fun expireAtForDays(days: Int): String = (Clock.System.now() + days.days).toString()
fun parseUiTime(raw: String): Long? {
    val s = raw.trim()
    if (s.isEmpty()) return null
    if (s.all(Char::isDigit) && s.length != 14) {
        return s.toLongOrNull()?.let { if (s.length == 13 || it > 100_000_000_000L) it else it * 1000 }
    }
    return runCatching {
        val normalized = if (s.length == 14 && s.all(Char::isDigit))
            "${s.take(4)}-${s.substring(4,6)}-${s.substring(6,8)}T${s.substring(8,10)}:${s.substring(10,12)}:${s.takeLast(2)}"
        else s.replace('/', '-').replace(' ', 'T')
        runCatching { Instant.parse(normalized) }.getOrElse {
            val local = when (normalized.length) {
                10 -> normalized + "T00:00:00"
                16 -> normalized + ":00"
                else -> normalized
            }
            LocalDateTime.parse(local).toInstant(TimeZone.currentSystemDefault())
        }.toEpochMilliseconds()
    }.getOrNull()
}

fun colorToHsv(color: androidx.compose.ui.graphics.Color): FloatArray {
    val r = color.red; val g = color.green; val b = color.blue
    val max = maxOf(r, g, b); val min = minOf(r, g, b); val delta = max - min
    val hue = when {
        delta == 0f -> 0f
        max == r -> 60f * ((g - b) / delta % 6f)
        max == g -> 60f * ((b - r) / delta + 2f)
        else -> 60f * ((r - g) / delta + 4f)
    }
    return floatArrayOf(if (hue < 0) hue + 360f else hue, if (max == 0f) 0f else delta / max, max)
}
