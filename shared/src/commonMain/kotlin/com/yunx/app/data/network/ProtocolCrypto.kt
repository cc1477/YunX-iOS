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

import okio.ByteString.Companion.toByteString
import kotlinx.datetime.*
internal fun md5Hex(data: ByteArray): String = data.toByteString().md5().hex()
internal fun sha1Hex(data: ByteArray): String = data.toByteString().sha1().hex()
internal fun crc32(data: ByteArray): Long {
    var crc = -1
    for (byte in data) {
        crc = crc xor (byte.toInt() and 255)
        repeat(8) { crc = (crc ushr 1) xor (if (crc and 1 != 0) 0xedb88320.toInt() else 0) }
    }
    return (crc.inv().toLong() and 0xffffffffL)
}
internal fun localSignTime(): String {
    val t = Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault())
    return "${t.date} ${t.hour.toString().padStart(2,'0')}:${t.minute.toString().padStart(2,'0')}:${t.second.toString().padStart(2,'0')}"
}
/** Fixed-width unsigned arithmetic for the 115 public exponent 65537. No private key operations. */
internal fun rsaPublicBlock(input: ByteArray, modulusHex: String): ByteArray {
    val modulus = modulusHex.chunked(2).map { it.toInt(16) }.toIntArray()
    val size = modulus.size + 1
    val n = IntArray(size); modulus.copyInto(n, 1)
    fun compare(a: IntArray, b: IntArray): Int {
        for (i in a.indices) if (a[i] != b[i]) return a[i].compareTo(b[i])
        return 0
    }
    fun addMod(a: IntArray, b: IntArray): IntArray {
        val out = IntArray(size); var carry = 0
        for (i in size-1 downTo 0) { val v = a[i] + b[i] + carry; out[i] = v and 255; carry = v ushr 8 }
        if (compare(out, n) >= 0) {
            var borrow = 0
            for (i in size-1 downTo 0) { val v = out[i] - n[i] - borrow; out[i] = v and 255; borrow = if (v < 0) 1 else 0 }
        }
        return out
    }
    fun multiply(a: IntArray, b: IntArray): IntArray {
        var result = IntArray(size)
        for (digit in b) for (bit in 7 downTo 0) {
            result = addMod(result, result)
            if (digit and (1 shl bit) != 0) result = addMod(result, a)
        }
        return result
    }
    require(input.size <= modulus.size)
    var base = IntArray(size)
    input.forEachIndexed { i, b -> base[size-input.size+i] = b.toInt() and 255 }
    require(compare(base, n) < 0) { "115 RSA block exceeds modulus" }
    val original = base.copyOf()
    repeat(16) { base = multiply(base, base) }
    base = multiply(base, original)
    return ByteArray(modulus.size) { base[it+1].toByte() }
}
