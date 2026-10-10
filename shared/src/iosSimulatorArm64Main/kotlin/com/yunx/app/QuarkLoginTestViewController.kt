@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package com.yunx.app

import androidx.compose.runtime.*
import androidx.compose.material3.Text
import androidx.compose.ui.window.ComposeUIViewController
import com.yunx.app.data.network.QuarkApi
import com.yunx.app.data.network.QuarkConstants
import com.yunx.app.data.repository.QuarkAccountRepository
import com.yunx.app.ui.login.CookieLoginScreen
import com.yunx.app.ui.login.LocalCookieLoginTestConfiguration
import com.yunx.app.ui.theme.ComposeEmptyActivityTheme
import kotlinx.serialization.json.*
import platform.Foundation.*
import platform.UIKit.UIViewController

/** Simulator-only account test; reports contain booleans/counts, never cookies or filenames. */
fun QuarkLoginTestViewController(): UIViewController = ComposeUIViewController {
    val api = remember { QuarkApi() }
    val repository = remember { QuarkAccountRepository(api = api) }
    var saved by remember { mutableStateOf(false) }
    var finished by remember { mutableStateOf(false) }
    fun report(stage: String, cookie: String = "", count: Int? = null) {
        val fields = cookie.split(';').associate { it.trim().substringBefore('=') to it.trim().substringAfter('=', "") }
        val body = buildJsonObject {
            put("stage", stage)
            if (cookie.isNotEmpty()) {
                put("hasPus", !fields["__pus"].isNullOrBlank())
                put("hasPuus", !fields["__puus"].isNullOrBlank())
                put("cookieCount", fields.size)
            }
            count?.let { put("fileCount", it) }
        }.toString()
        (body as NSString).writeToFile(NSHomeDirectory() + "/Documents/quark-login-result.json", true,
            NSUTF8StringEncoding, null)
    }
    LaunchedEffect(Unit) { report("waiting_for_login") }
    ComposeEmptyActivityTheme {
        if (saved) Text("登录验证完成")
        else CompositionLocalProvider(LocalCookieLoginTestConfiguration provides ::configureQuarkSmsTest) {
        CookieLoginScreen("夸克登录测试", QuarkConstants.LOGIN_URL, {}, { saved = true },
            hideCredential = true,
            cookieIsPlausible = QuarkConstants::isValidCookie,
            onCredentialObserved = { if (!finished) report("waiting_for_login", it) },
            validateAndSave = { cookie ->
                val accepted = repository.saveQuarkAccount(cookie)
                if (!accepted) report("validation_rejected", cookie)
                else {
                    report("account_saved", cookie)
                    val persisted = checkNotNull(repository.getAccount()).cookie
                    try {
                        val files = api.listCloudFiles("0", persisted)
                        finished = true
                        report("drive_read_success", count = files?.size ?: 0)
                    } catch (_: Exception) {
                        finished = true
                        report("drive_read_failed")
                    }
                }
                accepted
            })
        }
    }
}
