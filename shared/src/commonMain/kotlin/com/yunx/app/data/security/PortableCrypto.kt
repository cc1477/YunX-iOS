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

package com.yunx.app.data.security
import com.yunx.app.platform.aesCrypt
import okio.ByteString.Companion.toByteString
/** GCM built from the platform AES block primitive: 96-bit nonce, full 128-bit tag, purpose AAD. */
internal object PortableCrypto {
    private fun block(key: ByteArray, value: ByteArray): ByteArray = aesCrypt(value, key, null, true).copyOf(16)
    private fun xor(a: ByteArray, b: ByteArray) = ByteArray(16) { (a[it].toInt() xor b[it].toInt()).toByte() }
    private fun multiply(x: ByteArray, y: ByteArray): ByteArray {
        val z = ByteArray(16); val v = y.copyOf()
        repeat(128) { bit ->
            if ((x[bit / 8].toInt() ushr (7 - bit % 8)) and 1 != 0) repeat(16) { z[it] = (z[it].toInt() xor v[it].toInt()).toByte() }
            val low = v[15].toInt() and 1
            for (i in 15 downTo 0) v[i] = (((v[i].toInt() and 255) ushr 1) or (if (i > 0) (v[i-1].toInt() and 1) shl 7 else 0)).toByte()
            if (low != 0) v[0] = (v[0].toInt() xor 0xe1).toByte()
        }
        return z
    }
    private fun tag(key: ByteArray, nonce: ByteArray, aad: ByteArray, ciphertext: ByteArray): ByteArray {
        val h = block(key, ByteArray(16)); var state = ByteArray(16)
        fun feed(bytes: ByteArray) { var at = 0; while (at < bytes.size) { val next = ByteArray(16); bytes.copyInto(next, 0, at, minOf(at + 16, bytes.size)); state = multiply(xor(state, next), h); at += 16 } }
        feed(aad); feed(ciphertext)
        val lengths = ByteArray(16)
        for (i in 0..7) { lengths[7-i] = ((aad.size.toLong() * 8) ushr (i * 8)).toByte(); lengths[15-i] = ((ciphertext.size.toLong() * 8) ushr (i * 8)).toByte() }
        state = multiply(xor(state, lengths), h)
        return xor(state, block(key, nonce + byteArrayOf(0, 0, 0, 1)))
    }
    private fun ctr(key: ByteArray, nonce: ByteArray, input: ByteArray): ByteArray {
        val output = ByteArray(input.size); val counter = nonce + byteArrayOf(0, 0, 0, 1)
        var at = 0
        while (at < input.size) {
            for (i in 15 downTo 12) { counter[i] = (counter[i].toInt() + 1).toByte(); if (counter[i] != 0.toByte()) break }
            val mask = block(key, counter)
            repeat(minOf(16, input.size - at)) { output[at+it] = (input[at+it].toInt() xor mask[it].toInt()).toByte() }; at += 16
        }
        return output
    }
    fun gcm(data: ByteArray, key: ByteArray, nonce: ByteArray, aad: ByteArray = byteArrayOf(), encrypt: Boolean): ByteArray {
        require(key.size == 32 && nonce.size == 12)
        if (encrypt) { val ciphertext = ctr(key, nonce, data); return ciphertext + tag(key, nonce, aad, ciphertext) }
        require(data.size >= 16) { "GCM ciphertext is truncated" }
        val ciphertext = data.copyOfRange(0, data.size - 16); val expected = tag(key, nonce, aad, ciphertext)
        var difference = 0
        repeat(16) { difference = difference or (expected[it].toInt() xor data[ciphertext.size+it].toInt()) }
        require(difference == 0) { "GCM authentication failed" }
        return ctr(key, nonce, ciphertext)
    }
    /** PBKDF2-HMAC-SHA256, one 32-byte block, UTF-8 password bytes. */
    fun deriveKey(password: String, salt: ByteArray, iterations: Int): ByteArray {
        require(iterations > 0)
        val passwordBytes = password.encodeToByteArray().toByteString()
        fun hmac(bytes: ByteArray) = bytes.toByteString().hmacSha256(passwordBytes).toByteArray()
        var u = hmac(salt + byteArrayOf(0, 0, 0, 1)); val result = u.copyOf()
        repeat(iterations - 1) { u = hmac(u); repeat(32) { result[it] = (result[it].toInt() xor u[it].toInt()).toByte() } }
        u.fill(0)
        return result
    }
}
