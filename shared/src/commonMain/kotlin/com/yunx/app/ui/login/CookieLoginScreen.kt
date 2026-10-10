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

import com.yunx.app.ui.components.AppScaffold
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CookieLoginScreen(
    title: String, url: String, onBack: () -> Unit, onSaved: () -> Unit,
    credentialLabel: String = "Cookie", loginDomains: List<String> = loginCookieDomains(url),
    webTokenKey: String? = null, cookieIsPlausible: ((String) -> Boolean)? = null,
    hideCredential: Boolean = false, onCredentialObserved: (String) -> Unit = {},
    validateAndSave: suspend (String) -> Boolean
) {
    var credential by remember(url) { mutableStateOf("") }
    var manualCredential by remember(url) { mutableStateOf(false) }
    var saving by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    if (webTokenKey != null || cookieIsPlausible != null) rememberWebLoginAutoDetect(
        sampleCredential = { credential },
        isPlausible = { cookieIsPlausible?.invoke(it) ?: (normalizeWebLoginToken(it) != null) },
        validateAndSave = validateAndSave,
        isPaused = { saving || manualCredential },
        onInFlightChange = { saving = it },
        onAutoSaved = onSaved
    )
    AppScaffold(topBar = {
        TopAppBar(title = { Text(title) }, navigationIcon = {
            IconButton(onClick = onBack, enabled = !saving) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "返回")
            }
        })
    }) { padding ->
        BoxWithConstraints(Modifier.fillMaxSize().padding(padding).padding(16.dp)) {
        val formMaxHeight = maxHeight * 0.55f
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.fillMaxWidth().heightIn(max = formMaxHeight).verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("在网页完成登录后保存，或手动粘贴 $credentialLabel。凭证仅保存在本机。")
            OutlinedTextField(value = credential, onValueChange = { credential = it; manualCredential = it.isNotBlank(); error = null },
                label = { Text(credentialLabel) }, modifier = Modifier.fillMaxWidth(), enabled = !saving,
                minLines = 1, maxLines = 3, isError = error != null,
                visualTransformation = if (hideCredential) androidx.compose.ui.text.input.PasswordVisualTransformation()
                    else androidx.compose.ui.text.input.VisualTransformation.None)
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            Button(enabled = !saving && credential.isNotBlank(), onClick = {
                saving = true
                scope.launch {
                    try {
                        if (validateAndSave(credential.trim())) onSaved()
                        else error = "凭证无效或登录尚未完成，请重试"
                    } catch (e: CancellationException) { throw e }
                    catch (e: Exception) { error = "保存失败，请检查网络后重试" }
                    finally { saving = false }
                }
            }, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(if (saving) "正在校验…" else "保存登录") }
        }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                CompositionLocalProvider(LocalWebLoginTokenReader provides webTokenKey?.let { key ->
                    WebLoginTokenReader(key) { token -> if (!manualCredential) credential = token }
                }) {
                CookieLoginWebView(url, loginDomains) { cookies ->
                    if (!manualCredential && credentialLabel == "Cookie") {
                        credential = cookies.entries.joinToString("; ") { "${it.key}=${it.value}" }
                        onCredentialObserved(credential)
                    }
                }
                }
            }
        }
        }
    }
}
