// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI

/// 分享内容浏览：目录导航（面包屑）、搜索、多选批量下载、单文件在线播放 / 复制直链。
struct ShareBrowserView: View {
    let session: ShareSession

    @Environment(AccountStore.self) private var accounts
    @Environment(DownloadManager.self) private var downloads
    @Environment(ToastCenter.self) private var toast
    @Environment(SettingsStore.self) private var settings

    private struct Crumb: Hashable { let id: String; let name: String }

    @State private var crumbs: [Crumb] = []
    @State private var files: [ShareFile] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var query = ""
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var actionFile: ShareFile?
    @State private var working: String?
    @State private var player: PlayerTarget?

    private struct PlayerTarget: Identifiable {
        let id = UUID()
        let link: DownloadLink
    }

    private var cookie: String { accounts.cookie(.drive(session.platform)) }
    private var resolver: ShareResolver? { try? ShareResolvers.resolver(for: session.platform) }

    private var visible: [ShareFile] {
        // 文件夹在前，其余保持服务端顺序
        let sorted = files.filter(\.isDir) + files.filter { !$0.isDir }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private var downloadable: [ShareFile] { visible.filter { !$0.isDir } }

    var body: some View {
        List {
            Section {
                headerCard
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if crumbs.count > 1 {
                Section { breadcrumb.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4)) }
            }
            Section {
                if isLoading {
                    ForEach(0..<6, id: \.self) { _ in skeletonRow }
                } else if let loadError {
                    ContentUnavailableView {
                        Label("加载失败", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("重试") { Task { await load() } }.buttonStyle(.borderedProminent)
                    }
                    .listRowBackground(Color.clear)
                } else if visible.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "空文件夹" : "没有匹配的文件", systemImage: query.isEmpty ? "folder" : "magnifyingglass")
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(visible) { file in row(file) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle(crumbs.last?.name ?? session.title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "搜索文件")
        .refreshable { await load() }
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .confirmationDialog(actionFile?.name ?? "", isPresented: Binding(get: { actionFile != nil }, set: { if !$0 { actionFile = nil } }), titleVisibility: .visible) {
            if let file = actionFile { fileActions(file) }
        }
        .sheet(item: $player) { target in
            MediaPlayerSheet(url: target.link.url, headers: target.link.headers, title: target.link.fileName)
        }
        .overlay {
            if let working {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text(working).font(.subheadline)
                }
                .padding(24)
                .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .task {
            guard crumbs.isEmpty else { return }
            crumbs = [Crumb(id: session.rootId, name: session.title)]
            await load()
        }
    }

    // MARK: 组件

    private var headerCard: some View {
        HStack(spacing: 14) {
            PlatformLogo(name: session.platform.logo, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.headline).lineLimit(2)
                HStack(spacing: 6) {
                    Tag(text: session.platform.displayName, color: session.platform.tint)
                    if !isLoading {
                        let folderCount = files.filter(\.isDir).count
                        let size = files.reduce(Int64(0)) { $0 + ($1.isDir ? 0 : $1.size) }
                        Text("\(files.count - folderCount) 个文件\(folderCount > 0 ? " · \(folderCount) 个文件夹" : "")\(size > 0 ? " · \(Format.bytes(size))" : "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { index, crumb in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Button(index == 0 ? "全部" : crumb.name) {
                        guard index < crumbs.count - 1 else { return }
                        crumbs = Array(crumbs.prefix(index + 1))
                        Task { await load() }
                    }
                    .font(.subheadline.weight(index == crumbs.count - 1 ? .semibold : .regular))
                    .foregroundStyle(index == crumbs.count - 1 ? Color.primary : settings.accent.color)
                    .lineLimit(1)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var skeletonRow: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(height: 12)
                RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 90, height: 10)
            }
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
    }

    private func row(_ file: ShareFile) -> some View {
        Button {
            if selecting {
                guard !file.isDir else { return }
                if selection.contains(file.id) { selection.remove(file.id) } else { selection.insert(file.id) }
            } else if file.isDir {
                crumbs.append(Crumb(id: file.id, name: file.name))
                Task { await load() }
            } else {
                actionFile = file
            }
        } label: {
            HStack(spacing: 12) {
                if selecting && !file.isDir {
                    Image(systemName: selection.contains(file.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(file.id) ? settings.accent.color : Color.secondary)
                        .transition(.scale.combined(with: .opacity))
                }
                FileIcon(kind: file.fileKind)
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.name).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        if !file.isDir, file.size > 0 { Text(Format.bytes(file.size)) }
                        if !file.modified.isEmpty { Text(file.modified) }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if file.isDir {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                } else if !selecting {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(settings.accent.color)
                        .onTapGesture { Task { await download([file]) } }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if !file.isDir {
                Button { Task { await download([file]) } } label: { Label("下载", systemImage: "arrow.down") }
                    .tint(settings.accent.color)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if !downloadable.isEmpty {
                Button(selecting ? "完成" : "选择") {
                    withAnimation(.snappy) {
                        selecting.toggle()
                        selection.removeAll()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if !isLoading, !downloadable.isEmpty {
            HStack(spacing: 12) {
                if selecting {
                    Button(selection.count == downloadable.count ? "取消全选" : "全选") {
                        if selection.count == downloadable.count { selection.removeAll() } else { selection = Set(downloadable.map(\.id)) }
                    }
                    .buttonStyle(ChipButtonStyle(tint: settings.accent.color))
                }
                Button {
                    let targets = selecting ? downloadable.filter { selection.contains($0.id) } : downloadable
                    Task { await download(targets) }
                } label: {
                    Label(selecting ? "下载所选（\(selection.count)）" : "全部下载（\(downloadable.count)）", systemImage: "arrow.down.to.line")
                }
                .buttonStyle(GradientButtonStyle())
                .disabled(selecting && selection.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
    }

    @ViewBuilder
    private func fileActions(_ file: ShareFile) -> some View {
        Button("下载") { Task { await download([file]) } }
        if file.fileKind == .video || file.fileKind == .audio {
            Button("在线播放") { Task { await play(file) } }
        }
        Button("复制直链") { Task { await copyLink(file) } }
    }

    // MARK: 动作

    private func load() async {
        guard let resolver, let dir = crumbs.last else { return }
        isLoading = true
        loadError = nil
        selection.removeAll()
        do {
            files = try await resolver.list(session, dirId: dir.id, cookie: cookie)
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func download(_ targets: [ShareFile]) async {
        guard let resolver, !targets.isEmpty, working == nil else { return }
        var added = 0
        var lastError: String?
        for (index, file) in targets.enumerated() {
            working = targets.count > 1 ? "正在获取直链 \(index + 1)/\(targets.count)" : "正在获取直链…"
            do {
                let link = try await resolver.downloadLink(session, file: file, cookie: cookie)
                downloads.enqueue(link, source: session.platform.displayName, logo: session.platform.logo)
                added += 1
            } catch {
                lastError = error.localizedDescription
            }
            // 蓝奏等平台有频控，批量取链之间稍作间隔
            if targets.count > 1 { try? await Task.sleep(nanoseconds: 350_000_000) }
        }
        working = nil
        if selecting { withAnimation { selecting = false; selection.removeAll() } }
        if added > 0 {
            toast.show(added == targets.count ? "已加入下载（\(added)）" : "已加入 \(added) 个，\(targets.count - added) 个失败", .success)
        } else if let lastError {
            toast.show(lastError, .error)
        }
    }

    private func play(_ file: ShareFile) async {
        guard let resolver else { return }
        working = "正在获取播放地址…"
        defer { working = nil }
        do {
            let link = try await resolver.downloadLink(session, file: file, cookie: cookie)
            player = PlayerTarget(link: link)
        } catch {
            toast.show(error.localizedDescription, .error)
        }
    }

    private func copyLink(_ file: ShareFile) async {
        guard let resolver else { return }
        working = "正在获取直链…"
        defer { working = nil }
        do {
            let link = try await resolver.downloadLink(session, file: file, cookie: cookie)
            UIPasteboard.general.string = link.url
            toast.show("直链已复制（需带请求头才能下载）", .success)
        } catch {
            toast.show(error.localizedDescription, .error)
        }
    }
}
