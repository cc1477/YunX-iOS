// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI

/// 视频 / 图集解析结果：封面大图、作者信息、正文，视频卡片可在线播放，图集三列网格可放大查看。
struct VideoResultView: View {
    let result: VideoParseResult

    @Environment(DownloadManager.self) private var downloads
    @Environment(ToastCenter.self) private var toast
    @Environment(SettingsStore.self) private var settings
    @State private var expanded = false
    @State private var playing: VideoMedia?
    @State private var viewerIndex: Int?

    private var heroImage: String { result.cover.isEmpty ? (result.images.first?.url ?? "") : result.cover }
    private var heroHeaders: [String: String] { result.medias.first?.headers ?? [:] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                VStack(alignment: .leading, spacing: 20) {
                    authorRow
                    if !result.text.isEmpty, result.text != result.title { description }
                    if !result.notice.isEmpty {
                        Label(result.notice, systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                    if !result.videos.isEmpty { videoSection }
                    if !result.images.isEmpty { imageSection }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 100)
        }
        .background(AppBackground())
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !result.url.isEmpty, let url = URL(string: result.url) {
                        ShareLink(item: url) { Label("分享原链接", systemImage: "square.and.arrow.up") }
                        Button { UIPasteboard.general.string = result.url } label: { Label("复制原链接", systemImage: "link") }
                    }
                    if !result.text.isEmpty {
                        Button { UIPasteboard.general.string = result.text } label: { Label("复制文案", systemImage: "doc.on.doc") }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.title3)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                downloadAll()
            } label: {
                Label(result.medias.count > 1 ? "全部下载（\(result.medias.count)）" : "下载", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(GradientButtonStyle())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .sheet(item: $playing) { media in
            MediaPlayerSheet(url: media.url, headers: media.headers, audioURL: media.audioURL, title: result.title)
        }
        .fullScreenCover(isPresented: Binding(get: { viewerIndex != nil }, set: { if !$0 { viewerIndex = nil } })) {
            ImageViewer(medias: result.images, index: viewerIndex ?? 0) { media in
                download(media)
            }
        }
    }

    // MARK: 组件

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            RemoteImage(url: heroImage, headers: heroHeaders)
                .frame(height: 320)
                .frame(maxWidth: .infinity)
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    PlatformLogo(name: result.platform.logo, size: 26)
                    Text(result.platform.displayName).font(.caption.weight(.semibold))
                    if !result.videos.isEmpty { Tag(text: "视频 \(result.videos.count)", color: .white) }
                    if !result.images.isEmpty { Tag(text: "图片 \(result.images.count)", color: .white) }
                }
                Text(result.title.isEmpty ? "无标题" : result.title)
                    .font(.title3.bold())
                    .lineLimit(3)
            }
            .foregroundStyle(.white)
            .padding(16)
        }
        .frame(height: 320)
    }

    private var authorRow: some View {
        HStack(spacing: 12) {
            if !result.avatar.isEmpty {
                RemoteImage(url: result.avatar, headers: heroHeaders)
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 40)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.author.isEmpty ? "未知作者" : result.author).font(.subheadline.weight(.semibold))
                if result.timestamp > 0 {
                    Text(Format.date(result.timestamp)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var description: some View {
        GlassCard(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.text)
                    .font(.subheadline)
                    .lineLimit(expanded ? nil : 4)
                    .textSelection(.enabled)
                Button(expanded ? "收起" : "展开") { withAnimation(.snappy) { expanded.toggle() } }
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "视频")
            ForEach(result.videos) { media in
                GlassCard(padding: 12) {
                    HStack(spacing: 14) {
                        Button { playing = media } label: {
                            ZStack {
                                RemoteImage(url: heroImage, headers: heroHeaders)
                                    .frame(width: 112, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(.white, .black.opacity(0.35))
                            }
                        }
                        .buttonStyle(.plain)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(media.fileName).font(.subheadline.weight(.medium)).lineLimit(2)
                            HStack(spacing: 6) {
                                if !media.quality.isEmpty { Tag(text: media.quality, color: settings.accent.color) }
                                if media.size > 0 { Text(Format.bytes(media.size)).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Spacer(minLength: 0)
                        Button { download(media) } label: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(settings.accent.color)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    Button { UIPasteboard.general.string = media.url } label: { Label("复制直链", systemImage: "link") }
                }
            }
        }
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "图片（\(result.images.count)）")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(Array(result.images.enumerated()), id: \.element.id) { index, media in
                    Button { viewerIndex = index } label: {
                        RemoteImage(url: media.url, headers: media.headers)
                            .aspectRatio(1, contentMode: .fill)
                            .frame(minWidth: 0, maxWidth: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                if !media.motionURL.isEmpty {
                                    Image(systemName: "livephoto")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(5)
                                        .background(.black.opacity(0.35), in: Circle())
                                        .padding(5)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { download(media) } label: { Label("下载这张", systemImage: "arrow.down.circle") }
                        Button { UIPasteboard.general.string = media.url } label: { Label("复制直链", systemImage: "link") }
                    }
                }
            }
        }
    }

    // MARK: 动作

    private func download(_ media: VideoMedia) {
        downloads.enqueue(media, result: result)
        toast.show("已加入下载", .success)
    }

    private func downloadAll() {
        result.medias.forEach { downloads.enqueue($0, result: result) }
        toast.show("已加入下载（\(result.medias.count)）", .success)
    }
}
