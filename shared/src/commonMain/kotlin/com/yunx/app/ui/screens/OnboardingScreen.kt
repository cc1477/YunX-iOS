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

package com.yunx.app.ui.screens
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import com.yunx.app.ui.components.AppScaffold
import com.yunx.app.platform.*
import com.yunx.app.util.AppLinks
@Composable
fun OnboardingScreen(onFinish: () -> Unit, modifier: Modifier = Modifier) {
    var accepted by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf(false) }
    AppScaffold(modifier = modifier, bottomBar = {
        Surface(shadowElevation = 2.dp) {
            Box(
                Modifier.fillMaxWidth().windowInsetsPadding(
                    WindowInsets.safeDrawing.only(WindowInsetsSides.Horizontal + WindowInsetsSides.Bottom)
                ), contentAlignment = Alignment.Center
            ) {
                Column(Modifier.widthIn(max = 560.dp).fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp)) {
                    Row(
                        Modifier.fillMaxWidth().toggleable(accepted, role = Role.Checkbox, onValueChange = { accepted = it })
                            .heightIn(min = 48.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Checkbox(accepted, onCheckedChange = null)
                        Spacer(Modifier.width(12.dp))
                        Text("我已阅读并同意使用说明", modifier = Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    }
                    Spacer(Modifier.height(8.dp))
                    Button(onClick = onFinish, enabled = accepted, modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) {
                        Text("开始使用")
                    }
                }
            }
        }
    }) {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 560.dp).fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp)
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text("欢迎使用云析", style = MaterialTheme.typography.headlineLarge)
                    Text("解析分享链接、浏览云盘、管理下载。", style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text("使用说明", style = MaterialTheme.typography.titleMedium)
                        Text("请只解析与下载您有权使用的内容，并遵守各网盘服务条款。第三方服务可能限制访问或下载速度。")
                        Text("账号凭证保存在本机。下载保存在 App 沙盒；卸载应用会删除本地数据。")
                        Text("本项目按 AGPL-3.0-or-later 开源。", style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                PermissionPage()
                Column {
                    TextButton(onClick = { openUrl(AppLinks.GITHUB_REPO) }) { Text("GitHub · 云析") }
                    TextButton(onClick = { copyToClipboard(AppLinks.QQ_GROUP); showToast("群号已复制") }) { Text("QQ 交流群 ${AppLinks.QQ_GROUP}") }
                }
            }
        }
    }
}
