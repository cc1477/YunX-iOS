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

package com.yunx.app.ui.login

import androidx.compose.runtime.Composable

/** Platform web login; cookies are scoped to the login host and never logged. */
@Composable
expect fun CookieLoginWebView(url: String, onCookies: (Map<String, String>) -> Unit)

/** Explicit domain scope without changing the existing two-argument expect/JVM ABI. */
internal val LocalCookieLoginDomains = androidx.compose.runtime.staticCompositionLocalOf<List<String>> { emptyList() }
internal data class WebLoginTokenReader(val key: String, val onToken: (String) -> Unit)
internal val LocalWebLoginTokenReader = androidx.compose.runtime.staticCompositionLocalOf<WebLoginTokenReader?> { null }

internal fun isLoginHost(host: String, domains: List<String>): Boolean =
    domains.any { host.equals(it, true) || host.lowercase().endsWith(".${it.lowercase()}") }

internal fun webLoginTokenScript(key: String): String =
    "(() => { try { return localStorage.getItem(${kotlinx.serialization.json.JsonPrimitive(key)}) || ''; } catch (_) { return ''; } })()"

internal fun normalizeWebLoginToken(raw: String): String? {
    val value = raw.trim()
    if (value.isEmpty()) return null
    val token = if (value.startsWith('"')) runCatching {
        (kotlinx.serialization.json.Json.parseToJsonElement(value) as? kotlinx.serialization.json.JsonPrimitive)?.content
    }.getOrNull() ?: return null else value
    return token.takeIf { it.isNotBlank() && it.length <= 16384 && it.none { c -> c.code < 32 || c.code == 127 } }
}

internal fun loginCookieDomains(url: String): List<String> {
    val host = runCatching { io.ktor.http.Url(url).host.lowercase() }.getOrDefault("")
    val known = listOf("quark.cn", "uc.cn", "xunlei.com", "123pan.com", "123pan.cn", "123865.com", "123912.com",
        "115.com", "baidu.com", "139.com", "lanzou.com", "lanzoui.com", "lanzoux.com", "ilanzou.com", "guangya.com")
    val root = known.firstOrNull { host == it || host.endsWith(".$it") } ?: host
    return listOf(root).filter { it.isNotBlank() }
}

@Composable
fun CookieLoginWebView(url: String, loginDomains: List<String>, onCookies: (Map<String, String>) -> Unit) {
    androidx.compose.runtime.CompositionLocalProvider(LocalCookieLoginDomains provides loginDomains) {
        CookieLoginWebView(url, onCookies)
    }
}
