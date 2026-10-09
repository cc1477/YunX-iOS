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

package com.yunx.app.util
import okio.use

import com.yunx.app.platform.*
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.datetime.Clock
import okio.FileSystem
import okio.Path
import okio.Path.Companion.toPath
import okio.buffer

object DiagnosticLog {
    const val DB = "db"
    const val CRYPTO = "crypto"
    const val DOWNLOAD = "download"
    const val WEBVIEW = "webview"
    const val NETWORK = "network"
    const val OPERATION = "operation"
    private const val LEVEL_INFO = "INFO"
    private const val LEVEL_WARN = "WARN"
    private const val LEVEL_ERROR = "ERROR"
    private const val MAX_LINES_PER_SECOND = 300
    private val lock = PlatformLock()
    private val fileLock = PlatformLock()
    private var enabled = false
    private var windowStart = 0L
    private var windowCount = 0
    private data class Entry(val module: String, val time: Long, val level: String, val line: String)
    private sealed interface Message {
        data class Line(val entry: Entry): Message
        data class Barrier(val done: CompletableDeferred<Unit>): Message
    }
    private val queue = Channel<Message>(2000)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    init {
        scope.launch {
            for (message in queue) when (message) {
                is Message.Line -> runCatching { writeLine(message.entry) }
                    .onFailure { PlatformLog.w("YunX-Diag", "Diagnostic write failed", it) }
                is Message.Barrier -> message.done.complete(Unit)
            }
        }
    }
    fun install() { FileSystem.SYSTEM.createDirectories(dirOf()) }
    fun setEnabled(value: Boolean) { locked(lock) { enabled = value }; if (value) install() }
    fun isEnabled(): Boolean = locked(lock) { enabled }
    fun dirOf(): Path = (appDataDir() + "/diagnostic_logs").toPath()
    fun hasLogs(): Boolean = runCatching { FileSystem.SYSTEM.list(dirOf()).any { it.name.endsWith(".log") } }.getOrDefault(false)
    suspend fun flush(timeoutMs: Long = 2000L) {
        withTimeoutOrNull(timeoutMs) {
            val done = CompletableDeferred<Unit>()
            queue.send(Message.Barrier(done)); done.await()
        }
    }
    private fun allow(): Boolean = locked(lock) {
        val now = Clock.System.now().toEpochMilliseconds()
        if (now - windowStart >= 1000) { windowStart = now; windowCount = 0 }
        windowCount++ < MAX_LINES_PER_SECOND
    }
    fun log(
        module: String,
        event: String,
        level: String = LEVEL_INFO,
        taskId: Any? = null,
        status: String? = null,
        costMs: Long? = null,
        size: Long? = null,
        code: Any? = null,
        summary: String? = null
    ) {
        if (!isEnabled()) return
        if (!allow()) return
        val sb = StringBuilder(96)
        sb.append("event=").append(event)
        if (taskId != null) sb.append(" | task=").append(taskId)
        if (!status.isNullOrBlank()) sb.append(" | status=").append(status)
        if (costMs != null) sb.append(" | cost=").append(costMs).append("ms")
        if (size != null) sb.append(" | size=").append(size)
        if (code != null) sb.append(" | code=").append(code)
        if (!summary.isNullOrBlank()) sb.append(" | ").append(summary.replace('\n', ' ').take(600))
        queue.trySend(Message.Line(Entry(module, Clock.System.now().toEpochMilliseconds(), level, LogRedactor.line(sb.toString()))))
    }

    /** 简写：INFO 级、无附加字段 */
    fun event(module: String, event: String, summary: String? = null) =
        log(module, event, summary = summary)

    fun warn(module: String, event: String, summary: String? = null) =
        log(module, event, level = LEVEL_WARN, summary = summary)

    fun error(module: String, event: String, code: Any? = null, summary: String? = null) =
        log(module, event, level = LEVEL_ERROR, code = code, summary = summary)

    /** 数据库读写：表名 / 操作 / 耗时 / 影响行数 / 错误 */
    fun db(table: String, op: String, costMs: Long, rows: Int = -1, error: String? = null, summary: String? = null) {
        log(
            DB,
            "db_$op",
            level = if (error != null) LEVEL_ERROR else LEVEL_INFO,
            costMs = costMs,
            size = rows.takeIf { it >= 0 }?.toLong(),
            code = error?.let { "SQL_ERROR" },
            summary = buildString {
                append("table=").append(table)
                append(" | rows=").append(if (rows >= 0) rows else "?")
                if (error != null) append(" | err=").append(error)
                if (!summary.isNullOrBlank()) append(" | ").append(summary)
            }
        )
    }

