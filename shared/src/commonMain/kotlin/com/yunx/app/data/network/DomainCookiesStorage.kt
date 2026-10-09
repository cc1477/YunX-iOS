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

package com.yunx.app.data.network

import io.ktor.client.plugins.cookies.*
import io.ktor.http.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** One AcceptAll storage per cookie domain allows deletion without losing unrelated sessions. */
class DomainCookiesStorage : CookiesStorage {
    private val mutex = Mutex()
    private val domains = mutableMapOf<String, AcceptAllCookiesStorage>()
    override suspend fun addCookie(requestUrl: Url, cookie: Cookie) = mutex.withLock {
        val domain = (cookie.domain ?: requestUrl.host).trimStart('.').lowercase()
        domains.getOrPut(domain) { AcceptAllCookiesStorage() }.addCookie(requestUrl, cookie)
    }
    override suspend fun get(requestUrl: Url): List<Cookie> = mutex.withLock {
        domains.values.flatMap { it.get(requestUrl) }
    }
    suspend fun clearDomain(domain: String) = mutex.withLock {
        val target = domain.trimStart('.').lowercase()
        val keys = domains.keys.filter { it == target || it.endsWith(".$target") }
        keys.forEach { domains.remove(it)?.close() }
    }
    // Client clones share this storage; closing a client must not delete its replacement's cookies.
    override fun close() = Unit
}
