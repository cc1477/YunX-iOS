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
import platform.UIKit.UIPasteboard
actual fun copyToClipboard(text: String) { UIPasteboard.generalPasteboard.string = text }
actual fun readClipboard(): String? = UIPasteboard.generalPasteboard.string
// UI feedback is carried by SnackbarController; avoid presenting over a login controller.
actual fun showToast(msg: String) {
    platform.darwin.dispatch_async(platform.darwin.dispatch_get_main_queue()) {
        com.yunx.app.ui.SnackbarController.show(msg)
    }
}
