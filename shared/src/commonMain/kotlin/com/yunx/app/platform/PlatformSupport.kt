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

expect class PlatformLock() {
    fun lock()
    fun unlock()
}
inline fun <T> locked(lock: PlatformLock, block: () -> T): T {
    lock.lock()
    try { return block() } finally { lock.unlock() }
}
expect fun secureRandomBytes(size: Int): ByteArray
/** AES with PKCS#7 padding; null IV selects ECB, otherwise CBC. */
expect fun aesCrypt(data: ByteArray, key: ByteArray, iv: ByteArray?, encrypt: Boolean): ByteArray

expect fun gunzip(data: ByteArray): ByteArray
