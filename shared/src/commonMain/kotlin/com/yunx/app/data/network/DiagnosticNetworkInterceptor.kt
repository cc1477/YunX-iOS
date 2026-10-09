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
import io.ktor.client.call.save
import io.ktor.http.*
import io.ktor.http.content.*
import kotlinx.coroutines.CancellationException
import kotlin.time.TimeSource

val DiagnosticNetworkInterceptor = createClientPlugin("DiagnosticNetworkInterceptor") {
    on(Send) { request ->
        if (!DiagnosticLog.isEnabled()) return@on proceed(request)
        val start = TimeSource.Monotonic.markNow()
        val safeUrl = LogRedactor.url(request.url.build())
        fun requestSummary(): String? = when (val body = request.body) {
            is TextContent -> LogRedactor.line(body.text.diagnosticPrefix())
            // Form and multipart bodies carry credentials. Omit them instead of serializing secrets.
            else -> null
        }
        try {
            val original = proceed(request)
            val call = if (original.response.status.isSuccess()) original else original.save()
            val response = call.response
            val summary = if (!response.status.isSuccess()) runCatching {
                LogRedactor.line(response.bodyAsText().diagnosticPrefix())
            }.getOrNull() else null
            DiagnosticLog.network(request.method.value, safeUrl, response.status.value,
                start.elapsedNow().inWholeMilliseconds, responseBody = summary)
            call
        } catch (error: Throwable) {
            if (error is CancellationException) throw error
            DiagnosticLog.network(request.method.value, safeUrl, -1,
                start.elapsedNow().inWholeMilliseconds, error = LogRedactor.line(error.message.orEmpty().diagnosticPrefix()), requestBody = requestSummary())
            throw error
        }
    }
}

private fun String.diagnosticPrefix(): String {
    val bytes = encodeToByteArray()
    return bytes.copyOfRange(0, minOf(bytes.size, 1536)).decodeToString()
}
