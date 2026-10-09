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
import com.yunx.app.data.network.model.PlayLink
import com.yunx.app.data.network.model.QuotaInfo
import com.yunx.app.data.network.model.ShareFile
import com.yunx.app.data.network.model.ShareInfo
import com.yunx.app.data.network.model.ShareToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/**
 * UC Cookie 工具：合并/剥离 __puus、__pus（与夸克共用，对应 AList pkg/cookie）。
 * __puus 约 3 小时过期，是取链接口（/file/download 等）必须携带的有效会话字段。
 */
object UCCookieUtil {
    private val TRACKED = setOf("__puus", "__pus")

    /** 把响应 Set-Cookie 列表里的最新 __puus/__pus 合并回原 Cookie 串 */
    fun mergeFromSetCookies(original: String, setCookies: List<String>): String {
        var cookie = original
        for (sc in setCookies) {
            val kv = sc.substringBefore(';').trim()
            val eq = kv.indexOf('=')
            if (eq <= 0) continue
            val name = kv.substring(0, eq)
            if (name in TRACKED) cookie = setOrReplace(cookie, name, kv.substring(eq + 1))
        }
        return cookie
    }

    /** 去掉 __puus，用于触发服务端重新下发（AList refreshPuus） */
    fun withoutPuus(cookie: String): String =
        cookie.split(";").map { it.trim() }
            .filter { !it.startsWith("__puus=") }
            .joinToString("; ")

    private fun setOrReplace(cookie: String, name: String, value: String): String {
        val parts = cookie.split(";").map { it.trim() }.toMutableList()
        val idx = parts.indexOfFirst { it.startsWith("$name=") }
        val kv = "$name=$value"
        if (idx >= 0) parts[idx] = kv else parts.add(kv)
        return parts.joinToString("; ")
    }
}

/**
 * UC 网盘 API 封装（OkHttp）：账号验证 + 分享解析 + 下载直链。
 * 与夸克 API 结构一致，仅域名/UA/pr 参数不同。
 */
