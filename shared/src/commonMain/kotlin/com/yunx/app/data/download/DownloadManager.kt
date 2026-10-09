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

package com.yunx.app.data.download
import com.yunx.app.data.db.*
import com.yunx.app.data.prefs.SettingsRepository
import com.yunx.app.data.security.*
import com.yunx.app.platform.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.*
import kotlinx.datetime.Clock
import kotlinx.serialization.json.*
import okio.*
import okio.Path.Companion.toPath
import kotlin.coroutines.coroutineContext
import kotlin.time.TimeSource
/** 实时下载统计（用于 UI 展示速度/剩余时间/线程数） */
data class DownloadStats(
    val speed: Long = 0L,        // 字节/秒
    val remainMillis: Long = -1L, // 剩余时间（毫秒），未知为 -1
    val chunkCount: Int = 1,      // 分片（线程）数
    /**
     * 分片合并进度（0~100）：-1 表示不在合并阶段。
     * 合并只活在内存里、不写 DB —— 进程被杀时合并本来就会中断，无需在库里留状态。
     */
    val mergePercent: Int = -1
)

/**
 * 单个「在飞分片」的调试快照（下载调试页用）。
 * 一路在飞分片就对应一个正在干活的 worker，所以这张表就是「每个线程此刻在干什么」。
 * [key] 形如 `m<片号>`（主池）/ `seg@<起点>`（弹性区）/ `retry@<起点>`（失败重试）。
 */
data class ChunkDebug(
    val key: String,
    val start: Long,
    val size: Long,
    /** 负责这一片的 worker 序号（0 起）：`worker #k`，方便看「哪个线程在干什么」 */
    val worker: Int,
    val received: Long,
    /** 看门狗上一次采样算出的瞬时速度（字节/秒） */
    val bps: Long,
    val elapsedMs: Long,
    /** 已被「慢连接抢占」换连接的次数 */
    val preemptCount: Int,
    /** 是否已置位抢占标志（下一次检查点会断开换连接） */
    val preempting: Boolean
)

/** 下载引擎的全局资源快照（下载调试页的「全局资源」面板用） */
data class DownloadResourceDebug(
    /** 全进程在飞分片配额（MAX_INFLIGHT_CHUNKS） */
    val inflightCap: Int,
    /** 当前已占用的在飞槽位 */
    val inflightUsed: Int,
    /** 正在跑的任务协程数 */
    val activeTasks: Int,
    val heapUsed: Long,
    val heapMax: Long,
    /** 分片 IO 线程池当前线程数 */
    val poolSize: Int,
    /** 分片 IO 线程池正在执行任务的线程数 */
    val poolActive: Int,
    /** 分片 IO 线程池等待队列长度（>0 说明有 worker 在排队等线程，常因并发开得比线程池大） */
    val poolQueue: Int
)


