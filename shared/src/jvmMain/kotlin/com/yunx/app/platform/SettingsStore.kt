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

package com.yunx.app.platform
import java.util.prefs.Preferences
actual class SettingsStore actual constructor() {
    private val prefs = Preferences.userRoot().node("yunx")
    actual fun getString(key: String, default: String?): String? = prefs.get(key, default)
    actual fun putString(key: String, value: String?) { if (value == null) prefs.remove(key) else prefs.put(key, value); prefs.flush() }
    actual fun getBoolean(key: String, default: Boolean): Boolean = prefs.getBoolean(key, default)
    actual fun putBoolean(key: String, value: Boolean) { prefs.putBoolean(key, value); prefs.flush() }
    actual fun getInt(key: String, default: Int): Int = prefs.getInt(key, default)
    actual fun putInt(key: String, value: Int) { prefs.putInt(key, value); prefs.flush() }
    actual fun getLong(key: String, default: Long): Long = prefs.getLong(key, default)
    actual fun putLong(key: String, value: Long) { prefs.putLong(key, value); prefs.flush() }
    actual fun getFloat(key: String, default: Float): Float = prefs.getFloat(key, default)
    actual fun putFloat(key: String, value: Float) { prefs.putFloat(key, value); prefs.flush() }
    actual fun remove(key: String) { prefs.remove(key); prefs.flush() }
}
