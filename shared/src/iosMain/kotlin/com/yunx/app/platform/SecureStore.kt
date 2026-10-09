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

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app.platform
import kotlinx.cinterop.*
import platform.CoreFoundation.*
import platform.Security.*
import platform.Foundation.NSDate
import platform.UIKit.UIApplication
import platform.WebKit.WKWebsiteDataStore
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue
import com.yunx.app.data.security.CredentialKeyException
actual class SecureStore actual constructor() {
    private inline fun <T> query(key: String, block: (CFMutableDictionaryRef) -> T): T = memScoped {
        val service = CFStringCreateWithCString(null, "com.yunx.app.ios".cstr.ptr, kCFStringEncodingUTF8)!!
        val account = CFStringCreateWithCString(null, key.cstr.ptr, kCFStringEncodingUTF8)!!
        // Objects stay alive until the Security operation finishes; the dictionary has no retain callbacks.
        val dictionary = CFDictionaryCreateMutable(null, 0, null, null)!!
        try {
            CFDictionarySetValue(dictionary, kSecClass, kSecClassGenericPassword)
            CFDictionarySetValue(dictionary, kSecAttrService, service)
            CFDictionarySetValue(dictionary, kSecAttrAccount, account)
            block(dictionary)
        } finally { CFRelease(dictionary); CFRelease(account); CFRelease(service) }
    }
    private fun check(status: Int) { if (status != errSecSuccess) throw CredentialKeyException.Unavailable("Keychain status=$status") }
    actual fun saveSecret(key: String, bytes: ByteArray) = memScoped {
        val input = if (bytes.isEmpty()) byteArrayOf(0) else bytes
        val value = input.usePinned { CFDataCreate(null, it.addressOf(0).reinterpret(), bytes.size.toLong()) }!!
        val attributes = CFDictionaryCreateMutable(null, 0, null, null)!!
        try {
            CFDictionarySetValue(attributes, kSecValueData, value)
            CFDictionarySetValue(attributes, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlock)
            query(key) { dictionary ->
                val status = SecItemUpdate(dictionary, attributes)
                if (status == errSecItemNotFound) {
                    CFDictionarySetValue(dictionary, kSecValueData, value)
                    CFDictionarySetValue(dictionary, kSecAttrAccessible, kSecAttrAccessibleAfterFirstUnlock)
                    check(SecItemAdd(dictionary, null))
                } else check(status)
            }
        } finally { CFRelease(attributes); CFRelease(value) }
    }
    actual fun loadSecret(key: String): ByteArray? = memScoped {
        query(key) { dictionary ->
            CFDictionarySetValue(dictionary, kSecReturnData, kCFBooleanTrue)
            CFDictionarySetValue(dictionary, kSecMatchLimit, kSecMatchLimitOne)
            val result = alloc<CFTypeRefVar>()
            result.value = null
            val status = SecItemCopyMatching(dictionary, result.ptr)
            // Any lookup failure returns null: common credential recovery owns self-healing.
            if (status != errSecSuccess || result.value == null) {
                result.value?.let { CFRelease(it) }
                return@query null
            }
            val data = result.value!!.reinterpret<__CFData>()
            try {
                val bytes = ByteArray(CFDataGetLength(data).toInt())
                if (bytes.isNotEmpty()) bytes.usePinned { platform.posix.memcpy(it.addressOf(0), CFDataGetBytePtr(data), bytes.size.toULong()) }
                bytes
            } finally { CFRelease(data) }
        }
    }
    actual fun deleteSecret(key: String) = query(key) { dictionary ->
        val status = SecItemDelete(dictionary)
        if (status != errSecItemNotFound) check(status)
    }
}
actual fun clearLoginWebData() {
    dispatch_async(dispatch_get_main_queue()) {
        WKWebsiteDataStore.defaultDataStore().removeDataOfTypes(WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince = NSDate.distantPast, completionHandler = {})
    }
}
/** Prevents auto-lock only. OS background transfers use NSURLSession, not this idle timer. */
actual fun setDownloadIdleTimerDisabled(disabled: Boolean) {
    dispatch_async(dispatch_get_main_queue()) { UIApplication.sharedApplication.idleTimerDisabled = disabled }
}
internal actual fun localCredentialKey(secret: ByteArray): ByteArray = secret.copyOf()