/** Persistent Ktor downloads. All mutable cross-coroutine registries are protected by a platform lock. */
class DownloadManager(
    private val dao: DownloadTaskDao,
    private val downloader: ChunkDownloader,
    private val threadProvider: (String) -> Int = { 32 },
    private val saveDirProvider: () -> String? = { null },
    private val concurrencyProvider: () -> Int = { 3 },
    private val speedLimitProvider: () -> Long = { 0L },
    private val retryCountProvider: () -> Int = { 3 },
    private val keepWhenLockedProvider: () -> Boolean = { true },
    private val showSpeedProvider: () -> Boolean = { true }
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val lock = PlatformLock()
    private val fs = FileSystem.SYSTEM
    private val service = DownloadServiceController()
    private val settings = SettingsRepository()
    private val jobs = mutableMapOf<Long, Job>()
    private val callbacks = mutableMapOf<Long, suspend () -> Unit>()
    private val fallbackUrls = mutableMapOf<Long, String>()
    private val chunks = mutableMapOf<Long, MutableMap<String, LiveChunk>>()
    private var activeTasks = 0
    private var backgroundDownloader: BackgroundDownloader? = null
    private var foregroundAllowed = true
    private val backgroundPaused = mutableSetOf<Long>()
    private val handoffMutex = Mutex()
    private val initialized = scope.async { CredentialStore.installRecovery(); DownloadDebugLog.install(); dao.markInterruptedAsPaused() }
    private val _stats = MutableStateFlow<Map<Long, DownloadStats>>(emptyMap())
    val stats: StateFlow<Map<Long, DownloadStats>> = _stats.asStateFlow()
    val tasks: Flow<List<DownloadTaskEntity>> = dao.observeAll()
    private data class LiveChunk(val start: Long, val size: Long, val worker: Int, val began: Long,
        val preempt: ChunkPreemption = ChunkPreemption(), var received: Long = 0L,
        var sampled: Long = 0L, var bps: Long = 0L, var preemptions: Int = 0, var lastPreempt: Long = 0)
    init { DownloadBackgroundLifecycle.register(this) }

    fun attachBackgroundDownloader(backend: BackgroundDownloader) {
        locked(lock) { backgroundDownloader = backend }
        backend.setListener(object : BackgroundDownloadListener {
            private val persistence = BackgroundDownloadPersistence(dao)
            override suspend fun onProgress(id: Long, received: Long, total: Long) {
                initialized.await()
                persistence.onProgress(id, received, total)
            }
            override suspend fun onComplete(id: Long, destPath: String) {
                initialized.await()
                persistence.onComplete(id, destPath)
                deleteParts(id)
                locked(lock) { callbacks.remove(id) }?.invoke()
                locked(lock) { fallbackUrls.remove(id); backgroundPaused.remove(id) }
            }
            override suspend fun onError(id: Long, message: String) {
                initialized.await()
                persistence.onError(id, message)
            }
        })
    }

    /** Called while iOS still grants a short transition budget, never runs 32 workers in background. */
    suspend fun prepareForBackground() = handoffMutex.withLock {
        initialized.await()
        val backend = locked(lock) { foregroundAllowed = false; backgroundDownloader }
        val running = locked(lock) { jobs.keys.toList() }
        // Stop ALL workers before allocating OS tasks. Cancellation preserves existing Range parts.
        running.forEach { id -> locked(lock) { jobs[id] }?.cancel(); downloader.cancelCalls(id) }
        running.forEach { stopAndWait(it) }
        for (id in running) {
            coroutineContext.ensureActive()
            val task = dao.get(id) ?: continue
            if (task.status == DownloadTaskEntity.STATUS_COMPLETED) continue
            val headers = loadPersistedHeaders(task)
            val direct = task.url.startsWith("https://") || task.url.startsWith("http://")
            val hls = task.url.substringBefore('?').endsWith(".m3u8", true)
            // Conservative: all provider/credential/header-bound requests pause. Anonymous direct URLs
            // may restart from byte zero in one OS connection; never append to our Range part files.
            if (backend == null || !direct || hls || headers.isNotEmpty() || task.platform.isNotBlank()) {
                dao.updateError(id, "已暂停，回到前台继续（此任务不支持 iOS 后台单连接下载）")
                locked(lock) { backgroundPaused.add(id) }
                continue
            }
            val destination = DownloadSaver.openDestination(task.fileName, saveDirProvider())
            if (destination == null) {
                dao.updateError(id, "后台保存路径不可用，回到前台继续")
                locked(lock) { backgroundPaused.add(id) }
                continue
            }
            dao.updateProgress(id, DownloadTaskEntity.STATUS_DOWNLOADING, 0, task.totalSize)
            dao.updateError(id, "后台单连接下载从头开始；原有前台分片保留")
            backend.enqueue(id, task.url, destination.path, emptyMap())
        }
    }

    suspend fun resumeAfterBackground() = handoffMutex.withLock {
        val paused = locked(lock) { foregroundAllowed = true; backgroundPaused.toList().also { backgroundPaused.clear() } }
        paused.forEach { id ->
            if (dao.get(id)?.status == DownloadTaskEntity.STATUS_PAUSED) start(id)
        }
        // OS tasks remain owned by NSURLSession until completion or explicit user pause.
    }

    private fun now() = Clock.System.now().toEpochMilliseconds()
    fun chunkDebugSnapshot(taskId: Long): List<ChunkDebug> = locked(lock) {
        chunks[taskId].orEmpty().map { (key, chunk) -> ChunkDebug(key, chunk.start, chunk.size, chunk.worker, chunk.received, chunk.bps,
            (now() - chunk.began).coerceAtLeast(0L), chunk.preemptions, chunk.preempt.get()) }.sortedBy { it.start }
    }
    fun forcePreemptChunk(taskId: Long, key: String): Boolean = locked(lock) {
        val chunk = chunks[taskId]?.get(key) ?: return@locked false
        if (chunk.preemptions >= 3) return@locked false
        chunk.preemptions++; chunk.lastPreempt = now(); chunk.preempt.set(true); true
    }
    fun resourceDebugSnapshot(): DownloadResourceDebug = locked(lock) {
        DownloadResourceDebug(MAX_INFLIGHT_CHUNKS, MAX_INFLIGHT_CHUNKS - inflight.availablePermits, activeTasks, -1, -1, -1, -1, -1)
    }
    suspend fun enqueue(url: String, fileName: String, headers: Map<String, String> = emptyMap(), size: Long = -1L,
        platform: String = "", fallbackUrl: String = "", onComplete: suspend () -> Unit = {}): Long {
        initialized.await()
        val magnet = MagnetLink.isMagnet(url)
        val name = fileName.ifBlank { if (magnet) MagnetLink.displayName(url) else url.substringAfterLast('/').substringBefore('?').ifBlank { "download_${now()}" } }
        val id = dao.insert(DownloadTaskEntity(url = url, fileName = name, totalSize = size.coerceAtLeast(0L),
            requestHeadersJson = encodeHeaders(headers), platform = if (magnet) DownloadPlatform.MAGNET else platform))
        if (magnet) { failMagnet(id, name); return id }
        if (settings.downloadEngine == SettingsRepository.ENGINE_GOPEED) PlatformLog.w("YunX-DL", "Gopeed 不适用于 iOS，回退 builtin")
        locked(lock) { callbacks[id] = onComplete; if (fallbackUrl.isNotBlank()) fallbackUrls[id] = fallbackUrl }
        DownloadDebugLog.record(id, "入队", "platform=$platform size=$size")
        start(id, headers); return id
    }
    private suspend fun failMagnet(id: Long, name: String) {
        val error = "iOS 版暂不支持磁力/BT 下载"
        dao.updateStatus(id, DownloadTaskEntity.STATUS_FAILED); dao.updateError(id, error)
        service.notifyResult(id, name, false, error)
    }
    suspend fun redownload(id: Long): Boolean {
        locked(lock) { backgroundDownloader }?.cancel(id)
        initialized.await(); stopAndWait(id)
        val task = dao.get(id) ?: return false
        deleteParts(id); dao.updatePlan(id, 0, 0L); dao.updateProgress(id, DownloadTaskEntity.STATUS_PENDING, 0L, task.totalSize)
        dao.updateError(id, ""); start(id); return true
    }
    fun start(id: Long, headers: Map<String, String> = emptyMap()) {
        val job = locked(lock) {
            if (!foregroundAllowed || jobs.containsKey(id) || backgroundDownloader?.isEnqueued(id) == true) return
            scope.launch(start = CoroutineStart.LAZY) {
                var acquired = false; var title = ""
                try {
                    initialized.await()
                    val task = dao.get(id) ?: return@launch
                    title = task.fileName
                    if (MagnetLink.isMagnet(task.url)) { failMagnet(id, title); return@launch }
                    if (task.status == DownloadTaskEntity.STATUS_COMPLETED) return@launch
                    if (settings.downloadEngine == SettingsRepository.ENGINE_GOPEED || task.engineTaskId.isNotEmpty()) {
                        PlatformLog.w("YunX-DL", "Gopeed 任务回退 builtin"); dao.updateEngineTaskId(id, "")
                    }
                    while (!locked(lock) { if (activeTasks < concurrencyProvider().coerceIn(1, 10)) { activeTasks++; true } else false }) delay(150)
                    acquired = true; service.acquire(id, title, keepWhenLockedProvider())
                    dao.updateStatus(id, DownloadTaskEntity.STATUS_DOWNLOADING); dao.updateError(id, "")
                    val requestHeaders = if (headers.isNotEmpty()) headers.also { dao.updateRequestHeaders(id, encodeHeaders(it)) } else loadPersistedHeaders(task)
                    val began = TimeSource.Monotonic.markNow()
                    var failure: Exception? = null
                    for (attempt in 0..retryCountProvider().coerceIn(0, 10)) {
                        try { runTask(task, requestHeaders, began, useFallback = attempt > 0); failure = null; break }
                        catch (error: CancellationException) { throw error }
                        catch (error: Exception) { failure = error; DownloadDebugLog.record(id, "重试", "attempt=$attempt"); if (attempt < retryCountProvider().coerceIn(0, 10)) delay(1000L shl minOf(attempt, 4)) }
                    }
                    failure?.let { throw it }
                    service.notifyResult(id, title, true)
                    locked(lock) { callbacks.remove(id) }?.let { cb -> try { cb() } catch (error: Exception) { PlatformLog.w("YunX-DL", "下载完成清理失败", error) } }
                    locked(lock) { fallbackUrls.remove(id) }
                } catch (error: CancellationException) {
                    withContext(NonCancellable) {
                        if (dao.get(id)?.status != DownloadTaskEntity.STATUS_COMPLETED) dao.updateStatus(id, DownloadTaskEntity.STATUS_PAUSED)
                    }
                    throw error
                } catch (error: Exception) {
                    dao.updateStatus(id, DownloadTaskEntity.STATUS_FAILED)
                    // Network exception messages may contain signed URLs: show a fixed error, keep diagnostic details redacted.
                    val message = "下载失败，请重试或重新解析链接"
                    dao.updateError(id, message); DownloadDebugLog.record(id, "失败", error::class.simpleName.orEmpty())
                    service.notifyResult(id, title, false, message)
                } finally {
                    if (acquired) { locked(lock) { activeTasks-- }; service.release(id) }
                    locked(lock) { jobs.remove(id); chunks.remove(id) }
                    _stats.update { it - id }
                }
            }.also { jobs[id] = it }
        }
        job.start()
    }
    fun pause(id: Long) {
        locked(lock) { backgroundPaused.remove(id); backgroundDownloader }?.cancel(id)
        locked(lock) { jobs[id] }?.cancel(); downloader.cancelCalls(id)
        scope.launch { stopAndWait(id); if (dao.get(id)?.status != DownloadTaskEntity.STATUS_COMPLETED) dao.updateStatus(id, DownloadTaskEntity.STATUS_PAUSED) }
    }
    private suspend fun stopAndWait(id: Long) { val job = locked(lock) { jobs[id] }; job?.cancelAndJoin(); downloader.cancelCalls(id) }
    fun remove(id: Long, deleteLocal: Boolean = false) {
        locked(lock) { backgroundPaused.remove(id); backgroundDownloader }?.cancel(id)
        scope.launch {
            initialized.await(); stopAndWait(id)
            val task = dao.get(id)
            if (deleteLocal && !task?.savePath.isNullOrBlank()) DownloadSaver.delete(task!!.savePath)
            deleteParts(id); dao.delete(id); locked(lock) { callbacks.remove(id); fallbackUrls.remove(id) }; DownloadDebugLog.drop(id)
        }
    }
    private fun directory(id: Long) = appCacheDir().toPath() / "downloads" / id.toString()
    private fun deleteParts(id: Long) { val dir = directory(id); if (fs.exists(dir)) fs.deleteRecursively(dir) }
    private fun encodeHeaders(headers: Map<String, String>): String = SecureStoreCredentialCipher.shared.encrypt(
        JsonObject(headers.mapValues { JsonPrimitive(it.value) }).toString(), "download.requestHeaders")
    private suspend fun loadPersistedHeaders(task: DownloadTaskEntity): Map<String, String> {
        try {
            val stored = task.requestHeadersJson
            val plain = SecureStoreCredentialCipher.shared.decrypt(stored, "download.requestHeaders")
            val headers = Json.parseToJsonElement(plain).jsonObject.mapValues { it.value.jsonPrimitive.content }
            if (!SecureStoreCredentialCipher.shared.isEncrypted(stored)) dao.updateRequestHeaders(task.id, encodeHeaders(headers))
            return headers
        } catch (error: Exception) {
            if (CredentialStore.isKeyFailure(error) && !CredentialStore.isKeyLost(error)) throw error
            dao.updateRequestHeaders(task.id, "{}")
            if (CredentialStore.isKeyLost(error)) CredentialStore.markKeyLost()
            return emptyMap()
        }
    }
    /** One process-wide pacing gate applies the user's limit to bytes from every task. */
    private suspend fun pace(bytes: Long) = speedMutex.withLock {
        val limit = speedLimitProvider()
        if (limit <= 0) return@withLock
        val elapsed = speedClock.elapsedNow().inWholeMilliseconds
        nextByteTime = maxOf(nextByteTime, elapsed) + bytes * 1000 / limit.coerceAtLeast(1)
        val wait = nextByteTime - elapsed
        if (wait > 0) delay(wait)
    }
    private suspend fun runTask(task: DownloadTaskEntity, headers: Map<String, String>, began: kotlin.time.TimeMark, useFallback: Boolean = false) = coroutineScope {
        val id = task.id; val current = dao.get(id) ?: error("任务已删除")
        val dir = directory(id); fs.createDirectories(dir)
        val fallback = locked(lock) { fallbackUrls[id] }
        var url = if (useFallback && fallback != null) fallback else task.url
        if (useFallback && fallback != null) { deleteParts(id); fs.createDirectories(dir) }
        var total = current.plannedTotalSize.takeIf { it > 0 } ?: current.totalSize.takeIf { it > 0 } ?: downloader.getTotalSize(url, headers) ?: -1L
        if (total <= 0 && fallback != null) { url = fallback; total = downloader.getTotalSize(url, headers) ?: -1L }
        val hls = url.substringBefore('?').endsWith(".m3u8", true)
        val count = if (hls || total <= 0) 1 else (current.chunkCount.takeIf { it > 0 } ?: threadProvider(task.platform).coerceIn(1, 512)).coerceAtMost(total.coerceAtMost(512).toInt())
        if (current.plannedTotalSize > 0 && current.plannedTotalSize != total) { deleteParts(id); fs.createDirectories(dir) }
        dao.updatePlan(id, count, total.coerceAtLeast(0))
        val paths = (0 until count).map { dir / "part_$it" }
        val progressLock = Mutex(); var received = if (hls) 0L else paths.sumOf { fs.metadataOrNull(it)?.size ?: 0L }
        var lastPersist = 0L; var lastSample = began.elapsedNow().inWholeMilliseconds; var sampledBytes = received
        suspend fun progress(bytes: Long) {
            pace(bytes)
            progressLock.withLock {
                received += bytes
                val elapsed = began.elapsedNow().inWholeMilliseconds
                if (elapsed - lastSample >= 500) {
                    val speed = (received - sampledBytes) * 1000 / (elapsed - lastSample).coerceAtLeast(1)
                    _stats.update { it + (id to DownloadStats(speed, if (speed > 0 && total > received) (total - received) * 1000 / speed else -1L, count)) }
                    service.update(id, task.fileName, if (total > 0) (received * 100 / total).toInt().coerceIn(0, 100) else 0, "$speed B/s", showSpeedProvider())
                    lastSample = elapsed; sampledBytes = received
                }
                if (elapsed - lastPersist >= 500) { dao.updateProgress(id, DownloadTaskEntity.STATUS_DOWNLOADING, received, total.coerceAtLeast(0)); lastPersist = elapsed }
            }
        }
        val digests = mutableMapOf<Path, String>()
        var finalPaths = paths
        if (hls) {
            check(HlsDownloader.download(url, headers, paths[0]) { progress(it) }) { "HLS 下载失败" }
        } else if (total <= 0) {
            received = 0; check(downloader.downloadFull(id, url, paths[0], headers) { progress(it) }) { "流式下载失败" }
        } else {
            val limiter = Semaphore(minOf(count, 8))
            val watchdog = launch {
                while (isActive) {
                    delay(5000)
                    locked(lock) {
                        val live = chunks[id].orEmpty().values
                        val fastest = live.maxOfOrNull { (it.received - it.sampled) / 5 } ?: 0L
                        var preempted = 0
                        live.forEach { chunk ->
                            chunk.bps = (chunk.received - chunk.sampled) / 5; chunk.sampled = chunk.received
                            val age = now() - chunk.began
                            if (preempted < 2 && chunk.preemptions < 3 && now() - chunk.lastPreempt > 10000 && age > (if (live.size <= 3) 3000 else 15000) && chunk.size - chunk.received > 128 * 1024 && chunk.bps < 12 * 1024 && (live.size <= 3 || chunk.bps * 3 < fastest)) {
                                chunk.preemptions++; chunk.lastPreempt = now(); chunk.preempt.set(true); preempted++
                            }
                        }
                    }
                }
            }
            val results = try {
                paths.mapIndexed { index, path -> async {
                    limiter.withPermit { inflight.withPermit {
                        delay(minOf(index, 8) * 25L)
                        val start = total * index / count; val end = total * (index + 1) / count - 1
                        val live = LiveChunk(start, end - start + 1, index, now(), received = fs.metadataOrNull(path)?.size ?: 0L)
                        locked(lock) { chunks.getOrPut(id) { mutableMapOf() }["m$index"] = live }
                        val hashing = HashingSink.sha256(blackholeSink()); val digestOutput = hashing.buffer()
                        if (fs.exists(path)) fs.source(path).use { digestOutput.writeAll(it) }
                        try {
                            val result = downloader.downloadChunk(id, url, start, end, path, headers, live.preempt,
                                contentDigest = { bytes, n -> digestOutput.write(bytes, 0, n) }) { bytes -> locked(lock) { live.received += bytes }; progress(bytes) }
                            digestOutput.flush()
                            if (result == ChunkResult.OK) locked(lock) { digests[path] = hashing.hash.hex() }
                            result
                        } finally { digestOutput.close(); locked(lock) { chunks[id]?.remove("m$index") } }
                    } }
                } }.awaitAll()
            } finally { watchdog.cancelAndJoin() }
            if (results.any { it == ChunkResult.RANGE_IGNORED }) {
                deleteParts(id); fs.createDirectories(dir); received = 0L; digests.clear(); finalPaths = listOf(dir / "full")
                dao.updatePlan(id, 1, total)
                check(downloader.downloadFull(id, url, finalPaths[0], headers, total) { progress(it) }) { "服务器忽略 Range，单流下载失败" }
            } else check(results.all { it == ChunkResult.OK }) { "分片下载失败" }
        }
        val destination = DownloadSaver.openDestination(task.fileName, saveDirProvider()) ?: error("无法创建下载文件")
        try {
            val sink = destination.open() ?: error("无法打开下载文件")
            val fullDigest = if (settings.fullFileSha256) HashingSink.sha256(sink) else null
            val output = fullDigest?.buffer() ?: sink
            val expected = finalPaths.sumOf { fs.metadata(it).size ?: 0L }
            val written = output.use {
                downloader.mergeChunksToStream(finalPaths, it, onProgress = { done ->
                    _stats.update { state -> state + (id to (state[id] ?: DownloadStats()).copy(mergePercent = if (expected > 0) (done * 100 / expected).toInt() else 100)) }
                }, onPartDigest = { path, digest -> check(digests[path] == null || digests[path] == digest) { "分片校验失败" } })
            }
            if (!hls && total > 0) check(written == total) { "文件大小校验失败" }
            if (fullDigest != null) DownloadDebugLog.record(id, "全量校验", fullDigest.hash.hex())
            coroutineContext.ensureActive(); destination.commit()
            withContext(NonCancellable) {
                dao.updateProgress(id, DownloadTaskEntity.STATUS_COMPLETED, written, written)
                dao.complete(id, DownloadTaskEntity.STATUS_COMPLETED, destination.path, written * 1000 / began.elapsedNow().inWholeMilliseconds.coerceAtLeast(1))
            }
            runCatching { deleteParts(id) }
        } catch (error: Exception) { destination.abort(); throw error }
    }
    companion object {
        internal fun inflightChunksFor(maxHeapBytes: Long, bufferSize: Int = BUFFER_SIZE): Int = (maxHeapBytes / 8 / bufferSize.coerceAtLeast(1)).toInt().coerceIn(8, 512)
        // KMP has no portable max heap measurement: conservative 32 x 64KiB transport buffers.
        val MAX_INFLIGHT_CHUNKS = 32
        val chunkIoDispatcher: CoroutineDispatcher = Dispatchers.Default
        private val inflight = Semaphore(MAX_INFLIGHT_CHUNKS)
        private val speedMutex = Mutex()
        private val speedClock = TimeSource.Monotonic.markNow()
        private var nextByteTime = 0L
    }
}
