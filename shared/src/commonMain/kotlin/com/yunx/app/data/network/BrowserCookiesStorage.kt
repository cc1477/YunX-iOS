package com.yunx.app.data.network

import io.ktor.client.plugins.cookies.CookiesStorage
import io.ktor.http.Cookie
import io.ktor.http.CookieEncoding
import io.ktor.http.Url

/** Ktor 3.1 captures an explicit Cookie header as URI_ENCODING without decoding its value.
 * Those attribute-free captures are already wire encoded; encoding them again corrupts sessions.
 * Set-Cookie entries retain their own encoding and attributes.
 */
internal class BrowserCookiesStorage(private val delegate: CookiesStorage) : CookiesStorage by delegate {
    override suspend fun addCookie(requestUrl: Url, cookie: Cookie) {
        val headerCapture = cookie.domain == null && cookie.path == null && cookie.encoding == CookieEncoding.URI_ENCODING
        delegate.addCookie(requestUrl, if (headerCapture) cookie.copy(encoding = CookieEncoding.RAW) else cookie)
    }
}
