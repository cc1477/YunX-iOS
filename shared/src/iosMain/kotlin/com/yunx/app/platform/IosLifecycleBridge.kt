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

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)
package com.yunx.app.platform

import com.yunx.app.data.download.DownloadBackgroundLifecycle
import com.yunx.app.crash.installCrashHandler
import kotlinx.coroutines.*

/** Swift lifecycle entry points; all are called on the main thread. */
object IosLifecycleBridge {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var handoff: Job? = null
    fun install() {
        installCrashHandler()
        DownloadBackgroundLifecycle.install { it.attachBackgroundDownloader(BackgroundDownloader()) }
    }
    fun enterBackground(completionHandler: () -> Unit) {
        handoff?.cancel()
        handoff = scope.launch {
            try { DownloadBackgroundLifecycle.current()?.prepareForBackground() }
            catch (error: CancellationException) { throw error }
            catch (error: Exception) { PlatformLog.w("Lifecycle", "后台接管失败，任务保留为暂停", error) }
            finally { completionHandler() }
        }
    }
    fun expireBackgroundTransition() { handoff?.cancel() }
    fun enterForeground() {
        scope.launch {
            // Wait for previous transition cleanup before restarting foreground workers.
            handoff?.join()
            DownloadBackgroundLifecycle.current()?.resumeAfterBackground()
        }
    }
}
