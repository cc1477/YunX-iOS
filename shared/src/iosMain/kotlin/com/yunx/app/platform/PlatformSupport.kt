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

import kotlinx.cinterop.*
import platform.Foundation.NSRecursiveLock
import platform.Security.SecRandomCopyBytes
import platform.Security.kSecRandomDefault
import platform.CoreCrypto.*
import platform.zlib.*
import platform.posix.memset
import okio.Buffer
@OptIn(ExperimentalForeignApi::class)
actual class PlatformLock actual constructor() {
    private val delegate = NSRecursiveLock()
    actual fun lock() = delegate.lock()
    actual fun unlock() = delegate.unlock()
}
@OptIn(ExperimentalForeignApi::class)
actual fun secureRandomBytes(size: Int): ByteArray = ByteArray(size).also { bytes ->
    if (size > 0) bytes.usePinned { check(SecRandomCopyBytes(kSecRandomDefault, size.toULong(), it.addressOf(0)) == 0) }
}
@OptIn(ExperimentalForeignApi::class)
actual fun aesCrypt(data: ByteArray, key: ByteArray, iv: ByteArray?, encrypt: Boolean): ByteArray = memScoped {
    require(key.size in listOf(16, 24, 32))
    require(iv == null || iv.size == 16)
    val output = ByteArray(data.size + 16)
    val written = alloc<ULongVar>()
    val options = kCCOptionPKCS7Padding or (if (iv == null) kCCOptionECBMode else 0u)
    val input = if (data.isEmpty()) byteArrayOf(0) else data
    key.usePinned { kp -> input.usePinned { dp -> output.usePinned { op ->
        fun run(ivPointer: COpaquePointer?): Int = CCCrypt(
            if (encrypt) kCCEncrypt else kCCDecrypt, kCCAlgorithmAES, options,
            kp.addressOf(0), key.size.toULong(), ivPointer, dp.addressOf(0), data.size.toULong(),
            op.addressOf(0), output.size.toULong(), written.ptr)
        val status = if (iv == null) run(null) else iv.usePinned { run(it.addressOf(0)) }
        check(status == kCCSuccess) { "AES operation failed: $status" }
    } } }
    output.copyOf(written.value.toInt())
}

@OptIn(ExperimentalForeignApi::class)
actual fun gunzip(data: ByteArray): ByteArray = memScoped {
    require(data.isNotEmpty())
    val stream = alloc<z_stream>()
    memset(stream.ptr, 0, sizeOf<z_stream>().toULong())
    stream.zalloc = null; stream.zfree = null; stream.opaque = null
    check(inflateInit2_(stream.ptr, 31, zlibVersion()?.toKString(), sizeOf<z_stream>().toInt()) == Z_OK)
    val result = Buffer()
    try {
        data.usePinned { input ->
            stream.next_in = input.addressOf(0).reinterpret()
            stream.avail_in = data.size.toUInt()
            val chunk = ByteArray(8192)
            var status = Z_OK
            do {
                chunk.usePinned { output ->
                    stream.next_out = output.addressOf(0).reinterpret()
                    stream.avail_out = chunk.size.toUInt()
                    status = inflate(stream.ptr, Z_NO_FLUSH)
                    check(status == Z_OK || status == Z_STREAM_END) { "Invalid gzip payload: $status" }
                    result.write(chunk, 0, chunk.size - stream.avail_out.toInt())
                }
            } while (status != Z_STREAM_END)
        }
    } finally { inflateEnd(stream.ptr) }
    result.readByteArray()
}
