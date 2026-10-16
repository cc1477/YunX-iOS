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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.yunx.app.data.backup.AuthBackupManager
import com.yunx.app.data.prefs.SettingsRepository
import com.yunx.app.data.update.UpdateChecker
import com.yunx.app.platform.*
import com.yunx.app.ui.theme.ThemeController
import com.yunx.app.util.AppLinks
import com.yunx.app.util.DiagnosticLog
import com.yunx.app.util.LogExporter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

enum class SettingsSection(val title: String) {
    APPEARANCE("外观与显示"), DOWNLOAD("下载设置"), SHARING("分享导入"),
    NETWORK("网络设置"), BACKUP("账号备份"), DIAGNOSTICS("问题诊断")
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SettingsScreen(scrollBehavior: TopAppBarScrollBehavior,
    themeRowModifier: Modifier = Modifier, aboutRowModifier: Modifier = Modifier,
    supportRowModifier: Modifier = Modifier, engineRowModifier: Modifier = Modifier,
    onThemeClick: () -> Unit, onAboutClick: () -> Unit, onSupportClick: () -> Unit,
    onGopeedClick: () -> Unit, backupManager: AuthBackupManager, modifier: Modifier = Modifier,
    section: SettingsSection? = null, onSectionSelected: (SettingsSection?) -> Unit = {}
) {
    val settings = remember { SettingsRepository() }
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf("") }
    var backup by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var platformThreadsExpanded by remember { mutableStateOf(false) }
    var exportingLogs by remember { mutableStateOf(false) }
    var logResult by remember { mutableStateOf("") }
    Column(modifier.fillMaxSize().nestedScroll(scrollBehavior.nestedScrollConnection)
        .verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(24.dp)) {
        when (section) {
            null -> {
                SettingsGroup("常用") {
                    SettingsRow("外观与显示", summary = "主题、系统文字与文件名", icon = Icons.Outlined.Palette,
                        onClick = { onSectionSelected(SettingsSection.APPEARANCE) })
                    SettingsRow("下载设置", summary = "线程、并发与文件校验", icon = Icons.Outlined.Download,
                        onClick = { onSectionSelected(SettingsSection.DOWNLOAD) })
                }
                SettingsGroup("工具") {
                    SettingsRow("分享导入", icon = Icons.Outlined.Link,
                        onClick = { onSectionSelected(SettingsSection.SHARING) })
                    SettingsRow("网络设置", icon = Icons.Outlined.Language,
                        onClick = { onSectionSelected(SettingsSection.NETWORK) })
                    SettingsRow("账号备份", icon = Icons.Outlined.Backup,
                        onClick = { onSectionSelected(SettingsSection.BACKUP) })
                    SettingsRow("问题诊断", icon = Icons.Outlined.Description,
                        onClick = { onSectionSelected(SettingsSection.DIAGNOSTICS) })
                }
                SettingsGroup("关于") {
                    SettingsRow("获取最新版本", icon = Icons.Outlined.SystemUpdate,
                        onClick = { openUrl(AppLinks.IOS_DISTRIBUTION) })
                    SettingsRow("关于 YunX", icon = Icons.Outlined.Info, modifier = aboutRowModifier, onClick = onAboutClick)
                    SettingsRow("支持开发", icon = Icons.Outlined.FavoriteBorder, modifier = supportRowModifier, onClick = onSupportClick)
                }
                Text("YunX ${UpdateChecker.installedVersion}（${UpdateChecker.installedBuild}）",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
            }
            SettingsSection.APPEARANCE -> {
                SettingsGroup("显示") {
                    SettingsRow("主题与外观", summary = "跟随系统、深色模式与主题色", modifier = themeRowModifier, onClick = onThemeClick)
                    PreferenceSwitch("文件名多行显示", ThemeController.fileNameMultiLine) { ThemeController.setFileNameMultiLine(it) }
                    PreferenceSwitch("识别剪贴板分享链接", ThemeController.clipboardSuggestEnabled) { ThemeController.setClipboardSuggestEnabled(it) }
                }
                SettingsNote("文字使用 iOS 系统字体，随系统文字大小与粗体文本设置调整。")
            }
            SettingsSection.DOWNLOAD -> {
                SettingsGroup("下载参数") {
                    PreferenceNumber("默认下载线程", settings.downloadThreads, 1..SettingsRepository.MAX_DOWNLOAD_THREADS) { settings.downloadThreads = it }
                    PreferenceNumber("同时下载任务", settings.maxConcurrentDownloads, 1..16) { settings.maxConcurrentDownloads = it }
                    PreferenceNumber("失败重试次数", settings.downloadRetryCount, 0..10) { settings.downloadRetryCount = it }
                    PreferenceNumber("限速（KB/s）", (settings.downloadSpeedLimit / 1024).toInt(), 0..1048576) { settings.downloadSpeedLimit = it.toLong() * 1024 }
                    SettingsRow("各平台下载线程", value = if (platformThreadsExpanded) "收起" else null,
                        onClick = { platformThreadsExpanded = !platformThreadsExpanded })
                    if (platformThreadsExpanded) {
                        for ((platform, label) in listOf("quark" to "夸克", "uc" to "UC", "baidu" to "百度", "c139" to "移动云盘",
                            "pan123" to "123", "pan115" to "115", "guangya" to "光鸭", "ilanzou" to "蓝奏优享", "lanzou" to "蓝奏", "github" to "GitHub")) {
                            PreferenceNumber("$label 下载线程", settings.downloadThreadsFor(platform), 1..SettingsRepository.MAX_DOWNLOAD_THREADS) { settings.setDownloadThreads(platform, it) }
                        }
                    }
                }
                SettingsNote("限速设为 0 时不限速。迅雷下载线程固定为 8。")
                SettingsGroup("文件与后台") {
                    PreferenceSwitch("完整文件 SHA-256", settings.fullFileSha256) { settings.fullFileSha256 = it }
                    PreferenceSwitch("夸克免转存下载", settings.quarkNoSaveDownload) { settings.quarkNoSaveDownload = it }
                    SettingsRow("下载引擎", modifier = engineRowModifier, onClick = onGopeedClick)
                    SettingsRow("通知权限", onClick = { scope.launch { result = if (requestPermission(Permission.NOTIFICATIONS)) "通知权限已允许" else "请在 iOS 系统设置中开启通知权限" } })
                }
                SettingsNote("文件位置：我的 iPhone → YunX → Downloads。卸载应用会删除这些文件。普通直链支持系统后台下载；网盘认证与视频分片任务请保持应用在前台。")
            }
            SettingsSection.SHARING -> {
                SettingsGroup("从其他 App 导入") {
                    SettingsNote("在浏览器或其他 App 中打开分享菜单，选择 YunX。返回 YunX 后，链接会自动填入并开始解析。")
                }
                SettingsNote("第一次使用可在分享菜单的「更多」中启用 YunX。分享内容通过系统剪贴板暂存；只会自动导入 YunX 分享入口标记的内容。")
            }
            SettingsSection.NETWORK -> {
                SettingsGroup("连接") {
                    PreferenceText("GitHub 镜像前缀", settings.githubMirrorPrefix.orEmpty()) { settings.githubMirrorPrefix = it.takeIf(String::isNotBlank) }
                    PreferenceSwitch("启用代理", settings.proxyEnabled) {
                        settings.proxyEnabled = it
                        com.yunx.app.data.network.HttpClients.setProxy(if (it) settings.proxyHost else null, settings.proxyPort)
                    }
                    PreferenceText("代理主机", settings.proxyHost) {
                        settings.proxyHost = it
                        if (settings.proxyEnabled) com.yunx.app.data.network.HttpClients.setProxy(it, settings.proxyPort)
                    }
                    PreferenceNumber("代理端口", settings.proxyPort, 1..65535) {
                        settings.proxyPort = it
                        if (settings.proxyEnabled) com.yunx.app.data.network.HttpClients.setProxy(settings.proxyHost, it)
                    }
                }
            }
            SettingsSection.BACKUP -> {
                SettingsNote("导出或恢复已登录账号。备份可能包含登录凭证，请妥善保管。")
                OutlinedTextField(password, { password = it }, label = { Text("备份密码（可选）") }, singleLine = true,
                    visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(12.dp))
                OutlinedTextField(backup, { backup = it }, label = { Text("备份内容") }, modifier = Modifier.fillMaxWidth(),
                    minLines = 3, maxLines = 6, shape = RoundedCornerShape(12.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(enabled = !busy, onClick = {
                        busy = true
                        scope.launch {
                            try { backup = backupManager.export(password.takeIf(String::isNotBlank)); result = "备份已生成" }
                            catch (e: CancellationException) { throw e }
                            catch (e: Exception) { result = "导出失败" }
                            finally { busy = false }
                        }
                    }) { Text("导出备份") }
                    OutlinedButton(enabled = !busy && backup.isNotBlank(), onClick = {
                        busy = true
                        scope.launch {
                            try { result = "已导入 ${backupManager.import(backup, password.takeIf(String::isNotBlank))} 个账号" }
                            catch (e: CancellationException) { throw e }
                            catch (e: Exception) { result = "导入失败，请检查内容与密码" }
                            finally { busy = false }
                        }
                    }) { Text("导入备份") }
                    TextButton(enabled = backup.isNotBlank() && !busy, onClick = { copyToClipboard(backup); result = "备份已复制" }) { Text("复制") }
                    TextButton(enabled = backup.isNotBlank() && !busy, onClick = { scope.launch { result = if (backupManager.saveToDownloads(backup, password.isNotBlank())) "已保存至 Downloads" else "保存失败" } }) { Text("保存到文件") }
                }
            }
            SettingsSection.DIAGNOSTICS -> {
                SettingsGroup("日志") {
                    PreferenceSwitch("记录诊断日志", settings.diagnosticMode) { settings.diagnosticMode = it; DiagnosticLog.setEnabled(it) }
                }
                SettingsNote("先开启记录，再重现登录、解析或下载问题，最后导出日志。日志自动隐藏登录凭证。")
                Button(enabled = !exportingLogs, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp), onClick = {
                    exportingLogs = true
                    scope.launch {
                        try {
                            DiagnosticLog.event(DiagnosticLog.OPERATION, "export_requested")
                            val file = withContext(Dispatchers.Default) { LogExporter.exportDiagnosticToDownloads() }
                            logResult = if (file == null) "导出失败，请重试"
                                else if (LogExporter.share(file)) "日志已保存，可通过分享菜单发送或存储。"
                                else "日志已保存：在「文件」→ 我的 iPhone → YunX → Downloads 中查找。"
                        } catch (e: CancellationException) { throw e }
                        catch (e: Exception) { DiagnosticLog.exception(DiagnosticLog.OPERATION, "export_failed", e); logResult = "导出失败，请重试" }
                        finally { exportingLogs = false }
                    }
                }) { Text(if (exportingLogs) "正在导出…" else "导出诊断日志") }
                if (logResult.isNotBlank()) SettingsNote(logResult)
                SettingsGroup("调试") {
                    PreferenceSwitch("下载调试", ThemeController.downloadDebug) {
                        ThemeController.setDownloadDebug(it); com.yunx.app.data.download.DownloadDebugLog.setEnabled(it)
                    }
                }
            }
        }
        if (result.isNotBlank()) SettingsNote(result)
        Spacer(Modifier.height(8.dp))
    }
}

@Composable
private fun SettingsGroup(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(horizontal = 16.dp))
        Surface(shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.45f)) {
            Column(verticalArrangement = Arrangement.spacedBy(0.5.dp), content = content)
        }
    }
}

