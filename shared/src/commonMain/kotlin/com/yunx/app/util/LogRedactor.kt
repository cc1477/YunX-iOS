package com.yunx.app.util

import io.ktor.http.Url
import kotlinx.serialization.json.*

/** Exported diagnostics must never contain credentials or capability URLs. */
object LogRedactor {
    private val absoluteUrl = Regex("""https?://[^\s\"'<>]+""", RegexOption.IGNORE_CASE)
    private const val secrets = "cookie|set-cookie|authorization|proxy-authorization|.*token|.*password|passwd|pwd|passcode|captcha|otp|verification_code|phone|mobile|bduss|stoken|__p[a-z]+|rmkey|signature|sign|secret|credential|session[_-]?id"
    private val secretKey = Regex("^(?:$secrets)$", RegexOption.IGNORE_CASE)
    private val header = Regex("""(?im)\b(cookie|set-cookie|authorization|proxy-authorization)\s*[:=]\s*[^\r\n]+""")
    private val assignment = Regex("""(?i)([\"']?\b(?:[\w-]*token|[\w-]*password|passwd|pwd|passcode|captcha|otp|verification_code|phone|mobile|bduss|stoken|__p[a-z]+|rmkey|signature|sign|secret|credential|session[_-]?id)\b[\"']?\s*[:=]\s*)(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s,;|}]+)""")

    fun url(value: Any?): String {
        val raw = value?.toString()?.takeIf { it.isNotBlank() } ?: return "<none>"
        return runCatching {
            if (!Regex("^[A-Za-z][A-Za-z0-9+.-]*://").containsMatchIn(raw)) return@runCatching "<relative-url>"
            val uri = Url(raw)
            val scheme = uri.protocol.name.lowercase()
            val host = uri.host.lowercase().takeIf { it.isNotEmpty() } ?: return@runCatching "<$scheme-url>"
            val defaultPort = (scheme == "https" && uri.port == 443) || (scheme == "http" && uri.port == 80)
            val port = if (uri.port >= 0 && !defaultPort) ":${uri.port}" else ""
            "$scheme://$host$port"
        }.getOrDefault("<invalid-url>")
    }

    private fun redactJson(element: JsonElement): JsonElement = when (element) {
        is JsonObject -> JsonObject(element.mapValues { (key, value) ->
            if (secretKey.matches(key)) JsonPrimitive("<redacted>") else redactJson(value)
        })
        is JsonArray -> JsonArray(element.map(::redactJson))
        is JsonPrimitive -> if (element.isString) JsonPrimitive(text(element.content)) else element
        else -> element
    }

    private fun text(value: String): String {
        val withoutPayloads = Regex("""(?im)\b(req|resp)\s*=\s*[^\r\n]*""").replace(value) { "${it.groupValues[1]}=<omitted>" }
        val withoutHeaders = header.replace(withoutPayloads) { "${it.groupValues[1]}=<redacted>" }
        val withoutSecrets = assignment.replace(withoutHeaders) { "${it.groupValues[1]}<redacted>" }
        return absoluteUrl.replace(withoutSecrets) { url(it.value) }
            .replace(Regex("(?<![0-9])1[3-9][0-9]{9}(?![0-9])"), "<phone>")
    }

    fun line(value: String): String {
        val trimmed = value.trim()
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
            runCatching { Json.parseToJsonElement(trimmed) }.getOrNull()?.let { return redactJson(it).toString() }
        }
        return text(value)
    }
}
