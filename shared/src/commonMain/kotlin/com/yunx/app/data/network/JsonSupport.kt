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

import kotlinx.serialization.json.*

@OptIn(kotlinx.serialization.ExperimentalSerializationApi::class)
internal val protocolJson = Json { isLenient = true; ignoreUnknownKeys = true; allowTrailingComma = true }
internal fun parseJsonObject(text: String): JsonObject = protocolJson.parseToJsonElement(normalizeJsonQuotes(text)).jsonObject
internal fun jsonArrayOf(text: String): JsonArray = protocolJson.parseToJsonElement(normalizeJsonQuotes(text)).jsonArray
internal fun jsonArrayOf(values: Collection<*>): JsonArray = JsonArray(values.map(::jsonValue))
internal fun jsonValue(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is Boolean -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Collection<*> -> JsonArray(value.map(::jsonValue))
    else -> JsonPrimitive(value.toString())
}
/** Immutable copy: callers must retain the returned object/array. */
internal fun JsonObject.withField(key: String, value: Any?): JsonObject = buildJsonObject {
    this@withField.forEach { (k, v) -> if (k != key || value != null) put(k, v) }
    if (value != null) put(key, jsonValue(value))
}
internal fun JsonArray.withField(value: Any?): JsonArray = buildJsonArray {
    this@withField.forEach { add(it) }; add(jsonValue(value))
}
private fun JsonElement?.textOrNull(): String? = when (this) {
    null, JsonNull -> null
    is JsonPrimitive -> contentOrNull
    else -> toString()
}
internal fun JsonObject.optString(key: String, fallback: String = ""): String = this[key].textOrNull() ?: fallback
internal fun JsonArray.optString(index: Int, fallback: String = ""): String = getOrNull(index).textOrNull() ?: fallback
private fun JsonElement?.number(): Double? = (this as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()
internal fun JsonObject.optInt(key: String, fallback: Int = 0): Int = this[key].number()?.toInt() ?: fallback
internal fun JsonObject.optLong(key: String, fallback: Long = 0L): Long = (this[key] as? JsonPrimitive)?.longOrNull ?: this[key].number()?.toLong() ?: fallback
internal fun JsonObject.optDouble(key: String, fallback: Double = Double.NaN): Double = this[key].number() ?: fallback
internal fun JsonObject.optBoolean(key: String, fallback: Boolean = false): Boolean = when ((this[key] as? JsonPrimitive)?.contentOrNull?.lowercase()) {
    "true" -> true; "false" -> false; else -> fallback
}
internal fun JsonObject.optJsonObject(key: String): JsonObject? = this[key] as? JsonObject
internal fun JsonObject.optJsonArray(key: String): JsonArray? = this[key] as? JsonArray
internal fun JsonArray.optJsonObject(index: Int): JsonObject? = getOrNull(index) as? JsonObject
internal fun JsonArray.optJsonArray(index: Int): JsonArray? = getOrNull(index) as? JsonArray
internal fun JsonObject.has(key: String): Boolean = containsKey(key)
internal fun JsonObject.isNull(key: String): Boolean = this[key] == null || this[key] == JsonNull
internal fun JsonArray.isNull(index: Int): Boolean = getOrNull(index) == null || getOrNull(index) == JsonNull
internal fun JsonArray.length(): Int = size
internal fun JsonObject.keys(): Iterator<String> = keys.iterator()
/** Preserve org.json primitive inspection at the few generic parsing boundaries. */
internal fun JsonObject.opt(key: String): Any? = when (val value = this[key]) {
    null, JsonNull -> null
    is JsonPrimitive -> if (value.isString) value.content else value.longOrNull ?: value.doubleOrNull ?: value.booleanOrNull
    else -> value
}

internal fun JsonObject.edit(block: JsonObjectBuilder.() -> Unit): JsonObject = buildJsonObject {
    this@edit.forEach { (key, value) -> put(key, value) }
    block()
}

/** org.json accepted single-quoted object keys/values; normalize only outside double-quoted strings. */
private fun normalizeJsonQuotes(text: String): String = buildString {
    var quote: Char? = null
    var escaped = false
    for (c in text) {
        if (escaped) {
            if (quote == '\'' && c == '\'') append(c)
            else { append('\\'); append(c) }
            escaped = false
        } else if (quote != null && c == '\\') escaped = true
        else if (quote == null && (c == '\'' || c == '"')) { quote = c; append('"') }
        else if (c == quote) { quote = null; append('"') }
        else if (quote == '\'' && c == '"') append("\\\"")
        else append(c)
    }
    if (escaped) append('\\')
}
