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

import com.yunx.app.util.DiagnosticLog
import com.yunx.app.util.LogRedactor
import io.ktor.client.plugins.api.*
import io.ktor.client.statement.*
import io.ktor.http.*
import kotlinx.coroutines.CancellationException
import kotlin.time.TimeSource

val DiagnosticNetworkInterceptor = createClientPlugin("DiagnosticNetworkInterceptor") {
    on(Send) { request ->
        if (!DiagnosticLog.isEnabled()) return@on proceed(request)
        val start = TimeSource.Monotonic.markNow()
        val safeUrl = LogRedactor.url(request.url.build())
        val requestId = kotlin.random.Random.nextInt(1, Int.MAX_VALUE)
        val range = request.headers["Range"]?.takeIf { it.matches(Regex("bytes=[0-9]*-[0-9]*")) }
        DiagnosticLog.log(DiagnosticLog.NETWORK, "http_started", taskId = requestId,
            summary = request.method.value + " " + safeUrl + " | ranged=" + (range != null) +
                " | authenticated=" + request.headers.names().any { it.equals("Cookie", true) || it.equals("Authorization", true) })
        try {
            // Never consume or copy payloads: they may contain credentials, file names or large downloads.
            val call = proceed(request)
            val response = call.response
            DiagnosticLog.network(request.method.value, safeUrl, response.status.value,
                start.elapsedNow().inWholeMilliseconds, requestId = requestId)
            DiagnosticLog.log(DiagnosticLog.NETWORK, "http_metadata", taskId = requestId,
                size = response.headers[HttpHeaders.ContentLength]?.toLongOrNull(),
                summary = "type=" + response.headers[HttpHeaders.ContentType]?.substringBefore(';')
                    ?.takeIf { it.matches(Regex("[a-zA-Z0-9.+-]+/[a-zA-Z0-9.+-]+")) }.orEmpty() +
                    " | range=" + range.orEmpty())
            call
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            DiagnosticLog.network(request.method.value, safeUrl, -1,
                start.elapsedNow().inWholeMilliseconds, error = error::class.simpleName, requestId = requestId)
            DiagnosticLog.exception(DiagnosticLog.NETWORK, "transport_exception", error)
            throw error
        }
    }
}
