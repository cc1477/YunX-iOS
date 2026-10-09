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

package com.yunx.app.data.backup
import kotlinx.serialization.json.*
/** Internal builders preserve the upstream backup wire fields without org.json. */
internal class JSONObject private constructor(private val values: MutableMap<String, JsonElement>) {
    constructor() : this(mutableMapOf())
    constructor(text: String) : this(Json.parseToJsonElement(text).jsonObject.toMutableMap())
    constructor(value: JsonObject) : this(value.toMutableMap())
    fun put(key: String, value: Any?): JSONObject { values[key] = when (value) {
        null -> JsonNull
        is JSONArray -> value.json()
        is String -> JsonPrimitive(value)
        is Number -> JsonPrimitive(value)
        is Boolean -> JsonPrimitive(value)
        else -> error("Unsupported backup field")
    }; return this }
    fun optString(key: String, default: String = "") = (values[key] as? JsonPrimitive)?.contentOrNull ?: default
    fun optLong(key: String, default: Long = 0L) = (values[key] as? JsonPrimitive)?.longOrNull ?: default
    fun optJSONArray(key: String) = (values[key] as? JsonArray)?.let { JSONArray(it) }
    fun json() = JsonObject(values.toMap())
    fun toString(indent: Int): String = Json { prettyPrint = indent > 0 }.encodeToString(JsonObject.serializer(), json())
}
internal class JSONArray(private val values: MutableList<JsonElement> = mutableListOf()) {
    constructor(array: JsonArray) : this(array.toMutableList())
    fun put(value: JSONObject): JSONArray { values.add(value.json()); return this }
    fun length() = values.size
    fun optJSONObject(index: Int) = (values.getOrNull(index) as? JsonObject)?.let { JSONObject(it) }
    fun json() = JsonArray(values.toList())
}
