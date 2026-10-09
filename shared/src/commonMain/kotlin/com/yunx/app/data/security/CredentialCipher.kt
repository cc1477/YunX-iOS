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
package com.yunx.app.data.security
import com.yunx.app.platform.*
import kotlin.io.encoding.Base64
internal sealed class CredentialKeyException(message: String, cause: Throwable? = null) : Exception(message, cause) {
    class PermanentlyInvalid(reason: String, cause: Throwable? = null) : CredentialKeyException("本机密钥不可用：$reason", cause)
    class Unavailable(reason: String, cause: Throwable? = null) : CredentialKeyException("本机密钥暂时不可用：$reason", cause)
}
object CredentialStore {
    private val prefs = SettingsStore()
    internal fun isKeyFailure(error: Throwable) = error is CredentialKeyException
    internal fun isKeyLost(error: Throwable) = error is CredentialKeyException.PermanentlyInvalid
    internal fun markKeyLost() { prefs.putBoolean("credential_key_lost", true) }
    fun hasKeyLostNotice() = prefs.getBoolean("credential_key_lost", false)
    fun consumeKeyLostNotice() = prefs.remove("credential_key_lost")
    fun installRecovery() { SecureStoreCredentialCipher.shared.onKeyProvisioned { markKeyLost() } }
}
internal interface CredentialCipher {
    fun encrypt(plaintext: String, purpose: String): String
    fun decrypt(stored: String, purpose: String): String
    fun isEncrypted(stored: String): Boolean
    fun onKeyProvisioned(listener: () -> Unit)
}
internal class SecureStoreCredentialCipher(private val store: SecureStore = SecureStore()) : CredentialCipher {
    private val lock = PlatformLock()
    private var cachedKey: ByteArray? = null
    private var listener: (() -> Unit)? = null
    override fun onKeyProvisioned(listener: () -> Unit) { locked(lock) { this.listener = listener } }
    private fun key(): ByteArray = locked(lock) {
        cachedKey ?: try {
            val stored = store.loadSecret("yunx.credentials.v1")
            val key = if (stored == null) {
                secureRandomBytes(32).also { store.saveSecret("yunx.credentials.v1", it); listener?.invoke() }
            } else {
                if (stored.size != 32) {
                    // A malformed local key cannot authenticate old ciphertext. Replace it once, and let each record heal separately.
                    store.deleteSecret("yunx.credentials.v1")
                    secureRandomBytes(32).also { store.saveSecret("yunx.credentials.v1", it); CredentialStore.markKeyLost(); listener?.invoke() }
                } else stored
            }
            localCredentialKey(key).also { cachedKey = it }
        } catch (error: CredentialKeyException) { throw error }
        catch (error: Exception) { throw CredentialKeyException.Unavailable("无法访问安全存储", error) }
    }
    override fun encrypt(plaintext: String, purpose: String): String {
        val nonce = secureRandomBytes(12)
        val encrypted = PortableCrypto.gcm(plaintext.encodeToByteArray(), key(), nonce, purpose.encodeToByteArray(), true)
        return "yunx:v1:${Base64.encode(nonce)}:${Base64.encode(encrypted)}"
    }
    override fun decrypt(stored: String, purpose: String): String {
        if (!isEncrypted(stored)) return stored
        val parts = stored.split(':')
        require(parts.size == 4 && parts[1] == "v1") { "不支持的凭证格式" }
        return PortableCrypto.gcm(Base64.decode(parts[3]), key(), Base64.decode(parts[2]), purpose.encodeToByteArray(), false).decodeToString()
    }
    override fun isEncrypted(stored: String) = stored.startsWith("yunx:")
    companion object { val shared = SecureStoreCredentialCipher() }
}

/** Source compatibility for callers ported from the Android composition root. */
internal typealias AndroidKeystoreCredentialCipher = SecureStoreCredentialCipher