    /**
     * 包一层数据库调用：自动记「耗时 / 影响行数 / 异常」，异常照原样抛出（调用方行为不变）。
     * `rowsOf` 用来从返回值里取影响行数（Room 的 `@Update`/`@Delete` 返回 Int 时用得上）。
     */
    suspend fun <T> dbOp(table: String, op: String, rowsOf: (T) -> Int = { -1 }, block: suspend () -> T): T {
        if (!isEnabled()) return block()
        val start = Clock.System.now().toEpochMilliseconds()
        return try {
            val result = block()
            db(table, op, Clock.System.now().toEpochMilliseconds() - start, rowsOf(result))
            result
        } catch (e: Throwable) {
            db(table, op, Clock.System.now().toEpochMilliseconds() - start, -1, e.message ?: e.toString())
            throw e
        }
    }

    /** 网络请求：方法 / URL（已脱敏）/ 状态码 / 耗时 / 请求体与响应体摘要 */
    fun network(
        method: String,
        url: String,
        code: Int,
        costMs: Long,
        requestBody: String? = null,
        responseBody: String? = null,
        error: String? = null
    ) {
        log(
            NETWORK,
            if (error != null) "http_error" else "http",
            level = if (error != null || code !in 200..299) LEVEL_WARN else LEVEL_INFO,
            status = if (error != null) "failed" else "http_$code",
            costMs = costMs,
            code = code,
            summary = buildString {
                append(method).append(' ').append(LogRedactor.url(url))
                if (error != null) append(" | err=").append(error)
                // 请求体/响应体只在「解析错误、非 200/206」时记（见 DiagnosticNetworkInterceptor）
                if (!requestBody.isNullOrBlank()) append(" | req=").append(oneLine(requestBody))
                if (!responseBody.isNullOrBlank()) append(" | resp=").append(oneLine(responseBody))
            }
        )
    }

    /** WebView：加载 URL / 页面状态 / JS 桥调用 / 错误，全走这一个入口 */
    fun webview(event: String, url: String? = null, code: Any? = null, summary: String? = null) {
        log(
            WEBVIEW,
            event,
            level = if (code != null) LEVEL_WARN else LEVEL_INFO,
            code = code,
            summary = buildString {
                if (!url.isNullOrBlank()) append("url=").append(LogRedactor.url(url))
                if (!summary.isNullOrBlank()) append(if (url.isNullOrBlank()) "" else " | ").append(summary)
            }
        )
    }


    private fun writeLine(entry: Entry) = locked(fileLock) {
        val fs = FileSystem.SYSTEM
        val dir = dirOf(); fs.createDirectories(dir)
        val module = entry.module.replace(Regex("[^a-zA-Z0-9_-]"), "_").take(64)
        val current = dir / "$module.log"
        if ((fs.metadataOrNull(current)?.size ?: 0) >= 2 * 1024 * 1024) {
            fs.delete(dir / "$module.4.log", mustExist = false)
            for (i in 3 downTo 0) {
                val source = if (i == 0) current else dir / "$module.$i.log"
                if (fs.exists(source)) fs.atomicMove(source, dir / "$module.${i+1}.log")
            }
        }
        fs.appendingSink(current).buffer().use { sink ->
            sink.writeUtf8("${entry.time} | ${entry.level} | $module | ${entry.line}\n")
        }
        val files = fs.list(dir).filter { it.name.endsWith(".log") }.sortedBy { fs.metadata(it).lastModifiedAtMillis ?: 0 }
        var total = files.sumOf { fs.metadata(it).size ?: 0 }
        for (file in files) {
            if (total <= 10 * 1024 * 1024) break
            total -= fs.metadata(file).size ?: 0
            fs.delete(file)
        }
    }
    suspend fun exportZip(): Path? {
        flush(3000)
        return runCatching { locked(fileLock) {
            val fs = FileSystem.SYSTEM
            val files = fs.list(dirOf()).filter { it.name.endsWith(".log") }
            if (files.isEmpty()) return@locked null
            val target = (appCacheDir() + "/yunx_diagnostic_logs_${Clock.System.now().toEpochMilliseconds()}.zip").toPath()
            writeLogZip(files, target)
            target
        } }.getOrNull()
    }
    private fun oneLine(text: String): String = LogRedactor.line(text.replace('\n', ' ').replace('\r', ' ')).take(1500)
}
