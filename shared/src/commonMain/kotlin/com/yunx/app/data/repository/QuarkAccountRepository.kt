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

package com.yunx.app.data.repository

import com.yunx.app.platform.clearLoginWebData

import kotlinx.datetime.Clock

import com.yunx.app.data.db.QuarkAccountDao
import com.yunx.app.data.db.QuarkAccountEntity
import com.yunx.app.data.network.QuarkApi
import com.yunx.app.data.network.QuarkConstants
import com.yunx.app.util.DiagnosticLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/**
 * 夸克账号数据仓库：Room 持久化 + 网络验证 + __puus 会话刷新（修复 AlistGo/alist#830 下载 412）。
 * __puus 约 3 小时过期，是下载直链签名校验的关键字段；下载前惰性刷新 + 响应 Set-Cookie 自动回写双保险。
 */
class QuarkAccountRepository(
    private val dao: QuarkAccountDao = com.yunx.app.data.db.AppDatabase.getInstance().quarkAccountDao(),
    private val api: QuarkApi
) {

    /** 上次主动刷新 __puus 的时间戳（进程内；跨进程重启后首次下载会因间隔超时触发刷新） */
    private var lastRefreshTs = 0L

    /** cookieSink 落库用独立作用域（非 UI 线程，避免阻塞 API 调用链） */
    private val sinkScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val accountWrites = Mutex()

    init {
        // 每次 API 响应若带 Set-Cookie（__puus/__pus），自动合并并落库，保持会话始终新鲜
        api.cookieSink = { original, merged ->
            sinkScope.launch {
                accountWrites.withLock {
                    dao.getAccount()?.let { acc ->
                        if (acc.cookie == original && acc.cookie != merged) {
                            dao.upsert(acc.copy(cookie = merged, updatedAt = Clock.System.now().toEpochMilliseconds()))
                            DiagnosticLog.event(DiagnosticLog.OPERATION, "quark_rotated_session_saved")
                        } else if (acc.cookie != merged) {
                            DiagnosticLog.warn(DiagnosticLog.OPERATION, "quark_stale_session_update_ignored")
                        }
                    }
                }
            }
        }
    }

    fun observeAccount(): Flow<QuarkAccountEntity?> = dao.observeAccount()

    suspend fun getAccount(): QuarkAccountEntity? = dao.getAccount()

    /**
     * 返回「保证 __puus 未过期」的 Cookie（下载前调用）：
     * - 距上次刷新超过 PUUS_REFRESH_INTERVAL_MS 时，先 refreshSession 再落库；
     * - 刷新失败则回退返回当前 Cookie（不让下载直接崩）。
     */
    suspend fun getFreshCookie(): String? {
        val acc = dao.getAccount() ?: return null
        val need = Clock.System.now().toEpochMilliseconds() - lastRefreshTs > QuarkConstants.PUUS_REFRESH_INTERVAL_MS
        if (!need) return acc.cookie
        val refreshed = api.refreshSession(acc.cookie, publishUpdates = false)
        return accountWrites.withLock {
            val current = dao.getAccount()
            if (current?.cookie != acc.cookie) return@withLock current?.cookie
            if (refreshed != null) {
                dao.upsert(acc.copy(cookie = refreshed, updatedAt = Clock.System.now().toEpochMilliseconds()))
                lastRefreshTs = Clock.System.now().toEpochMilliseconds()
                refreshed
            } else {
                acc.cookie
            }
        }
    }

    /** 退出登录：清理 WebView Cookie + 清除本地记录 */
    suspend fun logoutQuark() {
        withContext(Dispatchers.Default) {
            runCatching {
                clearLoginWebData()
                Unit
            }
        }
        accountWrites.withLock { dao.clear(); lastRefreshTs = 0L }
    }

    /**
     * 校验 Cookie 有效性；有效则拉取昵称并落库，返回 true；无效返回 false。
     */
    suspend fun saveQuarkAccount(cookie: String): Boolean {
        DiagnosticLog.event(DiagnosticLog.OPERATION, "quark_save_started",
            "hasPrincipal=" + QuarkConstants.hasLoginPrincipal(cookie) + " | hasSession=" + QuarkConstants.isValidCookie(cookie))
        if (!QuarkConstants.hasLoginPrincipal(cookie)) {
            DiagnosticLog.warn(DiagnosticLog.OPERATION, "quark_save_missing_principal")
            return false
        }
        val verifiedCookie = api.validateCookie(cookie) ?: run {
            DiagnosticLog.warn(DiagnosticLog.OPERATION, "quark_save_rejected")
            return false
        }
        val nickname = api.fetchNickname(verifiedCookie) ?: "夸克用户"
        accountWrites.withLock {
            dao.upsert(
                QuarkAccountEntity(
                    id = "quark",
                    cookie = verifiedCookie,
                    nickname = nickname
                )
            )
            // 新会话避免立即触发一次无谓刷新。
            lastRefreshTs = Clock.System.now().toEpochMilliseconds()
        }
        DiagnosticLog.event(DiagnosticLog.OPERATION, "quark_account_saved")
        return true
    }
}
