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
import com.yunx.app.platform.SettingsStore
import com.yunx.app.platform.PlatformLock
import com.yunx.app.platform.locked
/** Persistent token storage; reads heal corrupt ciphertext but preserve temporarily inaccessible keys. */
object GitHubCredentialStorage {
    private val prefs = SettingsStore()
    private val lock = PlatformLock()
    fun getToken(): String? = locked(lock) {
        val stored = prefs.getString("github_token_encrypted", null) ?: return@locked null
        try {
            SecureStoreCredentialCipher.shared.decrypt(stored, "github_token").trim().takeIf { it.isNotEmpty() }
                .also { if (!SecureStoreCredentialCipher.shared.isEncrypted(stored) && it != null) setToken(it) }
        } catch (error: Exception) {
            if (!CredentialStore.isKeyFailure(error) || CredentialStore.isKeyLost(error)) {
                prefs.remove("github_token_encrypted")
                if (CredentialStore.isKeyLost(error)) CredentialStore.markKeyLost()
            }
            null
        }
    }
    fun setToken(token: String?) = locked(lock) {
        val normalized = token?.trim()?.takeIf { it.isNotEmpty() }
        if (normalized == null) prefs.remove("github_token_encrypted") else prefs.putString("github_token_encrypted", SecureStoreCredentialCipher.shared.encrypt(normalized, "github_token"))
    }
    fun hasToken() = !getToken().isNullOrBlank()
}
