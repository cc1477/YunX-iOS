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

@file:OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
package com.yunx.app.data.backup
import com.yunx.app.platform.secureRandomBytes
import com.yunx.app.data.security.PortableCrypto
import kotlin.io.encoding.Base64
/** Wire-compatible YUNX_AUTH_V2: PBKDF2-SHA256 (210000), AES-256-GCM, salt(16), IV(12), tag(16). */
object AuthCrypto {
    fun encrypt(plain: String, password: String): String {
        require(password.length >= 8) { "备份口令至少 8 位" }
        val salt = secureRandomBytes(16); val iv = secureRandomBytes(12)
        val key = PortableCrypto.deriveKey(password, salt, 210_000)
        return try { Base64.encode("YUNX_AUTH_V2".encodeToByteArray() + salt + iv + PortableCrypto.gcm(plain.encodeToByteArray(), key, iv, encrypt = true)) }
        finally { key.fill(0) }
    }
    fun decrypt(data: String, password: String): String {
        val payload = Base64.decode(data.trim()); require(payload.size >= 56) { "加密备份文件已损坏" }
        val magic = payload.copyOfRange(0, 12).decodeToString()
        val iterations = when (magic) { "YUNX_AUTH_V2" -> 210_000; "YUNX_AUTH_V1" -> 10_000; else -> throw IllegalArgumentException("不是有效的加密备份文件") }
        val salt = payload.copyOfRange(12, 28); val iv = payload.copyOfRange(28, 40)
        val key = PortableCrypto.deriveKey(password, salt, iterations)
        return try { PortableCrypto.gcm(payload.copyOfRange(40, payload.size), key, iv, encrypt = false).decodeToString() }
        finally { key.fill(0) }
    }
    fun isEncrypted(data: String): Boolean = runCatching {
        val bytes = Base64.decode(data.trim())
        bytes.size >= 12 && bytes.copyOfRange(0, 12).decodeToString() in listOf("YUNX_AUTH_V1", "YUNX_AUTH_V2")
    }.getOrDefault(false)
}
