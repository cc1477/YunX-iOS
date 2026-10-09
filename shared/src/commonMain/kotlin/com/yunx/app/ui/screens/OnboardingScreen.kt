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
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.yunx.app.platform.*
import com.yunx.app.util.AppLinks
@Composable
fun OnboardingScreen(onFinish: () -> Unit, modifier: Modifier = Modifier) {
    var accepted by remember { mutableStateOf(false) }
    Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text("欢迎使用云析", style = MaterialTheme.typography.headlineLarge)
        Text("解析网盘分享链接、浏览云盘并管理下载。账号凭证保存在本机。")
        TextButton(onClick = { openUrl(AppLinks.GITHUB_REPO) }) { Text("GitHub · 云析") }
        TextButton(onClick = { copyToClipboard(AppLinks.QQ_GROUP); showToast("群号已复制") }) { Text("QQ 交流群 ${AppLinks.QQ_GROUP}") }
        Text("请只解析与下载您有权使用的内容，并遵守各网盘服务条款。第三方服务可能限制访问或下载速度。")
        Text("本项目按 AGPL-3.0-or-later 开源。下载保存在 App 沙盒；卸载应用会删除本地数据。")
        PermissionPage()
        Row { Checkbox(accepted, { accepted = it }); Text("我已阅读并同意使用说明") }
        Button(onClick = onFinish, enabled = accepted) { Text("开始使用") }
    }
}
