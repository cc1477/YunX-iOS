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

package com.yunx.app.platform

import platform.Foundation.*
private fun directory(type: ULong, child: String? = null): String {
    val manager = NSFileManager.defaultManager
    val base = (manager.URLsForDirectory(type, NSUserDomainMask).first() as NSURL).path!!
    val path = if (child == null) base else "$base/$child"
    manager.createDirectoryAtPath(path, true, null, null)
    return path
}
actual fun appDataDir(): String = directory(NSApplicationSupportDirectory, "YunX")
actual fun appCacheDir(): String = directory(NSCachesDirectory, "YunX")
actual fun appDownloadDir(): String = directory(NSDocumentDirectory, "Downloads")
