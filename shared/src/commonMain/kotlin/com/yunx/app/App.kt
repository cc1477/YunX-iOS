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

package com.yunx.app
import androidx.compose.runtime.*
import com.yunx.app.ui.MainScreen
import com.yunx.app.ui.theme.ComposeEmptyActivityTheme
import com.yunx.app.data.prefs.SettingsRepository
import com.yunx.app.platform.*

/** Common entry replacing MainActivity / Application / ContentProvider startup. */
@Composable
fun App() {
    remember { AppStartup.initialize() }
    CompositionLocalProvider(androidx.compose.ui.platform.LocalUriHandler provides object : androidx.compose.ui.platform.UriHandler {
        override fun openUri(uri: String) { openUrl(uri) }
    }) {
        ComposeEmptyActivityTheme { MainScreen() }
    }
}
private object AppStartup {
    private val lock = PlatformLock()
    private var initialized = false
    fun initialize() = locked(lock) {
        if (!initialized) {
            com.yunx.app.data.security.CredentialStore.installRecovery()
            com.yunx.app.data.network.XunleiDeviceFingerprint.init()
            com.yunx.app.data.network.Pan123DeviceId.install()
            com.yunx.app.util.DiagnosticLog.install()
            com.yunx.app.data.download.DownloadDebugLog.install()
            val settings = SettingsRepository()
            com.yunx.app.util.DiagnosticLog.setEnabled(settings.diagnosticMode)
            // Only the Ktor engine is available in this port.
            settings.downloadEngine = SettingsRepository.ENGINE_BUILTIN
            if (settings.proxyEnabled) com.yunx.app.data.network.HttpClients.setProxy(settings.proxyHost, settings.proxyPort)
            runCatching { com.yunx.app.data.download.DownloadSaver.purgeOwnPendingFiles() }
                .onFailure { PlatformLog.w("App", "下载临时文件清理失败", it) }
            initialized = true
        }
    }
}
