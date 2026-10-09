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

import java.util.concurrent.locks.ReentrantLock
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.SecretKeySpec
import javax.crypto.spec.IvParameterSpec
actual class PlatformLock actual constructor() {
    private val delegate = ReentrantLock()
    actual fun lock() = delegate.lock()
    actual fun unlock() = delegate.unlock()
}
actual fun secureRandomBytes(size: Int): ByteArray = ByteArray(size).also { SecureRandom().nextBytes(it) }
actual fun aesCrypt(data: ByteArray, key: ByteArray, iv: ByteArray?, encrypt: Boolean): ByteArray {
    val cipher = Cipher.getInstance(if (iv == null) "AES/ECB/PKCS5Padding" else "AES/CBC/PKCS5Padding")
    val mode = if (encrypt) Cipher.ENCRYPT_MODE else Cipher.DECRYPT_MODE
    if (iv == null) cipher.init(mode, SecretKeySpec(key, "AES"))
    else cipher.init(mode, SecretKeySpec(key, "AES"), IvParameterSpec(iv))
    return cipher.doFinal(data)
}

actual fun gunzip(data: ByteArray): ByteArray = java.util.zip.GZIPInputStream(data.inputStream()).use { it.readBytes() }
