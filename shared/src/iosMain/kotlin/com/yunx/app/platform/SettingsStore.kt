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
import platform.Foundation.NSUserDefaults
actual class SettingsStore actual constructor() {
    private val prefs = NSUserDefaults.standardUserDefaults
    actual fun getString(key: String, default: String?): String? = if (prefs.objectForKey(key) == null) default else prefs.stringForKey(key)
    actual fun putString(key: String, value: String?) { if (value == null) prefs.removeObjectForKey(key) else prefs.setObject(value, forKey = key) }
    actual fun getBoolean(key: String, default: Boolean): Boolean = if (prefs.objectForKey(key) == null) default else prefs.boolForKey(key)
    actual fun putBoolean(key: String, value: Boolean) { prefs.setBool(value, forKey = key) }
    actual fun getInt(key: String, default: Int): Int = if (prefs.objectForKey(key) == null) default else prefs.integerForKey(key).toInt()
    actual fun putInt(key: String, value: Int) { prefs.setInteger(value.toLong(), forKey = key) }
    actual fun getLong(key: String, default: Long): Long = if (prefs.objectForKey(key) == null) default else prefs.integerForKey(key)
    actual fun putLong(key: String, value: Long) { prefs.setInteger(value, forKey = key) }
    actual fun getFloat(key: String, default: Float): Float = if (prefs.objectForKey(key) == null) default else prefs.floatForKey(key)
    actual fun putFloat(key: String, value: Float) { prefs.setFloat(value, forKey = key) }
    actual fun remove(key: String) { prefs.removeObjectForKey(key) }
}