class UCApi(
    private val clientProvider: () -> HttpClient = { HttpClients.apiClient() }
) {
    /** 每次请求动态获取全局客户端（忽略 SSL 开关切换即时生效） */
    private val client get() = clientProvider()

    /**
     * Cookie 回写接收器（推荐由 UCAccountRepository 注入并落库）：
     * 每次响应把 Set-Cookie 合并后的最新 Cookie 回调，保持 __puus/__pus 始终新鲜。
     */
    var cookieSink: ((String) -> Unit)? = null

    /**
     * 游客态令牌 `__pugs`（未登录取链响应 Set-Cookie 下发，3 小时有效）。
     * UC 下载层只认这一个 cookie：缺它 OSS 直链直接 403（RequestDeniedByCallback）。
     * 进程内复用，登录态路径完全不受影响（只在 [getGuestShareDownloadLink] 里读写）。
     */

    var guestPugs: String = ""
        private set

    private val jsonMediaType = "application/json; charset=utf-8"

    // ---------- 账号 ----------

    suspend fun fetchNickname(cookie: String): String? = withContext(Dispatchers.Default) {
        val request = HttpRequestBuilder()
            .withUrl(UCConstants.ACCOUNT_INFO_URL)
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", UCConstants.USER_AGENT)
            .withGet()

        runCatching {
            client.executeRequest(request).let { response ->
                if (!response.status.isSuccess()) return@let null
                val body = response.bodyAsText() ?: return@let null
                val json = parseJsonObject(body)
                if (json.optBoolean("success", false)) {
                    json.optJsonObject("data")
                        ?.optString("nickname")
                        ?.takeIf { it.isNotBlank() }
                } else null
            }
        }.getOrNull()
    }

    // ---------- 分享解析 ----------

    suspend fun getShareToken(shareId: String, pwd: String?, cookie: String): ShareToken? = withContext(Dispatchers.Default) {
        // 官方抓包：body 为 pwd_id/passcode/share_for_transfer（用于转存/下载场景）
        var body = buildJsonObject {}
            .withField("pwd_id", shareId)
            .withField("passcode", pwd ?: "")
            .withField("share_for_transfer", true)
            .toString()
        val request = postJson(UCConstants.SHARE_TOKEN_URL, cookie, body)
        parseData(request) { data ->
            ShareToken(
                stoken = data.optString("stoken"),
                title = data.optString("title"),
                firstFid = data.optString("first_fid")
            )
        }
    }

    /**
     * 获取分享文件列表（sharepage/v2/detail，UC 官方为 POST + JSON body）。
     * 官方抓包：body 携带 pwd_id/passcode/page/size/fetch_banner 等，不携带 stoken；
     * 进入子目录时 body 追加 pdir_fid。
     */
    /**
     * 获取转存分享文件列表（transfer_share/detail，官方下载流程）。
     * GET + query 携带 stoken → 返回的 share_fid_token 与 stoken 绑定，download 才能通过校验。
     */
    suspend fun getTransferShareFiles(
        shareId: String,
        stoken: String,
        pdirFid: String,
        cookie: String,
        page: Int = 1,
        size: Int = 50
    ): List<ShareFile>? = withContext(Dispatchers.Default) {
        val url = buildString {
            append(UCConstants.TRANSFER_SHARE_DETAIL_URL)
            append("&pwd_id=").append(shareId)
            append("&pdir_fid=").append(pdirFid)
            append("&fetch_file_list=1")
            append("&passcode=")
            append("&_page=").append(page)
            append("&_size=").append(size)
            append("&_fetch_total=1")
            append("&_fetch_task=1")
            append("&_fetch_share=1")
            append("&_sort=")
            append("&stoken=").append(formEncode(stoken))
        }
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", UCConstants.USER_AGENT)
            .withHeader("Origin", "https://fast.uc.cn")
            .withHeader("Referer", "https://fast.uc.cn/")
            .withGet()

        parseData(request) { data ->
            // 兼容 data.list 或 data.detail_info.list 两种结构
            val array = data.optJsonArray("list")
                ?: data.optJsonObject("detail_info")?.optJsonArray("list")
                ?: buildJsonArray {}
            buildList {
                for (i in 0 until array.length()) {
                    val item = array.optJsonObject(i) ?: continue
                    add(
                        ShareFile(
                            fid = item.optString("fid"),
                            fname = item.optString("file_name"),
                            fsize = item.optLong("size"),
                            isdir = item.optBoolean("dir", false),
                            pdirFid = item.optString("pdir_fid"),
                            fidToken = item.optString("share_fid_token"),
                            modifyTime = item.optString("updated_at")
                        )
                    )
                }
            }
        }
    }

    suspend fun getShareFiles(
        shareId: String,
        pwd: String?,
        pdirFid: String,
        cookie: String,
        page: Int = 1,
        size: Int = 50
    ): List<ShareFile>? = withContext(Dispatchers.Default) {
        var body = buildJsonObject {}
            .withField("pwd_id", shareId)
            .withField("passcode", pwd ?: "")
            .withField("force", 0)
            .withField("page", page)
            .withField("size", size)
            .withField("fetch_banner", 1)
            .withField("fetch_share", 1)
            .withField("fetch_total", 1)
            .withField("sort", "file_type:asc,file_name:asc")
            .withField("banner_platform", "other")
            .withField("web_platform", "windows")
            .withField("fetch_error_background", 1)
        // 子目录时追加 pdir_fid（根目录官方不传）
        if (pdirFid.isNotBlank() && pdirFid != UCConstants.DEFAULT_PDIR_FID) {
            body = body.withField("pdir_fid", pdirFid)
        }
        val request = HttpRequestBuilder()
            .withUrl("${UCConstants.SHARE_DETAIL_URL}&ve=2.5.20")
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", UCConstants.USER_AGENT)
            .withHeader("Origin", "https://drive.uc.cn")
            .withHeader("Referer", "https://drive.uc.cn/")
            .withHeader("Content-Type", "application/json;charset=UTF-8")
            .withPost(body.toString().toRequestBody(jsonMediaType))

        parseData(request) { data ->
            // UC v2/detail：文件列表在 data.detail_info.list（不是 data.list）
            val detailInfo = data.optJsonObject("detail_info")
            val array = detailInfo?.optJsonArray("list") ?: buildJsonArray {}
            buildList {
                for (i in 0 until array.length()) {
                    val item = array.optJsonObject(i) ?: continue
                    add(
                        ShareFile(
                            fid = item.optString("fid"),
                            fname = item.optString("file_name"),
                            fsize = item.optLong("size"),
                            isdir = item.optBoolean("dir", false),
                            pdirFid = item.optString("pdir_fid"),
                            fidToken = item.optString("share_fid_token"),
                            modifyTime = item.optString("updated_at")
                        )
                    )
                }
            }
        }
    }

    // ---------- 个人网盘 / 转存 ----------

    suspend fun getFileList(
        pdirFid: String,
        cookie: String,
        page: Int = 1,
        size: Int = 100
    ): List<ShareFile>? = withContext(Dispatchers.Default) {
        val url = "${UCConstants.FILE_URL}&pdir_fid=$pdirFid&page=$page&size=$size"
        val request = get(url, cookie)
        parseData(request) { data ->
            val array = data.optJsonArray("list") ?: buildJsonArray {}
            buildList {
                for (i in 0 until array.length()) {
                    val item = array.optJsonObject(i) ?: continue
                    add(
                        ShareFile(
                            fid = item.optString("fid"),
                            fname = item.optString("file_name").ifEmpty { item.optString("fname") },
                            fsize = if (item.has("size")) item.optLong("size") else item.optLong("fsize"),
                            isdir = item.optBoolean("dir", false) || item.optInt("isdir") == 1,
                            pdirFid = item.optString("pdir_fid"),
                            fidToken = item.optString("fid_token"),
                            modifyTime = item.optString("modify_time")
                        )
                    )
                }
            }
        }
    }

    suspend fun createFolder(name: String, parentFid: String, cookie: String): String? =
        withContext(Dispatchers.Default) {
            var body = buildJsonObject {}
                .withField("pdir_fid", parentFid)
                .withField("file_name", name)
                .withField("dir_path", "")
                .withField("dir_init_lock", false)
                .toString()
            val request = postJson(UCConstants.FILE_URL, cookie, body)
            parseData(request) { data -> data.optString("fid") }
        }

    suspend fun saveShareFile(
        shareId: String,
        stoken: String,
        pdirFid: String,
        fid: String,
        fidToken: String,
        toPdirFid: String,
        cookie: String
    ): String? = withContext(Dispatchers.Default) {
        var body = buildJsonObject {}
            .withField("pwd_id", shareId)
            .withField("stoken", stoken)
            .withField("pdir_fid", pdirFid)
            .withField("to_pdir_fid", toPdirFid)
            .withField("fid_list", buildJsonArray {}.withField(fid))
            .withField("fid_token_list", buildJsonArray {}.withField(fidToken))
            .withField("scene", "link")
            .toString()
        val request = postJson(UCConstants.SAVE_URL, cookie, body)
        parseData(request) { data -> data.optString("task_id").takeIf { it.isNotBlank() } }
    }

    suspend fun pollTask(taskId: String, cookie: String): String? = withContext(Dispatchers.Default) {
        val url = "${UCConstants.TASK_URL}&task_id=${formEncode(taskId)}&retry_index=0"
        for (i in 0 until 10) {
            val savedFid = runCatching {
                client.executeRequest(get(url, cookie)).let { response ->
                    val json = parseJsonObject(response.bodyAsText() ?: "{}")
                    if (json.optInt("status") != 200) return@let null
                    val data = json.optJsonObject("data") ?: return@let null
                    val finished = data.optLong("finished_at") > 0 ||
                        data.optInt("status") == 2 ||
                        data.optInt("task_status") == 2
                    if (!finished) return@let null
                    data.optJsonObject("save_as")
                        ?.optJsonArray("save_as_top_fids")
                        ?.optString(0)
                        ?.takeIf { it.isNotBlank() }
                }
            }.getOrNull()
            if (savedFid != null) return@withContext savedFid
            delay(1000)
        }
        null
    }

    // ---------- 下载直链 ----------

    /**
     * 刷新会话 Cookie（对应 AList refreshPuus，修复与夸克同源的 #830 类缺陷）：
     * 剥离 __puus 后请求任意接口（/config），服务端会在 Set-Cookie 中重新下发 __puus/__pus。
     * @return 合并了最新 __puus/__pus 的 Cookie；失败返回 null（调用方应回退原 Cookie）。
     */
    suspend fun refreshSession(cookie: String): String? = withContext(Dispatchers.Default) {
        val request = HttpRequestBuilder()
            .withUrl(UCConstants.CONFIG_URL)
            .withHeader("Cookie", UCCookieUtil.withoutPuus(cookie))
            .withHeader("User-Agent", UCConstants.USER_AGENT)
            .withHeader("Referer", UCConstants.DOWNLOAD_REFERER)
            .withGet()

        runCatching {
            client.executeRequest(request).let { resp ->
                val merged = UCCookieUtil.mergeFromSetCookies(cookie, (resp.headers.getAll("Set-Cookie") ?: emptyList()))
                if (merged != cookie) cookieSink?.invoke(merged)
                merged
            }
        }.getOrNull()
    }

    /**
     * UC 官方下载流程（抓包）：不需要先转存！
     * POST file/download?entry=ft&fr=pc&pr=UCBrowser
     * body: {"fids":[分享fid],"pwd_id":短码,"stoken":token接口返回,"fids_token":[分享fid_token]}
     */
    suspend fun getShareDownloadLink(
        fid: String,
        fidToken: String,
        stoken: String,
        pwdId: String,
        cookie: String
    ): DownloadLink? = withContext(Dispatchers.Default) {
        var body = buildJsonObject {}
            .withField("fids", buildJsonArray {}.withField(fid))
            .withField("pwd_id", pwdId)
            .withField("stoken", stoken)
            .withField("fids_token", buildJsonArray {}.withField(fidToken))
            .toString()
        val request = postJson(UCConstants.DOWNLOAD_URL, cookie, body)
        val response = client.executeRequest(request)
        val bodyStr = response.let {
            it.bodyAsText() ?: throw QuarkApiException("获取下载链接失败：响应为空")
        }
        val json = runCatching { parseJsonObject(bodyStr) }.getOrElse {
            throw QuarkApiException("响应解析失败")
        }
        if (json.optInt("status") != 200) {
            throw QuarkApiException(json.optString("message").ifBlank { "获取下载链接失败" })
        }
        val item = json.optJsonArray("data")?.optJsonObject(0)
            ?: throw QuarkApiException("未返回下载链接")
        DownloadLink(
            fid = item.optString("fid"),
            filename = item.optString("file_name").ifEmpty { item.optString("filename") },
            downloadUrl = item.optString("download_url"),
            size = item.optLong("size")
        )
    }

    /**
     * 游客分享取链（未登录直链）：与 [getShareDownloadLink] 同一个端点、同一个 body
     * （对齐 LinkSwift 分享页匿名链路：不带账号 Cookie，只带分享参数 + uc-cloud-drive 客户端 UA）。
     *
     * 下载层只认一个 cookie —— 服务端随本次响应 Set-Cookie 下发的游客态 `__pugs`
     * （3 小时有效，且与本次直链同响应绑定；缺它 CDN 直接 403 RequestDeniedByCallback）。
     * 这里捕获后写进 [DownloadLink.guestCookie]，同时缓存到 [guestPugs] 供后续文件复用。
     *
     * @throws QuarkApiException 需登录（31001）、超出游客大小上限（23018）、令牌失效（14001/41020）等
     */
    suspend fun getGuestShareDownloadLink(
        fid: String,
        fidToken: String,
        stoken: String,
        pwdId: String
    ): DownloadLink? = withContext(Dispatchers.Default) {
        var body = buildJsonObject {}
            .withField("fids", buildJsonArray {}.withField(fid))
            .withField("pwd_id", pwdId)
            .withField("stoken", stoken)
            .withField("fids_token", buildJsonArray {}.withField(fidToken))
            .toString()
        val request = postJsonGuest(UCConstants.DOWNLOAD_URL, guestPugs, body)
        val response = client.executeRequest(request)
        // 先取本次响应的 __pugs（与本次直链同响应绑定，不能用别的响应/上一次的值）
        val responsePugs = pugsFromSetCookies((response.headers.getAll("Set-Cookie") ?: emptyList()))
        val bodyStr = response.let {
            it.bodyAsText() ?: throw QuarkApiException("获取下载链接失败：响应为空")
        }
        if (responsePugs != null) guestPugs = responsePugs
        val json = runCatching { parseJsonObject(bodyStr) }.getOrElse {
            // 非 JSON（风控页/HTML 错误页）时带上 HTTP 状态码，便于分辨 401/403 与分享失效
            throw QuarkApiException("响应解析失败（HTTP ${response.status.value}）")
        }
        val code = json.optInt("code")
        if (json.optInt("status") != 200 && code != 0) {
            throw QuarkApiException(guestErrorMessage(code, json.optString("message")), code)
        }
        val array = json.optJsonArray("data") ?: throw QuarkApiException("响应缺少 data")
        if (array.length() == 0) throw QuarkApiException("未返回下载链接")
        val item = array.optJsonObject(0) ?: throw QuarkApiException("未返回下载链接")
        DownloadLink(
            fid = item.optString("fid"),
            filename = item.optString("file_name").ifEmpty { item.optString("filename") },
            downloadUrl = item.optString("download_url"),
            size = item.optLong("size"),
            guestCookie = responsePugs ?: guestPugs
        )
    }

    /** 游客取链的服务端错误码 → 中文提示（错误码表对齐 panweb-parser 的 UC 适配器） */
    private fun guestErrorMessage(code: Int, message: String): String = when (code) {
        31001 -> "该分享需要登录 UC 网盘后才能下载"
        23018 -> "该文件超出游客可获取的大小上限，请先登录 UC 网盘再下载"
        14001 -> "分享已失效或提取码有误，请重新解析"
        41020 -> "文件令牌已过期，请重新解析分享"
        else -> message.ifBlank { "获取下载链接失败" }
    }

    /** 从响应 Set-Cookie 里取出游客态令牌，返回可直接当 Cookie 头用的 `__pugs=值`；没有则 null */
    private fun pugsFromSetCookies(setCookies: List<String>): String? =
        setCookies.asSequence()
            .map { it.substringBefore(';').trim() }
            .firstOrNull { it.startsWith("__pugs=") && it.length > "__pugs=".length }

    /** 游客请求构造：Cookie 为空时不发该头；UA/Sec-Ch-Ua 用 uc-cloud-drive 客户端（游客链路风控更严） */
    private fun postJsonGuest(url: String, cookie: String, body: String): HttpRequestBuilder =
        HttpRequestBuilder()
            .withUrl(url)
            .apply { if (cookie.isNotBlank()) withHeader("Cookie", cookie) }
            .withHeader("User-Agent", UCConstants.GUEST_UA)
            .withHeader("Sec-Ch-Ua", UCConstants.GUEST_SEC_CH_UA)
            .withHeader("Content-Type", "application/json")
            .withPost(body.toRequestBody(jsonMediaType))


suspend fun getDownloadLink(fid: String, cookie: String): DownloadLink? = withContext(Dispatchers.Default) {
        var body = buildJsonObject {}.withField("fids", buildJsonArray {}.withField(fid)).toString()
        val request = postJson(UCConstants.DOWNLOAD_URL, cookie, body)
        val response = client.executeRequest(request)
        val bodyStr = response.let {
            it.bodyAsText() ?: throw QuarkApiException("获取下载链接失败：响应为空")
        }
        val json = runCatching { parseJsonObject(bodyStr) }.getOrElse {
            throw QuarkApiException("响应解析失败")
        }
        if (json.optInt("status") != 200 && json.optInt("code") != 0) {
            throw QuarkApiException(
                json.optString("message").ifBlank { "获取下载链接失败" },
                json.optInt("code")
            )
        }
        val array = json.optJsonArray("data") ?: throw QuarkApiException("响应缺少 data")
        if (array.length() == 0) throw QuarkApiException("未返回下载链接")
        val item = array.optJsonObject(0) ?: throw QuarkApiException("未返回下载链接")
        DownloadLink(
            fid = item.optString("fid"),
            filename = item.optString("file_name").ifEmpty { item.optString("filename") },
            downloadUrl = item.optString("download_url"),
            size = item.optLong("size")
        )
    }

    // ---------- 云盘文件管理（UC 网盘功能） ----------

    /** 网盘空间详情（/1/clouddrive/member：total_capacity / use_capacity，CLOUD_UA） */
    suspend fun getQuota(cookie: String): QuotaInfo? = withContext(Dispatchers.Default) {
        val url = "https://pc-api.uc.cn/1/clouddrive/member?pr=UCBrowser&fr=pc&fetch_subscribe=true&_ch=home"
        runCatching {
            val request = HttpRequestBuilder()
                .withUrl(url)
                .withHeader("Cookie", cookie)
                .withHeader("User-Agent", UCConstants.CLOUD_UA)
                .withHeader("Origin", "https://drive.uc.cn")
                .withHeader("Referer", "https://drive.uc.cn/")
                .withGet()

            val response = client.executeRequest(request)
            val body = response.let { it.bodyAsText() ?: return@runCatching null }
            val data = parseJsonObject(body).optJsonObject("data") ?: return@runCatching null
            QuotaInfo(
                used = data.optLong("use_capacity"),
                total = data.optLong("total_capacity")
            )
        }.getOrNull()
    }

    /** 云盘下载直链（抓包：个人云盘文件用 ?pr=UCBrowser&fr=pc&sys=win32&ve=1.6.1，非 entry=ft 分享通道） */
    suspend fun cloudGetDownloadLink(fid: String, cookie: String): DownloadLink? = withContext(Dispatchers.Default) {
        var body = buildJsonObject {}.withField("fids", buildJsonArray {}.withField(fid)).toString()
        val request = HttpRequestBuilder()
            .withUrl(UCConstants.CLOUD_DOWNLOAD_URL)
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", UCConstants.CLOUD_UA)
            .withHeader("Origin", "https://drive.uc.cn")
            .withHeader("Referer", "https://drive.uc.cn/")
            .withHeader("Content-Type", "application/json;charset=UTF-8")
            .withPost(body.toRequestBody(jsonMediaType))

        val response = client.executeRequest(request)
        val bodyStr = response.let {
            it.bodyAsText() ?: throw QuarkApiException("获取下载链接失败：响应为空")
        }
        val json = runCatching { parseJsonObject(bodyStr) }.getOrElse {
            throw QuarkApiException("响应解析失败")
        }
        if (json.optInt("status") != 200 && json.optInt("code") != 0) {
            throw QuarkApiException(
                json.optString("message").ifBlank { "获取下载链接失败" },
                json.optInt("code")
            )
        }
        val array = json.optJsonArray("data") ?: throw QuarkApiException("响应缺少 data")
        if (array.length() == 0) throw QuarkApiException("未返回下载链接")
        val item = array.optJsonObject(0) ?: throw QuarkApiException("未返回下载链接")
        DownloadLink(
            fid = item.optString("fid"),
            filename = item.optString("file_name").ifEmpty { item.optString("filename") },
            downloadUrl = item.optString("download_url"),
            size = item.optLong("size")
        )
    }

        /**
     * 分享视频预览（原画直链，绕过非会员视频下载被换成宣传片的问题）。
     * GET share/sharepage/video_preview？pwd_id/stoken/fid/fid_token →
     * data.play_info.url（原画 OSS 直链，走播放回调 checkplay 不换片）+ size（原画大小，可校验）。
     * 仅对分享态视频有意义；链接约 3 小时有效（x-ttl=10800）。
     */
    suspend fun getVideoPreview(
        pwdId: String,
        stoken: String,
        fid: String,
        fidToken: String,
        cookie: String
    ): DownloadLink? = withContext(Dispatchers.Default) {
        val url = buildString {
            append(UCConstants.VIDEO_PREVIEW_URL)
            append("?pr=UCBrowser&fr=h5")
            append("&pwd_id=").append(formEncode(pwdId))
            append("&stoken=").append(formEncode(stoken))
            append("&fid=").append(formEncode(fid))
            append("&fid_token=").append(formEncode(fidToken))
        }
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", UCConstants.USER_AGENT)
            .withHeader("Origin", UCConstants.WEB_ORIGIN)
            .withHeader("Referer", UCConstants.DOWNLOAD_REFERER)
            .withHeader("Content-Type", "application/json")
            .withGet()

        runCatching {
            val resp = client.executeRequest(request)
            val json = parseJsonObject(resp.let { it.bodyAsText() } ?: "{}")
            if (json.optInt("status") != 200 && json.optInt("code") != 0) return@runCatching null
            val data = json.optJsonObject("data") ?: return@runCatching null
            val playInfo = data.optJsonObject("play_info") ?: return@runCatching null
            val directUrl = playInfo.optString("url").takeIf { it.isNotBlank() } ?: return@runCatching null
            DownloadLink(
                fid = fid,
                filename = "",
                downloadUrl = directUrl,
                size = playInfo.optLong("size")
            )
        }.getOrNull()
    }

    /**
     * UC 转码播放流（绕过非会员视频下载被换成宣传片的问题）。
     * POST file/v2/play/project → data.video_list[].video_info.url（m3u8/fmp4）。
     * 仅对视频有意义；返回首个非空播放地址 + 其清晰度。
     * 先试带 pr/fr 的主路径；失败则用裸路径重试（Alist getTranscodingLink 方式，对 UC 也可通）。
     */
    suspend fun getPlayLink(fid: String, cookie: String): PlayLink? = withContext(Dispatchers.Default) {
        playProject(UCConstants.PLAY_URL, fid, cookie)
            ?: playProject("${UCConstants.API_BASE}/1/clouddrive/file/v2/play/project", fid, cookie)
    }

    private suspend fun playProject(url: String, fid: String, cookie: String): PlayLink? {
        var body = buildJsonObject {}
            .withField("fid", fid)
            .withField("resolutions", "low,normal,high,super,2k,4k")
            .withField("supports", "fmp4_av,m3u8,dolby_vision")
            .toString()
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", UCConstants.USER_AGENT)
            .withHeader("Content-Type", "application/json;charset=UTF-8")
            .withHeader("Origin", UCConstants.WEB_ORIGIN)
            .withHeader("Referer", UCConstants.DOWNLOAD_REFERER)
            .withPost(body.toRequestBody(jsonMediaType))

        return runCatching {
            val resp = client.executeRequest(request)
            val json = parseJsonObject(resp.let { it.bodyAsText() } ?: "{}")
            if (json.optInt("status") != 200 && json.optInt("code") != 0) return@runCatching null
            val list = json.optJsonObject("data")?.optJsonArray("video_list") ?: return@runCatching null
            for (i in 0 until list.length()) {
                val info = list.optJsonObject(i)?.optJsonObject("video_info") ?: continue
                val u = info.optString("url").takeIf { it.isNotBlank() } ?: continue
                return@runCatching PlayLink(
                    url = u,
                    resolution = info.optString("resolution"),
                    format = info.optString("format"),
                    isHls = u.contains(".m3u8") || info.optString("format").contains("m3u8", true)
                )
            }
            null
        }.getOrNull()
    }

    /** 删除文件（抓包：action_type=2 + filelist + exclude_fids）；返回 task_id */
    suspend fun deleteFile(fid: String, cookie: String): String? =
        withContext(Dispatchers.Default) {
            var body = buildJsonObject {}
                .withField("action_type", 2)
                .withField("filelist", buildJsonArray {}.withField(fid))
                .withField("exclude_fids", buildJsonArray {})
                .toString()
            val request = postJson(UCConstants.DELETE_URL, cookie, body)
            parseData(request) { data -> data.optString("task_id").takeIf { it.isNotBlank() } }
        }

    /** 云盘文件列表（抓包 /1/clouddrive/file/sort，pdir_fid=0 根目录）
     *  自动翻页：单页满 size 继续，封顶 100 页防异常死循环；默认单页 100（接口支持）。
     */
    suspend fun listCloudFiles(
        pdirFid: String,
        cookie: String,
        page: Int = 1,
        size: Int = 100
    ): List<ShareFile>? = withContext(Dispatchers.Default) {
        val all = mutableListOf<ShareFile>()
        var p = page
        while (true) {
            val url = buildString {
                append(UCConstants.CLOUD_FILE_SORT_URL)
                append("&pdir_fid=").append(pdirFid)
                append("&_page=").append(p)
                append("&_size=").append(size)
                append("&_fetch_total=1")
                append("&_fetch_sub_dirs=0")
                append("&_sort=file_type%3Aasc%2Cupdated_at%3Adesc")
            }
            val request = HttpRequestBuilder()
                .withUrl(url)
                .withHeader("Cookie", cookie)
                .withHeader("User-Agent", UCConstants.CLOUD_UA)
                .withHeader("Origin", "https://drive.uc.cn")
                .withHeader("Referer", "https://drive.uc.cn/")
                .withGet()

            val files = parseData(request) { data ->
                val array = data.optJsonArray("list") ?: buildJsonArray {}
                buildList {
                    for (i in 0 until array.length()) {
                        val item = array.optJsonObject(i) ?: continue
                        add(
                            ShareFile(
                                fid = item.optString("fid"),
                                fname = item.optString("file_name").ifEmpty { item.optString("fname") },
                                fsize = item.optLong("size"),
                                isdir = item.optBoolean("dir", false),
                                pdirFid = item.optString("pdir_fid"),
                                fidToken = "",
                                modifyTime = item.optString("updated_at")
                            )
                        )
                    }
                }
            }
            all += files
            // 本页未满 size → 已是最后一页；封顶 100 页防止异常死循环
            if (files.size < size || p >= 100) break
            p++
        }
        all.ifEmpty { null }
    }

    /** 重命名（抓包：POST file/rename） */
    suspend fun renameFile(fid: String, newName: String, cookie: String): Boolean =
        withContext(Dispatchers.Default) {
            var body = buildJsonObject {}
                .withField("fid", fid)
                .withField("file_name", newName)
                .toString()
            val request = postJson(UCConstants.RENAME_URL, cookie, body)
            runCatching {
                client.executeRequest(request).let { response ->
                    parseJsonObject(response.bodyAsText() ?: "{}").optInt("status") == 200
                }
            }.getOrDefault(false)
        }

    /** 移动（抓包：action_type=1 + to_pdir_fid + filelist）；返回 task_id */
    suspend fun moveFile(fid: String, toPdirFid: String, cookie: String): String? =
        withContext(Dispatchers.Default) {
            var body = buildJsonObject {}
                .withField("action_type", 1)
                .withField("to_pdir_fid", toPdirFid)
                .withField("filelist", buildJsonArray {}.withField(fid))
                .withField("exclude_fids", buildJsonArray {})
                .toString()
            val request = postJson(UCConstants.MOVE_URL, cookie, body)
            parseData(request) { data -> data.optString("task_id").takeIf { it.isNotBlank() } }
        }

    /** 创建分享（抓包：POST /1/clouddrive/share，url_type 1=无提取码 2=带提取码，
     *  expired_type 1永久/2一天/3七天/4三十天，**取值域与 UI 中性码一致**（[com.yunx.app.data.network.model.ShareExpire]），无需转换，Agent.md §3.20；调用方只能传 1..4）。
     *  注意：分享创建是**异步任务**——响应只有 data.task_id，必须轮询 /1/clouddrive/task 直到完成拿到 share_id。 */
    suspend fun createShare(
        fidList: List<String>,
        title: String,
        urlType: Int,
        passcode: String,
        expiredType: Int,
        cookie: String
    ): String? = withContext(Dispatchers.Default) {
        var body = buildJsonObject {}
            .withField("fid_list", buildJsonArray { fidList.forEach { add(jsonValue(it)) } })
            .withField("title", title.ifBlank { "分享文件" })
            .withField("url_type", urlType)
            .withField("expired_type", expiredType)
            .withField("public_search", if (passcode.isNotBlank()) 0 else 1)
            .edit { if (passcode.isNotBlank()) put("passcode", passcode) }
            .toString()
        val request = postJson(UCConstants.SHARE_CREATE_URL, cookie, body)
        // 1) 创建分享 → task_id（异步，须轮询等待完成）
        val taskId = parseData(request) { data ->
            data.optString("task_id").takeIf { it.isNotBlank() }
        } ?: return@withContext null
        // 2) 轮询 task 直到完成，取 share_id（官方响应 status=2 + share_id）
        pollShareTask(taskId, cookie)
    }

    /** 轮询分享创建任务（GET /1/clouddrive/task），返回 share_id；超时返回 null */
    private suspend fun pollShareTask(taskId: String, cookie: String): String? =
        withContext(Dispatchers.Default) {
            val url = "${UCConstants.TASK_URL}&task_id=${formEncode(taskId)}&retry_index=0"
            for (i in 0 until 15) {
                val shareId = runCatching {
                    client.executeRequest(get(url, cookie)).let { resp ->
                        val json = parseJsonObject(resp.bodyAsText() ?: "{}")
                        if (json.optInt("status") != 200) return@let null
                        val data = json.optJsonObject("data") ?: return@let null
                        val finished = data.optLong("finished_at") > 0 || data.optInt("status") == 2
                        if (!finished) return@let null
                        data.optString("share_id").takeIf { it.isNotBlank() }
                    }
                }.getOrNull()
                if (shareId != null) return@withContext shareId
                delay(1000)
            }
            null
        }

    /** 查询分享信息（抓包：POST share/password body={share_id} → 链接/提取码/标题） */
    suspend fun getShareInfo(shareId: String, cookie: String): ShareInfo? = withContext(Dispatchers.Default) {
        var body = buildJsonObject {}.withField("share_id", shareId).toString()
        val request = postJson(UCConstants.SHARE_INFO_URL, cookie, body)
        parseData(request) { data ->
            ShareInfo(
                shareUrl = data.optString("share_url"),
                passcode = data.optString("passcode"),
                pwdId = data.optString("pwd_id"),
                title = data.optString("title"),
                expiredType = data.optInt("expired_type")
            )
        }
    }
    // ---------- 请求构造与响应解析 ----------

    private fun get(url: String, cookie: String): HttpRequestBuilder =
        HttpRequestBuilder()
            .withUrl(url)
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", UCConstants.USER_AGENT)
            .withGet()


    private fun postJson(url: String, cookie: String, body: String): HttpRequestBuilder =
        HttpRequestBuilder()
            .withUrl(url)
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", UCConstants.USER_AGENT)
            .withHeader("Content-Type", "application/json")
            .withPost(body.toRequestBody(jsonMediaType))


    private suspend fun <T> parseData(request: HttpRequestBuilder, parser: (JsonObject) -> T): T {
        val response = client.executeRequest(request)
        val body = response.let {
            mergeCookieFromResponse(request, it)
            it.bodyAsText() ?: throw QuarkApiException("请求失败：响应为空")
        }
        val json = runCatching { parseJsonObject(body) }.getOrElse {
            // 服务端返回非 JSON（多半是 HTML 错误页/风控页）时带上 HTTP 状态码，
            // 便于分辨「未登录被拒（401/403）」与「分享已失效」
            throw QuarkApiException("响应解析失败（HTTP ${response.status.value}）")
        }
        if (json.optInt("status") != 200) {
            // 透传服务端 message，如「提取码错误」「分享已失效」等
            throw QuarkApiException(json.optString("message").ifBlank { "请求失败" })
        }
        return parser(json.optJsonObject("data") ?: throw QuarkApiException("响应缺少 data"))
    }

    /** 从响应 Set-Cookie 合并 __puus/__pus 回原 Cookie 并回调 cookieSink（保持会话新鲜，对齐 AList requestWithCookie） */
    private fun mergeCookieFromResponse(request: HttpRequestBuilder, response: HttpResponse) {
        val setCookies = (response.headers.getAll("Set-Cookie") ?: emptyList())
        if (setCookies.isEmpty()) return
        val original = request.headers["Cookie"].orEmpty()
        if (original.isBlank()) return
        val merged = UCCookieUtil.mergeFromSetCookies(original, setCookies)
        if (merged != original) cookieSink?.invoke(merged)
    }
}
