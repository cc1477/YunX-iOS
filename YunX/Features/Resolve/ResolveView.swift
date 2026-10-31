// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI

enum ResolveRoute: Hashable {
    case share(ShareSession)
    case video(VideoParseResult)
}

@MainActor
@Observable
final class ResolveModel {
    var input = ""
    var pwd = ""
    var isLoading = false
    var path: [ResolveRoute] = []
    var successTick = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    var detected: DetectedLink? { DetectedLink.detect(input) }

    /// 网盘链接本身没带提取码时，显示提取码输入框
    var needsPwdField: Bool {
        if case .share(let share) = detected, share.pwd == nil { return true }
        return false
    }

    func cancel() {
        task?.cancel()
        task = nil
        isLoading = false
    }

    func start(accounts: AccountStore, history: HistoryStore, toast: ToastCenter) {
        let text = input.trimmed
        guard !text.isEmpty else { return }
        guard let link = DetectedLink.detect(text) else {
            toast.show("没有识别到支持的分享链接", .error)
            return
        }
        guard link.isAvailable else {
            toast.show("iOS 版暂未支持\(link.displayName)，敬请期待", .info)
            return
        }
        task?.cancel()
        isLoading = true
        task = Task {
            defer { isLoading = false }
            do {
                switch link {
                case .video(let video):
                    let result = try await VideoParseService.parse(video, cookie: accounts.cookie(.video(video.platform)))
                    guard !Task.isCancelled else { return }
                    if result.medias.isEmpty { throw VideoParseError(.unknown, "没有解析到可下载的媒体") }
                    history.add(text: text, title: result.title.isEmpty ? result.author : result.title, link: link)
                    if !result.notice.isEmpty { toast.show(result.notice, .info) }
                    path.append(.video(result))
                case .share(let share):
                    let resolver = try ShareResolvers.resolver(for: share.platform)
                    let code = share.pwd ?? (pwd.trimmed.isEmpty ? nil : pwd.trimmed)
                    let session = try await resolver.open(share, pwd: code, cookie: accounts.cookie(.drive(share.platform)))
                    guard !Task.isCancelled else { return }
                    history.add(text: text, title: session.title, link: link)
                    path.append(.share(session))
                }
                successTick += 1
            } catch is CancellationError {
            } catch {
                toast.show(error.localizedDescription, .error)
            }
        }
    }
}

