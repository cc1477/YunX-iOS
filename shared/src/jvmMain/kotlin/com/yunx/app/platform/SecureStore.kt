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
import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermissions
/** Desktop fallback: private files, not a hardware-backed keystore. The credential key is random 32 bytes. */
actual class SecureStore actual constructor() {
    private val directory = File(System.getProperty("user.home"), ".yunx-ios").apply { mkdirs() }
    private fun file(key: String) = File(directory, if (key == "yunx.credentials.v1") "secret.key" else "secret-${java.security.MessageDigest.getInstance("SHA-256").digest(key.toByteArray()).joinToString("") { "%02x".format(it) }}.key")
    actual fun saveSecret(key: String, bytes: ByteArray) {
        val target = file(key)
        val temporary = Files.createTempFile(directory.toPath(), "secret-", ".tmp")
        try {
            runCatching { Files.setPosixFilePermissions(directory.toPath(), PosixFilePermissions.fromString("rwx------")) }
            runCatching { Files.setPosixFilePermissions(temporary, PosixFilePermissions.fromString("rw-------")) }
            Files.write(temporary, bytes)
            Files.move(temporary, target.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally { Files.deleteIfExists(temporary) }
    }
    actual fun loadSecret(key: String): ByteArray? = file(key).let { if (it.exists()) it.readBytes() else null }
    actual fun deleteSecret(key: String) { Files.deleteIfExists(file(key).toPath()) }
}
/** Simplified FileCredentialCipher policy: domain-separated PBKDF2, cached by the common cipher. */
internal actual fun localCredentialKey(secret: ByteArray): ByteArray = com.yunx.app.data.security.PortableCrypto.deriveKey(
    secret.joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') },
    "YUNX_DESKTOP_V1".toByteArray(), 10_000
)
