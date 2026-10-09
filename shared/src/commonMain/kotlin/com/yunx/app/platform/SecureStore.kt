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
/** Missing keys return null; temporarily inaccessible storage must throw, never masquerade as missing. */
expect class SecureStore() {
    fun saveSecret(key: String, bytes: ByteArray)
    fun loadSecret(key: String): ByteArray?
    fun deleteSecret(key: String)
}

/** Desktop derives a local wrapping key from its random file secret; Keychain uses the secret directly. */
internal expect fun localCredentialKey(secret: ByteArray): ByteArray
