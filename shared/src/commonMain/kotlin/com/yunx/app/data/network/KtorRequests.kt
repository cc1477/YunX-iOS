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

import io.ktor.client.HttpClient
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.client.request.forms.*
import io.ktor.http.*
import io.ktor.http.content.TextContent

internal fun HttpRequestBuilder.withUrl(value: String) = apply { url(value) }
internal fun HttpRequestBuilder.withHeader(key: String, value: String) = apply { headers.remove(key); headers.append(key, value) }
internal fun HttpRequestBuilder.withHeaders(value: Headers) = apply { headers.clear(); headers.appendAll(value) }
internal fun HttpRequestBuilder.withHeaders(value: HeadersBuilder) = withHeaders(value.build())
internal fun HttpRequestBuilder.withGet() = apply { method = HttpMethod.Get }
internal fun HttpRequestBuilder.withHead() = apply { method = HttpMethod.Head }
internal fun HttpRequestBuilder.withPost(value: Any) = apply {
    method = HttpMethod.Post
    if (value is ParametersBuilder) {
        contentType(ContentType.Application.FormUrlEncoded)
        setBody(FormDataContent(value.build()))
    } else {
        if (value is FormDataContent) contentType(ContentType.Application.FormUrlEncoded)
        setBody(value)
    }
}
/** Dispatch native Ktor requests, retaining Range and every provider-specific header. */
internal suspend fun HttpClient.executeRequest(builder: HttpRequestBuilder): HttpResponse = when (builder.method) {
    HttpMethod.Get -> get(builder.url.build().toString()) { takeFrom(builder) }
    HttpMethod.Post -> post(builder.url.build().toString()) { takeFrom(builder) }
    HttpMethod.Head -> head(builder.url.build().toString()) { takeFrom(builder) }
    else -> request(builder)
}
/** Already encoded upstream forms remain byte-identical; native FormBody uses FormDataContent. */
internal fun String.toRequestBody(mediaType: String): TextContent = TextContent(this, ContentType.parse(mediaType))
/** Java form encoding (space='+', '*' remains literal, '~' is encoded). */
internal fun formEncode(value: String): String = buildString {
    value.encodeToByteArray().forEach { byte ->
        val b = byte.toInt() and 255
        when {
            b in 65..90 || b in 97..122 || b in 48..57 || b == 45 || b == 95 || b == 46 || b == 42 -> append(b.toChar())
            b == 32 -> append('+')
            else -> { append('%'); append(b.toString(16).uppercase().padStart(2, '0')) }
        }
    }
}
internal fun formDecode(value: String, charset: String = "UTF-8"): String {
    require(charset.equals("UTF-8", true))
    return value.decodeURLQueryComponent(plusIsSpace = true)
}
/** Resolve relative links and remove literal dot segments without decoding escaped separators. */
internal fun resolveUrl(base: String, target: String): String = URLBuilder(base).apply {
    takeFrom(target)
    val parts = encodedPath.split('/')
    val normalized = mutableListOf<String>()
    parts.forEachIndexed { index, part ->
        when (part) {
            "." -> if (index == parts.lastIndex) normalized.add("")
            ".." -> {
                if (normalized.size > 1) normalized.removeAt(normalized.lastIndex)
                if (index == parts.lastIndex) normalized.add("")
            }
            else -> normalized.add(part)
        }
    }
    encodedPath = normalized.joinToString("/")
}.buildString()
internal fun randomUuid(): String {
    val bytes = com.yunx.app.platform.secureRandomBytes(16)
    bytes[6] = ((bytes[6].toInt() and 15) or 64).toByte()
    bytes[8] = ((bytes[8].toInt() and 63) or 128).toByte()
    val hex = bytes.joinToString("") { (it.toInt() and 255).toString(16).padStart(2, '0') }
    return "${hex.take(8)}-${hex.substring(8,12)}-${hex.substring(12,16)}-${hex.substring(16,20)}-${hex.substring(20)}"
}

@OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)
internal fun decodeBase64(value: String, urlSafe: Boolean = false): ByteArray {
    val clean = value.filterNot { it.isWhitespace() }
    val padded = clean + "=".repeat((4 - clean.length % 4) % 4)
    return if (urlSafe) kotlin.io.encoding.Base64.UrlSafe.decode(padded) else kotlin.io.encoding.Base64.decode(padded)
}
