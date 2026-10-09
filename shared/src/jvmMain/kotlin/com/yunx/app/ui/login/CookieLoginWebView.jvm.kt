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
import androidx.compose.ui.unit.dp
import com.yunx.app.platform.openUrl
@Composable
actual fun CookieLoginWebView(url: String, onCookies: (Map<String, String>) -> Unit) {
    var input by remember(url) { mutableStateOf("") }
    Column(Modifier.fillMaxSize().padding(12.dp)) {
        Text("请手动粘贴 Cookie")
        TextButton(onClick = { openUrl(url) }) { Text("在浏览器打开登录网页") }
        OutlinedTextField(input, { input = it }, label = { Text("Cookie") }, modifier = Modifier.fillMaxWidth())
        Button(enabled = input.isNotBlank(), onClick = {
            val cookies = input.split(';').mapNotNull {
                val name = it.substringBefore('=').trim()
                if ('=' !in it || name.isBlank()) null else name to it.substringAfter('=').trim()
            }.toMap()
            if (cookies.isNotEmpty()) onCookies(cookies)
        }) { Text("使用 Cookie") }
    }
}
