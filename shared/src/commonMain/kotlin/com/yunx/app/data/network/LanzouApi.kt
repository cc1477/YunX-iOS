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
import com.yunx.app.data.network.model.ShareFile
import com.yunx.app.data.network.model.ShareInfo
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

/** 个人盘登录态参数（文档 §B1）。 */
data class LanzouLoginParams(val uid: String, val vei: String)

/** 文件夹分页参数（文档 §A7）。 */
data class LanzouFolderParams(val lx: String, val fid: String, val t: String, val k: String)

/** 分享页解析结果。 */
data class LanzouSharePage(
    val shareUrl: String,
    val baseUrl: String,
    val title: String,
    val isFolder: Boolean,
    val needsPwd: Boolean,
    val iframeUrl: String?,
    val fileId: String?,
    val folderParams: LanzouFolderParams?,
    val html: String,
    val singleFile: ShareFile?
)

/**
 * 蓝奏云 API 封装（文档 §3/§4）：
 * - 匿名分享：分享页 HTML → 同源 iframe → ajaxm/ajaxfile 取参数 → HEAD 探测直链 → 验证并下载；
 * - 个人盘：Cookie（ylogin + phpdisk_info）→ mydisk.php 取 uid/vei → doupload.php 系列 task。
 */
class LanzouApi(
    private val clientProvider: () -> HttpClient = { HttpClients.apiClient() }
) {
    private val client get() = clientProvider()
    private val noRedirect get() = HttpClients.withoutRedirects(client)

    // 蓝奏可能返回 acw_sc__v2 的 JS 校验页（并下发 down_ip 等 Cookie）：
    // 按 host 记录 Cookie，遇到校验页时本地计算 Cookie 并重放一次（参考实现 wenxi lanzou.dart / lanzou_protocol.dart）。
    private val challengeCookies = DomainCookiesStorage()

    private fun hostOf(url: String): String = runCatching { Url(url).host }.getOrNull().orEmpty()

    private suspend fun setCookie(host: String, name: String, value: String) {
        if (host.isBlank()) return
        challengeCookies.addCookie(Url("https://$host/"), io.ktor.http.Cookie(name, value, domain = host, path = "/"))
    }
    private suspend fun cookieHeader(host: String): String = if (host.isBlank()) "" else
        challengeCookies.get(Url("https://$host/")).joinToString("; ") { "${it.name}=${it.value}" }
    private suspend fun mergedCookie(host: String, extra: String?): String = listOfNotNull(
        cookieHeader(host).takeIf { it.isNotEmpty() }, extra?.takeIf { it.isNotBlank() }
    ).joinToString("; ")
    suspend fun clearCookiesForDomain(domain: String) {
        challengeCookies.clearDomain(domain)
        HttpClients.clearCookiesForDomain(domain)
    }

    // ---------- 个人盘（文档 §4） ----------

    /** B1：从 mydisk.php 提取 uid / vei。 */
    suspend fun fetchLoginParams(cookie: String): LanzouLoginParams? = withContext(Dispatchers.Default) {
        val request = HttpRequestBuilder()
            .withUrl(LanzouConstants.MYDISK_FILES_URL)
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", LanzouConstants.WEB_UA)
            .withHeader("Referer", LanzouConstants.MYDISK_URL)
            .withHeader("Origin", LanzouConstants.ORIGIN)
            .withGet()

        client.executeRequest(request).let { resp ->
            if (!resp.status.isSuccess()) throw IllegalStateException("蓝奏登录态无效，请重新登录")
            val html = resp.bodyAsText().orEmpty()
            // 文件页里形如：url:'/doupload.php?uid=4133097', data:{ 'vei':'B1UHVFBWVQgFB1JWAFo=' }
            // uid 出现在 URL（uid=数字）；vei 带引号包裹、值为含 '=' 的 base64 —— 两者都要兼容。
            val uid = Regex("""uid['"]?\s*[=:]\s*['"]?(\d{1,20})""").find(html)?.groupValues?.get(1)
            val vei = Regex("""vei['"]?\s*[=:]\s*['"]?([A-Za-z0-9_\-+/=]{1,256})""").find(html)?.groupValues?.get(1)
            if (uid.isNullOrBlank() || vei.isNullOrBlank()) {
                throw IllegalStateException("蓝奏登录态无效，请重新登录")
            }
            LanzouLoginParams(uid, vei)
        }
    }

    /**
     * 原生账号密码登录（官网 accounts.woozooo.com）：
     * 1) POST /accounts.php（表单 task=uselogin / username / password / ref=pc.woozooo.com）；
     *    若返回 JS 人机校验页（`arg1` + acw_sc__v2）则计算 Cookie 后重试（最多 4 次）；
     * 2) 成功响应 `{zt:'1', msgs:<中转鉴权 URL>}` → GET msgs（带 Cookie、跟随跳转）下发登录 Cookie；
     * 3) 返回 `ylogin=..; ylogins=..; uag=..; phpdisk_info=..; lanzou_ifo=..`。
     * 失败抛 IllegalStateException（服务端 msg，如「密码错误」「用户名不正确」）。
     */
    suspend fun login(account: String, password: String): String = withContext(Dispatchers.Default) {
        val name = account.trim()
        if (name.isEmpty() || password.isEmpty()) throw IllegalStateException("请输入蓝奏云账号和密码")
        val loginStorage = DomainCookiesStorage()
        val loginClient = HttpClients.newSessionClient(storage = loginStorage)
        try {
        val headers = HeadersBuilder()
            .apply { append("User-Agent", LanzouConstants.WEB_UA) }
            .apply { append("Origin", LanzouConstants.ACCOUNTS_ORIGIN) }
            .apply { append("Referer", "${LanzouConstants.ACCOUNTS_ORIGIN}/accounts.php?action=login&ref=${LanzouConstants.LOGIN_REF}") }
            .apply { append("X-Requested-With", "XMLHttpRequest") }
            .apply { append("Accept", "application/json, text/javascript, */*; q=0.01") }

        suspend fun postLogin(): String {
            val form = ParametersBuilder()
                .apply { append("task", "uselogin") }
                .apply { append("username", name) }
                .apply { append("password", password) }
                .apply { append("ref", LanzouConstants.LOGIN_REF) }

            loginClient.executeRequest(
                HttpRequestBuilder().withUrl(LanzouConstants.ACCOUNTS_URL).withHeaders(headers).withPost(form)
            ).let { return it.bodyAsText().orEmpty() }
        }

        var body = postLogin()
        var attempt = 0
        while (attempt < 4 && body.contains("arg1=") && !body.contains("\"zt\"")) {
            val arg1 = Regex("""arg1\s*=\s*'([0-9A-Fa-f]{40})'""").find(body)?.groupValues?.getOrNull(1)
                ?: break
            loginStorage.addCookie(Url(LanzouConstants.ACCOUNTS_URL), io.ktor.http.Cookie("acw_sc__v2", acwScV2(arg1), domain = "accounts.woozooo.com", path = "/"))
            body = postLogin()
            attempt++
        }

        val json = runCatching { parseJsonObject(body) }.getOrElse {
            throw IllegalStateException("蓝奏云登录失败，请稍后重试")
        }
        if (json.optString("zt") != "1") {
            throw IllegalStateException(json.optString("msgs").ifBlank { "蓝奏云登录失败，请检查账号密码" })
        }
        val msgs = json.optString("msgs")
        if (msgs.isNotBlank()) {
            runCatching {
                loginClient.executeRequest(
                    HttpRequestBuilder().withUrl(msgs).withHeaders(
                        HeadersBuilder()
                            .apply { append("User-Agent", LanzouConstants.WEB_UA) }
                            .apply { append("Referer", "${LanzouConstants.ACCOUNTS_ORIGIN}/") }

                    ).withGet()
                ).let { it.bodyAsText() }
            }
            // 再访问一次文件页：获取/固定 PHPSESSID（vei 与该会话绑定，后续 doupload 需同一会话）
            runCatching {
                loginClient.executeRequest(
                    HttpRequestBuilder().withUrl(LanzouConstants.MYDISK_FILES_URL).withHeaders(
                        HeadersBuilder()
                            .apply { append("User-Agent", LanzouConstants.WEB_UA) }
                            .apply { append("Referer", LanzouConstants.MYDISK_URL) }

                    ).withGet()
                ).let { it.bodyAsText() }
            }
        }
        val cookies = loginStorage.get(Url(LanzouConstants.MYDISK_FILES_URL))
        val cookie = cookies.joinToString("; ") { "${it.name}=${it.value}" }
        if (cookie.isBlank()) throw IllegalStateException("蓝奏登录未返回 Cookie")
        cookie
        } finally { loginClient.close() }
    }

    /**
     * 计算 JS 人机校验 Cookie `acw_sc__v2`（固定公开变换，仅字符串运算、不执行页面脚本）：
     * 页面给 40 位十六进制 `arg1`，按固定位置重排后与掩码逐字节异或。
     */
    private fun acwScV2(arg1: String): String {
        val pos = intArrayOf(
            15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11,
            39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36
        )
        val mask = "3000176000856006061501533003690027800375"
        val q = CharArray(pos.size)
        for (x in arg1.indices) {
            for (z in pos.indices) {
                if (pos[z] == x + 1) q[z] = arg1[x]
            }
        }
        val u = String(q)
        return buildString {
            var i = 0
            while (i + 2 <= u.length && i + 2 <= mask.length) {
                val a = u.substring(i, i + 2).toInt(16)
                val b = mask.substring(i, i + 2).toInt(16)
                append((a xor b).toString(16).padStart(2, '0'))
                i += 2
            }
        }
    }

    /** 个人盘列目录：文件夹（task=47）+ 文件（task=5）合并。 */
    suspend fun listCloudFiles(cookie: String, uid: String, vei: String, folderId: String): List<ShareFile> =
        withContext(Dispatchers.Default) {
            val result = mutableListOf<ShareFile>()
            // 文件夹
            val folderJson = doupload(cookie, uid, vei, listOf("task" to "47", "folder_id" to folderId), allowEnd = true)
            folderJson.optJsonArray("text")?.let { arr ->
                for (i in 0 until arr.length()) {
                    val item = arr.optJsonObject(i) ?: continue
                    val id = firstNonBlank(item.optString("fol_id"), item.optString("id"))
                    if (id.isBlank()) continue
                    result.add(
                        ShareFile(
                            fid = LanzouConstants.FOLDER_PREFIX + id,
                            fname = firstNonBlank(item.optString("name"), item.optString("name_all")),
                            fsize = 0L,
                            isdir = true,
                            pdirFid = folderId,
                            fidToken = "",
                            modifyTime = item.optString("time")
                        )
                    )
                }
            }
            // 文件
            val seen = mutableSetOf<String>()
            var pg = 1
            while (pg <= LanzouConstants.MAX_FILE_PAGES) {
                val json = doupload(
                    cookie, uid, vei,
                    listOf("task" to "5", "folder_id" to folderId, "pg" to pg.toString()),
                    allowEnd = true
                )
                val arr = json.optJsonArray("text")
                if (arr == null || arr.length() == 0) break
                var added = 0
                for (i in 0 until arr.length()) {
                    val item = arr.optJsonObject(i) ?: continue
                    val id = item.optString("id")
                    if (id.isBlank() || !seen.add(id)) continue
                    result.add(
                        ShareFile(
                            fid = LanzouConstants.FILE_PREFIX + id,
                            fname = firstNonBlank(item.optString("name_all"), item.optString("name")),
                            fsize = parseDisplaySize(item.optString("size")),
                            isdir = false,
                            pdirFid = folderId,
                            fidToken = "",
                            modifyTime = item.optString("time")
                        )
                    )
                    added++
                }
                if (added == 0) throw IllegalStateException("蓝奏文件分页重复，请刷新后重试")
                pg++
            }
            result
        }

    /** B4：新建文件夹，返回新目录 id。 */
    suspend fun createFolder(cookie: String, uid: String, vei: String, parentId: String, name: String): String =
        withContext(Dispatchers.Default) {
            val json = doupload(
                cookie, uid, vei,
                listOf(
                    "task" to "2",
                    "parent_id" to parentId,
                    "folder_name" to name,
                    "folder_description" to ""
                )
            )
            val text = json.optString("text")
            if (!Regex("""^\d+$""").matches(text)) throw IllegalStateException("蓝奏未返回新文件夹信息")
            text
        }

    /** B5：重命名文件夹。 */
    suspend fun renameFolder(cookie: String, uid: String, vei: String, folderId: String, newName: String) =
        withContext(Dispatchers.Default) {
            doupload(
                cookie, uid, vei,
                listOf(
                    "task" to "4",
                    "folder_id" to folderId,
                    "folder_name" to newName,
                    "folder_description" to ""
                )
            )
        }

    /** B6：重命名文件。 */
    suspend fun renameFile(cookie: String, uid: String, vei: String, fileId: String, newName: String) =
        withContext(Dispatchers.Default) {
            doupload(
                cookie, uid, vei,
                listOf("task" to "46", "file_id" to fileId, "file_name" to newName, "type" to "2")
            )
        }

    /** B7：移动文件（逐个）。 */
    suspend fun moveFile(cookie: String, uid: String, vei: String, folderId: String, fileId: String) =
        withContext(Dispatchers.Default) {
            doupload(cookie, uid, vei, listOf("task" to "20", "folder_id" to folderId, "file_id" to fileId))
        }

    /** B8：删除文件夹。 */
    suspend fun deleteFolder(cookie: String, uid: String, vei: String, folderId: String) =
        withContext(Dispatchers.Default) {
            doupload(cookie, uid, vei, listOf("task" to "3", "folder_id" to folderId))
        }

    /** B9：删除文件。 */
    suspend fun deleteFile(cookie: String, uid: String, vei: String, fileId: String) =
        withContext(Dispatchers.Default) {
            doupload(cookie, uid, vei, listOf("task" to "6", "file_id" to fileId))
        }

    /** B10：获取文件分享链接。 */
    suspend fun createFileShare(cookie: String, uid: String, vei: String, fileId: String): ShareInfo =
        withContext(Dispatchers.Default) {
            val json = doupload(cookie, uid, vei, listOf("task" to "22", "file_id" to fileId))
            val info = json.optJsonObject("info") ?: throw IllegalStateException("蓝奏未返回分享链接")
            buildShareInfo(info.optString("f_id"), info.optString("is_newd"), info.optString("pwd"))
        }

    /** B11：获取文件夹分享链接。 */
    suspend fun createFolderShare(cookie: String, uid: String, vei: String, folderId: String): ShareInfo =
        withContext(Dispatchers.Default) {
            val json = doupload(cookie, uid, vei, listOf("task" to "18", "file_id" to folderId))
            val info = json.optJsonObject("info") ?: throw IllegalStateException("蓝奏未返回分享链接")
            buildShareInfo(info.optString("new_url"), info.optString("is_newd"), info.optString("pwd"))
        }

    // ---------- 匿名分享（文档 §3） ----------

    /** A1/A2：获取分享页并解析（文件夹分享 / 文件分享）。 */
    suspend fun resolveShare(shareUrl: String, pwd: String?): LanzouSharePage = withContext(Dispatchers.Default) {
        val normalized = LanzouConstants.normalizeShareUrl(shareUrl)
        val html = fetchPageFollowingLanzou(normalized)
        val uri = Url(normalized)
        val origin = "${uri.protocol.name}://${uri.host}"
        val title = extractTitle(html)
        val needsPwd = html.contains("请输入密码") || html.contains("id=\"pwbox\"") ||
            html.contains("input_password") || html.contains("密码不正确")
        val isFolder = html.contains("filemoreajax") || html.contains("class=\"filemore\"") ||
            html.contains("file_more")
        val iframeUrl = Regex("""<iframe[^>]+src=["']([^"']+)["']""").find(html)?.groupValues?.get(1)
            ?.let { absolutize(origin, it) }
        val fileId = Regex("""(?:ajaxm|ajaxfile)\.php\?file=(\d+)""").find(html)?.groupValues?.get(1)
            ?: Regex("""name=["']file["']\s+value=["'](\d+)["']""").find(html)?.groupValues?.get(1)
            ?: Regex("""file=(\d+)""").find(html)?.groupValues?.get(1)
        val folderParams = if (isFolder) {
            val lx = jsVar(html, "lx")
            val fid = jsVar(html, "fid") ?: uri.encodedPath.substringAfterLast('/')
            val t = jsVar(html, "t")
            val k = jsVar(html, "k")
            if (lx != null && t != null && k != null) LanzouFolderParams(lx, fid, t, k) else null
        } else null
        val shareId = uri.encodedPath.trim('/').substringAfterLast('/').ifBlank { uri.encodedPath.trim('/') }
        // 单文件分享的展示大小：页面文本「文件大小：1.5 M」（参考 wenxi LanzouPage.displaySize）
        val displaySize = Regex("""(?:文件大小|大小)\s*[:：]\s*([\d.]+)\s*([KMGT]?)(?:i?B)?""", RegexOption.IGNORE_CASE)
            .find(html)?.let { parseDisplaySize("${it.groupValues[1]} ${it.groupValues[2]}") } ?: 0L
        val singleFile = if (!isFolder) {
            ShareFile(
                fid = shareId,
                fname = title,
                fsize = displaySize,
                isdir = false,
                pdirFid = "",
                fidToken = ""
            )
        } else null
        LanzouSharePage(
            shareUrl = normalized,
            baseUrl = origin,
            title = title.ifBlank { "蓝奏分享" },
            isFolder = isFolder,
            needsPwd = needsPwd,
            iframeUrl = iframeUrl,
            fileId = fileId,
            folderParams = folderParams,
            html = html,
            singleFile = singleFile
        )
    }

    /** A7：文件夹分页列表。 */
    suspend fun listShareFolder(page: LanzouSharePage, pwd: String?, dirFid: String): List<ShareFile> =
        withContext(Dispatchers.Default) {
            val params = page.folderParams
                ?: throw IllegalStateException("蓝奏分享分页异常，请重试")
            val all = mutableListOf<ShareFile>()
            val seen = mutableSetOf<String>()
            var pg = 1
            while (pg <= LanzouConstants.MAX_FOLDER_PAGES) {
                var attempt = 0
                var json: JsonObject? = null
                while (attempt <= 2) {
                    json = try {
                        formPost(
                            url = "${page.baseUrl}/filemoreajax.php",
                            fields = listOf(
                                "lx" to params.lx,
                                "fid" to params.fid,
                                "t" to params.t,
                                "k" to params.k,
                                "pwd" to pwd.orEmpty(),
                                "pg" to pg.toString()
                            ),
                            referer = page.shareUrl,
                            origin = page.baseUrl,
                            cookie = null
                        )
                        break
                    } catch (e: Exception) {
                        attempt++
                        if (attempt > 2) throw IllegalStateException("蓝奏请求过于频繁，请稍后再试")
                        delay(300)
                        null
                    }
                }
                val body = json ?: break
                val zt = body.optInt("zt", 0)
                when (zt) {
                    1 -> {}
                    2 -> return@withContext all
                    3 -> throw IllegalStateException("蓝奏提取码错误，请检查后重新解析")
                    4 -> {
                        pg--
                        if (attempt >= 2) throw IllegalStateException("蓝奏请求过于频繁，请稍后再试")
                    }
                    else -> throw IllegalStateException("蓝奏解析失败，请确认分享链接和提取码后重试")
                }
                val arr = body.optJsonArray("text")
                if (arr == null || arr.length() == 0) break
                var added = 0
                for (i in 0 until arr.length()) {
                    val item = arr.optJsonObject(i) ?: continue
                    val id = item.optString("id")
                    if (id.isBlank() || !seen.add(id)) continue
                    all.add(
                        ShareFile(
                            fid = id,
                            fname = firstNonBlank(item.optString("name_all"), item.optString("name")),
                            fsize = parseDisplaySize(item.optString("size")),
                            isdir = false,
                            pdirFid = "",
                            fidToken = "",
                            modifyTime = item.optString("time")
                        )
                    )
                    added++
                }
                if (added == 0) throw IllegalStateException("蓝奏分页重复，请重新打开目录")
                pg++
            }
            all
        }

    /** A2-A6：获取分享文件下载直链（匿名）。 */
    suspend fun getShareDownloadLink(page: LanzouSharePage, file: ShareFile, pwd: String?): DownloadLink =
        withContext(Dispatchers.Default) {
            val origin = page.baseUrl
            // A2：同源 iframe 下载页
            var html = page.html
            page.iframeUrl?.let { iframe ->
                val iframeUri = runCatching { Url(iframe) }.getOrNull()
                if (iframeUri != null && iframeUri.host.equals(Url(page.shareUrl).host, ignoreCase = true)) {
                    html = fetchPage(iframe, page.shareUrl, null)
                } else if (iframeUri != null && iframeUri.host != null) {
                    throw IllegalStateException("蓝奏下载页面地址异常，请检查分享链接")
                }
            }
            val fileId = page.fileId
                ?: Regex("""(?:ajaxm|ajaxfile)\.php\?file=(\d+)""").find(html)?.groupValues?.get(1)
                ?: Regex("""file=(\d+)""").find(html)?.groupValues?.get(1)
                ?: throw IllegalStateException("蓝奏解析失败，请确认分享链接和提取码后重试")
            // A3：取下载参数
            val withPwd = !pwd.isNullOrBlank()
            // 下载接口可能在同源，也可能在 apifile.woozooo.com（新版页面用 domain1/domain2 给出完整 URL）
            val ajaxUrl = resolveAjaxUrl(html, origin, fileId, withPwd)
            // 新版页面签名变量为 wp_sign（旧版为 sign）
            val sign = jsVar(html, "wp_sign") ?: jsVar(html, "sign") ?: inputValue(html, "sign")
                ?: throw IllegalStateException("蓝奏分享页缺少下载参数，请重新解析")
            val ajaxData = jsVar(html, "ajaxdata")
            val kd = jsVarRaw(html, "kdns") ?: "1"
            val fields = mutableListOf<Pair<String, String>>()
            fields += "action" to "downprocess"
            fields += "sign" to sign
            if (withPwd) {
                fields += "p" to pwd!!
                fields += "kd" to "1"
            } else {
                // 新版无密码协议：websignkey/signs 用 ajaxdata，websign 空，kd 用 kdns
                val key = ajaxData ?: jsVar(html, "websignkey") ?: inputValue(html, "websignkey") ?: ""
                fields += "signs" to (jsVar(html, "signs") ?: key)
                fields += "websignkey" to key
                fields += "websign" to (jsVar(html, "websign") ?: "")
                fields += "kd" to kd
                fields += "ves" to "1"
            }
            val ajaxJson = formPost(ajaxUrl, fields, page.shareUrl, origin, null)
            validateAjax(ajaxJson)
            val dom = ajaxJson.optString("dom")
            val rel = ajaxJson.optString("url")
            if (dom.isBlank() || rel.isBlank() || rel.startsWith("/") || rel.contains("://")) {
                throw IllegalStateException("蓝奏解析失败，请确认分享链接和提取码后重试")
            }
            val domOrigin = runCatching { Url(dom) }.getOrNull()
                ?: throw IllegalStateException("蓝奏解析失败，请确认分享链接和提取码后重试")
            val jump = "${domOrigin.protocol.name}://${domOrigin.host}/file/$rel"
            val (finalUrl, size) = probeAndVerify(jump, origin)
            DownloadLink(
                fid = file.fid,
                filename = file.fname.ifBlank { ajaxJson.optString("inf") },
                downloadUrl = finalUrl,
                size = size
            )
        }

    // ---------- 个人盘下载 ----------

    /**
     * 个人盘文件下载：蓝奏云文档未提供个人盘直链接口，这里按官方能力组合实现 ——
     * 先用 task=22 生成该文件的分享链接，再走匿名分享的下载链路取直链。
     */
    suspend fun getPersonalDownloadLink(
        cookie: String,
        uid: String,
        vei: String,
        fileId: String,
        fileName: String
    ): DownloadLink = withContext(Dispatchers.Default) {
        val info = createFileShare(cookie, uid, vei, fileId)
        val page = resolveShare(info.shareUrl, info.passcode)
        val file = page.singleFile
            ?: ShareFile(fid = page.shareUrl, fname = fileName, fsize = 0L, isdir = false, pdirFid = "", fidToken = "")
        getShareDownloadLink(page, file, info.passcode)
    }

    // ---------- 内部 ----------

    private suspend fun probeAndVerify(jump: String, shareOrigin: String): Pair<String, Long> {
        var url = jump
        // 下载节点要求注入 down_ip=1 Cookie（文档 §A4）
        setCookie(hostOf(jump), "down_ip", "1")
        var confirmedHosts = mutableSetOf<String>()
        val challenges = mutableSetOf<String>()
        val visited = mutableSetOf<String>()
        repeat(8) {
            val uri = runCatching { Url(url) }.getOrNull()
                ?: throw IllegalStateException("蓝奏下载地址暂时不可用，请稍后重试")
            val host = uri.host ?: throw IllegalStateException("蓝奏下载地址暂时不可用，请稍后重试")
            if (!visited.add(url)) throw IllegalStateException("蓝奏下载地址循环跳转，请重新解析")
            val response = headRequest(url, shareOrigin)
            when {
                response.code in 300..399 -> {
                    val loc = response.location ?: throw IllegalStateException("蓝奏下载地址暂时不可用，请稍后重试")
                    url = absolutize("${uri.protocol.name}://${uri.host}", loc)
                    response.close()
                }
                response.code == 200 || response.code == 206 -> {
                    val size = response.size
                    val contentType = response.contentType.orEmpty()
                    val isHtml = contentType.contains("text/html")
                    response.close()
                    if (isHtml) {
                        val body = httpGetText(url, shareOrigin)
                        // 下载节点可能先返回 acw_sc__v2 人机校验页：计算 Cookie 后重放
                        val challenge = lanzouChallengeCookie(body)
                        if (challenge != null) {
                            if (!challenges.add(host)) throw IllegalStateException("蓝奏需要进一步验证，请在分享页完成验证后重试")
                            setCookie(host, "acw_sc__v2", challenge)
                            return@repeat
                        }
                        if (body.contains("验证并下载")) {
                            if (confirmedHosts.add(host)) {
                                val verified = submitVerify(url, body, shareOrigin)
                                if (verified != null) {
                                    url = verified
                                    return@repeat
                                }
                            }
                            throw IllegalStateException("蓝奏需要进一步验证，请在分享页完成验证后重试")
                        }
                        throw IllegalStateException("蓝奏返回的是验证页面，未创建下载任务，请在分享页完成验证后重试")
                    }
                    // HEAD 未给大小或缺少 content-type：回退 GET Range
                    if (size <= 0) {
                        val fallback = rangeProbe(url, shareOrigin)
                        if (fallback.second > 0) return url to fallback.second
                    }
                    return url to size
                }
                response.code == 403 || response.code == 404 || response.code == 410 -> {
                    response.close()
                    throw IllegalStateException("蓝奏下载地址已失效，请稍后重新解析")
                }
                response.code == 429 -> {
                    response.close()
                    throw IllegalStateException("蓝奏下载请求过于频繁，请稍后再试")
                }
                else -> {
                    response.close()
                    val fallback = rangeProbe(url, shareOrigin)
                    if (fallback.second > 0) return url to fallback.second
                    throw IllegalStateException("蓝奏下载地址暂时不可用，请稍后重试")
                }
            }
        }
        throw IllegalStateException("蓝奏下载地址暂时不可用，请稍后重试")
    }

    /** A6：提交「验证并下载」，返回新的直链 URL 或 null。 */
    private suspend fun submitVerify(nodeUrl: String, html: String, shareOrigin: String): String? {
        val uri = runCatching { Url(nodeUrl) }.getOrNull() ?: return null
        // 新版确认页：data : { 'file':'<base64>','el':el,'sign':'<base64>' }
        val dataMatch = Regex("""data\s*:\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}""", RegexOption.DOT_MATCHES_ALL)
            .findAll(html)
            .map { it.groupValues[1] }
            .firstOrNull { it.contains("'file'") || it.contains("\"file\"") }
        val file = dataMatch?.let { Regex("""['"]?file['"]?\s*:\s*['"]([^'"]+)['"]""").find(it)?.groupValues?.get(1) }
            ?: Regex("""name=["']file["'][^>]*value=["']([^"']+)["']""").find(html)?.groupValues?.get(1)
            ?: return null
        val sign = dataMatch?.let { Regex("""['"]?sign['"]?\s*:\s*['"]([^'"]+)['"]""").find(it)?.groupValues?.get(1) }
            ?: jsVar(html, "sign") ?: inputValue(html, "sign")
            ?: return null
        // 节点页面 2 秒后才显示按钮，需等同样时长再提交
        Thread.sleep(2000)
        val ajaxUrl = runCatching { resolveUrl(uri.toString(), "ajax.php") }
            .getOrDefault("${uri.protocol.name}://${uri.host}/ajax.php")
        val json = runCatching {
            formPost(
                ajaxUrl,
                listOf("file" to file, "el" to "2", "sign" to sign),
                nodeUrl,
                "${uri.protocol.name}://${uri.host}",
                null
            )
        }.getOrNull() ?: throw IllegalStateException("蓝奏下载验证服务暂时不可用，请稍后重试")
        val zt = json.optInt("zt", 0)
        val url = json.optString("url")
        if (zt != 1 || url.isBlank()) {
            // zt!=1 时 url 字段承载错误文案（如「验证码错误」）
            throw IllegalStateException(url.ifBlank { "蓝奏需要进一步验证，请在分享页完成验证后重试" })
        }
        if (url == "?SignError") throw IllegalStateException("蓝奏下载验证已过期，请重新解析")
        return url
    }

    private class HeadResult(
        val code: Int,
        val location: String?,
        val size: Long,
        val contentType: String?,
        private val closeAction: () -> Unit
    ) {
        fun close() = closeAction.invoke()
    }

    private suspend fun headRequest(url: String, shareOrigin: String): HeadResult {
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("User-Agent", LanzouConstants.WEB_UA)
            .withHeader("Referer", "$shareOrigin/")
            .apply {
                val c = mergedCookie(hostOf(url), LanzouConstants.DOWN_IP_COOKIE)
                if (c.isNotEmpty()) withHeader("Cookie", c)
            }
            .withHead()

        val response = noRedirect.executeRequest(request)
        val cr = response.headers["Content-Range"]
        val size = when {
            cr != null -> cr.substringAfterLast('/').toLongOrNull() ?: 0L
            response.status.value == 200 -> response.headers["Content-Length"]?.toLongOrNull() ?: 0L
            else -> 0L
        }
        return HeadResult(
            code = response.status.value,
            location = response.headers["Location"],
            size = size,
            contentType = response.headers["Content-Type"],
            closeAction = { response.coroutineContext.cancel() }
        )
    }

    private suspend fun rangeProbe(url: String, shareOrigin: String): Pair<String, Long> {
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("User-Agent", LanzouConstants.WEB_UA)
            .withHeader("Referer", "$shareOrigin/")
            .apply {
                val c = mergedCookie(hostOf(url), LanzouConstants.DOWN_IP_COOKIE)
                if (c.isNotEmpty()) withHeader("Cookie", c)
            }
            .withHeader("Range", "bytes=0-8191")
            .withGet()

        noRedirect.executeRequest(request).let { resp ->
            val cr = resp.headers["Content-Range"]
            val size = if (cr != null) cr.substringAfterLast('/').toLongOrNull() ?: 0L else 0L
            resp.coroutineContext.cancel()
            return url to size
        }
    }

    private suspend fun httpGetText(url: String, referer: String?): String {
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("User-Agent", LanzouConstants.WEB_UA)
            .apply { if (referer != null) withHeader("Referer", referer) }
            .apply {
                val c = mergedCookie(hostOf(url), LanzouConstants.DOWN_IP_COOKIE)
                if (c.isNotEmpty()) withHeader("Cookie", c)
            }
            .withGet()

        client.executeRequest(request).let { resp ->
            return resp.bodyAsText().orEmpty()
        }
    }

    private suspend fun fetchPageFollowingLanzou(url: String): String {
        var current = url
        val challenged = mutableSetOf<String>()
        repeat(8) {
            val host = hostOf(current)
            val request = HttpRequestBuilder()
                .withUrl(current)
                .withHeader("User-Agent", LanzouConstants.WEB_UA)
                .withHeader("Referer", current)
                .apply { val c = cookieHeader(host); if (c.isNotEmpty()) withHeader("Cookie", c) }
                .withGet()

            noRedirect.executeRequest(request).let { resp ->
                val code = resp.status.value
                if (code in 300..399) {
                    val loc = resp.headers["Location"]
                        ?: throw IllegalStateException("蓝奏页面跳转次数过多，请重新解析")
                    val next = absolutize(current, loc)
                    val nextHost = runCatching { Url(next).host }.getOrNull()
                    if (nextHost == null || !LanzouConstants.isLanzouHost(nextHost)) {
                        throw IllegalStateException("蓝奏分享链接无效")
                    }
                    current = next
                    return@let
                }
                val body = resp.bodyAsText().orEmpty()
                if (body.length > 2_000_000) throw IllegalStateException("蓝奏分享页面过大或异常")
                // 分享页可能先返回 acw_sc__v2 人机校验页：计算 Cookie 后重放
                val challenge = lanzouChallengeCookie(body)
                if (challenge != null) {
                    if (!challenged.apply { append(host) }) throw IllegalStateException("蓝奏需要进一步验证，请在分享页完成验证后重试")
                    setCookie(host, "acw_sc__v2", challenge)
                    return@let
                }
                if (body.contains("文件已取消") || body.contains("不存在")) {
                    throw IllegalStateException("蓝奏文件已取消分享或不存在")
                }
                if (body.contains("请求过于频繁") || body.contains("稍后再试")) {
                    throw IllegalStateException("蓝奏请求过于频繁，请稍后再试")
                }
                return body
            }
        }
        throw IllegalStateException("蓝奏页面跳转次数过多，请重新解析")
    }

    private suspend fun fetchPage(url: String, referer: String?, cookie: String?): String {
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("User-Agent", LanzouConstants.WEB_UA)
            .withHeader("Referer", referer ?: url)
            .apply {
                val c = mergedCookie(hostOf(url), cookie)
                if (c.isNotEmpty()) withHeader("Cookie", c)
            }
            .withGet()

        client.executeRequest(request).let { resp ->
            if (!resp.status.isSuccess()) throw IllegalStateException("蓝奏文件已取消分享或不存在")
            return resp.bodyAsText().orEmpty()
        }
    }

    private fun validateAjax(json: JsonObject) {
        if (json.optInt("zt", 0) == 1) return
        val inf = json.optString("inf")
        when {
            inf.contains("密码") || inf.contains("提取码") -> throw IllegalStateException("蓝奏提取码错误，请检查后重新解析")
            inf.contains("不存在") || inf.contains("取消") || inf.contains("过期") || inf.contains("删除") ->
                throw IllegalStateException("蓝奏文件已取消分享或不存在")
            inf.contains("频繁") || inf.contains("次数") || inf.contains("稍后") ->
                throw IllegalStateException("蓝奏请求过于频繁，请稍后再试")
            else -> throw IllegalStateException("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
    }

    /** doupload.php 系列统一请求；allowEnd 时 zt==2 视为成功（列表结束）。 */
    private suspend fun doupload(
        cookie: String,
        uid: String,
        vei: String,
        fields: List<Pair<String, String>>,
        allowEnd: Boolean = false
    ): JsonObject {
        val request = HttpRequestBuilder()
            .withUrl("${LanzouConstants.DOUPLOAD_URL}?uid=$uid&vei=$vei")
            .withHeader("Cookie", cookie)
            .withHeader("User-Agent", LanzouConstants.WEB_UA)
            .withHeader("Referer", LanzouConstants.MYDISK_URL)
            .withHeader("Origin", LanzouConstants.ORIGIN)
            .withHeader("X-Requested-With", "XMLHttpRequest")
            .withPost(formBody(fields))

        client.executeRequest(request).let { resp ->
            if (resp.status.value == 401 || resp.status.value == 403) throw IllegalStateException("蓝奏登录已过期，请重新网页登录")
            val body = resp.bodyAsText().orEmpty()
            val json = runCatching { parseJsonObject(body) }.getOrElse {
                throw IllegalStateException("蓝奏文件操作失败，请在官网检查权限和文件类型")
            }
            val zt = json.optInt("zt", -1)
            when {
                zt == 1 -> return json
                zt == 2 && allowEnd -> return json
                zt == 4 -> throw IllegalStateException("蓝奏请求频繁，请稍后重试")
                zt == 9 -> throw IllegalStateException("蓝奏登录已过期，请重新网页登录")
                else -> throw IllegalStateException("蓝奏文件操作失败（$zt），请在官网检查权限和文件类型")
            }
        }
    }

    private suspend fun formPost(
        url: String,
        fields: List<Pair<String, String>>,
        referer: String,
        origin: String,
        cookie: String?
    ): JsonObject = formPostRaw(url, fields, referer, origin, cookie).let { body ->
        runCatching { parseJsonObject(body) }.getOrElse {
            if (body.trimStart().startsWith("<")) {
                throw IllegalStateException("蓝奏返回了验证页面，请稍后重试或在分享页完成验证")
            }
            throw IllegalStateException("蓝奏解析服务响应异常，请稍后重试")
        }
    }

    private suspend fun formPostRaw(
        url: String,
        fields: List<Pair<String, String>>,
        referer: String,
        origin: String,
        cookie: String?
    ): String {
        val request = HttpRequestBuilder()
            .withUrl(url)
            .withHeader("User-Agent", LanzouConstants.WEB_UA)
            .withHeader("Referer", referer)
            .withHeader("Origin", origin)
            .withHeader("X-Requested-With", "XMLHttpRequest")
            .apply {
                val c = mergedCookie(hostOf(url), cookie)
                if (c.isNotEmpty()) withHeader("Cookie", c)
            }
            .withPost(formBody(fields))

        noRedirect.executeRequest(request).let { resp ->
            if (resp.status.value == 429) throw IllegalStateException("蓝奏请求过于频繁，请稍后再试")
            val body = resp.bodyAsText().orEmpty()
            if (body.length > 4_000_000) throw IllegalStateException("蓝奏解析服务返回内容过大，请稍后重试")
            if (!resp.status.isSuccess() && body.isBlank()) {
                throw IllegalStateException("蓝奏解析服务响应异常（HTTP ${resp.status.value}），请稍后重试")
            }
            return body
        }
    }

    private fun formBody(fields: List<Pair<String, String>>): FormDataContent {
        val builder = ParametersBuilder()
        fields.forEach { (k, v) -> builder.apply { append(k, v) } }
        return FormDataContent(builder.build())
    }

    private fun buildShareInfo(raw: String, domain: String, pwd: String): ShareInfo {
        val base = when {
            domain.isBlank() -> "https://pan.lanzoui.com"
            domain.contains("://") -> domain
            else -> "https://$domain"
        }
        val url = if (raw.contains("://")) {
            raw
        } else {
            val origin = runCatching { Url(base) }.getOrNull()?.let { "${it.protocol.name}://${it.host}" } ?: base
            "$origin/${raw.trimStart('/')}"
        }
        return ShareInfo(
            shareUrl = url,
            passcode = pwd,
            pwdId = raw,
            title = "蓝奏云分享",
            expiredType = com.yunx.app.data.network.model.ShareExpire.UNKNOWN
        )
    }

    private fun extractTitle(html: String): String {
        Regex("""<title>([^<]*)</title>""").find(html)?.groupValues?.get(1)?.let { t ->
            val clean = t.replace(" - 蓝奏云", "").replace("蓝奏云", "").trim()
            if (clean.isNotBlank() && !clean.contains("密码")) return clean
        }
        Regex("""class=["']n["']>([^<]+)<""").find(html)?.groupValues?.get(1)?.let { return it.trim() }
        Regex("""var\s+filename\s*=\s*['"]([^'"]+)['"]""").find(html)?.groupValues?.get(1)?.let { return it }
        return ""
    }

    private fun jsVar(html: String, name: String): String? =
        Regex("""(?:(?:var|let|const)\s+)?$name\s*=\s*['"]([^'"]*)['"]""").find(html)?.groupValues?.get(1)

    /** 读取未加引号的 JS 变量值（如 `var kdns = 0`）。 */
    private fun jsVarRaw(html: String, name: String): String? =
        Regex("""(?:var|let|const)\s+$name\s*=\s*([^;,\n\r]+)""").find(html)?.groupValues?.get(1)
            ?.trim()?.trim('\'', '"')

    /** 页面若是 acw_sc__v2 校验页则返回应设置的 Cookie 值。 */
    private fun lanzouChallengeCookie(source: String): String? {
        val arg1 = Regex("""\barg1\s*=\s*'([0-9A-Fa-f]{40})'""").find(source)?.groupValues?.getOrNull(1)
            ?: return null
        return acwScV2(arg1)
    }

    /**
     * 下载接口 URL：优先页面里的 `domain1`/`domain2`（新版在 apifile.woozooo.com，跨域），
     * 其次页面中出现的绝对 ajaxm/ajaxfile 地址，最后回退同源。
     */
    private fun resolveAjaxUrl(html: String, origin: String, fileId: String, withPwd: Boolean): String {
        val candidate = jsVar(html, "domain1")?.takeIf { it.contains("/ajax") }
            ?: jsVar(html, "domain2")?.takeIf { it.contains("/ajax") }
            ?: Regex("""https?://[^'"\s]+/(?:ajaxm|ajaxfile)\.php\?file=\d+""").find(html)?.value
        if (!candidate.isNullOrBlank()) return candidate
        return if (withPwd) "$origin/ajaxfile.php?file=$fileId" else "$origin/ajaxm.php?file=$fileId"
    }

    private fun inputValue(html: String, name: String): String? =
        Regex("""<input[^>]*name=["']$name["'][^>]*value=["']([^"']*)["']""").find(html)?.groupValues?.get(1)
            ?: Regex("""<input[^>]*value=["']([^"']*)["'][^>]*name=["']$name["']""").find(html)?.groupValues?.get(1)

    private fun absolutize(base: String, target: String): String {
        if (target.startsWith("http://") || target.startsWith("https://")) return target
        val uri = runCatching { Url(base) }.getOrNull() ?: return target
        val root = "${uri.protocol.name}://${uri.host}"
        return if (target.startsWith("/")) root + target else "$root/$target"
    }

    private fun parseDisplaySize(text: String): Long {
        val t = text.trim()
        if (t.isEmpty()) return 0L
        val m = Regex("""([\d.]+)\s*([KMGT]?)""", RegexOption.IGNORE_CASE).find(t) ?: return 0L
        val value = m.groupValues[1].toDoubleOrNull() ?: return 0L
        val unit = m.groupValues[2].uppercase()
        val factor = when (unit) {
            "K" -> 1024L
            "M" -> 1024L * 1024
            "G" -> 1024L * 1024 * 1024
            "T" -> 1024L * 1024 * 1024 * 1024
            else -> 1L
        }
        return (value * factor).toLong()
    }

    private fun firstNonBlank(vararg values: String): String =
        values.firstOrNull { !it.isNullOrBlank() }?.trim().orEmpty()
}
