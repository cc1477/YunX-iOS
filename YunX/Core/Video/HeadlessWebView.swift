// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import UIKit
import WebKit

/// 无界面 WKWebView：加载页面 → 轮询就绪脚本 → 执行提取脚本拿 JSON 字符串。
///
/// 抖音网页版的作品数据由前端脚本动态拉取（带签名），纯 HTTP 拿不到时用它兜底。
/// WebView 挂在 key window 上（1×1、近乎透明），否则 iOS 会节流后台 WebView 的 JS 定时器。
@MainActor
final class HeadlessWebView: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var keepAlive: HeadlessWebView?

    static func loadAndExtract(
        url: String,
        userAgent: String,
        readyCheckJS: String,
        extractJS: String,
        documentStartJS: [String] = [],
        timeout: TimeInterval = 30
    ) async -> String? {
        let runner = HeadlessWebView()
        return await runner.run(url: url, userAgent: userAgent, readyCheckJS: readyCheckJS,
                                extractJS: extractJS, documentStartJS: documentStartJS, timeout: timeout)
    }

    private func run(
        url: String,
        userAgent: String,
        readyCheckJS: String,
        extractJS: String,
        documentStartJS: [String],
        timeout: TimeInterval
    ) async -> String? {
        guard let target = URL(string: url) else { return nil }
        keepAlive = self
        defer { teardown() }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        for script in documentStartJS {
            config.userContentController.addUserScript(
                WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        webView.customUserAgent = userAgent
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.navigationDelegate = self
        self.webView = webView

        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) {
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            window.insertSubview(webView, at: 0)
        }
        webView.load(URLRequest(url: target))

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return nil }
            if await evaluate(readyCheckJS, in: webView) == "true" { break }
        }
        // 就绪后再等一拍，让图集懒加载的其余图片补齐
        try? await Task.sleep(nanoseconds: 800_000_000)
        return await evaluate("JSON.stringify(\(extractJS))", in: webView)
    }

    /// 用回调版 API：async 版 evaluateJavaScript 在脚本返回 undefined 时会崩溃（iOS 15+ 已知问题）
    private func evaluate(_ script: String, in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private func teardown() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        keepAlive = nil
    }
}
