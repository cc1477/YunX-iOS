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

@file:OptIn(kotlin.io.encoding.ExperimentalEncodingApi::class)

package com.yunx.app.util

import com.yunx.app.platform.*
import com.yunx.app.data.network.*
import kotlinx.serialization.json.*
import kotlinx.datetime.*
import io.ktor.client.HttpClient
import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.client.call.*
import io.ktor.http.*
import io.ktor.client.request.forms.*
import kotlin.random.Random
import kotlin.io.encoding.Base64
import kotlin.io.encoding.ExperimentalEncodingApi


/**
 * 应用对外的联系方式、仓库地址与 iOS 分发入口。
 *
 * ★ 为什么要集中放：同一个 QQ 群号、同一个仓库地址会在多个界面出现，
 *   就地写死的话改一处漏一处（换群号时最容易漏），所以对外入口一律从这里取常量。
 * ★ 新增对外入口（比如 Telegram 群、邮件反馈）时，先往这里加常量，再到界面里引用。
 */
object AppLinks {
    /** iOS 测试版本与签名导入入口。 */
    const val IOS_DISTRIBUTION = "https://yunx-lcsign-cc1477.pages.dev/"

    /** QQ 交流群群号（设置页与关于页共用）。 */
    const val QQ_GROUP = "635207650"

    /** GitHub 仓库完整地址（点击用系统浏览器打开） */
    const val GITHUB_REPO = "https://github.com/CYQawa/YunX"

    /** GitHub 仓库展示用短地址（去掉协议头，界面文字用；与 [GITHUB_REPO] 必须指向同一仓库） */
    const val GITHUB_REPO_DISPLAY = "github.com/CYQawa/YunX"

    /**
     * QQ 群资料页 scheme：QQ 已安装时直接拉起群卡片，用户点一下「加入」即可进群。
     *
     * ★ 为什么不用 https://qm.qq.com/... ：那种加群链接需要在 QQ 群后台申请一个 key，
     *   光有群号拼不出来；只有群号时只能走 mqqapi 这种私有 scheme。
     */
    fun qqGroupScheme(): String =
        "mqqapi://card/show_pslcard?src_type=internal&version=1&uin=$QQ_GROUP&card_type=group&source=qrcode"

    /**
     * 尝试拉起 QQ 群资料页；返回 false 表示这台设备上没有应用能处理该 scheme（基本都是没装 QQ）。
     *
     * ★ 刻意不用 resolveActivity() 预检：Android 11+ 的软件包可见性会让它在未声明 <queries> 时
     *   直接返回 null，把「装了 QQ」误判成「没装」；而隐式 Intent 直接 startActivity 不受该限制。
     *   所以这里靠捕获 ActivityNotFoundException 判断，返回 false 时调用方退回复制群号。
     */
    fun openQQGroup(): Boolean = openUrl(qqGroupScheme())
}
