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

import okio.FileSystem
import okio.Path.Companion.toPath

import kotlinx.datetime.Clock

import com.yunx.app.data.db.BaiduAccountDao
import com.yunx.app.data.db.BaiduAccountEntity
import com.yunx.app.data.db.C139AccountDao
import com.yunx.app.data.db.C139AccountEntity
import com.yunx.app.data.db.GuangYaAccountDao
import com.yunx.app.data.db.GuangYaAccountEntity
import com.yunx.app.data.db.ILanzouAccountDao
import com.yunx.app.data.db.ILanzouAccountEntity
import com.yunx.app.data.db.LanzouAccountDao
import com.yunx.app.data.db.LanzouAccountEntity
import com.yunx.app.data.db.Pan115AccountDao
import com.yunx.app.data.db.Pan115AccountEntity
import com.yunx.app.data.db.Pan123AccountDao
import com.yunx.app.data.db.Pan123AccountEntity
import com.yunx.app.data.db.QuarkAccountDao
import com.yunx.app.data.db.QuarkAccountEntity
import com.yunx.app.data.db.UCAccountDao
import com.yunx.app.data.db.UCAccountEntity
import com.yunx.app.data.db.XunleiAccountDao
import com.yunx.app.data.db.XunleiAccountEntity
import com.yunx.app.data.security.GitHubCredentialStorage as GitHubTokenStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 网盘认证信息备份：把已登录的平台（夸克/UC/迅雷/百度/139/123/115/光鸭/蓝奏云优享版/蓝奏云）凭证打包为 JSON，
 * 可导出到下载目录并在另一台设备导入恢复。
 */
