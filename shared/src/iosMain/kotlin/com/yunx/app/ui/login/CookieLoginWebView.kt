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
import com.yunx.app.util.DiagnosticLog
import com.yunx.app.data.network.QuarkConstants
import platform.Foundation.*
import platform.UIKit.UIViewController
import platform.WebKit.*
import platform.darwin.NSObject

/** Simulator tests can configure their own WebKit controller; shipping screens use the default. */
internal val LocalCookieLoginTestConfiguration = staticCompositionLocalOf<(WKWebViewConfiguration) -> Unit> { {} }

/** Swift's existing UIViewControllerRepresentable hosts Compose; Compose hosts this child controller. */
@Composable
actual fun CookieLoginWebView(url: String, onCookies: (Map<String, String>) -> Unit) {
    val callback = rememberUpdatedState(onCookies)
    val tokenReader = rememberUpdatedState(LocalWebLoginTokenReader.current)
    val explicitDomains = LocalCookieLoginDomains.current
    val testConfiguration = LocalCookieLoginTestConfiguration.current
    val domains = remember(url, explicitDomains) {
        (explicitDomains.ifEmpty { loginCookieDomains(url) })
            .map { it.trim().removePrefix(".").lowercase() }.filter { it.isNotEmpty() }
    }
    val cookieStore = remember(url) { WKWebsiteDataStore.defaultDataStore().httpCookieStore }
    val cookieObserver = remember(url, domains) { object : NSObject(), WKHTTPCookieStoreObserverProtocol {
        var active = false
        var reading = false
        var lastCookies: Map<String, String>? = null
        fun readCookies() {
            if (!active || reading) return
            reading = true
            cookieStore.getAllCookies { cookies ->
                NSOperationQueue.mainQueue.addOperationWithBlock {
                    reading = false
                    if (active) {
                        val snapshots = cookies.orEmpty().filterIsInstance<NSHTTPCookie>().map {
                            LoginCookie(it.name, it.value, it.domain, it.path, it.expiresDate?.timeIntervalSince1970?.times(1000)?.toLong())
                        }
                        val scoped = selectLoginCookies(snapshots, url, domains, kotlinx.datetime.Clock.System.now().toEpochMilliseconds())
                        if (scoped != lastCookies) {
                            lastCookies = scoped
                            val credential = scoped.entries.joinToString("; ") { it.key + "=" + it.value }
                            DiagnosticLog.webview("cookies_changed", url,
                                summary = "count=" + scoped.size + " | hasPrincipal=" + QuarkConstants.hasLoginPrincipal(credential) +
                                    " | hasSession=" + QuarkConstants.isValidCookie(credential) +
                                    " | duplicateNames=" + snapshots.filter { isLoginHost(it.domain.removePrefix("."), domains) }.groupBy { it.name }.count { it.value.size > 1 })
                            callback.value(scoped)
                        }
                    }
                }
            }
        }
        override fun cookiesDidChangeInCookieStore(cookieStore: WKHTTPCookieStore) { readCookies() }
    } }
    val delegate = remember(url, domains, cookieObserver) { object : NSObject(), WKNavigationDelegateProtocol {
        override fun webView(webView: WKWebView, didFinishNavigation: WKNavigation?) {
            DiagnosticWebViewClient.navigationCompleted(webView.URL?.host.orEmpty())
            DiagnosticLog.webview("navigation_finished", webView.URL?.absoluteString)
            cookieObserver.readCookies()
        }
        override fun webView(webView: WKWebView, didFailProvisionalNavigation: WKNavigation?, withError: NSError) {
            DiagnosticLog.webview("navigation_start_failed", webView.URL?.absoluteString, withError.code,
                "errorDomain=" + withError.domain)
        }
        override fun webView(webView: WKWebView, didFailNavigation: WKNavigation?, withError: NSError) {
            DiagnosticLog.webview("navigation_failed", webView.URL?.absoluteString, withError.code,
                "errorDomain=" + withError.domain)
        }
        override fun webView(webView: WKWebView, decidePolicyForNavigationAction: WKNavigationAction,
            decisionHandler: (WKNavigationActionPolicy) -> Unit) {
            val scheme = decidePolicyForNavigationAction.request.URL?.scheme?.lowercase()
            decisionHandler(if (scheme in listOf("http", "https", "about"))
                WKNavigationActionPolicy.WKNavigationActionPolicyAllow else WKNavigationActionPolicy.WKNavigationActionPolicyCancel)
        }
    } }
    val webView = remember(url, delegate) {
        WKWebView(frame = cValue { }, configuration = WKWebViewConfiguration().apply(testConfiguration)).apply {
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
            cookieObserver.readCookies()
            val reader = tokenReader.value
            val host = webView.URL?.host.orEmpty()
            if (reader != null && webView.URL?.scheme == "https" && isLoginHost(host, domains)) {
                webView.evaluateJavaScript(webLoginTokenScript(reader.key)) { result, error ->
                    if (error == null && isLoginHost(webView.URL?.host.orEmpty(), domains)) {
                        (result as? String)?.let(::normalizeWebLoginToken)?.let { tokenReader.value?.onToken?.invoke(it) }
                    } else if (error != null) {
                        DiagnosticLog.webview("token_read_failed", webView.URL?.absoluteString, error.code,
                            "errorDomain=" + error.domain)
                    }
                }
            }
            delay(1500)
        }
    }
    DisposableEffect(webView, cookieObserver) {
        // SPA/QR login can update HttpOnly cookies without finishing a navigation.
        cookieObserver.active = true
        DiagnosticLog.webview("login_webview_opened", url)
        cookieStore.addObserver(cookieObserver)
        cookieObserver.readCookies()
        onDispose {
            cookieObserver.active = false
            DiagnosticLog.webview("login_webview_closed", url)
            cookieStore.removeObserver(cookieObserver)
            webView.stopLoading()
            webView.navigationDelegate = null
        }
    }
    UIKitViewController(factory = { controller }, modifier = Modifier.fillMaxSize())
}
