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

@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class, androidx.compose.ui.ExperimentalComposeUiApi::class)
package com.yunx.app.ui.login

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.interop.UIKitViewController
import kotlinx.cinterop.cValue
import kotlinx.coroutines.delay
import platform.Foundation.*
import platform.UIKit.UIViewController
import platform.WebKit.*
import platform.darwin.NSObject

/** Swift's existing UIViewControllerRepresentable hosts Compose; Compose hosts this child controller. */
@Composable
actual fun CookieLoginWebView(url: String, onCookies: (Map<String, String>) -> Unit) {
    val callback = rememberUpdatedState(onCookies)
    val tokenReader = rememberUpdatedState(LocalWebLoginTokenReader.current)
    val explicitDomains = LocalCookieLoginDomains.current
    val domains = remember(url, explicitDomains) {
        (explicitDomains.ifEmpty { loginCookieDomains(url) })
            .map { it.trim().removePrefix(".").lowercase() }.filter { it.isNotEmpty() }
    }
    val delegate = remember(url, domains) { object : NSObject(), WKNavigationDelegateProtocol {
        override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) {
            DiagnosticWebViewClient.navigationCompleted(webView.URL?.host.orEmpty())
            // Read the WebKit jar after every didFinish, including SSO redirects. Domain boundaries
            // come from the caller, never from the redirect host or a naive last-two-label heuristic.
            WKWebsiteDataStore.defaultDataStore().httpCookieStore.getAllCookies { cookies ->
                val scoped = cookies.orEmpty().filterIsInstance<NSHTTPCookie>().filter { cookie ->
                    val domain = cookie.domain.removePrefix(".").lowercase()
                    domains.any { domain == it || domain.endsWith(".$it") }
                }.associate { it.name to it.value }
                NSOperationQueue.mainQueue.addOperationWithBlock { callback.value(scoped) }
            }
        }
        override fun webView(webView: WKWebView, decidePolicyForNavigationAction: WKNavigationAction,
            decisionHandler: (WKNavigationActionPolicy) -> Unit) {
            val scheme = decidePolicyForNavigationAction.request.URL?.scheme?.lowercase()
            decisionHandler(if (scheme in listOf("http", "https", "about"))
                WKNavigationActionPolicy.WKNavigationActionPolicyAllow else WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
        }
    } }
    val webView = remember(url, delegate) {
        WKWebView(frame = cValue { }, configuration = WKWebViewConfiguration()).apply {
            navigationDelegate = delegate
            // Match upstream desktop Chrome 131 UA. This changes the UA string only: WebKit stays
            // WebKit and cannot emulate Chromium client hints / all desktop login behavior.
            customUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
            NSURL.URLWithString(url)?.let { loadRequest(NSURLRequest.requestWithURL(it)) }
        }
    }
    val controller = remember(webView) { UIViewController().apply { view = webView } }
    // QR login updates localStorage in the same SPA document without a navigation callback.
    LaunchedEffect(webView) {
        while (true) {
            val reader = tokenReader.value
            val host = webView.URL?.host.orEmpty()
            if (reader != null && webView.URL?.scheme == "https" && isLoginHost(host, domains)) {
                webView.evaluateJavaScript(webLoginTokenScript(reader.key)) { result, error ->
                    if (error == null && isLoginHost(webView.URL?.host.orEmpty(), domains)) {
                        (result as? String)?.let(::normalizeWebLoginToken)?.let { tokenReader.value?.onToken?.invoke(it) }
                    }
                }
            }
            delay(1500)
        }
    }
    DisposableEffect(webView) {
        onDispose { webView.stopLoading(); webView.navigationDelegate = null }
    }
    UIKitViewController(factory = { controller }, modifier = Modifier.fillMaxSize())
}
