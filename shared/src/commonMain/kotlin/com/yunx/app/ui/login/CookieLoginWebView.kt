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
