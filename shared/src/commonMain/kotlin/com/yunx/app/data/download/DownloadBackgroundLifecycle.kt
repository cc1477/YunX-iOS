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

package com.yunx.app.data.download

import com.yunx.app.platform.PlatformLock
import com.yunx.app.platform.locked

/** iOS installs this hook before the Compose UI creates its manager; JVM needs no lifecycle hook. */
object DownloadBackgroundLifecycle {
    private val lock = PlatformLock()
    private var manager: DownloadManager? = null
    private var onRegister: ((DownloadManager) -> Unit)? = null
    fun install(callback: (DownloadManager) -> Unit) {
        val existing = locked(lock) { onRegister = callback; manager }
        existing?.let(callback)
    }
    internal fun register(value: DownloadManager) {
        val callback = locked(lock) { manager = value; onRegister }
        callback?.invoke(value)
    }
    fun current(): DownloadManager? = locked(lock) { manager }
}
