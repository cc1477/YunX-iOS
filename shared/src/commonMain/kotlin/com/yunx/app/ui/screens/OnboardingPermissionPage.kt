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
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.yunx.app.platform.*
import kotlinx.coroutines.launch
@Composable
internal fun PermissionPage(storageGranted: Boolean = true, storageDenied: Boolean = false, onRequestStorage: () -> Unit = {}) {
    val scope = rememberCoroutineScope()
    var status by remember { mutableStateOf("通知权限用于下载提醒，可稍后开启。") }
    var requesting by remember { mutableStateOf(false) }
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
        Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("应用权限", style = MaterialTheme.typography.titleMedium)
            Text("使用 App 沙盒下载目录，无需存储授权。")
            Text(status, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            OutlinedButton(enabled = !requesting, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), onClick = {
                requesting = true
                scope.launch {
                    try {
                        status = if (requestPermission(Permission.NOTIFICATIONS)) "已允许通知" else "未允许通知，可在系统设置中开启"
                    } finally { requesting = false }
                }
            }) { Text(if (requesting) "正在申请…" else "申请通知权限") }
        }
    }
}
