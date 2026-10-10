package com.yunx.app

import com.yunx.app.data.network.XunleiKouling
import com.yunx.app.data.network.resolveUrl
import com.yunx.app.data.network.lanzouDownloadSign
import com.yunx.app.ui.login.isLoginHost
import com.yunx.app.ui.login.normalizeWebLoginToken
import com.yunx.app.ui.login.webLoginTokenScript
import com.yunx.app.data.update.UpdateChecker
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertNull

class PortingRegressionTest {
    @Test
    fun webLoginTokenStaysScopedAndHandlesStoredJsonStrings() {
        assertTrue(isLoginHost("yun.123pan.cn", listOf("123pan.cn")))
        assertFalse(isLoginHost("123pan.cn.other.example", listOf("123pan.cn")))
        assertFalse(isLoginHost("other123pan.cn", listOf("123pan.cn")))
        assertEquals("example.jwt.token", normalizeWebLoginToken("\"example.jwt.token\""))
        assertEquals("example.jwt.token", normalizeWebLoginToken("example.jwt.token"))
        assertNull(normalizeWebLoginToken(""))
        assertNull(normalizeWebLoginToken("token\nheader"))
        assertTrue(webLoginTokenScript("authorToken").contains("localStorage.getItem(\"authorToken\")"))
    }

    @Test
    fun lanzouReadsRotatingSignVariableAndItsFinalAssignment() {
        val html = """
            var isngis = '';
            var isngis = 'current-download-sign';
            // data: { 'action':'downprocess', 'sign':old_sign }
            data: { 'action':'downprocess', 'sign':isngis, 'p':pwd }
        """.trimIndent()
        assertEquals("current-download-sign", lanzouDownloadSign(html))
        assertEquals("literal-sign", lanzouDownloadSign("data: {'action':'downprocess', 'sign':'literal-sign'}"))
        assertEquals("legacy-sign", lanzouDownloadSign("var wp_sign = 'legacy-sign';"))
        assertNull(lanzouDownloadSign("var isngis = ''; data: {'action':'downprocess', 'sign':isngis}"))
    }

    @Test
    fun chineseKoulingIsRecognizedWithoutCallingTheNetwork() {
        assertTrue(XunleiKouling.looksLikeKouling("「张三丰资源123」"))
        assertFalse(XunleiKouling.looksLikeKouling("abc123"))
        assertFalse(XunleiKouling.looksLikeKouling("资源 分享"))
        assertFalse(XunleiKouling.looksLikeKouling("https://pan.xunlei.com/s/abc"))
    }

    @Test
    fun releaseNotesKeepContentAndCollapseEmptyLines() {
        val notes = "\n## 更新\n\n\n修复下载\n<img src=\"https://capsule-render.vercel.app/api?type=waving\" />\n新增登录\n"
        assertEquals("## 更新\n\n修复下载\n新增登录", UpdateChecker.cleanReleaseNotes(notes))
    }

    @Test
    fun readmeLinksResolveAgainstTheContainingDirectory() {
        val base = "https://raw.githubusercontent.com/owner/repo/main/docs/"
        assertEquals("${base}images/icon.png", resolveUrl(base, "./images/icon.png"))
        assertEquals("https://raw.githubusercontent.com/owner/repo/main/LICENSE", resolveUrl(base, "../LICENSE"))
        assertEquals("https://raw.githubusercontent.com/owner/repo/main/", resolveUrl(base, ".."))
        assertEquals("https://raw.githubusercontent.com/LICENSE", resolveUrl(base, "../../../../../../LICENSE"))
        assertEquals("${base}image%2Fname.png?raw=1#preview", resolveUrl(base, "./image%2Fname.png?raw=1#preview"))
        assertEquals("https://example.com/file", resolveUrl(base, "https://example.com/file"))
    }
}
