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

package com.yunx.app.data.network

import com.yunx.app.platform.*
import kotlinx.serialization.json.*
import okio.FileSystem
import okio.Path.Companion.toPath

/** Small non-secret settings files. Tokens deliberately do not use this store. */
internal class LocalSettings(name: String) {
    private val path = (appDataDir() + "/$name.json").toPath()
    private val lock = PlatformLock()
    private fun load(): JsonObject = runCatching {
        FileSystem.SYSTEM.read(path) { Json.parseToJsonElement(readUtf8()).jsonObject }
    }.getOrDefault(buildJsonObject {})
    fun readString(key: String, fallback: String? = null): String? = locked(lock) { (load()[key] as? JsonPrimitive)?.contentOrNull ?: fallback }
    fun writeString(key: String, value: String?) = locked(lock) {
        val values = load().toMutableMap()
        if (value == null) values.remove(key) else values[key] = JsonPrimitive(value)
        FileSystem.SYSTEM.createDirectories(path.parent!!)
        val temporary = (path.toString() + ".tmp").toPath()
        FileSystem.SYSTEM.write(temporary) { writeUtf8(JsonObject(values).toString()) }
        FileSystem.SYSTEM.atomicMove(temporary, path)
    }
}
