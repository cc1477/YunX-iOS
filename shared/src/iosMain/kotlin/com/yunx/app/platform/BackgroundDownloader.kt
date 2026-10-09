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

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app.platform

import com.yunx.app.data.db.AppDatabase
import com.yunx.app.data.download.BackgroundDownloadPersistence
import kotlinx.cinterop.ObjCObjectVar
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.value
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.*
import platform.Foundation.*
import platform.darwin.NSObject
import platform.darwin.dispatch_async
import platform.darwin.dispatch_get_main_queue

private fun onMain(block: () -> Unit) {
    if (NSThread.isMainThread) block() else dispatch_async(dispatch_get_main_queue(), block)
}

/** All instances share one delegate/session. A second session with the same identifier is unsafe. */
actual class BackgroundDownloader actual constructor() {
    actual fun enqueue(id: Long, url: String, destPath: String, headers: Map<String, String>) {
        onMain { BackgroundSession.enqueue(id, url, destPath, headers) }
    }
    actual fun cancel(id: Long) {
        onMain { BackgroundSession.cancel(id) }
    }
    actual fun setListener(listener: BackgroundDownloadListener) {
        onMain { BackgroundSession.setListener(listener) }
    }
    actual fun isEnqueued(id: Long): Boolean = BackgroundSession.records().containsKey(id.toString())
}

/** Exported as BackgroundSessionBridge.shared to Swift. UIKit calls this on the main thread. */
object BackgroundSessionBridge {
    const val identifier = "com.yunx.app.bg"
    private var completion: (() -> Unit)? = null
    fun reconnect(completionHandler: () -> Unit) {
        completion = completionHandler
        BackgroundSession.reconnect()
    }
    internal fun finishEvents() {
        val handler = completion
        completion = null
        handler?.invoke()
    }
}

