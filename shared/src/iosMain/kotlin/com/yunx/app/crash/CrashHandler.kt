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
package com.yunx.app.crash

import kotlinx.cinterop.staticCFunction
import platform.Foundation.*

/** Best-effort NSException log; this cannot catch signals or every Kotlin/Native fatal exception. */
actual fun installCrashHandler() {
    NSSetUncaughtExceptionHandler(staticCFunction { exception: NSException? ->
        // Avoid account values, exception.reason and arbitrary userInfo in the crash log.
        runCatching {
            val message = "${NSDate()}: NSException ${exception?.name ?: "unknown"}\n" +
                exception?.callStackSymbols.orEmpty().joinToString("\n")
            val data = (message as NSString).dataUsingEncoding(NSUTF8StringEncoding)
            data?.writeToFile(NSHomeDirectory() + "/Library/Caches/yunx-nsexception.log", atomically = true)
        }
        Unit
    })
}
