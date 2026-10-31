// YunX Flutter —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import AVFoundation
import Flutter

/// 哔哩哔哩 DASH 合轨：AVMutableComposition 把视频轨 + 音轨直通（不重编码）导出为 mp4
public class YunxMediaPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "yunx/media", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(YunxMediaPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "mux",
              let args = call.arguments as? [String: Any],
              let video = args["video"] as? String,
              let audio = args["audio"] as? String,
              let output = args["output"] as? String else {
            result(FlutterMethodNotImplemented)
            return
        }
        Self.mux(video: URL(fileURLWithPath: video), audio: URL(fileURLWithPath: audio), output: URL(fileURLWithPath: output)) { error in
            DispatchQueue.main.async {
                if let error {
                    result(FlutterError(code: "mux_failed", message: error, details: nil))
                } else {
                    result(nil)
                }
            }
        }
    }

    private static func mux(video: URL, audio: URL, output: URL, done: @escaping (String?) -> Void) {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        guard let sourceVideo = videoAsset.tracks(withMediaType: .video).first,
              let sourceAudio = audioAsset.tracks(withMediaType: .audio).first else {
            done("分轨文件缺少音频或视频轨")
            return
        }
        let duration = CMTimeMinimum(videoAsset.duration, audioAsset.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            done("无法创建轨道")
            return
        }
        do {
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)
            try audioTrack.insertTimeRange(range, of: sourceAudio, at: .zero)
        } catch {
            done(error.localizedDescription)
            return
        }
        videoTrack.preferredTransform = sourceVideo.preferredTransform
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            done("无法创建导出会话")
            return
        }
        try? FileManager.default.removeItem(at: output)
        export.outputURL = output
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.exportAsynchronously {
            done(export.status == .completed ? nil : (export.error?.localizedDescription ?? "导出失败"))
        }
    }
}
