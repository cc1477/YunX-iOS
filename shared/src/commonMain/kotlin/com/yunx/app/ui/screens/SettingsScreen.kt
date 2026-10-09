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
import androidx.compose.ui.Modifier
import androidx.compose.ui.Alignment
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.unit.dp
import com.yunx.app.data.backup.AuthBackupManager
import com.yunx.app.data.prefs.SettingsRepository
import com.yunx.app.platform.*
import com.yunx.app.ui.theme.ThemeController
import com.yunx.app.util.AppLinks
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun SettingsScreen(scrollBehavior: TopAppBarScrollBehavior,
    themeRowModifier: Modifier = Modifier, aboutRowModifier: Modifier = Modifier,
    supportRowModifier: Modifier = Modifier, engineRowModifier: Modifier = Modifier,
    onThemeClick: () -> Unit, onAboutClick: () -> Unit, onSupportClick: () -> Unit,
    onGopeedClick: () -> Unit, backupManager: AuthBackupManager,
    onCheckUpdate: () -> Unit, onPreviewUpdateSheet: () -> Unit, modifier: Modifier = Modifier
) {
    val settings = remember { SettingsRepository() }
    val scope = rememberCoroutineScope()
    var result by remember { mutableStateOf("") }
    var backup by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var advanced by remember { mutableStateOf(false) }
    var platformThreadsExpanded by remember { mutableStateOf(false) }
    Column(modifier.fillMaxSize().nestedScroll(scrollBehavior.nestedScrollConnection)
        .verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("下载", style = MaterialTheme.typography.titleLarge)
        Text("在「文件」App 中打开：我的 iPhone → YunX → Downloads。",
            style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text("卸载 YunX 会删除应用内的文件。", style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        PreferenceNumber("默认下载线程", settings.downloadThreads, 1..SettingsRepository.MAX_DOWNLOAD_THREADS) { settings.downloadThreads = it }
        TextButton(onClick = { platformThreadsExpanded = !platformThreadsExpanded }) {
            Text(if (platformThreadsExpanded) "收起各平台下载线程" else "各平台下载线程")
        }
        if (platformThreadsExpanded) {
            for ((platform, label) in listOf("quark" to "夸克", "uc" to "UC", "baidu" to "百度", "c139" to "移动云盘", "pan123" to "123", "pan115" to "115", "guangya" to "光鸭", "ilanzou" to "蓝奏优享", "lanzou" to "蓝奏")) {
                PreferenceNumber("$label 下载线程", settings.downloadThreadsFor(platform), 1..SettingsRepository.MAX_DOWNLOAD_THREADS) { settings.setDownloadThreads(platform, it) }
            }
            Text("迅雷下载线程固定为 8")
            PreferenceNumber("GitHub 下载线程", settings.downloadThreadsFor("github"), 1..SettingsRepository.MAX_DOWNLOAD_THREADS) { settings.setDownloadThreads("github", it) }
        }
        PreferenceNumber("同时下载任务", settings.maxConcurrentDownloads, 1..16) { settings.maxConcurrentDownloads = it }
        PreferenceNumber("失败重试次数", settings.downloadRetryCount, 0..10) { settings.downloadRetryCount = it }
        PreferenceNumber("全局限速（KB/s，0 不限速）", (settings.downloadSpeedLimit / 1024).toInt(), 0..1048576) { settings.downloadSpeedLimit = it.toLong() * 1024 }
        PreferenceSwitch("完整文件 SHA-256", settings.fullFileSha256) { settings.fullFileSha256 = it }
        PreferenceSwitch("夸克免转存下载", settings.quarkNoSaveDownload) { settings.quarkNoSaveDownload = it }
        Button(onClick = onGopeedClick, modifier = engineRowModifier) { Text("下载引擎") }
        Text("iOS 前台下载可用，后台长时间下载能力将在后续平台阶段接入。")
        Button(onClick = { scope.launch { result = if (requestPermission(Permission.NOTIFICATIONS)) "通知权限已允许" else "未允许通知，请在系统设置中开启" } }) { Text("申请通知权限") }
        Text("外观与行为", style = MaterialTheme.typography.titleLarge)
        Button(onClick = onThemeClick, modifier = themeRowModifier) { Text("主题与外观") }
        PreferenceSwitch("文件名多行显示", ThemeController.fileNameMultiLine) { ThemeController.setFileNameMultiLine(it) }
        PreferenceSwitch("识别剪贴板分享链接", ThemeController.clipboardSuggestEnabled) { ThemeController.setClipboardSuggestEnabled(it) }
        PreferenceSwitch("接受预发布更新", ThemeController.acceptPrereleaseUpdate) { ThemeController.setAcceptPrereleaseUpdate(it) }
        Text("网络", style = MaterialTheme.typography.titleLarge)
        PreferenceText("GitHub 镜像前缀", settings.githubMirrorPrefix.orEmpty()) { settings.githubMirrorPrefix = it.takeIf(String::isNotBlank) }
        PreferenceSwitch("启用代理", settings.proxyEnabled) { settings.proxyEnabled = it; com.yunx.app.data.network.HttpClients.setProxy(if (it) settings.proxyHost else null, settings.proxyPort) }
        PreferenceText("代理主机", settings.proxyHost) { settings.proxyHost = it }
        PreferenceNumber("代理端口", settings.proxyPort, 1..65535) { settings.proxyPort = it }
        Text("账号认证备份", style = MaterialTheme.typography.titleLarge)
        OutlinedTextField(password, { password = it }, label = { Text("备份密码（可选）") },
            visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth())
        OutlinedTextField(backup, { backup = it }, label = { Text("粘贴 / 查看备份内容") }, modifier = Modifier.fillMaxWidth(), maxLines = 6)
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Button(enabled = !busy, onClick = {
                busy = true
                scope.launch {
                    try { backup = backupManager.export(password.takeIf(String::isNotBlank)); result = "备份已生成，可复制或保存" }
                    catch (e: CancellationException) { throw e }
                    catch (e: Exception) { result = "导出失败" }
                    finally { busy = false }
                }
            }) { Text("导出认证") }
            Button(enabled = !busy && backup.isNotBlank(), onClick = {
                busy = true
                scope.launch {
                    try { result = "已导入 ${backupManager.import(backup, password.takeIf(String::isNotBlank))} 个账号" }
                    catch (e: CancellationException) { throw e }
                    catch (e: Exception) { result = "导入失败，请检查内容与密码" }
                    finally { busy = false }
                }
            }) { Text("导入认证") }
        }
        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton(enabled = backup.isNotBlank() && !busy, onClick = { copyToClipboard(backup); result = "备份已复制" }) { Text("复制备份") }
            TextButton(enabled = backup.isNotBlank() && !busy, onClick = { scope.launch { result = if (backupManager.saveToDownloads(backup, password.isNotBlank())) "已保存至 App 下载目录" else "保存失败" } }) { Text("保存备份") }
        }
        result.takeIf(String::isNotBlank)?.let { Text(it) }
        Text("关于", style = MaterialTheme.typography.titleLarge)
        Button(onClick = onCheckUpdate) { Text("检查更新") }
        Button(onClick = onAboutClick, modifier = aboutRowModifier) { Text("关于云析") }
        Button(onClick = onSupportClick, modifier = supportRowModifier) { Text("支持开发") }
        TextButton(onClick = { openUrl(AppLinks.GITHUB_REPO) }) { Text(AppLinks.GITHUB_REPO_DISPLAY) }
        TextButton(onClick = { copyToClipboard(AppLinks.QQ_GROUP); showToast("群号已复制") }) { Text("复制 QQ 群号 ${AppLinks.QQ_GROUP}") }
        TextButton(onClick = { advanced = !advanced }) { Text("开发调试") }
        if (advanced) {
            PreferenceSwitch("下载调试", ThemeController.downloadDebug) {
                ThemeController.setDownloadDebug(it)
                com.yunx.app.data.download.DownloadDebugLog.setEnabled(it)
            }
            PreferenceSwitch("诊断日志", settings.diagnosticMode) { settings.diagnosticMode = it; com.yunx.app.util.DiagnosticLog.setEnabled(it) }
            TextButton(onClick = onPreviewUpdateSheet) { Text("预览更新弹窗") }
        }
    }
}
@Composable
private fun PreferenceSwitch(label: String, initial: Boolean, save: (Boolean) -> Unit) {
    var value by remember(label) { mutableStateOf(initial) }
    Row(Modifier.fillMaxWidth().toggleable(value, role = Role.Switch, onValueChange = { value = it; save(it) })
        .heightIn(min = 48.dp), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, modifier = Modifier.weight(1f))
        Switch(value, onCheckedChange = null)
    }
}
@Composable
private fun PreferenceText(label: String, initial: String, save: (String) -> Unit) {
    var value by remember(label) { mutableStateOf(initial) }
    OutlinedTextField(value, { value = it; save(it) }, label = { Text(label) }, modifier = Modifier.fillMaxWidth())
}
@Composable
private fun PreferenceNumber(label: String, initial: Int, range: IntRange, save: (Int) -> Unit) {
    var value by remember(label) { mutableStateOf(initial.toString()) }
    OutlinedTextField(value, { input ->
        value = input.filter(Char::isDigit)
        value.toIntOrNull()?.takeIf { it in range }?.let(save)
    }, label = { Text(label) }, modifier = Modifier.fillMaxWidth(), singleLine = true,
        keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number))
}
