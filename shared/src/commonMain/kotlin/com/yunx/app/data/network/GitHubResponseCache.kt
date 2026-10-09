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
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.datetime.Clock

internal class ResponseCache(private val capacity: Int) {
    private data class Entry(val value: String?, val fetchedAt: Long, val success: Boolean)
    private data class Flight(val deferred: CompletableDeferred<String?>, val generation: Long)
    private val lock = PlatformLock()
    private val cache = mutableMapOf<String, Entry>()
    private val inFlight = mutableMapOf<String, Flight>()
    private var generation = 0L
    suspend fun getOrFetch(key: String, maxBytes: Int = 0, fetch: suspend () -> String?): String? {
        var cached: Entry? = null
        var owner = false
        val flight = locked(lock) {
            val now = Clock.System.now().toEpochMilliseconds()
            cache[key]?.let { entry ->
                if (now - entry.fetchedAt <= if (entry.success) 600_000 else 60_000) cached = entry
                else cache.remove(key)
            }
            if (cached != null) null else inFlight[key] ?: Flight(CompletableDeferred(), generation).also {
                inFlight[key] = it; owner = true
            }
        }
        cached?.let { return it.value }
        val active = flight!!
        if (!owner) return active.deferred.await()
        try {
            val value = try { fetch() } catch (e: CancellationException) { throw e } catch (_: Exception) { null }
            locked(lock) {
                if (active.generation == generation && (value == null || maxBytes <= 0 || value.encodeToByteArray().size <= maxBytes)) {
                    putLocked(key, value, value != null)
                }
            }
            active.deferred.complete(value)
            return value
        } catch (e: CancellationException) {
            active.deferred.cancel(e)
            throw e
        } finally {
            locked(lock) { if (inFlight[key] === active) inFlight.remove(key) }
        }
    }
    fun put(key: String, value: String?, success: Boolean) = locked(lock) { putLocked(key, value, success) }
    private fun putLocked(key: String, value: String?, success: Boolean) {
        cache[key] = Entry(value, Clock.System.now().toEpochMilliseconds(), success)
        while (cache.size > capacity) cache.entries.minByOrNull { it.value.fetchedAt }?.let { cache.remove(it.key) }
    }
    fun invalidatePrefix(prefix: String) = locked(lock) {
        generation++
        cache.keys.removeAll { it.startsWith(prefix) }
        // Old callers may finish, but future callers start a fresh request and stale results cannot re-cache.
        inFlight.keys.removeAll { it.startsWith(prefix) }
    }
}
object GitHubResponseCache {
    private val cache = ResponseCache(256)
    suspend fun getOrFetch(key: String, maxBytes: Int = 0, fetch: suspend () -> String?): String? = cache.getOrFetch(key, maxBytes, fetch)
    suspend fun put(key: String, value: String?, success: Boolean) = cache.put(key, value, success)
    fun invalidatePrefix(prefix: String) = cache.invalidatePrefix(prefix)
    fun clear() = invalidatePrefix("")
}
