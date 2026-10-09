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

import platform.Foundation.NSLog
actual object PlatformLog {
    private fun emit(level: String, tag: String, msg: String, thr: Throwable?) {
        NSLog("%@", "$level/$tag: $msg${thr?.let { "\n${it.stackTraceToString()}" }.orEmpty()}")
    }
    actual fun d(tag: String, msg: String, thr: Throwable?) = emit("D", tag, msg, thr)
    actual fun i(tag: String, msg: String, thr: Throwable?) = emit("I", tag, msg, thr)
    actual fun w(tag: String, msg: String, thr: Throwable?) = emit("W", tag, msg, thr)
    actual fun e(tag: String, msg: String, thr: Throwable?) = emit("E", tag, msg, thr)
}
