// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import AVKit
import SwiftUI

// MARK: - 远程图片（逐请求带 Referer / UA，直链不再 403）

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.totalCostLimit = 120 * 1024 * 1024 }

    func image(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func store(_ image: UIImage, _ key: String, cost: Int) { cache.setObject(image, forKey: key as NSString, cost: cost) }
}

struct RemoteImage: View {
    let url: String
    var headers: [String: String] = [:]
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay {
                        if failed {
                            Image(systemName: "photo").foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                        }
                    }
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard !url.isEmpty else { failed = true; return }
        if let cached = ImageCache.shared.image(url) { image = cached; return }
        var h = headers
        if h["User-Agent"] == nil { h["User-Agent"] = UserAgent.iPhone }
        guard let response = try? await HTTPClient.shared.send(url, headers: h, timeout: 30),
              response.isSuccess, let decoded = UIImage(data: response.data) else {
            failed = true
            return
        }
        ImageCache.shared.store(decoded, url, cost: response.data.count)
        withAnimation(.easeOut(duration: 0.2)) { image = decoded }
    }
}

// MARK: - 在线播放

struct MediaPlayerSheet: View {
    let url: String
    let headers: [String: String]
    var audioURL: String = ""
    var title: String = ""
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player).ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .task { await prepare() }
        .onDisappear { player?.pause() }
    }

    /// AVURLAssetHTTPHeaderFieldsKey 让 AVPlayer 的每个请求都带上平台要求的 Referer/Cookie；
    /// B 站分轨用 AVMutableComposition 把两路流式合并，预览也有声音
    private func prepare() async {
        guard let videoURL = URL(string: url) else { return }
        let options = ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let videoAsset = AVURLAsset(url: videoURL, options: options)
        var item = AVPlayerItem(asset: videoAsset)
        if let audio = URL(string: audioURL), !audioURL.isEmpty {
            let audioAsset = AVURLAsset(url: audio, options: options)
            let composition = AVMutableComposition()
            if let v = try? await videoAsset.loadTracks(withMediaType: .video).first,
               let a = try? await audioAsset.loadTracks(withMediaType: .audio).first,
               let duration = try? await videoAsset.load(.duration),
               let vt = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
               let at = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let range = CMTimeRange(start: .zero, duration: duration)
                try? vt.insertTimeRange(range, of: v, at: .zero)
                try? at.insertTimeRange(range, of: a, at: .zero)
                item = AVPlayerItem(asset: composition)
            }
        }
        let player = AVPlayer(playerItem: item)
        self.player = player
        player.play()
    }
}

// MARK: - 图片大图

struct ImageViewer: View {
    let medias: [VideoMedia]
    @State var index: Int
    var onDownload: (VideoMedia) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(medias.enumerated()), id: \.offset) { offset, media in
                    ZoomableImage(media: media).tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: medias.count > 1 ? .automatic : .never))
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("\(index + 1) / \(medias.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onDownload(medias[index])
                    } label: {
                        Label("下载", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
    }
}

private struct ZoomableImage: View {
    let media: VideoMedia
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        RemoteImage(url: media.url, headers: media.headers, contentMode: .fit)
            .scaleEffect(scale)
            .gesture(
                MagnificationGesture()
                    .onChanged { scale = max(1, lastScale * $0) }
                    .onEnded { _ in lastScale = scale }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring()) {
                    scale = scale > 1 ? 1 : 2.5
                    lastScale = scale
                }
            }
    }
}