class AuthBackupManager(
    private val quarkDao: QuarkAccountDao,
    private val ucDao: UCAccountDao,
    private val xunleiDao: XunleiAccountDao,
    private val baiduDao: BaiduAccountDao,
    private val c139Dao: C139AccountDao,
    private val pan123Dao: Pan123AccountDao,
    private val pan115Dao: Pan115AccountDao,
    private val guangyaDao: GuangYaAccountDao,
    private val ilanzouDao: ILanzouAccountDao,
    private val lanzouDao: LanzouAccountDao
) {

    private companion object {
        const val APP_TAG = "yunx_auth_backup"
        const val VERSION = 1
    }

    /**
     * 导出网盘认证（强制 AES-GCM 加密）：
     * @param password 至少 8 位的备份口令
     * @param onlyLoggedIn true=仅导出凭证可用的已登录平台；false=导出数据库里全部绑定记录
     * @return 明文 JSON 或 Base64 密文
     */
    suspend fun export(password: String? = null, onlyLoggedIn: Boolean = true): String =
        withContext(Dispatchers.Default) {
            require(!password.isNullOrBlank() && password.length >= 8) { "备份口令至少 8 位" }
            val json = exportJson(onlyLoggedIn)
            AuthCrypto.encrypt(json, password)
        }

    /** 导出所有已登录平台为 JSON 字符串；无已登录平台时返回空 accounts */
    suspend fun exportJson(onlyLoggedIn: Boolean = true): String = withContext(Dispatchers.Default) {
        val accounts = JSONArray()
        quarkDao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.cookie.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "quark")
                    .put("cookie", a.cookie)
                    .put("nickname", a.nickname)
                    .put("updatedAt", a.updatedAt)
            )
        }
        ucDao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.cookie.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "uc")
                    .put("cookie", a.cookie)
                    .put("nickname", a.nickname)
                    .put("updatedAt", a.updatedAt)
            )
        }
        xunleiDao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.accessToken.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "xunlei")
                    .put("accessToken", a.accessToken)
                    .put("refreshToken", a.refreshToken)
                    .put("deviceId", a.deviceId)
                    .put("captchaToken", a.captchaToken)
                    .put("nickname", a.nickname)
                    // 登录方式必须一起备份：网页登录的 token 只能用网页 OAuth 客户端刷新，
                    // 丢了它恢复后一刷新就失效（老备份没有这个字段，导入时按空串=App 通道处理）
                    .put("authType", a.authType)
                    .put("updatedAt", a.updatedAt)
            )
        }
        baiduDao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.cookie.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "baidu")
                    .put("cookie", a.cookie)
                    .put("nickname", a.nickname)
                    .put("updatedAt", a.updatedAt)
            )
        }
        c139Dao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.cookie.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "c139")
                    .put("cookie", a.cookie)
                    .put("authorization", a.authorization)
                    .put("nickname", a.nickname)
                    .put("updatedAt", a.updatedAt)
            )
        }
        pan123Dao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.accessToken.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "pan123")
                    .put("accessToken", a.accessToken)
                    .put("account", a.account)
                    .put("nickname", a.nickname)
                    .put("updatedAt", a.updatedAt)
            )
        }
        pan115Dao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.cookie.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "pan115")
                    .put("cookie", a.cookie)
                    .put("nickname", a.nickname)
                    .put("updatedAt", a.updatedAt)
            )
        }
        guangyaDao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.accessToken.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "guangya")
                    .put("accessToken", a.accessToken)
                    .put("refreshToken", a.refreshToken)
                    .put("deviceId", a.deviceId)
                    .put("deviceSign", a.deviceSign)
                    .put("account", a.account)
                    .put("nickname", a.nickname)
                    .put("updatedAt", a.updatedAt)
            )
        }
        ilanzouDao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.appToken.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "ilanzou")
                    .put("appToken", a.appToken)
                    .put("uuid", a.uuid)
                    .put("account", a.account)
                    .put("password", a.password)
                    .put("userId", a.userId)
                    .put("nickname", a.nickname)
                    .put("updatedAt", a.updatedAt)
            )
        }
        lanzouDao.getAccount()?.let { a ->
            if (!onlyLoggedIn || a.cookie.isNotBlank()) accounts.put(
                JSONObject()
                    .put("platform", "lanzou")
                    .put("cookie", a.cookie)
                    .put("nickname", a.nickname)
                    .put("updatedAt", a.updatedAt)
            )
        }
        val root = JSONObject()
            .put("app", APP_TAG)
            .put("version", VERSION)
            .put("exportedAt", Clock.System.now().toEpochMilliseconds())
            .put("accounts", accounts)
        // GitHub Token 单独顶层字段（它是单个标量凭证，存 Keystore 而非 Room，与网盘账号结构不同）。
        // 仅在已配置 Token 时导出；明文 token 仅存在于导出 JSON 内，最终由 AuthCrypto 口令加密保护，
        // 不落盘到其他位置、不打印日志。
        // 注意：runCatching 返回 Result，必须先 getOrNull() 解包出 String? 才能 ?.takeIf（否则 it 是 Result 类型编译失败）
        runCatching { GitHubTokenStore.getToken() ?: com.yunx.app.data.network.GitHubTokenStore.getToken() }.getOrNull()
            ?.takeIf { !it.isNullOrBlank() && (!onlyLoggedIn || GitHubTokenStore.hasToken() || com.yunx.app.data.network.GitHubTokenStore.hasToken()) }
            ?.let { root.put("githubToken", it) }
        root.toString(2)
    }

    /**
     * 导入认证内容（可选 AES 解密）：
     * @param password 非空时先解密（密码错误抛异常）；null/空按明文 JSON 解析
     * @return 成功恢复的平台数；文件不合法抛异常
     */
    suspend fun import(content: String, password: String? = null): Int =
        withContext(Dispatchers.Default) {
            val json = if (password.isNullOrBlank()) content else AuthCrypto.decrypt(content, password)
            importJson(json)
        }

    /** 导入 JSON，恢复各平台凭证；返回成功恢复的平台数；文件不合法抛异常 */
    suspend fun importJson(json: String): Int = withContext(Dispatchers.Default) {
        val root = JSONObject(json)
        if (root.optString("app") != APP_TAG) {
            throw IllegalArgumentException("不是有效的云析认证备份文件")
        }
        val accounts = root.optJSONArray("accounts") ?: return@withContext 0
        var count = 0
        for (i in 0 until accounts.length()) {
            val obj = accounts.optJSONObject(i) ?: continue
            when (obj.optString("platform")) {
                "quark" -> {
                    val c = obj.optString("cookie")
                    if (c.isNotBlank()) {
                        quarkDao.upsert(
                            QuarkAccountEntity(
                                id = "quark", cookie = c,
                                nickname = obj.optString("nickname"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
                "uc" -> {
                    val c = obj.optString("cookie")
                    if (c.isNotBlank()) {
                        ucDao.upsert(
                            UCAccountEntity(
                                id = "uc", cookie = c,
                                nickname = obj.optString("nickname"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
                "xunlei" -> {
                    val t = obj.optString("accessToken")
                    if (t.isNotBlank()) {
                        xunleiDao.upsert(
                            XunleiAccountEntity(
                                id = "xunlei", accessToken = t,
                                refreshToken = obj.optString("refreshToken"),
                                deviceId = obj.optString("deviceId"),
                                captchaToken = obj.optString("captchaToken"),
                                nickname = obj.optString("nickname"),
                                authType = obj.optString("authType"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
                "baidu" -> {
                    val c = obj.optString("cookie")
                    if (c.isNotBlank()) {
                        baiduDao.upsert(
                            BaiduAccountEntity(
                                id = "baidu", cookie = c,
                                nickname = obj.optString("nickname"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
                "c139" -> {
                    val c = obj.optString("cookie")
                    if (c.isNotBlank()) {
                        c139Dao.upsert(
                            C139AccountEntity(
                                id = "c139", cookie = c,
                                authorization = obj.optString("authorization"),
                                nickname = obj.optString("nickname"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
                "pan123" -> {
                    val t = obj.optString("accessToken")
                    if (t.isNotBlank()) {
                        pan123Dao.upsert(
                            Pan123AccountEntity(
                                id = "pan123", accessToken = t,
                                account = obj.optString("account"),
                                nickname = obj.optString("nickname"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
                "pan115" -> {
                    val c = obj.optString("cookie")
                    if (c.isNotBlank()) {
                        pan115Dao.upsert(
                            Pan115AccountEntity(
                                id = "pan115", cookie = c,
                                nickname = obj.optString("nickname"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
                "guangya" -> {
                    val t = obj.optString("accessToken")
                    if (t.isNotBlank()) {
                        guangyaDao.upsert(
                            GuangYaAccountEntity(
                                id = "guangya", accessToken = t,
                                refreshToken = obj.optString("refreshToken"),
                                deviceId = obj.optString("deviceId"),
                                deviceSign = obj.optString("deviceSign"),
                                account = obj.optString("account"),
                                nickname = obj.optString("nickname"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
                "ilanzou" -> {
                    val t = obj.optString("appToken")
                    if (t.isNotBlank()) {
                        ilanzouDao.upsert(
                            ILanzouAccountEntity(
                                id = "ilanzou", appToken = t,
                                uuid = obj.optString("uuid"),
                                account = obj.optString("account"),
                                password = obj.optString("password"),
                                userId = obj.optString("userId"),
                                nickname = obj.optString("nickname"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
                "lanzou" -> {
                    val c = obj.optString("cookie")
                    if (c.isNotBlank()) {
                        lanzouDao.upsert(
                            LanzouAccountEntity(
                                id = "lanzou", cookie = c,
                                nickname = obj.optString("nickname"),
                                updatedAt = obj.optLong("updatedAt", Clock.System.now().toEpochMilliseconds())
                            )
                        ); count++
                    }
                }
            }
        }
        // GitHub Token：顶层字段恢复。单独 runCatching 包住，失败不阻断其余账号导入；
        // 旧备份无该字段时 optString 返回空串，跳过——**不清除**设备上现有 Token（避免导入旧备份误清）。
        runCatching {
            val ghToken = root.optString("githubToken", "")
            if (ghToken.isNotBlank()) {
                GitHubTokenStore.setToken(ghToken)
                com.yunx.app.data.network.GitHubTokenStore.setToken(ghToken)
                count++
            }
        }
        count
    }

    /** Backups are written under AppDirs, then exposed to a document picker in Stage 3. */
    suspend fun saveToDownloads(content: String, encrypted: Boolean = false): Boolean = withContext(Dispatchers.Default) {
        runCatching {
            val directory = com.yunx.app.platform.appDownloadDir().toPath()
            FileSystem.SYSTEM.createDirectories(directory)
            val extension = if (encrypted) "yunx" else "json"
            FileSystem.SYSTEM.write(directory / "yunx_auth_backup_${Clock.System.now().toEpochMilliseconds()}.$extension") { writeUtf8(content) }
            true
        }.getOrDefault(false)
    }
    suspend fun readBackup(path: String): String = withContext(Dispatchers.Default) {
        FileSystem.SYSTEM.read(path.toPath()) { readUtf8() }
    }
}