@Composable
private fun SettingsNote(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp))
}

@Composable
private fun SettingsRow(title: String, summary: String? = null, value: String? = null, icon: ImageVector? = null,
    modifier: Modifier = Modifier, onClick: () -> Unit) {
    Surface(onClick = onClick, modifier = modifier.fillMaxWidth(), color = MaterialTheme.colorScheme.surfaceContainerLowest) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 12.dp).heightIn(min = 32.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            if (icon != null) Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(23.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                if (summary != null) Text(summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (value != null) Text(value, modifier = Modifier.widthIn(max = 130.dp), maxLines = 2,
                overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun PreferenceSwitch(label: String, initial: Boolean, save: (Boolean) -> Unit) {
    var value by remember(label) { mutableStateOf(initial) }
    Surface(color = MaterialTheme.colorScheme.surfaceContainerLowest) {
        Row(Modifier.fillMaxWidth().toggleable(value, role = Role.Switch, onValueChange = { value = it; save(it) })
            .padding(horizontal = 16.dp, vertical = 8.dp).heightIn(min = 44.dp),
            horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
            Switch(value, onCheckedChange = null)
        }
    }
}

@Composable
private fun PreferenceText(label: String, initial: String, save: (String) -> Unit) {
    var value by remember(label) { mutableStateOf(initial) }
    var editing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    SettingsRow(label, value = value.ifBlank { "未设置" }, onClick = { draft = value; editing = true })
    if (editing) AlertDialog(onDismissRequest = { editing = false }, title = { Text(label) }, text = {
        OutlinedTextField(draft, { draft = it }, label = { Text(label) }, modifier = Modifier.fillMaxWidth(), maxLines = 3)
    }, confirmButton = { TextButton(onClick = { value = draft.trim(); save(value); editing = false }) { Text("保存") } },
        dismissButton = { TextButton(onClick = { editing = false }) { Text("取消") } })
}

@Composable
private fun PreferenceNumber(label: String, initial: Int, range: IntRange, save: (Int) -> Unit) {
    var value by remember(label) { mutableStateOf(initial) }
    var editing by remember { mutableStateOf(false) }
    var draft by remember { mutableStateOf("") }
    SettingsRow(label, value = value.toString(), onClick = { draft = value.toString(); editing = true })
    if (editing) AlertDialog(onDismissRequest = { editing = false }, title = { Text(label) }, text = {
        OutlinedTextField(draft, { draft = it.filter(Char::isDigit) }, label = { Text(label) }, singleLine = true,
            supportingText = { Text("${range.first}–${range.last}") }, isError = draft.toIntOrNull()?.let { it !in range } != false,
            keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number))
    }, confirmButton = { TextButton(enabled = draft.toIntOrNull()?.let { it in range } == true,
        onClick = { value = draft.toInt(); save(value); editing = false }) { Text("保存") } },
        dismissButton = { TextButton(onClick = { editing = false }) { Text("取消") } })
}