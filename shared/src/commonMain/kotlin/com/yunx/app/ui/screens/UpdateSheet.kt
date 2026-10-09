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

@file:OptIn(androidx.compose.ui.ExperimentalComposeUiApi::class)

package com.yunx.app.ui.screens
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.yunx.app.data.update.UpdateChecker
import com.yunx.app.platform.openUrl
import com.mikepenz.markdown.m3.Markdown
/** iOS updates show the upstream release; APK installation is an Android-only flow. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun UpdateSheet(currentVersion: String, release: UpdateChecker.Release,
    onLater: () -> Unit, onIgnore: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onLater,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(24.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("发现新版本 ${release.tagName}", style = MaterialTheme.typography.headlineSmall)
            Text("当前版本：$currentVersion")
            Markdown(content = release.body)
            Text("查看项目发布说明与适用于您的平台的版本。iOS 不支持安装 APK。")
            Button(onClick = {
                openUrl(release.htmlUrl.ifBlank { "https://github.com/CYQawa/YunX/releases/latest" })
                onLater()
            }) { Text("查看 GitHub 发布页") }
            Row {
                TextButton(onClick = onIgnore) { Text("忽略本次") }
                TextButton(onClick = onLater) { Text("稍后") }
            }
        }
    }
}
