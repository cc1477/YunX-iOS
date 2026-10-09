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

package com.yunx.app.ui.login
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
@Composable
fun XunleiVerifyWebViewScreen(verifyUrl: String, deviceId: String,
    onResult: (success: Boolean, extra: String) -> Unit, onBack: () -> Unit) {
    val trusted = remember(verifyUrl) { XunleiVerificationPolicy.isTrustedPage(verifyUrl) }
    LaunchedEffect(trusted) { if (!trusted) onResult(false, "untrusted_verify_url") }
    Column(Modifier.fillMaxSize()) {
        TextButton(onClick = onBack) { Text("返回") }
        Text("完成网页验证后返回并重试登录。本页不会自动判定验证成功，请返回并重试登录。")
        if (trusted) Box(Modifier.weight(1f)) {
            CookieLoginWebView(verifyUrl, loginCookieDomains(verifyUrl)) { /* Cookie presence is not proof of verification. */ }
        }
    }
}
