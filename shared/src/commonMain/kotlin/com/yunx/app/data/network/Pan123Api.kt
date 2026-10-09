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

@file:OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)

package com.yunx.app.data.network

import com.yunx.app.platform.*
import com.yunx.app.data.network.*
import kotlinx.serialization.json.*
import kotlinx.datetime.*
import io.ktor.client.HttpClient
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.client.call.*
import io.ktor.http.*
import io.ktor.client.request.forms.*
import kotlin.random.Random
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi

import com.yunx.app.data.network.model.DownloadLink
import com.yunx.app.data.network.model.QuotaInfo
import com.yunx.app.data.network.model.ShareExpire
import com.yunx.app.data.network.model.ShareFile
import com.yunx.app.data.network.model.ShareInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * 123 账号密码登录结果。
 * 成功时拿到的是 authorToken（与网页登录从 localStorage 读到的同源同形，可直接替换使用）；
 * 失败时带上可以直接展示给用户的文案（不包含服务端原文）。
 */
sealed interface Pan123LoginResult {
    data class Success(val token: String) : Pan123LoginResult
    data class Failure(val message: String) : Pan123LoginResult
}

class Pan123Api(
    private val clientProvider: () -> HttpClient = { HttpClients.apiClient() }
) {
    /** 每次请求动态获取全局客户端（忽略 SSL 开关切换即时生效） */
    private val client get() = clientProvider()

    private val jsonMediaType = "application/json;charset=UTF-8"

    /** 设备标识（文档 §3.2：同一设备长期不变、不参与签名；由 [Pan123DeviceId] 持久化） */
    private val loginuuid: String = Pan123DeviceId.value()

    // ---------- 签名算法（文档 §6，已抓包逐字还原 + 实时验证） ----------

    /** 标准 CRC-32（IEEE 802.3）→ 8 位小写十六进制（与 Python zlib.crc32 & 0xFFFFFFFF format 'x' 一致） */
    private fun crc32Hex(s: String): String {
        return crc32(s.encodeToByteArray()).toString(16)
    }

    /**
     * 生成 123 云盘签名头（文档 §6.2）：
     * - auth-key (timeSign) = crc32_hex(替换表映射后的 UTC "YYYYMMDDHHmm"，基准 ts + 57600s = +16h)；
     * - auth-value = "<ts>-<random>-<crc32_hex(ts|random|path|web|3|auth_key)>"；
     * 签名内部固定 OS=web / VER=3（与请求头 platform/app-version 无关，文档 §6.3）。
     * @param path URL 路径：含 /b 前缀、不含 host、不含 query（如 /b/api/share/download/info）
     */
    fun makeSign(path: String, ts: Long = Clock.System.now().toEpochMilliseconds() / 1000): Pair<String, String> {
        // 1) auth-key (timeSign)：ts + 16h 以 UTC 格式化为 YYYYMMDDHHmm，逐数字替换
        val t = Instant.fromEpochSeconds(ts + Pan123Constants.SIGN_OFFSET_SECONDS).toLocalDateTime(TimeZone.UTC)
        val minute = listOf(t.year.toString().padStart(4, '0'), t.monthNumber, t.dayOfMonth, t.hour, t.minute)
            .map { it.toString().padStart(2, '0') }.joinToString("")
        val substituted = minute.map { Pan123Constants.SIGN_TABLE[it - '0'] }.joinToString("")
        val authKey = crc32Hex(substituted)

        // 2) auth-value：ts|random|path|web|3|auth_key 的 crc32
        val random = Random.nextInt(0, 10_000_000)
        val data = "$ts|$random|$path|${Pan123Constants.SIGN_OS}|${Pan123Constants.SIGN_VER}|$authKey"
        val authValue = "$ts-$random-${crc32Hex(data)}"
        return authKey to authValue
    }

    // ---------- 账号密码登录（文档 §3.1，与网页登录并列的另一条路） ----------

    /**
     * 账号密码登录：`POST https://user.123pan.cn/api/user/sign_in` → `data.token`（authorToken）。
     *
     * 三点容易踩：
     * 1. 这是**另一个站**（user.123pan.cn），个人盘 API 在 yun.123pan.cn，不能混用 host；
     * 2. 成功判定是 `code == 200`，**不是**其它接口的 `code == 0`；
     * 3. 密码按原值提交（不 trim——trim 会把「密码里有空格」的用户直接挡在门外），账号才 trim。
     *
     * 失败一律返回 [Pan123LoginResult.Failure]，文案由 [Pan123LoginSupport] 生成、绝不复述服务端原文。
     */
    suspend fun passwordLogin(account: String, password: String): Pan123LoginResult =
        withContext(Dispatchers.Default) {
            val passport = account.trim()
            if (passport.isEmpty() || password.isEmpty()) {
                return@withContext Pan123LoginResult.Failure("请输入账号和密码")
            }
            if (passport.length > 254 || password.length > 256) {
                return@withContext Pan123LoginResult.Failure("账号或密码过长")
            }
            val body = buildJsonObject {}
                .withField("passport", passport)
                .withField("password", password)
                .withField("remember", false)
                .toString()
            val request = HttpRequestBuilder()
                .withUrl(Pan123Constants.SIGN_IN_URL)
                .withHeader("platform", Pan123Constants.PLATFORM_WEB)
                .withHeader("app-version", Pan123Constants.APP_VERSION_SIGN_IN)
                .withHeader("loginuuid", loginuuid)
                .withHeader("Origin", Pan123Constants.SIGN_IN_ORIGIN)
                .withHeader("Referer", Pan123Constants.SIGN_IN_REFERER)
                .withHeader("User-Agent", Pan123Constants.WEB_UA)
                .withHeader("Content-Type", "application/json; charset=utf-8")
                .withPost(body.toRequestBody(jsonMediaType))

            runCatching {
                client.executeRequest(request).let { resp ->
                    val text = resp.bodyAsText().orEmpty()
                    val json = runCatching { parseJsonObject(text) }.getOrNull()
                    val code = json?.optInt("code", -1) ?: -1
                    val token = json?.optJsonObject("data")?.optString("token").orEmpty()
                    when {
                        resp.status.isSuccess() && code == 200 && Pan123LoginSupport.isValidToken(token) ->
                            Pan123LoginResult.Success(token)
                        // 响应不是 JSON（比如被重定向到 HTML 页）时 message 为空，走兜底文案
                        else -> Pan123LoginResult.Failure(
                            Pan123LoginSupport.describeFailure(
                                httpStatus = resp.status.value,
                                code = code,
                                serverMessage = json?.optString("message").orEmpty()
                            )
                        )
                    }
                }
            }.getOrElse {
                Pan123LoginResult.Failure("网络异常，无法连接 123 登录服务，请稍后重试")
            }
        }

    // ---------- 用户信息（文档 §5.11） ----------

    /** 校验登录态 + 取昵称：GET /b/api/user/info → data.Nickname；失败返回 null */
    suspend fun fetchNickname(token: String): String? = withContext(Dispatchers.Default) {
        runCatching {
            val json = getAuth(Pan123Constants.USER_INFO_URL, "/b/api/user/info", token)
            checkOk(json, "获取用户信息失败")
            json.optJsonObject("data")?.optString("Nickname")?.takeIf { it.isNotBlank() }
        }.getOrNull()
    }

    /** 网盘空间详情：GET /b/api/user/info → SpaceUsed / SpacePermanent / SpaceTemp（文档 §5.11） */
    suspend fun getQuota(token: String): QuotaInfo? = withContext(Dispatchers.Default) {
        runCatching {
            val json = getAuth(Pan123Constants.USER_INFO_URL, "/b/api/user/info", token)
            checkOk(json, "获取空间详情失败")
            val data = json.optJsonObject("data") ?: return@runCatching null
            QuotaInfo(
                used = data.optLong("SpaceUsed"),
                total = data.optLong("SpacePermanent") + data.optLong("SpaceTemp")
            )
        }.getOrNull()
    }

    // ---------- 分享文件列表（文档 §5.2，匿名、无签名） ----------

    /**
     * 读取分享文件/目录列表（匿名），支持提取码、翻页、进入子目录。
     * @return (文件列表, 下一页游标 or null=末页)。文档 §5.2：`Next=="-1"` 无下一页，空串 `""` 表示还有下一页。
     */
    suspend fun getShareFiles(
        shareKey: String,
        sharePwd: String,
        parentFileId: String,
        next: String,
        page: Int
    ): Pair<List<ShareFile>, String?> = withContext(Dispatchers.Default) {
        // 参数顺序与抓包一致（§5.2 文件夹分享/有提取码）；⚠️ 无提取码时不传 SharePwd（传空值会 400 "请输入Next"）
        val url = buildString {
            append(Pan123Constants.SHARE_GET_URL)
            append("?limit=100")
            append("&next=").append(next)
            append("&orderBy=file_name")
            append("&orderDirection=asc")
            append("&shareKey=").append(formEncode(shareKey))
            append("&ParentFileId=").append(parentFileId)
            append("&Page=").append(page)
            if (sharePwd.isNotBlank()) {
                append("&SharePwd=").append(formEncode(sharePwd))
            }
        }
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("User-Agent", Pan123Constants.DART_UA)
            .withGet()

        val json = executeJson(request)
        checkOk(json, "获取文件列表失败")
        val data = json.optJsonObject("data") ?: return@withContext Pair(emptyList(), null)
        if (data.optBoolean("Expired", false)) {
            throw IllegalStateException("分享已失效")
        }
        val files = parseInfoList(data)
        // 文档 §5.2：Next=="-1" 无下一页；空串 "" 表示还有下一页（需继续翻页）；数字为游标
        val nextCursor = data.optString("Next").takeIf { it != "-1" }
        Pair(files, nextCursor)
    }

    // ---------- 分享下载信息（文档 §5.3，需登录+签名） ----------

    /**
     * 分享文件取下载直链（POST /b/api/share/download/info）。
     * @param file 列表项（fidToken 编码了 "S3KeyFlag|Etag"）
     * @param token Bearer JWT
     * @return 解码后的真实 CDN 直链（下载需带 Referer: https://yun.123pan.cn/）
     */
    suspend fun getShareDownloadLink(
        shareKey: String,
        file: ShareFile,
        token: String
    ): DownloadLink? = withContext(Dispatchers.Default) {
        val (s3KeyFlag, etag, _) = decodeToken(file.fidToken)
        val body = buildJsonObject {}
            .withField("ShareKey", shareKey)
            .withField("FileID", file.fid)
            .withField("S3KeyFlag", s3KeyFlag)
            .withField("Size", file.fsize)
            .withField("Etag", etag)
        // 签名 path 与请求头一致（含 /b）；分享下载信息走 android 平台头，签名内部仍固定 web/3（文档 §6.3）
        val json = postAuth(
            Pan123Constants.SHARE_DOWNLOAD_INFO_URL,
            "/b/api/share/download/info",
            body.toString(),
            token,
            platform = Pan123Constants.PLATFORM_ANDROID,
            appVersion = Pan123Constants.APP_VERSION_ANDROID
        )
        checkOk(json, "获取下载链接失败")
        val data = json.optJsonObject("data") ?: return@withContext null
        val downloadUrl = data.optString("DownloadURL")
        if (downloadUrl.isBlank()) return@withContext null
        // download-v2 包装 URL → Base64 解码 params 得真实 CDN 文件 URL（文档 §5.3.1）
        val decoded = decodeDownloadUrl(downloadUrl) ?: downloadUrl
        // 同样循环跟随可能存在的 redirect_url（auto_redirect=0）
        val realUrl = followRedirectUrl(decoded)
        DownloadLink(
            fid = file.fid,
            filename = file.fname,
            downloadUrl = realUrl,
            size = file.fsize
        )
    }

    // ---------- 个人盘（网盘页，需登录+签名） ----------

    /** 单页个人盘文件：GET /b/api/file/list/new（文档 §5.4）。返回 (文件列表, 下一页游标 or null=末页) */
    private suspend fun fetchCloudPage(
        parentFileId: String,
        token: String,
        next: String
    ): Pair<List<ShareFile>, String?>? = withContext(Dispatchers.Default) {
        val url = buildString {
            append(Pan123Constants.FILE_LIST_URL)
            append("?driveId=0&limit=100&next=").append(next)
            append("&orderBy=update_time&orderDirection=desc")
            append("&parentFileId=").append(parentFileId)
            append("&trashed=false&SearchData=&Page=1&OnlyLookAbnormalFile=0")
            append("&event=homeListFile&operateType=1&inDirectSpace=false")
        }
        val json = getAuth(url, "/b/api/file/list/new", token)
        checkOk(json, "获取文件列表失败")
        val data = json.optJsonObject("data") ?: return@withContext null
        val files = parseInfoList(data)
        // 文档 §5.4：Next=="-1" 表示末页（游标取 null 结束翻页）；空串 ""/数字表示还有下一页
        val nextCursor = data.optString("Next").takeIf { it != "-1" }
        Pair(files, nextCursor)
    }

    /** 个人盘文件列表：GET /b/api/file/list/new（文档 §5.4）。自动翻页，返回该目录下全部文件 */
    suspend fun listCloudFiles(parentFileId: String, token: String): List<ShareFile> {
        val all = mutableListOf<ShareFile>()
        var next = "0"
        repeat(200) {            // 封顶 200 页，防异常死循环
            val (files, cursor) = fetchCloudPage(parentFileId, token, next) ?: return all
            all += files
            next = cursor ?: return all   // Next=="-1" 时 cursor 为 null，结束
        }
        return all
    }

    /** 个人盘下载信息：POST /api/file/download_info（注意无 /b/，文档 §5.5）。返回真实直链 */
    suspend fun getDownloadLink(file: ShareFile, token: String): DownloadLink? = withContext(Dispatchers.Default) {
        val (s3keyFlag, etag, _) = decodeToken(file.fidToken)
        val body = buildJsonObject {}
            .withField("driveId", 0)
            .withField("etag", etag)
            .withField("fileId", file.fid.toLongOrNull() ?: 0L)
            .withField("s3keyFlag", s3keyFlag)
            .withField("type", 0)
            .withField("fileName", file.fname)
            .withField("size", file.fsize)
        val json = postAuth(
            Pan123Constants.FILE_DOWNLOAD_INFO_URL,
            "/api/file/download_info",
            body.toString(),
            token
        )
        checkOk(json, "获取下载链接失败")
        val data = json.optJsonObject("data") ?: return@withContext null
        val raw = data.optString("DownloadUrl")
        if (raw.isBlank()) return@withContext null
        // ★ 个人盘同样存在 download-v2?params=<base64> 包装（Web 平台头触发，Web 中转页不是可下载直链）：
        //   统一过 decodeDownloadUrl——能解码就给真实 CDN 直链；直链形态 decode 返回 null 回退 raw。
        //   绝不能用 startsWith("http") 短路：中转页 URL 同样以 http 开头，无法区分。
        val decoded = decodeDownloadUrl(raw) ?: raw
        // ★ 解码直链带 auto_redirect=0 时，CDN 返回 JSON（data.redirect_url）而非直接文件：
        //   取链阶段循环跟随 redirect_url，交给下载引擎的必须是最终可下载地址。
        val url = followRedirectUrl(decoded)
        DownloadLink(
            fid = file.fid,
            filename = file.fname,
            downloadUrl = url,
            size = file.fsize
        )
    }

    // ---------- 网盘管理操作（文档 §5.7-5.10） ----------

    /**
     * 保存他人分享到个人网盘（copy/save，文档 §4.3）。
     * ⚠️ mshare 子域**无需任何客户端签名**（源码实证 + 实测 code:0），仅带 Bearer + LoginUuid。
     * 转存是异步任务：返回 (taskID, ShareId) 用于轮询 copy/save/get。
     * @param toDirFid 转存目标目录 ID（个人盘 fileId；body 的 parentFileID/parentFileId 字段）
     */
    suspend fun copySave(
        shareKey: String,
        sharePwd: String,
        file: ShareFile,
        toDirFid: String,
        token: String
    ): Pair<Long, String>? = withContext(Dispatchers.Default) {
        val shareId = shareIdOf(file)
        if (shareId.isBlank()) throw IllegalStateException("无法识别分享 ID（缺少 S3KeyFlag）")
        val (s3KeyFlag, etag, storageNode) = decodeToken(file.fidToken)
        val fileId = file.fid.toLongOrNull() ?: 0L
        val parentId = toDirFid.toLongOrNull() ?: 0L
        val body = buildJsonObject {}
            .withField(
                "fileList",
                buildJsonArray {}.withField(
                    buildJsonObject {}
                        .withField("fileID", fileId)
                        .withField("fileId", fileId)
                        .withField("size", file.fsize)
                        .withField("etag", etag)
                        .withField("type", if (file.isdir) 1 else 0)
                        .withField("parentFileID", parentId)
                        .withField("parentFileId", parentId)
                        .withField("fileName", file.fname)
                        .withField("driveID", 0)
                        .withField("driveId", 0)
                        .withField("s3keyFlag", s3KeyFlag)
                        .withField("S3KeyFlag", s3KeyFlag)
                        .withField("StorageNode", storageNode)
                )
            )
            .withField("shareKey", shareKey)
            // 无提取码发空串 ""，不要发 null（文档 §4.3）
            .withField("sharePwd", sharePwd.ifBlank { "" })
            .withField("currentLevel", 1)
            .withField("superAdmin", JsonNull)
        val request = HttpRequestBuilder()
            .withUrl("https://$shareId.mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save")
            .withHeader("Authorization", "Bearer $token")
            .withHeader("LoginUuid", loginuuid)
            .withHeader("platform", Pan123Constants.PLATFORM_WEB)
            .withHeader("Content-Type", "application/json;charset=UTF-8")
            .withHeader("User-Agent", Pan123Constants.DART_UA)
            .withPost(body.toString().toRequestBody(jsonMediaType))

        val json = executeJson(request)
        checkOk(json, "转存失败")
        val taskId = json.optJsonObject("data")?.optLong("taskID") ?: return@withContext null
        taskId to shareId
    }

    /**
     * 轮询转存任务结果（GET copy/save/get?taskID=，同样无需签名）。
     * @return 转存成功后的新 fileId（无法解析时返回 taskId 字符串兜底）；超时返回 null
     */
    suspend fun pollCopySave(taskId: Long, shareId: String, token: String): String? = withContext(Dispatchers.Default) {
        repeat(15) {
            kotlinx.coroutines.delay(1000)
            val url =
                "https://$shareId.mshare.123pan.cn/b/api/restful/goapi/v1/file/copy/save/get?taskID=$taskId"
            val request = HttpRequestBuilder()
                .withUrl(url)
                .withHeader("Authorization", "Bearer $token")
                .withHeader("LoginUuid", loginuuid)
                .withHeader("platform", Pan123Constants.PLATFORM_WEB)
                .withHeader("User-Agent", Pan123Constants.DART_UA)
                .withGet()

            val json = executeJson(request)
            if (json.optInt("code", -1) != 0) {
                // 任务失败/异常：读取 message 抛错（若只是进行中则继续轮询）
                val msg = json.optString("message")
                if (msg.isNotBlank()) throw IllegalStateException("转存失败：$msg")
                return@repeat
            }
            val data = json.optJsonObject("data") ?: return@repeat
            // 完成标志（响应格式未在抓包完整呈现，容错多种形态）：
            val status = data.optInt("status", -1)
            val state = data.optString("state").lowercase()
            val done = data.optBoolean("finished", false) ||
                status == 2 || status == 3 ||
                state == "success" || state == "done" || state == "2" ||
                data.has("fileId") || data.has("FileId") || data.has("newFileId")
            if (done) {
                return@withContext data.optString("newFileId")
                    .ifBlank { data.optString("FileId") }
                    .ifBlank { data.optString("fileId") }
                    .ifBlank { taskId.toString() }
            }
        }
        null
    }

    /** 从分享列表项提取数值 ShareId（S3KeyFlag 形如 "1816216065-0"，前缀即 mshare 子域数字） */
    private fun shareIdOf(file: ShareFile): String {
        val s3 = file.fidToken.substringBefore('|')
        return s3.substringBefore('-')
    }

    /** 删除（移入回收站）：POST /b/api/file/trash */
    suspend fun deleteFiles(files: List<ShareFile>, token: String) = withContext(Dispatchers.Default) {
        var list = buildJsonArray {}
        files.forEach { f ->
            val (s3, etag, _) = decodeToken(f.fidToken)
            list = list.withField(
                buildJsonObject {}
                    .withField("FileId", f.fid.toLongOrNull() ?: 0L)
                    .withField("FileName", f.fname)
                    .withField("Type", if (f.isdir) 1 else 0)
                    .withField("Size", f.fsize)
                    .withField("S3KeyFlag", s3)
                    .withField("Etag", etag)
            )
        }
        val body = buildJsonObject {}
            .withField("driveId", 0)
            .withField("fileTrashInfoList", list)
            .withField("operation", true)
            .withField("event", "intoRecycle")
            .withField("operatePlace", 1)
            .withField("safeBox", false)
        val json = postAuth(Pan123Constants.FILE_TRASH_URL, "/b/api/file/trash", body.toString(), token)
        checkOk(json, "删除失败")
    }

    /** 重命名：POST /b/api/file/rename */
    suspend fun renameFile(fileId: String, newName: String, token: String) = withContext(Dispatchers.Default) {
        val body = buildJsonObject {}
            .withField("driveId", 0)
            .withField("fileId", fileId.toLongOrNull() ?: 0L)
            .withField("fileName", newName)
            .withField("duplicate", 1)
            .withField("event", "fileRename")
            .withField("operatePlace", "right")
            .withField("RequestSource", JsonNull)
        val json = postAuth(Pan123Constants.FILE_RENAME_URL, "/b/api/file/rename", body.toString(), token)
        checkOk(json, "重命名失败")
    }

    /**
     * 新建文件夹：复用上传预创建接口（`type=1`），123 没有独立的建目录端点（文档 §2/§8）。
     * 签名 path 必须与请求 path 逐字一致，所以这里把 `/b/api/file/upload_request` 写死传进 [postAuth]。
     *
     * @param parentFileId 父目录 id（根目录 "0"）
     * @return 新文件夹 id
     */
    suspend fun createDir(parentFileId: String, name: String, token: String): String =
        withContext(Dispatchers.Default) {
            val body = buildJsonObject {}
                .withField("driveId", 0)
                .withField("parentFileId", parentFileId.toLongOrNull() ?: 0L)
                .withField("fileName", name)
                .withField("size", 0)
                .withField("type", 1)
                .withField("etag", "")
                .withField("duplicate", 1)
                .withField("NotReuse", true)
                .withField("RequestSource", JsonNull)
            val json = postAuth(
                Pan123Constants.FILE_UPLOAD_REQUEST_URL,
                "/b/api/file/upload_request",
                body.toString(),
                token
            )
            checkOk(json, "新建文件夹失败")
            val data = json.optJsonObject("data") ?: throw IllegalStateException("123 未返回文件夹编号")
            // 文档给的取法：data.Info.FileId → data.FileId → data.fileId（大小写三种都出现过）
            val id = data.optJsonObject("Info")?.optString("FileId").orEmpty()
                .ifBlank { data.optString("FileId") }
                .ifBlank { data.optString("fileId") }
            id.takeIf { it.isNotBlank() && it != "0" }
                ?: throw IllegalStateException("123 未返回文件夹编号")
        }

    /** 移动：POST /b/api/file/mod_pid */
    suspend fun moveFiles(fileIds: List<String>, toParentFileId: String, token: String) = withContext(Dispatchers.Default) {
        var list = buildJsonArray {}
        fileIds.forEach { list = list.withField(buildJsonObject {}.withField("FileId", it.toLongOrNull() ?: 0L)) }
        val body = buildJsonObject {}
            .withField("fileIdList", list)
            .withField("parentFileId", toParentFileId.toLongOrNull() ?: 0L)
            .withField("event", "fileMove")
            .withField("operatePlace", 1)
            .withField("RequestSource", JsonNull)
        val json = postAuth(Pan123Constants.FILE_MOD_PID_URL, "/b/api/file/mod_pid", body.toString(), token)
        checkOk(json, "移动失败")
    }

    /**
     * 创建分享：POST /b/api/share/create（文档 §5.10）。
     * @param fileIds 文件/目录 ID 列表（单文件抓包为标量 int，多文件用数组）
     * @param expiration 过期时间 ISO**绝对时间**（永久用 Pan123Constants.EXPIRATION_FOREVER，其余 =
     *   now + 天数）。⚠️ 必须先用 [com.yunx.app.data.network.model.ShareExpire.daysOrNull] 把 UI
     *   中性码转成天数——直接把中性码当天数会让「永久」变成 now+1 天、「7 天」变成 now+3 天（Agent.md §3.20）。
     * @param sharePwd 提取码（null/空 = 无提取码）
     */
    suspend fun createShare(
        fileIds: List<String>,
        shareName: String,
        expiration: String,
        sharePwd: String?,
        token: String
    ): ShareInfo = withContext(Dispatchers.Default) {
        val body = buildJsonObject {}
            .withField("driveId", 0)
            .withField("expiration", expiration)
            .edit {
                if (fileIds.size == 1) {
                    put("fileIdList", fileIds[0].toLongOrNull() ?: 0L)
                } else {
                    put("fileIdList", buildJsonArray { fileIds.forEach { add(jsonValue(it.toLongOrNull() ?: 0L)) } })
                }
            }
            .withField("shareName", shareName)
            .withField("event", "shareCreate")
            .withField("fileNum", fileIds.size)
            .withField("shareModality", 4)
            .withField("trafficLimitSwitch", 1)
            .withField("trafficLimit", 0)
            .withField("trafficSwitch", 1)
            .withField("fillPwdSwitch", 0)
            .edit { if (!sharePwd.isNullOrBlank()) put("sharePwd", sharePwd) }
        val json = postAuth(Pan123Constants.SHARE_CREATE_URL, "/b/api/share/create", body.toString(), token)
        checkOk(json, "创建分享失败")
        val data = json.optJsonObject("data")
            ?: throw IllegalStateException("创建分享失败：未返回数据")
        val shareKey = data.optString("ShareKey")
        if (shareKey.isBlank()) throw IllegalStateException("创建分享失败：未返回 ShareKey")
        val linkList = data.optJsonObject("shareLinkList")
        val shareUrl = linkList?.optJsonArray("list")?.optString(0)
            ?.takeIf { it.isNotBlank() }
            ?: linkList?.optString("standBy")
                ?.takeIf { it.isNotBlank() }
                ?: "https://www.123pan.com/s/$shareKey"
        ShareInfo(
            shareUrl = shareUrl,
            passcode = sharePwd.orEmpty(),
            pwdId = shareKey,
            title = shareName,
            // 123 响应不返回有效期；调用方（Pan123CloudViewModel）会用用户所选中性码覆盖此处，
            // 未覆盖时显示「未知」比硬猜「30 天」更安全（原实现 else -> 4 是错的）
            expiredType = ShareExpire.UNKNOWN
        )
    }

    // ---------- 内部工具 ----------

    /** 解析响应 InfoList（分享与个人盘结构一致，文档 §5.2/§5.4） */
    private fun parseInfoList(data: JsonObject): List<ShareFile> {
        val arr = data.optJsonArray("InfoList") ?: return emptyList()
        return buildList {
            for (i in 0 until arr.length()) {
                val item = arr.optJsonObject(i) ?: continue
                val type = item.optInt("Type", 0)
                add(
                    ShareFile(
                        fid = item.optString("FileId"),
                        fname = item.optString("FileName"),
                        fsize = item.optLong("Size"),
                        isdir = type == 1,
                        pdirFid = item.optString("ParentFileId"),
                        // 123 下载/转存需要 S3KeyFlag + Etag + StorageNode，编码进 fidToken："S3KeyFlag|Etag|StorageNode"
                        fidToken = "${item.optString("S3KeyFlag")}|${item.optString("Etag")}|${item.optString("StorageNode")}",
                        modifyTime = item.optString("UpdateAt")
                    )
                )
            }
        }
    }

    /** 解码 fidToken（"S3KeyFlag|Etag|StorageNode"；旧格式两段时 StorageNode 为空） */
    private fun decodeToken(fidToken: String): Triple<String, String, String> {
        val parts = fidToken.split('|')
        return Triple(
            parts.getOrNull(0) ?: "",
            parts.getOrNull(1) ?: "",
            parts.getOrNull(2) ?: ""
        )
    }

    /** 解码 123 下载 URL（兼容两种形态，文档 §5.3.1）：
     *  - 形态 1：整段 base64（alist 风格）→ 直接解码
     *  - 形态 2：download-v2?params=<base64 URL-safe> → 解码 params
     */
    private fun decodeDownloadUrl(downloadUrl: String): String? {
        val trimmed = downloadUrl.trim()
        // 形态 1：整段 base64（不含协议头的串）
        if (!trimmed.contains("://")) {
            return runCatching {
                (decodeBase64(trimmed)).decodeToString()
                    .takeIf { it.startsWith("http", ignoreCase = true) }
            }.getOrNull()
        }
        // 形态 2：download-v2?params=<base64>
        val idx = trimmed.indexOf("params=")
        if (idx < 0) return null
        val params = trimmed.substring(idx + "params=".length).substringBefore("&")
        return runCatching {
            val normalized = params.replace('-', '+').replace('_', '/')
            (decodeBase64(normalized)).decodeToString()
        }.getOrNull()
    }

    /**
     * 跟随 123 CDN 的 redirect_url：带 `auto_redirect=0` 时，GET 直链返回
     * JSON `{"code":0,"data":{"redirect_url":"https://...pd1.cjjd19.com/..."}}` 而非直接文件，
     * 且 redirect_url 自身也可能带 auto_redirect=0（可能多跳）。这里循环跟随（最多 5 跳），
     * 每跳仅当响应体很小（≤8KB，JSON 跳转页）才读取解析；大响应视为真实文件流，返回当前 URL。
     */
    private suspend fun followRedirectUrl(initialUrl: String): String {
        var url = initialUrl
        repeat(5) {
            val next = probeJsonRedirect(url) ?: return url
            url = next
        }
        return url
    }

    /** 探测单跳：响应为小 JSON 且含 data.redirect_url 时返回新地址，否则 null（当前 URL 即最终可下载地址） */
    private suspend fun probeJsonRedirect(url: String): String? = runCatching {
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("Referer", Pan123Constants.DOWNLOAD_REFERER)
            .withHeader("User-Agent", Pan123Constants.DART_UA)
            .withGet()

        client.executeRequest(request).let { response ->
            val len = response.headers["Content-Length"]?.toLongOrNull() ?: -1L
            if (len >= 0 && len <= 8192) {
                val body = response.bodyAsText() ?: return@let null
                if (body.trimStart().startsWith("{")) {
                    runCatching {
                        parseJsonObject(body).optJsonObject("data")
                            ?.optString("redirect_url")
                            ?.takeIf { it.isNotBlank() }
                    }.getOrNull()
                } else null
            } else null
        }
    }.getOrNull()

    /** 成功判定：code == 0（登录接口除外，为 200） */
    private fun checkOk(json: JsonObject, fallback: String) {
        val code = json.optInt("code", -1)
        if (code == 0) return
        val msg = json.optString("message").ifBlank { fallback }
        throw IllegalStateException("$msg（code=$code）")
    }

    /** 鉴权 GET（带 auth-key/auth-value 签名头） */
    private suspend fun getAuth(url: String, path: String, token: String): JsonObject {
        val (ak, av) = makeSign(path)
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("platform", Pan123Constants.PLATFORM_WEB)
            .withHeader("app-version", Pan123Constants.APP_VERSION_WEB)
            .withHeader("authorization", "Bearer $token")
            .withHeader("loginuuid", loginuuid)
            .withHeader("auth-key", ak)
            .withHeader("auth-value", av)
            .withHeader("User-Agent", Pan123Constants.WEB_UA)
            .withHeader("Accept", "application/json, text/plain, */*")
            .withGet()

        return executeJson(request)
    }

    /** 鉴权 POST（带 auth-key/auth-value 签名头；签名内部固定 web/3） */
    private suspend fun postAuth(
        url: String,
        path: String,
        body: String,
        token: String,
        platform: String = Pan123Constants.PLATFORM_WEB,
        appVersion: String = Pan123Constants.APP_VERSION_WEB
    ): JsonObject {
        val (ak, av) = makeSign(path)
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("platform", platform)
            .withHeader("app-version", appVersion)
            .withHeader("authorization", "Bearer $token")
            .withHeader("loginuuid", loginuuid)
            .withHeader("auth-key", ak)
            .withHeader("auth-value", av)
            .withHeader("Content-Type", "application/json;charset=UTF-8")
            .withHeader("User-Agent", Pan123Constants.WEB_UA)
            .withPost(body.toRequestBody(jsonMediaType))

        return executeJson(request)
    }

    private suspend fun executeJson(request: HttpRequestBuilder): JsonObject {
        client.executeRequest(request).let { response ->
            val body = response.bodyAsText()
                ?: throw IllegalStateException("请求失败：响应为空（${response.status.value}）")
            if (!response.status.isSuccess() && body.isBlank()) {
                throw IllegalStateException("请求失败（HTTP ${response.status.value}）")
            }
            return parseJsonObject(body)
        }
    }
}
