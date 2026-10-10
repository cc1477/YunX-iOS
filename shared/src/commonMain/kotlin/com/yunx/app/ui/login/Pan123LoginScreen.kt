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
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.yunx.app.data.network.Pan123Constants
import com.yunx.app.ui.viewmodel.Pan123AccountViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch
@Composable
fun Pan123LoginScreen(viewModel: Pan123AccountViewModel, onBack: () -> Unit, onSaved: () -> Unit) {
    var usePassword by remember { mutableStateOf(false) }
    var account by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize()) {
        TextButton(onClick = { usePassword = !usePassword }, enabled = !busy) {
            Text(if (usePassword) "切换网页登录 / Token" else "切换账号密码登录")
        }
        if (usePassword) {
            Column(Modifier.padding(16.dp)) {
                TextButton(onClick = onBack, enabled = !busy) { Text("返回") }
                OutlinedTextField(account, { account = it }, label = { Text("手机号 / 邮箱") })
                OutlinedTextField(password, { password = it }, label = { Text("密码") }, visualTransformation = PasswordVisualTransformation())
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Button(enabled = !busy && account.isNotBlank() && password.isNotBlank(), onClick = {
                    busy = true
                    scope.launch {
                        try { error = viewModel.login(account.trim(), password); if (error == null) onSaved() }
                        catch (e: CancellationException) { throw e }
                        catch (e: Exception) { error = "登录失败，请重试" }
                        finally { busy = false }
                    }
                }) { Text(if (busy) "登录中…" else "登录") }
            }
        } else CookieLoginScreen("123 云盘登录", Pan123Constants.WEB_LOGIN_URL, onBack, onSaved,
            credentialLabel = "Token", webTokenKey = Pan123Constants.LOCAL_STORAGE_TOKEN_KEY,
            validateAndSave = { viewModel.saveToken(it) })
    }
}
