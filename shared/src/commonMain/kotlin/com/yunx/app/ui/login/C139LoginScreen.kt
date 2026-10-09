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
import androidx.compose.runtime.Composable
import com.yunx.app.data.network.C139Constants
import com.yunx.app.ui.viewmodel.C139AccountViewModel
@Composable
fun C139LoginScreen(viewModel: C139AccountViewModel, onBack: () -> Unit, onSaved: () -> Unit) {
    CookieLoginScreen("中国移动云盘登录", C139Constants.LOGIN_URL, onBack, onSaved, validateAndSave = { viewModel.saveC139Account(it) })
}