struct ResolveView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(HistoryStore.self) private var history
    @Environment(ToastCenter.self) private var toast
    @Environment(AppRouter.self) private var router
    @Environment(SettingsStore.self) private var settings
    @State private var model = ResolveModel()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack(path: $model.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    inputCard
                    platforms
                    if !history.entries.isEmpty { historySection }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: ResolveRoute.self) { route in
                switch route {
                case .share(let session): ShareBrowserView(session: session)
                case .video(let result): VideoResultView(result: result)
                }
            }
        }
        .sensoryFeedback(.success, trigger: model.successTick)
        .onChange(of: router.pendingInput, initial: true) { _, text in
            guard let text else { return }
            model.input = text
            router.pendingInput = nil
            if router.autoStart {
                router.autoStart = false
                model.path.removeAll()
                start()
            }
        }
    }

    private func start() {
        focused = false
        model.start(accounts: accounts, history: history, toast: toast)
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image("AppLogo")
                .resizable()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: settings.accent.color.opacity(0.35), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("云析")
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(settings.accent.gradient)
                Text("粘贴分享链接，直接高速下载")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.top, 12)
    }

    // MARK: 输入卡片

    private var inputCard: some View {
        @Bindable var model = model
        return GlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    TextField("", text: $model.input, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($focused)
                        .font(.body)
                        .submitLabel(.go)
                        .onSubmit(start)
                    if model.input.isEmpty {
                        Text("粘贴网盘分享链接、视频链接或整段分享文案")
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                .padding(14)
                .background(Color(uiColor: .tertiarySystemFill).opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                detectionRow

                if model.needsPwdField {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill").foregroundStyle(.secondary)
                        TextField("提取码（没有可不填）", text: $model.pwd)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(12)
                    .background(Color(uiColor: .tertiarySystemFill).opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 10) {
                    PasteButton(payloadType: String.self) { strings in
                        guard let text = strings.first else { return }
                        Task { @MainActor in
                            model.input = text
                            start()
                        }
                    }
                    .buttonBorderShape(.capsule)
                    .labelStyle(.titleAndIcon)
                    .tint(settings.accent.color)
                    if !model.input.isEmpty {
                        Button {
                            model.input = ""
                            model.pwd = ""
                        } label: {
                            Label("清空", systemImage: "xmark")
                        }
                        .buttonStyle(ChipButtonStyle(tint: .secondary))
                    }
                    Spacer()
                }

                Button {
                    if model.isLoading { model.cancel() } else { start() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isLoading {
                            ProgressView().tint(.white)
                            Text("解析中… 点按取消")
                        } else {
                            Image(systemName: "sparkles")
                            Text("开始解析")
                        }
                    }
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(model.input.trimmed.isEmpty)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.needsPwdField)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.detected)
    }

    @ViewBuilder
    private var detectionRow: some View {
        if let link = model.detected {
            HStack(spacing: 10) {
                PlatformLogo(name: link.logo, size: 28)
                Text("识别为 \(link.displayName)").font(.subheadline.weight(.medium))
                if !link.isAvailable { Tag(text: "即将支持", color: .orange) }
                Spacer()
                Image(systemName: link.isAvailable ? "checkmark.seal.fill" : "clock.fill")
                    .foregroundStyle(link.isAvailable ? Color.green : Color.orange)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else if !model.input.isEmpty {
            Label("暂未识别到支持的链接", systemImage: "questionmark.circle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 平台

    private var platforms: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "支持的平台")
            GlassCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    platformRow("网盘", SharePlatform.allCases.map { PlatformChip(logo: $0.logo, name: $0.displayName, available: $0.isAvailable) })
                    Divider()
                    platformRow("视频", VideoPlatform.allCases.map { PlatformChip(logo: $0.logo, name: $0.displayName, available: $0.isAvailable) })
                }
            }
        }
    }

    private struct PlatformChip: Identifiable {
        let logo: String
        let name: String
        let available: Bool
        var id: String { logo }
    }

    private func platformRow(_ title: String, _ items: [PlatformChip]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { item in
                        VStack(spacing: 6) {
                            PlatformLogo(name: item.logo, size: 44, dimmed: !item.available)
                            Text(item.name).font(.caption2).foregroundStyle(item.available ? Color.primary : Color.secondary).lineLimit(1)
                        }
                        .frame(width: 60)
                    }
                }
            }
        }
    }

    // MARK: 历史

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "最近解析", trailing: "清空") { withAnimation { history.clear() } }
            GlassCard(padding: 6) {
                VStack(spacing: 0) {
                    ForEach(Array(history.entries.prefix(8).enumerated()), id: \.element.id) { index, entry in
                        Button {
                            model.input = entry.text
                            model.pwd = ""
                            start()
                        } label: {
                            HStack(spacing: 12) {
                                PlatformLogo(name: entry.logo, size: 36)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(entry.title.isEmpty ? entry.platformName : entry.title)
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text("\(entry.platformName) · \(entry.date.formatted(.relative(presentation: .named)))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { UIPasteboard.general.string = entry.text } label: { Label("复制链接", systemImage: "doc.on.doc") }
                            Button(role: .destructive) { withAnimation { history.remove(entry) } } label: { Label("删除", systemImage: "trash") }
                        }
                        if index < min(history.entries.count, 8) - 1 { Divider().padding(.leading, 58) }
                    }
                }
            }
        }
    }
}