private object BackgroundSession : NSObject(), NSURLSessionDownloadDelegateProtocol {
    private const val storageKey = "yunx.background.records"
    private val defaults = NSUserDefaults.standardUserDefaults
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val deliveryMutex = Mutex()
    private val deliveries = mutableListOf<Job>()
    private var listener: BackgroundDownloadListener? = null
    private val fallbackListener by lazy { BackgroundDownloadPersistence(AppDatabase.get().downloadTaskDao()) }
    private val lastProgress = mutableMapOf<Long, Double>()
    private val session: NSURLSession by lazy {
        val config = NSURLSessionConfiguration.backgroundSessionConfigurationWithIdentifier(BackgroundSessionBridge.identifier)
        config.sessionSendsLaunchEvents = true
        config.discretionary = false
        // These requests intentionally don't inherit the foreground Cookie jar or proxy settings.
        config.HTTPShouldSetCookies = false
        NSURLSession.sessionWithConfiguration(config, this, NSOperationQueue.mainQueue)
    }
    fun records(): JsonObject = runCatching {
        Json.parseToJsonElement(defaults.stringForKey(storageKey) ?: "{}").jsonObject
    }.getOrElse { JsonObject(emptyMap()) }
    private fun record(id: Long): JsonObject? = records()[id.toString()]?.jsonObject
    private fun write(id: Long, value: JsonObject?) {
        val all = records().toMutableMap()
        if (value == null) all.remove(id.toString()) else all[id.toString()] = value
        defaults.setObject(JsonObject(all).toString(), forKey = storageKey)
    }
    private fun current(task: NSURLSessionTask): Pair<Long, JsonObject>? {
        val id = task.taskDescription?.toLongOrNull() ?: return null
        val entry = record(id) ?: return null
        if (entry["task"]?.jsonPrimitive?.longOrNull != task.taskIdentifier.toLong()) return null
        return id to entry
    }
    fun reconnect() {
        // Recreate the same session after a system relaunch. Don't cancel restored OS tasks.
        session.getAllTasksWithCompletionHandler { _ -> }
        replay()
    }
    fun setListener(value: BackgroundDownloadListener) { listener = value; reconnect() }
    fun enqueue(id: Long, url: String, path: String, headers: Map<String, String>) {
        if (record(id) != null) return
        if (records().values.any { it.jsonObject["path"]?.jsonPrimitive?.content == path }) {
            deliver { activeListener().onError(id, "后台保存路径已被其他任务占用，回到前台重试") }
            return
        }
        val nativeUrl = NSURL.URLWithString(url)
        if (nativeUrl == null || nativeUrl.scheme !in listOf("http", "https")) {
            deliver { activeListener().onError(id, "后台下载仅支持 HTTP(S) 直链") }; return
        }
        val request = NSMutableURLRequest.requestWithURL(nativeUrl).apply {
            headers.forEach { (name, value) -> setValue(value, forHTTPHeaderField = name) }
        }
        val task = session.downloadTaskWithRequest(request)
        task.taskDescription = id.toString()
        // No credential/URL is copied into our journal; URLSession itself persists its request.
        write(id, buildJsonObject {
            put("task", task.taskIdentifier.toLong()); put("path", path); put("state", "running")
        })
        task.resume()
    }
    fun cancel(id: Long) {
        val token = record(id)?.get("task")?.jsonPrimitive?.longOrNull
        lastProgress.remove(id)
        write(id, null) // Makes subsequent delegate callbacks from this generation harmless.
        session.getAllTasksWithCompletionHandler { tasks ->
            tasks.orEmpty().filterIsInstance<NSURLSessionTask>().filter {
                it.taskDescription == id.toString() && it.taskIdentifier.toLong() == token
            }.forEach { it.cancel() }
        }
    }
    private fun activeListener(): BackgroundDownloadListener = listener ?: fallbackListener
    private fun deliver(block: suspend () -> Unit) {
        deliveries.removeAll { it.isCompleted }
        deliveries += scope.launch {
            deliveryMutex.withLock {
                try { block() } catch (error: Exception) {
                    // Terminal journal survives a locked database / failed write and replays next launch.
                    PlatformLog.w("BackgroundSession", "后台结果写入失败", error)
                }
            }
        }
    }
    private fun replay() {
        records().forEach { (key, value) ->
            val id = key.toLongOrNull() ?: return@forEach
            if (value.jsonObject["state"]?.jsonPrimitive?.content != "running") deliverTerminal(id, value.jsonObject)
        }
    }
    private fun terminal(id: Long, entry: JsonObject, state: String, message: String = "") {
        val result = JsonObject(entry + mapOf("state" to JsonPrimitive(state), "message" to JsonPrimitive(message)))
        lastProgress.remove(id)
        write(id, result)
        deliverTerminal(id, result)
    }
    private fun deliverTerminal(id: Long, entry: JsonObject) = deliver {
        if (record(id) != entry) return@deliver
        if (entry["state"]?.jsonPrimitive?.content == "complete") {
            activeListener().onComplete(id, entry.getValue("path").jsonPrimitive.content)
        } else activeListener().onError(id, entry.getValue("message").jsonPrimitive.content)
        if (record(id) == entry) write(id, null)
    }
    override fun URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask,
        didWriteData: Long, totalBytesWritten: Long, totalBytesExpectedToWrite: Long) {
        val (id, entry) = current(downloadTask) ?: return
        val now = NSDate().timeIntervalSince1970
        if (now - (lastProgress[id] ?: 0.0) < 1.0) return
        lastProgress[id] = now
        deliver {
            if (record(id) == entry) activeListener().onProgress(id, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }
    override fun URLSession(session: NSURLSession, downloadTask: NSURLSessionDownloadTask,
        didFinishDownloadingToURL: NSURL) {
        val (id, entry) = current(downloadTask) ?: return
        val status = (downloadTask.response as? NSHTTPURLResponse)?.statusCode ?: 0
        // This enqueue starts at byte 0: reject partial responses instead of saving a truncated file.
        if (status != 200L) { terminal(id, entry, "error", "后台服务器响应异常，回到前台重试"); return }
        val path = entry.getValue("path").jsonPrimitive.content
        val moved = memScoped {
            val error = alloc<ObjCObjectVar<NSError?>>()
            error.value = null
            NSFileManager.defaultManager.moveItemAtURL(didFinishDownloadingToURL, NSURL.fileURLWithPath(path), error.ptr)
        }
        // The OS deletes this temporary file as soon as this delegate method returns.
        if (moved) terminal(id, entry, "complete")
        else terminal(id, entry, "error", "后台文件保存失败，回到前台重试")
    }
    override fun URLSession(session: NSURLSession, task: NSURLSessionTask, didCompleteWithError: NSError?) {
        val (id, entry) = current(task) ?: return
        if (entry["state"]?.jsonPrimitive?.content != "running") return
        if (didCompleteWithError != null) terminal(id, entry, "error", "后台下载中断，回到前台继续")
        else terminal(id, entry, "error", "后台下载未收到文件，回到前台重试")
    }
    override fun URLSessionDidFinishEventsForBackgroundURLSession(session: NSURLSession) {
        val pending = deliveries.toList()
        scope.launch {
            pending.joinAll()
            // Main dispatcher + all DB deliveries drained, as required by UIKit's wake protocol.
            BackgroundSessionBridge.finishEvents()
        }
    }
}
