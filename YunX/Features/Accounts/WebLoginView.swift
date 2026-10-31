// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI
import WebKit

/// 网页登录：在独立（非持久化）的 WKWebView 里打开平台登录页，轮询 Cookie，
/// 一旦拿到必需字段就校验并保存 —— 用户不必手动点「完成」。
struct WebLoginView: View {
    let key: AccountKey
    var onManual: () -> Void

    @Environment(AccountStore.self) private var accounts
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss
    @State private var controller = WebLoginController()

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WebViewContainer(controller: controller)
                    .ignoresSafeArea(edges: .bottom)
                if controller.progress < 1 {
                    ProgressView(value: controller.progress)
                        .progressViewStyle(.linear)
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    Image(systemName: controller.status == .checking ? "hourglass" : "lock.shield")
                        .foregroundStyle(.secondary)
                    Text(controller.statusText).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("我已登录") { Task { await controller.capture(force: true) } }
                        .buttonStyle(ChipButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("登录\(key.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { controller.reload() } label: { Label("刷新页面", systemImage: "arrow.clockwise") }
                        Button {
                            dismiss()
                            onManual()
                        } label: { Label("手动填写 Cookie", systemImage: "keyboard") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .task {
            controller.onSuccess = { nickname, cookie in
                accounts.save(key, nickname: nickname, cookie: cookie)
                toast.show("\(key.displayName) 登录成功\(nickname.isEmpty ? "" : "：\(nickname)")", .success)
                dismiss()
            }
            controller.start(key)
        }
    }
}

@MainActor
@Observable
final class WebLoginController: NSObject, WKNavigationDelegate {
    enum Status { case waiting, checking, failed }

    var progress: Double = 0
    var status: Status = .waiting
    var statusText = "登录成功后会自动识别"

    @ObservationIgnored var onSuccess: ((String, String) -> Void)?
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var key: AccountKey?
    @ObservationIgnored private var poller: Task<Void, Never>?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var done = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        observation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            let value = view.estimatedProgress
            Task { @MainActor in self?.progress = value }
        }
    }

    func start(_ key: AccountKey) {
        guard self.key == nil, let raw = key.loginURL, let url = URL(string: raw) else { return }
        self.key = key
        webView.customUserAgent = key.loginUserAgent
        if let width = key.loginViewportWidth {
            // 强制桌面宽度渲染，WebView 自动缩放到整页可见，可双指放大
            let js = """
            (function(){var m=document.querySelector('meta[name="viewport"]');
            if(!m){m=document.createElement('meta');m.name='viewport';(document.head||document.documentElement).appendChild(m);}
            m.setAttribute('content','width=\(width), user-scalable=yes');})()
            """
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            )
        }
        webView.load(URLRequest(url: url))
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self?.capture(force: false)
            }
        }
    }

    func reload() { webView.reload() }

    func capture(force: Bool) async {
        guard let key, !done, status != .checking else { return }
        if let script = key.loginScript {
            // 凭证在页面 localStorage 里（迅雷网页版）：读出来的整段 JSON 就是要保存的登录态
            let value = await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                webView.evaluateJavaScript(script) { result, _ in continuation.resume(returning: result as? String ?? "") }
            }
            guard !value.isEmpty else {
                if force { statusText = "还没有拿到登录信息，请先完成登录" }
                return
            }
            await finish(key, credential: value, force: force)
            return
        }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let domain = key.cookieDomain
        let relevant = cookies.filter { domain.isEmpty || $0.domain.hasSuffix(domain) || $0.domain.hasSuffix(".\(domain)") }
        let names = Set(relevant.map(\.name))
        let ready = key.requiredCookies.allSatisfy { names.contains($0) }
        guard ready || force else { return }
        guard !relevant.isEmpty else {
            statusText = "还没有拿到登录信息，请先完成登录"
            return
        }
        let header = relevant.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        await finish(key, credential: header, force: force)
    }

    private func finish(_ key: AccountKey, credential: String, force: Bool) async {
        status = .checking
        statusText = "正在校验登录状态…"
        let nickname = await AccountStore.validate(key, cookie: credential)
        if let nickname {
            done = true
            poller?.cancel()
            onSuccess?(nickname, credential)
        } else {
            status = .failed
            statusText = force ? "校验未通过，请确认已完成登录" : "登录成功后会自动识别"
            if !force { status = .waiting }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in await self.capture(force: false) }
    }
}

private struct WebViewContainer: UIViewRepresentable {
    let controller: WebLoginController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
