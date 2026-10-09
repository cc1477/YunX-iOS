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

package com.yunx.app.data.download
import io.ktor.http.*
internal object HlsRequestPolicy {
    private val sensitive = setOf("authorization", "cookie", "origin", "proxy-authorization", "referer")
    fun initialUrl(url: String): Url? = runCatching { Url(url).takeIf { it.protocol == URLProtocol.HTTPS } }.getOrNull()
    fun resolve(base: Url, candidate: String): Url? = runCatching { URLBuilder(base).takeFrom(candidate).build().takeIf { it.protocol == URLProtocol.HTTPS } }.getOrNull()
    fun sameOrigin(left: Url, right: Url) = left.protocol == right.protocol && left.host == right.host && left.port == right.port
    fun headersFor(target: Url, credentialOrigin: Url, headers: Map<String, String>) = if (sameOrigin(target, credentialOrigin)) headers else headers.filterKeys { it.lowercase() !in sensitive }
}
