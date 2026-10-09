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

package com.yunx.app.data.db
import app.cash.sqldelight.Query
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.conflate
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.Dispatchers
private fun <T : Any, R> Query<T>.observe(read: (Query<T>) -> R): Flow<R> = callbackFlow {
    val listener = object : Query.Listener { override fun queryResultsChanged() { try { trySend(read(this@observe)) } catch (error: Throwable) { close(error) } } }
    addListener(listener)
    try { trySend(read(this@observe)); awaitClose { removeListener(listener) } }
    catch (error: Throwable) { removeListener(listener); throw error }
}.conflate().flowOn(Dispatchers.Default)
internal class SqlBaiduAccountDao(private val q: YunXDbQueries) : BaiduAccountDao {
    override fun observeAccount(): Flow<BaiduAccountEntity?> = q.BaiduAccountDao_observeAccount(mapper = { id, cookie, nickname, updatedAt -> BaiduAccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: BaiduAccountEntity) = q.BaiduAccountDao_upsert(id = account.id, cookie = account.cookie, nickname = account.nickname, updatedAt = account.updatedAt)
    override suspend fun getAccount(): BaiduAccountEntity? = q.BaiduAccountDao_getAccount(mapper = { id, cookie, nickname, updatedAt -> BaiduAccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.BaiduAccountDao_clear()
}

internal class SqlBookmarkDao(private val q: YunXDbQueries) : BookmarkDao {
    override fun observeAll(): Flow<List<BookmarkEntity>> = q.BookmarkDao_observeAll(mapper = { id, link, title, platform, pwd, category, homePinned, homeLabel, createTime -> BookmarkEntity(id = id, link = link, title = title, platform = platform, pwd = pwd, category = category, homePinned = homePinned, homeLabel = homeLabel, createTime = createTime) }).observe { it.executeAsList() }
    override fun observeHomePinned(): Flow<List<BookmarkEntity>> = q.BookmarkDao_observeHomePinned(mapper = { id, link, title, platform, pwd, category, homePinned, homeLabel, createTime -> BookmarkEntity(id = id, link = link, title = title, platform = platform, pwd = pwd, category = category, homePinned = homePinned, homeLabel = homeLabel, createTime = createTime) }).observe { it.executeAsList() }
    override fun observeCategories(): Flow<List<String>> = q.BookmarkDao_observeCategories().observe { it.executeAsList() }
    override suspend fun insert(bookmark: BookmarkEntity): Long = q.transactionWithResult { q.BookmarkDao_insert(id = bookmark.id, link = bookmark.link, title = bookmark.title, platform = bookmark.platform, pwd = bookmark.pwd, category = bookmark.category, homePinned = bookmark.homePinned, homeLabel = bookmark.homeLabel, createTime = bookmark.createTime); q.lastInsertRowId().executeAsOne() }
    override suspend fun updateCategory(id: Long, category: String) = q.BookmarkDao_updateCategory(id = id, category = category)
    override suspend fun updateHomePinned(id: Long, pinned: Boolean) = q.BookmarkDao_updateHomePinned(id = id, pinned = pinned)
    override suspend fun updateHomeLabel(id: Long, label: String) = q.BookmarkDao_updateHomeLabel(id = id, label = label)
    override suspend fun delete(id: Long) = q.BookmarkDao_delete(id = id)
}

internal class SqlC139AccountDao(private val q: YunXDbQueries) : C139AccountDao {
    override fun observeAccount(): Flow<C139AccountEntity?> = q.C139AccountDao_observeAccount(mapper = { id, cookie, nickname, authorization, updatedAt -> C139AccountEntity(id = id, cookie = cookie, nickname = nickname, authorization = authorization, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: C139AccountEntity) = q.C139AccountDao_upsert(id = account.id, cookie = account.cookie, nickname = account.nickname, authorization = account.authorization, updatedAt = account.updatedAt)
    override suspend fun getAccount(): C139AccountEntity? = q.C139AccountDao_getAccount(mapper = { id, cookie, nickname, authorization, updatedAt -> C139AccountEntity(id = id, cookie = cookie, nickname = nickname, authorization = authorization, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.C139AccountDao_clear()
}

internal class SqlDownloadTaskDao(private val q: YunXDbQueries) : DownloadTaskDao {
    override fun observeAll(): Flow<List<DownloadTaskEntity>> = q.DownloadTaskDao_observeAll(mapper = { id, url, fileName, totalSize, downloadedSize, status, errorMsg, savePath, requestHeadersJson, chunkCount, plannedTotalSize, cleanupId, platform, engineTaskId, avgSpeed, createTime -> DownloadTaskEntity(id = id, url = url, fileName = fileName, totalSize = totalSize, downloadedSize = downloadedSize, status = status, errorMsg = errorMsg, savePath = savePath, requestHeadersJson = requestHeadersJson, chunkCount = chunkCount, plannedTotalSize = plannedTotalSize, cleanupId = cleanupId, platform = platform, engineTaskId = engineTaskId, avgSpeed = avgSpeed, createTime = createTime) }).observe { it.executeAsList() }
    override suspend fun insert(task: DownloadTaskEntity): Long = q.transactionWithResult { q.DownloadTaskDao_insert(id = task.id, url = task.url, fileName = task.fileName, totalSize = task.totalSize, downloadedSize = task.downloadedSize, status = task.status, errorMsg = task.errorMsg, savePath = task.savePath, requestHeadersJson = task.requestHeadersJson, chunkCount = task.chunkCount, plannedTotalSize = task.plannedTotalSize, cleanupId = task.cleanupId, platform = task.platform, engineTaskId = task.engineTaskId, avgSpeed = task.avgSpeed, createTime = task.createTime); q.lastInsertRowId().executeAsOne() }
    override suspend fun get(id: Long): DownloadTaskEntity? = q.DownloadTaskDao_get(id = id, mapper = { id, url, fileName, totalSize, downloadedSize, status, errorMsg, savePath, requestHeadersJson, chunkCount, plannedTotalSize, cleanupId, platform, engineTaskId, avgSpeed, createTime -> DownloadTaskEntity(id = id, url = url, fileName = fileName, totalSize = totalSize, downloadedSize = downloadedSize, status = status, errorMsg = errorMsg, savePath = savePath, requestHeadersJson = requestHeadersJson, chunkCount = chunkCount, plannedTotalSize = plannedTotalSize, cleanupId = cleanupId, platform = platform, engineTaskId = engineTaskId, avgSpeed = avgSpeed, createTime = createTime) }).executeAsOneOrNull()
    override suspend fun updateProgress(id: Long, status: Int, downloadedSize: Long, totalSize: Long) = q.DownloadTaskDao_updateProgress(id = id, status = status, downloadedSize = downloadedSize, totalSize = totalSize)
    override suspend fun updatePlan(id: Long, chunkCount: Int, totalSize: Long) = q.DownloadTaskDao_updatePlan(id = id, chunkCount = chunkCount, totalSize = totalSize)
    override suspend fun updateRequestHeaders(id: Long, encryptedHeaders: String) = q.DownloadTaskDao_updateRequestHeaders(id = id, encryptedHeaders = encryptedHeaders)
    override suspend fun markInterruptedAsPaused() = q.DownloadTaskDao_markInterruptedAsPaused()
    override suspend fun updateStatus(id: Long, status: Int) = q.DownloadTaskDao_updateStatus(id = id, status = status)
    override suspend fun updateError(id: Long, errorMsg: String) = q.DownloadTaskDao_updateError(id = id, errorMsg = errorMsg)
    override suspend fun complete(id: Long, status: Int, savePath: String, avgSpeed: Long) = q.DownloadTaskDao_complete(id = id, status = status, savePath = savePath, avgSpeed = avgSpeed)
    override suspend fun delete(id: Long) = q.DownloadTaskDao_delete(id = id)
    override suspend fun updateEngineTaskId(id: Long, engineTaskId: String) = q.DownloadTaskDao_updateEngineTaskId(id = id, engineTaskId = engineTaskId)
    override suspend fun updateFileName(id: Long, name: String) = q.DownloadTaskDao_updateFileName(id = id, name = name)
    override suspend fun listSyncableEngineTasks(): List<DownloadTaskEntity> = q.DownloadTaskDao_listSyncableEngineTasks(mapper = { id, url, fileName, totalSize, downloadedSize, status, errorMsg, savePath, requestHeadersJson, chunkCount, plannedTotalSize, cleanupId, platform, engineTaskId, avgSpeed, createTime -> DownloadTaskEntity(id = id, url = url, fileName = fileName, totalSize = totalSize, downloadedSize = downloadedSize, status = status, errorMsg = errorMsg, savePath = savePath, requestHeadersJson = requestHeadersJson, chunkCount = chunkCount, plannedTotalSize = plannedTotalSize, cleanupId = cleanupId, platform = platform, engineTaskId = engineTaskId, avgSpeed = avgSpeed, createTime = createTime) }).executeAsList()
}

internal class SqlGuangYaAccountDao(private val q: YunXDbQueries) : GuangYaAccountDao {
    override fun observeAccount(): Flow<GuangYaAccountEntity?> = q.GuangYaAccountDao_observeAccount(mapper = { id, accessToken, refreshToken, deviceId, deviceSign, account, nickname, updatedAt -> GuangYaAccountEntity(id = id, accessToken = accessToken, refreshToken = refreshToken, deviceId = deviceId, deviceSign = deviceSign, account = account, nickname = nickname, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: GuangYaAccountEntity) = q.GuangYaAccountDao_upsert(id = account.id, accessToken = account.accessToken, refreshToken = account.refreshToken, deviceId = account.deviceId, deviceSign = account.deviceSign, account = account.account, nickname = account.nickname, updatedAt = account.updatedAt)
    override suspend fun getAccount(): GuangYaAccountEntity? = q.GuangYaAccountDao_getAccount(mapper = { id, accessToken, refreshToken, deviceId, deviceSign, account, nickname, updatedAt -> GuangYaAccountEntity(id = id, accessToken = accessToken, refreshToken = refreshToken, deviceId = deviceId, deviceSign = deviceSign, account = account, nickname = nickname, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.GuangYaAccountDao_clear()
}

internal class SqlILanzouAccountDao(private val q: YunXDbQueries) : ILanzouAccountDao {
    override fun observeAccount(): Flow<ILanzouAccountEntity?> = q.ILanzouAccountDao_observeAccount(mapper = { id, appToken, uuid, account, password, userId, nickname, updatedAt -> ILanzouAccountEntity(id = id, appToken = appToken, uuid = uuid, account = account, password = password, userId = userId, nickname = nickname, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: ILanzouAccountEntity) = q.ILanzouAccountDao_upsert(id = account.id, appToken = account.appToken, uuid = account.uuid, account = account.account, password = account.password, userId = account.userId, nickname = account.nickname, updatedAt = account.updatedAt)
    override suspend fun getAccount(): ILanzouAccountEntity? = q.ILanzouAccountDao_getAccount(mapper = { id, appToken, uuid, account, password, userId, nickname, updatedAt -> ILanzouAccountEntity(id = id, appToken = appToken, uuid = uuid, account = account, password = password, userId = userId, nickname = nickname, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.ILanzouAccountDao_clear()
}

internal class SqlLanzouAccountDao(private val q: YunXDbQueries) : LanzouAccountDao {
    override fun observeAccount(): Flow<LanzouAccountEntity?> = q.LanzouAccountDao_observeAccount(mapper = { id, cookie, nickname, updatedAt -> LanzouAccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: LanzouAccountEntity) = q.LanzouAccountDao_upsert(id = account.id, cookie = account.cookie, nickname = account.nickname, updatedAt = account.updatedAt)
    override suspend fun getAccount(): LanzouAccountEntity? = q.LanzouAccountDao_getAccount(mapper = { id, cookie, nickname, updatedAt -> LanzouAccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.LanzouAccountDao_clear()
}

internal class SqlPan115AccountDao(private val q: YunXDbQueries) : Pan115AccountDao {
    override fun observeAccount(): Flow<Pan115AccountEntity?> = q.Pan115AccountDao_observeAccount(mapper = { id, cookie, nickname, updatedAt -> Pan115AccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: Pan115AccountEntity) = q.Pan115AccountDao_upsert(id = account.id, cookie = account.cookie, nickname = account.nickname, updatedAt = account.updatedAt)
    override suspend fun getAccount(): Pan115AccountEntity? = q.Pan115AccountDao_getAccount(mapper = { id, cookie, nickname, updatedAt -> Pan115AccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.Pan115AccountDao_clear()
}

internal class SqlPan123AccountDao(private val q: YunXDbQueries) : Pan123AccountDao {
    override fun observeAccount(): Flow<Pan123AccountEntity?> = q.Pan123AccountDao_observeAccount(mapper = { id, accessToken, account, nickname, updatedAt -> Pan123AccountEntity(id = id, accessToken = accessToken, account = account, nickname = nickname, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: Pan123AccountEntity) = q.Pan123AccountDao_upsert(id = account.id, accessToken = account.accessToken, account = account.account, nickname = account.nickname, updatedAt = account.updatedAt)
    override suspend fun getAccount(): Pan123AccountEntity? = q.Pan123AccountDao_getAccount(mapper = { id, accessToken, account, nickname, updatedAt -> Pan123AccountEntity(id = id, accessToken = accessToken, account = account, nickname = nickname, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.Pan123AccountDao_clear()
}

internal class SqlQuarkAccountDao(private val q: YunXDbQueries) : QuarkAccountDao {
    override fun observeAccount(): Flow<QuarkAccountEntity?> = q.QuarkAccountDao_observeAccount(mapper = { id, cookie, nickname, updatedAt -> QuarkAccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: QuarkAccountEntity) = q.QuarkAccountDao_upsert(id = account.id, cookie = account.cookie, nickname = account.nickname, updatedAt = account.updatedAt)
    override suspend fun getAccount(): QuarkAccountEntity? = q.QuarkAccountDao_getAccount(mapper = { id, cookie, nickname, updatedAt -> QuarkAccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.QuarkAccountDao_clear()
}

internal class SqlUCAccountDao(private val q: YunXDbQueries) : UCAccountDao {
    override fun observeAccount(): Flow<UCAccountEntity?> = q.UCAccountDao_observeAccount(mapper = { id, cookie, nickname, updatedAt -> UCAccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: UCAccountEntity) = q.UCAccountDao_upsert(id = account.id, cookie = account.cookie, nickname = account.nickname, updatedAt = account.updatedAt)
    override suspend fun getAccount(): UCAccountEntity? = q.UCAccountDao_getAccount(mapper = { id, cookie, nickname, updatedAt -> UCAccountEntity(id = id, cookie = cookie, nickname = nickname, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.UCAccountDao_clear()
}

internal class SqlXunleiAccountDao(private val q: YunXDbQueries) : XunleiAccountDao {
    override fun observeAccount(): Flow<XunleiAccountEntity?> = q.XunleiAccountDao_observeAccount(mapper = { id, accessToken, refreshToken, deviceId, captchaToken, nickname, authType, updatedAt -> XunleiAccountEntity(id = id, accessToken = accessToken, refreshToken = refreshToken, deviceId = deviceId, captchaToken = captchaToken, nickname = nickname, authType = authType, updatedAt = updatedAt) }).observe { it.executeAsOneOrNull() }
    override suspend fun upsert(account: XunleiAccountEntity) = q.XunleiAccountDao_upsert(id = account.id, accessToken = account.accessToken, refreshToken = account.refreshToken, deviceId = account.deviceId, captchaToken = account.captchaToken, nickname = account.nickname, authType = account.authType, updatedAt = account.updatedAt)
    override suspend fun getAccount(): XunleiAccountEntity? = q.XunleiAccountDao_getAccount(mapper = { id, accessToken, refreshToken, deviceId, captchaToken, nickname, authType, updatedAt -> XunleiAccountEntity(id = id, accessToken = accessToken, refreshToken = refreshToken, deviceId = deviceId, captchaToken = captchaToken, nickname = nickname, authType = authType, updatedAt = updatedAt) }).executeAsOneOrNull()
    override suspend fun clear() = q.XunleiAccountDao_clear()
}
