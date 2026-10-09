@file:OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)

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
 * 139 网盘 API 封装（OkHttp）。
 * 登录态：cookie（含账号信息，authorization 可选）。
 * 分享解析（§15，7.13+）：share-kd-njs.yun.139.com
 *   - 列目录 getOutLinkInfoV6（pCaID:"root"/父coID，passwd 提取码）
 *   - 下载 dlFromOutLinkV3（coIDLst.item:[coID] → data.redrUrl OBS 直链，900s）
 * 分享接口请求/响应均经 AES-CBC 加密（§14）：base64(IV(16B) ‖ AES_CBC(KEY=PVGDwmcvfs1uV3d1, IV, 明文))；
 * mcloud-sign 按「明文 body」计算（§4），加密只是传输包装；mcloud-skey 可省略。
 */
class C139Api(
    private val clientProvider: () -> HttpClient = { HttpClients.apiClient() }
) {
    /** 每次请求动态获取全局客户端（忽略 SSL 开关切换即时生效） */
    private val client get() = clientProvider()

    private val jsonMediaType = "application/json;charset=UTF-8"

    private val shareAesKey = C139Constants.SHARE_AES_KEY.encodeToByteArray()

    // ---------- mcloud-sign 签名（§4） ----------

    private fun md5(s: String): String {
        return md5Hex(s.encodeToByteArray())
    }

    /** §4.1：encodeURIComponent（+→%20，并还原 ! ' ( ) *） */
    private fun encodeURIComponent(s: String): String =
        formEncode(s)
            .replace("+", "%20")
            .replace("%21", "!")
            .replace("%27", "'")
            .replace("%28", "(")
            .replace("%29", ")")
            .replace("%2A", "*")

    /**
     * §4.2 calSign：
     * body' 单字符 ASCII 升序 → base64 → md5(base64) + md5(ts:rand) → md5 → upper。
     * 注意：签名必须基于与实际发送一致的「明文 JSON」字符串（字段顺序、无空格）。
     */
    fun calSign(bodyJson: String, ts: String, rand: String): String {
        val encoded = encodeURIComponent(bodyJson)
        val sorted = encoded.toCharArray().sorted().joinToString("")
        val b64 = Base64.encode(sorted.encodeToByteArray())
        val res = md5(b64) + md5("$ts:$rand")
        return md5(res).uppercase()
    }

    /** 生成 mcloud-sign 头值：<ts>,<rand>,<sign>；ts 格式 YYYY-MM-DD HH:MM:SS，rand 16 位字母数字 */
    fun signHeader(bodyJson: String): String {
        val ts = localSignTime()
        val rand = buildString {
            val pool = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
            repeat(16) { append(pool.random()) }
        }
        return "$ts,$rand,${calSign(bodyJson, ts, rand)}"
    }

    /**
     * 从 authorization（"Basic base64(pc:账号:authToken)"）解码账号。
     * §3.2 最终态：Authorization = base64("pc:<account>:<authToken>")。
     */
    fun accountFromAuthorization(authorization: String): String? = runCatching {
        val b64 = authorization.removePrefix("Basic").trim()
        val decoded = (decodeBase64(b64)).decodeToString()
        decoded.split(":").getOrNull(1)?.takeIf { it.isNotBlank() }
    }.getOrNull()

    // ---------- §14 分享接口 AES-CBC 加解密（固定密钥 + IV 前置） ----------

    /** 明文 JSON → 加密 base64（IV(16B) 前置） */
    private fun encryptBody(plaintext: String): String {
        val iv = secureRandomBytes(16)
        val ct = aesCrypt(plaintext.encodeToByteArray(), shareAesKey, iv, true)
        return Base64.encode(iv + ct)
    }

    /** 加密 base64 → 明文 JSON；解密后若为 gzip（首 2 字节 0x1f 0x8b）先解压（alist YunCrypto 同款） */
    private fun decryptBody(b64: String): String {
        val raw = decodeBase64(b64)
        val iv = raw.copyOfRange(0, 16)
        val ct = raw.copyOfRange(16, raw.size)
        var d = aesCrypt(ct, shareAesKey, iv, false)  // PKCS5Padding 自动去填充
        // alist YunCrypto 同款：解密后若为 gzip 则解压（首 2 字节 0x1f 0x8b）
        if (d.size > 2 && d[0] == 0x1f.toByte() && d[1] == 0x8b.toByte()) {
            d = gunzip(d)
        }
        return (d).decodeToString()
    }

    // ---------- 分享解析（§15，7.13+ 加密） ----------

    /**
     * 分享标题：getOutLinkGeneral（匿名，§2.3）→ data.getOutLinkGeneralResp.outLinkGeneral[].lkName；
     * 失败返回 null。
     */
    suspend fun getOutLinkTitle(linkId: String): String? = withContext(Dispatchers.Default) {
        val req = buildJsonObject {}
            .withField("linkID", linkId)
            .withField("isPasswd", 1)
            .withField("account", "")
        val plain = buildJsonObject {}.withField("getOutLinkGeneralReq", req).toString()
        val respJson = sharePostAnonymous(C139Constants.SHARE_GENERAL_URL, plain)
        val resultCode = respJson.optString("resultCode")
        if (resultCode.isNotBlank() && resultCode != "0") return@withContext null
        if (!respJson.optBoolean("success", true)) return@withContext null
        val data = respJson.optJsonObject("data")
            ?.optJsonObject("getOutLinkGeneralResp") ?: return@withContext null
        val array = data.optJsonArray("outLinkGeneral") ?: return@withContext null
        if (array.length() == 0) return@withContext null
        array.optJsonObject(0)?.optString("lkName")?.takeIf { it.isNotBlank() }
    }

    /**
     * 分享明文提取码：getOutLinkGeneral（匿名）→ outLinkGeneral[].passwd。
     * 139 会在该接口明文回吐提取码（官方 Web 同样自动填），用于自动填入、避免下载因缺密码报 9188。
     */
    suspend fun getOutLinkPassword(linkId: String): String? = withContext(Dispatchers.Default) {
        val req = buildJsonObject {}
            .withField("linkID", linkId)
            .withField("isPasswd", 1)
            .withField("account", "")
        val plain = buildJsonObject {}.withField("getOutLinkGeneralReq", req).toString()
        val respJson = sharePostAnonymous(C139Constants.SHARE_GENERAL_URL, plain)
        val resultCode = respJson.optString("resultCode")
        if (resultCode.isNotBlank() && resultCode != "0") return@withContext null
        if (!respJson.optBoolean("success", true)) return@withContext null
        val data = respJson.optJsonObject("data")
            ?.optJsonObject("getOutLinkGeneralResp") ?: return@withContext null
        val array = data.optJsonArray("outLinkGeneral") ?: return@withContext null
        if (array.length() == 0) return@withContext null
        array.optJsonObject(0)?.optString("passwd")?.takeIf { it.isNotBlank() }
    }

    /**
     * 分享列目录：getOutLinkInfoV6 —— 官方为「匿名」调用（§9530修复文档 §2/§3）：
     * 不带 authorization、不带 mcloud-sign、不带 mcloud-* 头；body account 固定空串；
     * 带完整字段（caSrt/coSrt/srtDr/bNum/eNum），否则 9530；passwd 填错返回 9188。
     * ⚠️ 139 把【子文件夹】放在 caLst、【文件】放在 coLst（coType==2 也可能是文件夹）。
     *    原实现只读了 coLst，导致「顶层是文件夹 / 顶层只挂子文件夹」的分享显示为空。
     *    现同时解析 caLst + coLst 并合并返回（文件夹在前）。
     * @param pcaId 根目录传 "root"（不能为空，§16.2），子目录传父级 caID（或 coType==2 的 coID）
     * @param passwd 提取码（无则空串）
     * @return 文件夹（caLst）+ 文件/嵌套文件夹（coLst）合并列表；空目录返回 emptyList
     */
    suspend fun getShareFiles(
        linkId: String,
        pcaId: String,
        passwd: String,
        begin: Int = 1,
        end: Int = 200
    ): List<ShareFile> = withContext(Dispatchers.Default) {
        val req = buildJsonObject {}
            .withField("account", "")            // 列表端点 account 必须为空串，且本调用不带鉴权头（§3）
            .withField("linkID", linkId)
            .withField("passwd", passwd)
            .withField("caSrt", 1)               // 排序：目录按创建时间
            .withField("coSrt", 1)               // 排序：文件按创建时间
            .withField("srtDr", 0)               // 排序方向：降序
            .withField("bNum", begin)            // 分页起始
            .withField("pCaID", pcaId)
            .withField("eNum", end)              // 分页结束
        val plain = buildJsonObject {}.withField("getOutLinkInfoReq", req).toString()
        val respJson = sharePostAnonymous(C139Constants.SHARE_LIST_URL, plain)
        val resultCode = respJson.optString("resultCode")
        if (resultCode.isNotBlank() && resultCode != "0") {
            throw IllegalStateException(respJson.optString("desc").ifBlank { "获取文件列表失败（$resultCode）" })
        }
        if (!respJson.optBoolean("success", true)) {
            throw IllegalStateException(respJson.optString("desc").ifBlank { "获取文件列表失败" })
        }
        val data = respJson.optJsonObject("data") ?: return@withContext emptyList()
        val result = mutableListOf<ShareFile>()

        // 1) 子文件夹列表 caLst（之前被完全忽略 → 根因：含子文件夹的分享显示为空）
        data.optJsonArray("caLst")?.let { ca ->
            for (i in 0 until ca.length()) {
                val item = ca.optJsonObject(i) ?: continue
                result.add(
                    ShareFile(
                        fid = item.optString("caID"),
                        fname = item.optString("caName"),
                        fsize = 0,
                        isdir = true,
                        pdirFid = pcaId,
                        fidToken = "",
                        modifyTime = item.optString("udTime").ifBlank { item.optString("ctTime") }
                    )
                )
            }
        }

        // 2) 文件列表 coLst（含 coType==2 的文件夹）
        data.optJsonArray("coLst")?.let { co ->
            for (i in 0 until co.length()) {
                val item = co.optJsonObject(i) ?: continue
                result.add(
                    ShareFile(
                        fid = item.optString("coID"),
                        fname = item.optString("coName"),
                        fsize = item.optLong("coSize"),
                        isdir = item.optBoolean("isdir", item.optInt("coType", 1) == 2),
                        pdirFid = pcaId,
                        fidToken = "",
                        modifyTime = item.optString("udTime").ifBlank { item.optString("ctTime") }
                    )
                )
            }
        }
        result   // 空目录返回 emptyList，UI 显示「此目录为空」（保持原语义）
    }

    /**
     * 分享下载：dlFromOutLinkV3 → data.redrUrl（OBS S3 签名直链，900s 有效）。
     * @param coId Step1 列目录得到的 coID
     */
    suspend fun getShareDownloadLink(
        coId: String,
        linkId: String,
        account: String,
        authorization: String?
    ): DownloadLink? = withContext(Dispatchers.Default) {
        val reqV3 = buildJsonObject {}
            .withField("account", account)
            .withField("linkID", linkId)
            .withField("coIDLst", buildJsonObject {}.withField("item", buildJsonArray {}.withField(coId)))
            .withField(
                "commonAccountInfo",
                buildJsonObject {}.withField("account", account).withField("accountType", 1)
            )
        val plain = buildJsonObject {}.withField("dlFromOutLinkReqV3", reqV3).toString()
        val respJson = sharePostEncrypted(C139Constants.SHARE_LINK_URL, plain, authorization)
        val resultCode = respJson.optString("resultCode")
        if (resultCode.isNotBlank() && resultCode != "0") {
            throw IllegalStateException(respJson.optString("desc").ifBlank { "获取下载链接失败（$resultCode）" })
        }
        if (!respJson.optBoolean("success", true)) {
            throw IllegalStateException(respJson.optString("desc").ifBlank { "获取下载链接失败" })
        }
        val data = respJson.optJsonObject("data") ?: return@withContext null
        val url = data.optString("redrUrl")
        if (url.isBlank()) return@withContext null
        DownloadLink(
            fid = coId,
            filename = data.optString("fileName").ifEmpty { data.optString("coName").ifEmpty { coId } },
            downloadUrl = url,
            size = data.optLong("coSize", data.optLong("size"))
        )
    }

    // ---------- 个人网盘管理（§1 明文 JSON + Authorization + mcloud-sign，无 Cookie） ----------

    /** 异步任务状态（移动/删除轮询） */
    data class C139TaskStatus(
        val status: String,
        val progress: Int,
        val results: List<Pair<String, String>>
    )

    /** 转存结果（分享导入） */
    data class C139TransferResult(
        val done: Boolean,
        val mapping: Map<String, String>
    )

    /** 单页列目录（含翻页游标）；返回 (文件列表, 下一页游标 or null=末页) */
    private suspend fun fetchCloudPage(
        parentFileId: String,
        cookie: String,
        pageCursor: String?
    ): Pair<List<ShareFile>, String?>? = withContext(Dispatchers.Default) {
        val authorization = C139Constants.extractAuthorization(cookie)
            ?: throw IllegalStateException("登录态缺少 authorization，请重新登录")
        // ⚠️ pageCursor 必须是真正的 JSON null；若误传字符串 "null"，服务端会当作无效游标忽略
        //    并回吐第一页，导致翻页原地打转（抓包表现为重复发同一个请求直到封顶）
        val cursorValue: Any =
            pageCursor?.takeIf { it.isNotBlank() && it != "null" } ?: JsonNull
        val req = buildJsonObject {}
            .withField("pageInfo", buildJsonObject {}.withField("pageSize", 100).withField("pageCursor", cursorValue))
            .withField("orderBy", "updated_at")
            .withField("orderDirection", "DESC")
            .withField("parentFileId", parentFileId)
            .withField("imageThumbnailStyleList", buildJsonArray {}.withField("Small").withField("Large"))
        val resp = cloudPost(C139Constants.FILE_LIST_URL, req.toString(), authorization)
        checkCloud(resp, "获取文件列表失败")
        val data = resp.optJsonObject("data") ?: return@withContext null
        val files = buildList {
            data.optJsonArray("items")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val item = arr.optJsonObject(i) ?: continue
                    add(
                        ShareFile(
                            fid = item.optString("fileId"),
                            fname = item.optString("name"),
                            fsize = item.optLong("size"),
                            isdir = item.optString("type") == "folder",
                            pdirFid = parentFileId,
                            fidToken = item.optString("fileId"),
                            modifyTime = item.optString("updatedAt")
                        )
                    )
                }
            }
        }
        // ⚠️ Android org.json 陷阱：响应中 "nextPageCursor": null 时，optString 返回的是
        //    字符串 "null"（JsonNull.toString()）而非空串，isNotBlank 判定为「还有下一页」，
        //    于是带着 "null" 游标反复请求首页 → 200 次重复请求、列表加载极慢。
        //    必须先用 isNull() 判断真 JSON null，并额外过滤字符串 "null"。
        val next = if (data.isNull("nextPageCursor")) {
            null
        } else {
            data.optString("nextPageCursor").takeIf { it.isNotBlank() && it != "null" }
        }
        Pair(files, next)
    }

    /** 列目录（自动翻页，返回该目录下全部文件）；pageCursor 为起始游标（一般传 null=从头） */
    suspend fun listCloudFiles(
        parentFileId: String,
        cookie: String,
        pageCursor: String? = null
    ): List<ShareFile> {
        val all = mutableListOf<ShareFile>()
        val seen = HashSet<String>()
        var cursor = pageCursor
        repeat(200) {            // 封顶 200 页，防异常死循环
            val (files, next) = fetchCloudPage(parentFileId, cookie, cursor) ?: return all
            // 139 按 updated_at 排序翻页，大量文件时间相同时游标可能重复返回边界项，
            // 按 fid 去重，避免同一 fid 重复导致 LazyColumn key 冲突崩溃
            for (f in files) {
                if (f.fid.isNotBlank() && seen.add(f.fid)) all.add(f)
            }
            // 末页：nextPageCursor 为 JSON null
            if (next == null) return all
            // 游标未推进（服务端异常回吐同一游标）→ 立即终止，避免重复请求同一页
            if (next == cursor) return all
            cursor = next
        }
        return all
    }

    /** 仅列文件夹（移动到…目标选择） */
    suspend fun listFolders(parentFileId: String, cookie: String): List<ShareFile> = withContext(Dispatchers.Default) {
        val authorization = C139Constants.extractAuthorization(cookie)
            ?: throw IllegalStateException("登录态缺少 authorization，请重新登录")
        val req = buildJsonObject {}
            .withField("pageInfo", buildJsonObject {}.withField("pageSize", 100).withField("pageCursor", JsonNull))
            .withField("orderBy", "updated_at")
            .withField("orderDirection", "DESC")
            .withField("parentFileId", parentFileId)
            .withField("imageThumbnailStyleList", buildJsonArray {}.withField("Small").withField("Large"))
            .withField("type", "folder")
        val resp = cloudPost(C139Constants.FILE_LIST_URL, req.toString(), authorization)
        checkCloud(resp, "获取文件夹列表失败")
        val data = resp.optJsonObject("data") ?: return@withContext emptyList()
        buildList {
            data.optJsonArray("items")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val item = arr.optJsonObject(i) ?: continue
                    add(
                        ShareFile(
                            fid = item.optString("fileId"),
                            fname = item.optString("name"),
                            fsize = 0,
                            isdir = true,
                            pdirFid = parentFileId,
                            fidToken = item.optString("fileId"),
                            modifyTime = item.optString("updatedAt")
                        )
                    )
                }
            }
        }
    }

    /**
     * 新建文件夹（个人盘）：`POST /hcy/file/create`（文档 §3.13，靠 `type='folder'` 与上传预创建共用端点）。
     * `fileRenameMode='force_rename'`：重名由服务端自动改名（文档只列了这个取值，具体后缀格式未写）。
     *
     * @param parentFileId 父目录 fileId；本项目的根目录沿用列目录/移动的约定传 `"/"`
     * @return 新文件夹的 fileId
     */
    suspend fun createDir(parentFileId: String, name: String, cookie: String): String =
        withContext(Dispatchers.Default) {
            val authorization = C139Constants.extractAuthorization(cookie)
                ?: throw IllegalStateException("登录态缺少 authorization，请重新登录")
            val req = buildJsonObject {}
                .withField("parentFileId", parentFileId)
                .withField("name", name)
                .withField("description", "")
                .withField("type", "folder")
                .withField("fileRenameMode", "force_rename")
            val resp = cloudPost(C139Constants.FILE_CREATE_URL, req.toString(), authorization)
            checkCloud(resp, "新建文件夹失败")
            resp.optJsonObject("data")?.optString("fileId")?.takeIf { it.isNotBlank() }
                ?: throw IllegalStateException("移动云盘未返回文件夹编号")
        }

    /** 重命名 */
    suspend fun renameFile(fileId: String, newName: String, cookie: String): Boolean = withContext(Dispatchers.Default) {
        val authorization = C139Constants.extractAuthorization(cookie)
            ?: throw IllegalStateException("登录态缺少 authorization，请重新登录")
        val req = buildJsonObject {}
            .withField("fileId", fileId)
            .withField("name", newName)
            .withField("description", "")
        val resp = cloudPost(C139Constants.FILE_UPDATE_URL, req.toString(), authorization)
        checkCloud(resp, "重命名失败")
        true
    }

    /** 移动（异步），返回 taskId */
    suspend fun moveFiles(fileIds: List<String>, toParentFileId: String, cookie: String): String? = withContext(Dispatchers.Default) {
        val authorization = C139Constants.extractAuthorization(cookie)
            ?: throw IllegalStateException("登录态缺少 authorization，请重新登录")
        val req = buildJsonObject {}
            .withField("fileIds", buildJsonArray { fileIds.forEach { add(jsonValue(it)) } })
            .withField("toParentFileId", toParentFileId)
        val resp = cloudPost(C139Constants.BATCH_MOVE_URL, req.toString(), authorization)
        checkCloud(resp, "移动失败")
        resp.optJsonObject("data")?.optString("taskId")?.takeIf { it.isNotBlank() }
    }

    /** 删除（异步，移入回收站），返回 taskId */
    suspend fun deleteFiles(fileIds: List<String>, cookie: String): String? = withContext(Dispatchers.Default) {
        val authorization = C139Constants.extractAuthorization(cookie)
            ?: throw IllegalStateException("登录态缺少 authorization，请重新登录")
        val req = buildJsonObject {}.withField("fileIds", buildJsonArray { fileIds.forEach { add(jsonValue(it)) } })
        val resp = cloudPost(C139Constants.BATCH_TRASH_URL, req.toString(), authorization)
        checkCloud(resp, "删除失败")
        resp.optJsonObject("data")?.optString("taskId")?.takeIf { it.isNotBlank() }
    }

    /** 异步任务轮询（移动/删除），返回状态 */
    suspend fun getTask(taskId: String, cookie: String): C139TaskStatus = withContext(Dispatchers.Default) {
        val authorization = C139Constants.extractAuthorization(cookie)
            ?: throw IllegalStateException("登录态缺少 authorization，请重新登录")
        val req = buildJsonObject {}.withField("taskId", taskId)
        val resp = cloudPost(C139Constants.TASK_GET_URL, req.toString(), authorization)
        checkCloud(resp, "查询任务失败")
        val data = resp.optJsonObject("data") ?: return@withContext C139TaskStatus("", 0, emptyList())
        val taskInfo = data.optJsonObject("taskInfo")
        val status = taskInfo?.optString("status") ?: ""
        val progress = taskInfo?.optInt("progress") ?: 0
        val results = buildList {
            data.optJsonArray("batchFileResults")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val item = arr.optJsonObject(i) ?: continue
                    add(item.optString("fileId") to item.optString("errCode"))
                }
            }
        }
        C139TaskStatus(status, progress, results)
    }

    /** 下载直链（OBS 预签名，900s 有效） */
    suspend fun getDownloadUrl(fileId: String, cookie: String): DownloadLink? = withContext(Dispatchers.Default) {
        val authorization = C139Constants.extractAuthorization(cookie)
            ?: throw IllegalStateException("登录态缺少 authorization，请重新登录")
        val req = buildJsonObject {}.withField("fileId", fileId)
        val resp = cloudPost(C139Constants.DOWNLOAD_URL, req.toString(), authorization)
        checkCloud(resp, "获取下载链接失败")
        val data = resp.optJsonObject("data") ?: return@withContext null
        val url = data.optString("url")
        if (url.isBlank()) return@withContext null
        DownloadLink(
            fid = fileId,
            // getDownloadUrl 响应不含 name（§4.6 仅 url/expiration/size）；文件名由调用方用列表 name 填充
            filename = data.optString("name"),
            downloadUrl = url,
            size = data.optLong("size")
        )
    }

    /** 创建分享（getOutLink，需 Cookie + mcloud-skey；提取码系统自动生成）
     *
     *  @param period 有效期**天数**：null=永久（不传 period 字段）、1/7/30=天数。
     *    ⚠️ 这里不是 UI 中性码（1/2/3/4），调用方必须先用 [com.yunx.app.data.network.model.ShareExpire.daysOrNull]
     *    转换——否则「永久」会变成 1 天、「7 天」会变成 3 天（Agent.md §3.20）。
     */
    suspend fun createShare(
        coIDLst: List<String>,
        caIDLst: List<String>,
        period: Int?,
        dedicatedName: String,
        cookie: String
    ): ShareInfo = withContext(Dispatchers.Default) {
        val authorization = C139Constants.extractAuthorization(cookie)
            ?: throw IllegalStateException("登录态缺少 authorization，请重新登录")
        val account = accountFromAuthorization(authorization)
            ?: throw IllegalStateException("无法从登录态解析账号，请重新登录")
        val getOutLinkReq = buildJsonObject {}
            .withField("subLinkType", 0)
            .withField("encrypt", 1)
            .withField("coIDLst", buildJsonArray { coIDLst.forEach { add(jsonValue(it)) } })
            .withField("caIDLst", buildJsonArray { caIDLst.forEach { add(jsonValue(it)) } })
            .withField("pubType", 1)
            .withField("dedicatedName", dedicatedName)
            .withField("periodUnit", 1)
            .edit { if (period != null) put("period", period) }
            .withField("viewerLst", buildJsonArray {})
            .withField("extInfo", buildJsonObject {}.withField("isWatermark", 0).withField("shareChannel", "3001"))
            .withField("commonAccountInfo", buildJsonObject {}.withField("account", account).withField("accountType", 1))
        val plain = buildJsonObject {}.withField("getOutLinkReq", getOutLinkReq).toString()
        val resp = cloudPost(C139Constants.OUTLINK_CREATE_URL, plain, authorization, cookie, needSkey = true)
        // 分享接口成功码为 "0"
        if (!resp.optBoolean("success", true) || resp.optString("code") != "0") {
            throw IllegalStateException(resp.optString("message").ifBlank { "创建分享失败" })
        }
        val set = resp.optJsonObject("data")
            ?.optJsonObject("getOutLinkRes")
            ?.optJsonArray("getOutLinkResSet")
            ?.optJsonObject(0)
            ?: throw IllegalStateException("创建分享失败：未返回链接")
        val linkUrl = set.optString("linkUrl")
        if (linkUrl.isBlank()) throw IllegalStateException("创建分享失败：未返回链接")
        ShareInfo(
            shareUrl = linkUrl,
            passcode = set.optString("passwd"),
            pwdId = set.optString("linkID"),
            title = dedicatedName,
            // 139 响应不返回有效期，只能按请求时用的天数回填中性码；未知取值显示「未知」而不是猜「永久」
            expiredType = when (period) {
                null -> ShareExpire.FOREVER
                1 -> ShareExpire.ONE_DAY
                7 -> ShareExpire.SEVEN_DAYS
                30 -> ShareExpire.THIRTY_DAYS
                else -> ShareExpire.UNKNOWN
            }
        )
    }

    // ---------- 网盘空间详情 ----------

    /** 网盘空间详情（POST user-njs.yun.139.com/user/disk/quota/detail：diskSize/freeDiskSize，单位 MB；需 Cookie+mcloud-skey） */
    suspend fun getQuota(cookie: String): QuotaInfo? = withContext(Dispatchers.Default) {
        val authorization = C139Constants.extractAuthorization(cookie)
            ?: return@withContext null
        val account = accountFromAuthorization(authorization) ?: return@withContext null
        runCatching {
            val req = buildJsonObject {}
                .withField("userDomainId", "")
                .withField("commonAccountInfo", buildJsonObject {}.withField("account", account).withField("accountType", 1))
            val resp = cloudPost(
                "https://user-njs.yun.139.com/user/disk/quota/detail",
                req.toString(), authorization, cookie, needSkey = true
            )
            checkCloud(resp, "获取空间详情失败")
            val data = resp.optJsonObject("data") ?: return@runCatching null
            val total = data.optLong("diskSize") * 1024L * 1024L
            val used = data.optLong("freeDiskSize").let { free ->
                // quotaList[0] = 个人云（我的文件）已用（MB）
                data.optJsonArray("quotaList")?.optJsonObject(0)?.optLong("usedSize")?.times(1024L * 1024L)
                    ?: (total - free * 1024L * 1024L)
            }
            QuotaInfo(used = used, total = total)
        }.getOrNull()
    }

    // ---------- 转存（分享导入，share host AES 加密） ----------

    /** 创建转存任务，返回 taskID（含 sk* 前缀） */
    suspend fun createTransferTask(
        coIDLst: List<String>,
        catalogIDLst: List<String>,
        toFolderId: String,
        linkID: String,
        account: String,
        authorization: String?
    ): String? = withContext(Dispatchers.Default) {
        val taskInfo = buildJsonObject {}
            .withField("contentInfoList", buildJsonArray { coIDLst.forEach { add(jsonValue("/$it")) } })
            .withField("catalogInfoList", buildJsonArray { catalogIDLst.forEach { add(jsonValue(it)) } })
            .withField("newCatalogID", toFolderId)
            .withField("linkID", linkID)
            .withField("newCatalogName", "手机图片")
            .withField("needPassword", true)
        val req = buildJsonObject {}
            .withField("createOuterLinkBatchOprTaskReq", buildJsonObject {}
                .withField("msisdn", account)
                .withField("ownerAccount", "")
                .withField("taskType", 1)
                .withField("taskInfo", taskInfo)
                .withField("linkID", linkID)
                .withField("needPassword", true))
            .withField("commonAccountInfo", buildJsonObject {}.withField("account", account).withField("accountType", 1))
        val resp = sharePostEncrypted(C139Constants.TRANSFER_CREATE_URL, req.toString(), authorization)
        val code = resp.optString("resultCode").ifBlank { resp.optString("code") }
        if (code.isNotBlank() && code != "0") {
            throw IllegalStateException(resp.optString("desc").ifBlank { "创建转存任务失败（$code）" })
        }
        resp.optJsonObject("data")?.optString("taskID")?.takeIf { it.isNotBlank() }
    }

    /** 查询转存结果 */
    suspend fun queryTransferTask(taskID: String, account: String, authorization: String?): C139TransferResult =
        withContext(Dispatchers.Default) {
            val req = buildJsonObject {}.withField(
                "queryBatchOprTaskDetailReq",
                buildJsonObject {}
                    .withField("taskID", taskID)
                    .withField("msisdn", account)
                    .withField("commonAccountInfo", buildJsonObject {}.withField("account", account).withField("accountType", 1))
            )
            val resp = sharePostEncrypted(C139Constants.TRANSFER_QUERY_URL, req.toString(), authorization)
            val code = resp.optString("resultCode").ifBlank { resp.optString("code") }
            if (code.isNotBlank() && code != "0") {
                throw IllegalStateException(resp.optString("desc").ifBlank { "查询转存结果失败（$code）" })
            }
            val data = resp.optJsonObject("data") ?: return@withContext C139TransferResult(false, emptyMap())
            val task = data.optJsonObject("batchOprTask")
            val done = (task?.optInt("progress") ?: 0) >= 100 && (task?.optInt("taskStatus") ?: 0) == 2
            val mapping = buildMap {
                data.optJsonObject("contentList")?.optJsonArray("idRspInfo")?.let { arr ->
                    for (i in 0 until arr.length()) {
                        val item = arr.optJsonObject(i) ?: continue
                        if (item.optString("reason") == "0000") {
                            put(item.optString("srcId"), item.optString("rstId"))
                        }
                    }
                }
            }
            C139TransferResult(done, mapping)
        }

    /**
     * 个人网盘管理专用 POST（§1：明文 JSON，Authorization + mcloud-sign 按明文算；
     * 不需要 hcy-cool-flag，不需要加密；可选 Cookie + mcloud-skey（创建分享 getOutLink 必需））。
     * ⚠️ 修复（《139网盘管理认证失败修复》）：APISIX 网关鉴权层强制要求全套 x-yun-* / mcloud-* 渠道头，
     *    仅有 Authorization+mcloud-sign 会返回 HTTP 404 + code:"04000005" 认证失败。
     */
    private suspend fun cloudPost(
        url: String,
        plainBody: String,
        authorization: String,
        cookie: String? = null,
        needSkey: Boolean = false
    ): JsonObject {
        val builder = HttpRequestBuilder()
            .withUrl(url)
            // —— 鉴权 ——
            .withHeader("Authorization", authorization)
            .withHeader("mcloud-sign", signHeader(plainBody))
            // —— 渠道/上下文头（缺失 → 04000005 认证失败；值来自成功抓包写死）——
            .withHeader("x-yun-channel-source", C139Constants.YUN_CHANNEL_SOURCE)
            .withHeader("x-yun-app-channel", C139Constants.YUN_CHANNEL_SOURCE)
            .withHeader("x-huawei-channelSrc", C139Constants.YUN_CHANNEL_SOURCE)
            .withHeader("mcloud-version", C139Constants.MCLOUD_VERSION)
            .withHeader("mcloud-client", C139Constants.MCLOUD_CLIENT)
            .withHeader("mcloud-channel", C139Constants.MCLOUD_CHANNEL)
            .withHeader("mcloud-route", "001")
            .withHeader("x-yun-module-type", C139Constants.YUN_MODULE_TYPE)
            .withHeader("x-yun-api-version", "v1")
            .withHeader("x-yun-svc-type", "1")
            .withHeader("x-SvcType", "1")
            .withHeader("caller", "web")
            .withHeader("x-inner-ntwk", "2")
            .withHeader("CMS-DEVICE", "default")
            .withHeader("x-m4c-src", C139Constants.M4C_SRC)
            .withHeader("x-m4c-caller", C139Constants.M4C_CALLER)
            .withHeader("X-Deviceinfo", C139Constants.X_DEVICEINFO)
            .withHeader("x-yun-client-info", C139Constants.X_CLIENT_INFO)
            .withHeader("INNER-HCY-ROUTER-HTTPS", "1")
            .withHeader("Sec-Fetch-Site", "same-site")
            .withHeader("Sec-Fetch-Mode", "cors")
            .withHeader("Sec-Fetch-Dest", "empty")
            .withHeader("X-Requested-With", "mark.via")
            // —— 基础头 ——
            .withHeader("Content-Type", "application/json;charset=UTF-8")
            .withHeader("User-Agent", C139Constants.PC_UA)
            .withHeader("Origin", "https://yun.139.com")
            .withHeader("Referer", "https://yun.139.com/")
            .withHeader("Accept", "application/json, text/plain, */*")
        if (cookie != null) {
            builder.withHeader("Cookie", cookie)
            if (needSkey) {
                val skey = cookie.split(";").map { it.trim() }
                    .firstOrNull { it.startsWith("skey=") }?.substringAfter('=')
                if (!skey.isNullOrBlank()) builder.withHeader("mcloud-skey", skey)
            }
        }
        val request = builder.withPost(plainBody.toRequestBody(jsonMediaType))
        val response = client.executeRequest(request)
        val body = response.let { it.bodyAsText() ?: throw IllegalStateException("请求失败：响应为空") }
        return parseJsonObject(body)   // 管理接口明文响应
    }

    /** 管理接口成功判定：success==true 且 code ∈ {"0000","0"} */
    private fun checkCloud(json: JsonObject, fallback: String) {
        val code = json.optString("code")
        if (json.optBoolean("success", true) && (code == "0000" || code == "0")) return
        val msg = json.optString("message").ifBlank { fallback }
        throw IllegalStateException("$msg（code=$code）")
    }

    // ---------- 请求构造与响应解析 ----------

    /**
     * 匿名 POST（列表端点 getOutLinkInfoV6 专用，§9530修复文档 §3/§5 + hcy-cool-flag 修复）：
     * 不带 Authorization、不带 mcloud-sign、不带 mcloud-* 头；body 仍加密；
     * 必须带 hcy-cool-flag: 1（139 网关选择解密方案的开关，缺它业务层拿不到明文 → 9530）；
     * 响应解密（兼容明文透传）。
     */
    private suspend fun sharePostAnonymous(url: String, plainBody: String): JsonObject {
        val encrypted = encryptBody(plainBody)
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("hcy-cool-flag", "1")
            .withHeader("x-deviceinfo", C139Constants.SHARE_X_DEVICEINFO)
            .withHeader("x-huawei-channelsrc", C139Constants.SHARE_X_HUAWEI_CHANNELSRC)
            .withHeader("x-mm-source", C139Constants.SHARE_X_MM_SOURCE)
            .withHeader("Content-Type", "application/json;charset=UTF-8")
            .withHeader("User-Agent", C139Constants.SHARE_MOBILE_UA)
            .withHeader("Origin", "https://yun.139.com")
            .withHeader("Referer", "https://yun.139.com/")
            .withHeader("Accept", "application/json, text/plain, */*")
            .withPost(encrypted.toRequestBody(jsonMediaType))

        val response = client.executeRequest(request)
        val body = response.let { it.bodyAsText() ?: throw IllegalStateException("请求失败：响应为空") }
        // 响应体应为加密 base64（§14）；网关透传明文时兜底
        return runCatching { parseJsonObject(decryptBody(body)) }.getOrElse { parseJsonObject(body) }
    }

    /**
     * 分享专用 POST（§14/§15 + hcy-cool-flag 修复）：body 加密发送，mcloud-sign 按明文算，
     * 必须带 hcy-cool-flag: 1（网关解密开关，缺它业务层拿不到明文 → 9530），响应解密（兼容明文透传）。
     */
    private suspend fun sharePostEncrypted(url: String, plainBody: String, authorization: String?): JsonObject {
        val encrypted = encryptBody(plainBody)
        val request = HttpRequestBuilder()
            .withUrl(url)
            .apply { if (!authorization.isNullOrBlank()) withHeader("Authorization", authorization) }
            .withHeader("hcy-cool-flag", "1")
            .withHeader("x-deviceinfo", C139Constants.SHARE_X_DEVICEINFO)
            .withHeader("x-huawei-channelsrc", C139Constants.SHARE_X_HUAWEI_CHANNELSRC)
            .withHeader("x-mm-source", C139Constants.SHARE_X_MM_SOURCE)
            .withHeader("mcloud-sign", signHeader(plainBody))
            .withHeader("Content-Type", "application/json;charset=UTF-8")
            .withHeader("User-Agent", C139Constants.SHARE_MOBILE_UA)
            .withHeader("Origin", "https://yun.139.com")
            .withHeader("Referer", "https://yun.139.com/")
            .withHeader("Accept", "application/json, text/plain, */*")
            .withPost(encrypted.toRequestBody(jsonMediaType))

        val response = client.executeRequest(request)
        val body = response.let { it.bodyAsText() ?: throw IllegalStateException("请求失败：响应为空") }
        // 响应体应为加密 base64（§14）；网关透传明文时兜底
        return runCatching { parseJsonObject(decryptBody(body)) }.getOrElse { parseJsonObject(body) }
    }

}
