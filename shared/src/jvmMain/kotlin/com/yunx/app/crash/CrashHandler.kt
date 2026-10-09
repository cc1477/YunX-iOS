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

package com.yunx.app.crash
import com.yunx.app.platform.appDataDir
import com.yunx.app.util.LogRedactor
import java.io.File
private var installed = false
actual fun installCrashHandler() = synchronized(CrashHandler::class.java) {
    if (installed) return@synchronized
    installed = true
    val previous = Thread.getDefaultUncaughtExceptionHandler()
    Thread.setDefaultUncaughtExceptionHandler { thread, error ->
        runCatching {
            val directory = File(appDataDir(), "crash").apply { mkdirs() }
            File(directory, "crash-${System.currentTimeMillis()}.log").writeText(LogRedactor.line("thread=${thread.name}\n${error.stackTraceToString()}"))
        }
        previous?.uncaughtException(thread, error)
    }
}
