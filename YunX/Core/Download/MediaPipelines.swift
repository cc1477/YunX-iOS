// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import AVFoundation
import Foundation
import Photos

/// HLS（m3u8）下载：选最高码率变体 → 顺序下载 TS 分片追加写入同一个文件（.ts）。
///
/// 已下载的分片数由调用方保存，暂停后可从断点继续追加。加密流（AES-128）暂不支持。
enum HLSDownloader {
    struct Playlist {
        let segments: [String]
    }

    static func playlist(url: String, headers: [String: String]) async throws -> Playlist {
        let text = try await HTTPClient.shared.send(url, headers: headers).text
        guard text.contains("#EXTM3U") else { throw ResolveError("不是有效的 m3u8 播放列表") }
        let lines = text.components(separatedBy: .newlines).map(\.trimmed)

        // 主播放列表：挑带宽最高的变体
        if text.contains("#EXT-X-STREAM-INF") {
            var best: (bandwidth: Int, uri: String)?
            for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
                let bandwidth = Int(RX.first(#"BANDWIDTH=(\d+)"#, in: line) ?? "") ?? 0
                guard let uri = lines.dropFirst(index + 1).first(where: { !$0.isEmpty && !$0.hasPrefix("#") }) else { continue }
                if best == nil || bandwidth > best!.bandwidth { best = (bandwidth, uri) }
            }
            guard let best else { throw ResolveError("m3u8 没有可用的变体流") }
            return try await playlist(url: resolve(best.uri, base: url), headers: headers)
        }
        if let key = lines.first(where: { $0.hasPrefix("#EXT-X-KEY") }), !key.contains("METHOD=NONE") {
            throw ResolveError("该视频流已加密，iOS 版暂不支持下载，可在线播放")
        }
        let segments = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }.map { resolve($0, base: url) }
        guard !segments.isEmpty else { throw ResolveError("m3u8 没有分片") }
        return Playlist(segments: segments)
    }

    /// 从第 [startIndex] 个分片开始追加下载；每完成一片回调一次（已完成数, 总数, 累计字节）
    static func download(
        _ playlist: Playlist,
        headers: [String: String],
        to destination: URL,
        startIndex: Int,
        progress: (Int, Int, Int64) async -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if startIndex == 0 || !fm.fileExists(atPath: destination.path) {
            fm.createFile(atPath: destination.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var written = Int64((try? fm.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0)
        let start = min(startIndex, playlist.segments.count)
        for index in start..<playlist.segments.count {
            try Task.checkCancellation()
            var lastError: Error?
            var data: Data?
            for _ in 0..<3 {
                do {
                    let response = try await HTTPClient.shared.send(playlist.segments[index], headers: headers, timeout: 30)
                    guard response.isSuccess else { throw HTTPError.network("分片 HTTP \(response.status)") }
                    data = response.data
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                }
            }
            guard let data else { throw lastError ?? HTTPError.network("分片下载失败") }
            try handle.write(contentsOf: data)
            written += Int64(data.count)
            await progress(index + 1, playlist.segments.count, written)
        }
    }

    private static func resolve(_ uri: String, base: String) -> String {
        if uri.hasPrefix("http") { return uri }
        return URL(string: uri, relativeTo: URL(string: base))?.absoluteString ?? uri
    }
}

/// 哔哩哔哩 DASH 合轨：AVMutableComposition 把视频轨 + 音轨直通（不重编码）导出为 mp4。
enum DashMuxer {
    static func mux(video: URL, audio: URL, output: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let sourceVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
              let sourceAudio = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw ResolveError("合轨失败：分轨文件缺少音频或视频轨")
        }
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let duration = CMTimeMinimum(videoDuration, audioDuration)
        let range = CMTimeRange(start: .zero, duration: duration)

        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ResolveError("合轨失败：无法创建轨道")
        }
        try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
        try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ResolveError("合轨失败：无法创建导出会话")
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        if export.status != .completed {
            throw ResolveError("合轨失败：\(export.error?.localizedDescription ?? "未知错误")")
        }
    }
}

/// 存入相册
enum PhotoSaver {
    static func save(_ url: URL, kind: FileKind) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ResolveError("未获得相册写入权限，可在系统设置中开启") }
        try await PHPhotoLibrary.shared().performChanges {
            if kind == .video {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
        }
    }
}
