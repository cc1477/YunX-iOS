package com.yunx.app

import com.yunx.app.util.DiagnosticLog
import com.yunx.app.util.LogRedactor
import com.yunx.app.util.writeLogZip
import com.yunx.app.ui.login.LoginCookie
import com.yunx.app.ui.login.selectLoginCookies
import kotlinx.coroutines.runBlocking
import okio.FileSystem
import okio.Path.Companion.toPath
import java.nio.file.Files
import java.util.zip.ZipFile
import kotlin.test.*

class DiagnosticExportTest {
    @Test
    fun secretsAreRedactedInStructuredAndUnstructuredDiagnostics() {
        val input = listOf(
            """{"status":401,"nested":[{"access_token":"token-secret","password":"pass-secret","phone":"13800000000","Cookie":"a=cookie-secret; b=second-secret"}]}""",
            "HTTP error: Authorization: Bearer bearer-secret",
            "Cookie: first=cookie-secret; second=second-secret",
            """event=http | code=403 | resp={"file_name":"private-secret","list":["second-secret"]""",
            """event=failed | {"refresh_token":"token-secret","passcode":"code-secret"}""",
            "request https://user:pass@example.com/download/path-secret?token=token-secret#fragment-secret",
            "password=\"pass-secret\"; __pus=principal-secret; __puus=session-secret; otp=code-secret"
        )
        for (line in input) {
            val safe = LogRedactor.line(line)
            assertFalse(safe.contains("-secret"), safe)
            assertFalse(safe.contains("13800000000"), safe)
        }
        assertEquals("https://example.com", LogRedactor.url("https://example.com/private?token=secret"))
        assertTrue(LogRedactor.line(input.first()).contains("401"))
    }

    @Test
    fun sharedQuarkCookiesBeatStaleSiblingCookiesAndExpiredValues() {
        val cookies = listOf(
            LoginCookie("__pus", "authenticated", ".quark.cn", "/"),
            LoginCookie("__pus", "stale", "pan.quark.cn", "/"),
            LoginCookie("__puus", "fresh", ".quark.cn", "/", 2000),
            LoginCookie("__puus", "guest", "drive-pc.quark.cn", "/"),
            LoginCookie("__puus", "expired", ".quark.cn", "/", 500),
            LoginCookie("__pus", "unrelated", ".quark.cn.example.com", "/"),
            LoginCookie("__pus", "wrong-path", ".quark.cn", "/account"),
        )
        for (order in listOf(cookies, cookies.reversed())) {
            assertEquals(mapOf("__pus" to "authenticated", "__puus" to "fresh"),
                selectLoginCookies(order, "https://pan.quark.cn/", listOf("quark.cn"), 1000))
        }
        assertEquals("__pus=authenticated; __puus=fresh", com.yunx.app.data.network.QuarkCookieUtil.mergeFromSetCookies(
            "__pus=authenticated; __puus=stale; __puus=duplicate", listOf("__puus=fresh; Path=/")))
    }

    @Test
    fun exportedZipRedactsOldLogsAndIncludesEnvironmentAndFlushStatus() = runBlocking {
        val folder = Files.createTempDirectory("yunx-diagnostics").toFile()
        try {
            val source = folder.resolve("legacy.log").absolutePath.toPath()
            FileSystem.SYSTEM.write(source) { writeUtf8("Cookie: a=legacy-secret; b=second-secret\nstatus=failed\n") }
            val target = folder.resolve("export.zip").absolutePath.toPath()
            writeLogZip(listOf(source), target)
            ZipFile(target.toFile()).use { zip ->
                val safe = zip.getInputStream(zip.getEntry("legacy.log")).bufferedReader().readText()
                assertFalse(safe.contains("-secret"))
                assertTrue(safe.contains("status=failed"))
            }
            DiagnosticLog.setEnabled(true)
            DiagnosticLog.event(DiagnosticLog.OPERATION, "export_test")
            val export = assertNotNull(DiagnosticLog.exportZip())
            try {
                ZipFile(export.toFile()).use { zip ->
                    val info = zip.getInputStream(zip.getEntry("diagnostics-info.txt")).bufferedReader().readText()
                    assertTrue(info.contains("schema 2"))
                    assertTrue(info.contains("flushed=true"))
                    assertTrue(info.contains("Java "))
                    val log = zip.getInputStream(zip.getEntry("operation.log")).bufferedReader().readText()
                    assertTrue(log.contains("export_test"))
                }
            } finally { FileSystem.SYSTEM.delete(export) }
        } finally { DiagnosticLog.setEnabled(false); folder.deleteRecursively() }
    }
}
