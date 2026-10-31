// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI

@main
struct YunXApp: App {
    @State private var settings = SettingsStore()
    @State private var accounts = AccountStore()
    @State private var downloads = DownloadManager()
    @State private var history = HistoryStore()
    @State private var toast = ToastCenter()
    @State private var router = AppRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(settings)
                .environment(accounts)
                .environment(downloads)
                .environment(history)
                .environment(toast)
                .environment(router)
                .onOpenURL { router.handle($0) }
                .onAppear {
                    downloads.maxConcurrent = { [settings] in settings.maxConcurrent }
                    downloads.autoSaveToPhotos = { [settings] in settings.autoSaveToPhotos }
                }
        }
    }
}

enum AppTab: Hashable { case resolve, accounts, downloads, settings }

@MainActor
@Observable
final class AppRouter {
    var tab: AppTab = .resolve
    /// 待填入解析页的文本（深链 / 剪贴板）；解析页消费后清空
    var pendingInput: String?
    var autoStart = false

    /// yunx://resolve?url=<分享链接>
    func handle(_ url: URL) {
        guard url.scheme == "yunx" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let text = components?.queryItems?.first(where: { $0.name == "url" || $0.name == "text" })?.value, !text.isEmpty {
            open(text, autoStart: true)
        }
    }

    func open(_ text: String, autoStart: Bool) {
        tab = .resolve
        pendingInput = text
        self.autoStart = autoStart
    }
}

struct RootView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @State private var clipboardHint = false

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.tab) {
            ResolveView()
                .tabItem { Label("解析", systemImage: "link") }
                .tag(AppTab.resolve)
            AccountsView()
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
                .tag(AppTab.accounts)
            DownloadsView()
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
                .badge(downloads.runningCount)
                .tag(AppTab.downloads)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .tint(settings.accent.color)
        .preferredColorScheme(settings.appearance.colorScheme)
        .overlay { ToastOverlay() }
        .overlay(alignment: .bottom) {
            if clipboardHint {
                ClipboardBanner(isPresented: $clipboardHint)
                    .padding(.bottom, 60)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: Binding(get: { !settings.hasSeenNotice }, set: { if !$0 { settings.hasSeenNotice = true } })) {
            WelcomeSheet()
                .interactiveDismissDisabled()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: detectClipboard()
            case .background: downloads.persist()
            default: break
            }
        }
    }

    /// 只检测「剪贴板里像不像链接」，不读取内容 —— 不会触发系统的粘贴提示；用户点按后才真正读取
    private func detectClipboard() {
        guard settings.clipboardDetect, settings.hasSeenNotice else { return }
        let board = UIPasteboard.general
        let changeCount = board.changeCount
        guard changeCount != ClipboardBanner.lastHandledChange else { return }
        board.detectPatterns(for: [UIPasteboard.DetectionPattern.probableWebURL]) { result in
            guard case .success(let patterns) = result, patterns.contains(.probableWebURL) else { return }
            Task { @MainActor in
                ClipboardBanner.lastHandledChange = changeCount
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { clipboardHint = true }
            }
        }
    }
}

struct ClipboardBanner: View {
    @MainActor static var lastHandledChange = -1
    @Binding var isPresented: Bool
    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(settings.accent.gradient, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("检测到剪贴板中的链接").font(.subheadline.weight(.semibold))
                Text("一键粘贴并开始解析").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("解析") {
                if let text = UIPasteboard.general.string, !text.isEmpty {
                    router.open(text, autoStart: true)
                }
                withAnimation { isPresented = false }
            }
            .buttonStyle(ChipButtonStyle(tint: settings.accent.color))
            Button {
                withAnimation { isPresented = false }
            } label: {
                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
        .padding(.horizontal, 16)
        .task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            withAnimation { isPresented = false }
        }
    }
}

struct WelcomeSheet: View {
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image("AppLogo")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: settings.accent.color.opacity(0.4), radius: 20, y: 10)
            VStack(spacing: 8) {
                Text("欢迎使用云析").font(.largeTitle.bold())
                Text("粘贴分享链接，直接高速下载").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                feature("link.badge.plus", "网盘 & 视频解析", "夸克、蓝奏云、抖音、B站、快手、微博、AcFun")
                feature("bolt.fill", "断点续传", "暂停后继续，B站高清音视频自动合轨")
                feature("folder.fill", "文件 App 可见", "下载内容在「文件 › 我的 iPhone › 云析」")
                feature("heart.fill", "永久免费开源", "任何收费版本都是诈骗，请立即退款")
            }
            .padding(.horizontal, 8)
            Spacer()
            Text("本应用仅供学习交流，请遵守各平台用户协议，勿用于侵权用途。源代码遵循 GNU AGPL-3.0 协议。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("开始使用") { settings.hasSeenNotice = true }
                .buttonStyle(GradientButtonStyle())
        }
        .padding(28)
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(settings.accent.color)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}
