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

import com.yunx.app.platform.*
import io.ktor.client.HttpClient
import io.ktor.client.engine.ProxyBuilder
import io.ktor.client.engine.http
import io.ktor.client.plugins.*
import io.ktor.client.plugins.cookies.*
import io.ktor.client.plugins.contentnegotiation.*
import io.ktor.client.plugins.logging.*
import io.ktor.http.*
import io.ktor.serialization.kotlinx.json.*

object HttpClients {
    private val lock = PlatformLock()
    private var apiCache: HttpClient? = null
    private var downloadCache: HttpClient? = null
    private var proxyHost: String? = null
    private var proxyPort = 0
    private val redirectClients = mutableMapOf<HttpClient, HttpClient>()
    val cookieStorage = DomainCookiesStorage()

    fun setProxy(host: String?, port: Int) = locked(lock) {
        proxyHost = host?.trim()?.takeIf { it.isNotEmpty() && port in 1..65535 }
        proxyPort = if (proxyHost == null) 0 else port
        // Close stale engines; old client references must be reacquired via the provider.
        redirectClients.values.forEach { it.close() }; redirectClients.clear()
        apiCache?.close(); downloadCache?.close()
        apiCache = null; downloadCache = null
    }
    fun apiClient(): HttpClient = locked(lock) { apiCache ?: buildClient().also { apiCache = it } }
    fun downloadClient(): HttpClient = locked(lock) { downloadCache ?: buildClient().also { downloadCache = it } }
    fun newSessionClient(follow: Boolean = true, storage: CookiesStorage = cookieStorage): HttpClient = locked(lock) { buildClient(follow, storage) }
    internal fun withoutRedirects(source: HttpClient): HttpClient = locked(lock) {
        redirectClients.getOrPut(source) { source.config { followRedirects = false } }
    }
    suspend fun clearCookiesForDomain(domain: String) = cookieStorage.clearDomain(domain)
    // Ktor exposes no cross-engine idle-only pool eviction; kept as a harmless compatibility hook.
    fun evictIdleConnections() = Unit

    private fun buildClient(follow: Boolean = true, cookies: CookiesStorage = cookieStorage): HttpClient = HttpClient(platformHttpEngine()) {
        expectSuccess = false
        followRedirects = follow
        engine { proxyHost?.let { proxy = ProxyBuilder.http(Url("http://$it:$proxyPort")) } }
        install(HttpTimeout) { connectTimeoutMillis = 15_000; socketTimeoutMillis = 60_000; requestTimeoutMillis = 90_000 }
        install(HttpRequestRetry) {
            maxRetries = 1
            retryIf { request, response -> request.method == HttpMethod.Get && response.status.value in 500..599 }
            retryOnExceptionIf { request, cause -> request.method in listOf(HttpMethod.Get, HttpMethod.Head) && cause !is kotlinx.coroutines.CancellationException }
            exponentialDelay()
        }
        install(ContentNegotiation) { json(protocolJson) }
        install(HttpCookies) { storage = cookies }
        install(Logging) {
            // Diagnostic plugin controls logging, ensuring no successful body/header/token leaks.
            level = LogLevel.NONE
            logger = object : Logger { override fun log(message: String) = PlatformLog.d("Ktor", com.yunx.app.util.LogRedactor.line(message)) }
        }
        install(DiagnosticNetworkInterceptor)
    }
}
