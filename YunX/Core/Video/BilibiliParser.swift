// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 哔哩哔哩：已登录优先取 DASH 高清（音视频分轨，下载后由 DashMuxer 用 AVFoundation 合轨），
/// 否则退回 `fnval=1` 的单文件低清直链。
struct BilibiliParser: VideoParser {
    let platform = VideoPlatform.bilibili

    private let viewURL = "https://api.bilibili.com/x/web-interface/view"
    private let playURL = "https://api.bilibili.com/x/player/playurl"
    private let navURL = "https://api.bilibili.com/x/web-interface/nav"

    /// Referer 必须是 bilibili.com，CDN（upos-*.bilivideo.com）缺了直接 403
    private func headers(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": UserAgent.chrome, "Referer": "https://www.bilibili.com/"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    func validateCookie(_ cookie: String) async -> String? {
        guard !cookie.isEmpty,
              let json = try? await VideoHTTP.getJSON(navURL, headers: headers(cookie), what: "B站登录态校验"),
              json["data"]["isLogin"].bool
        else { return nil }
        return json["data"]["uname"].string
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let query = link.id.lowercased().hasPrefix("bv") ? "bvid=\(link.id)" : "aid=\(link.id.replacingOccurrences(of: "av", with: ""))"
        let view = try await VideoHTTP.getJSON("\(viewURL)?\(query)", headers: headers(cookie), what: "B站视频信息")
        guard view["code"].int == 0 else {
            throw VideoParseError(.notFound, "B站视频信息接口返回 code=\(view["code"].int) \(view["message"].string)")
        }
        let data = view["data"]
        let bvid = data["bvid"].string
        var cid = data["pages"][0]["cid"].int64
        if cid <= 0 { cid = data["cid"].int64 }
        guard !bvid.isEmpty, cid > 0 else { throw VideoParseError(.unknown, "B站视频信息缺少 bvid/cid") }

        let base = fileBase(data["title"].string, fallback: "bilibili_\(bvid)")

        // ① 已登录才试 DASH：匿名拿到的 DASH 往往也是最低清，不值得走更长的合轨链路
        if !cookie.isEmpty, let dash = await dashStream(bvid: bvid, cid: cid, cookie: cookie) {
            let media = VideoMedia(
                url: dash.video, kind: .video, fileName: "\(base).mp4",
                headers: headers(cookie), quality: "\(qualityLabel(dash.quality)) · 分轨",
                audioURL: dash.audio, audioHeaders: headers(cookie)
            )
            return result(data, bvid: bvid, media: media)
        }

        // ② 单文件 durl
        let play = try await VideoHTTP.getJSON(
            "\(playURL)?bvid=\(bvid)&cid=\(cid)&qn=80&fnval=1&fnver=0&fourk=1&platform=html5&high_quality=1",
            headers: headers(cookie), what: "B站取直链"
        )
        let first = play["data"]["durl"][0]
        guard first.exists else {
            throw VideoParseError(.unsupported, "B站未返回可下载的直链：该视频可能是番剧或付费内容")
        }
        let url = first["url"].string
        guard !url.isEmpty else { throw VideoParseError(.blocked, "B站直链为空（可能需要登录或已被风控）") }
        let media = VideoMedia(
            url: url.secureURL, kind: .video, fileName: "\(base).mp4",
            size: first["size"].int64, headers: headers(cookie),
            quality: qualityLabel(play["data"]["quality"].int)
        )
        return result(data, bvid: bvid, media: media)
    }

    private func result(_ data: JSON, bvid: String, media: VideoMedia) -> VideoParseResult {
        VideoParseResult(
            platform: platform,
            title: data["title"].string,
            author: data["owner"]["name"].string,
            avatar: data["owner"]["face"].string.secureURL,
            cover: data["pic"].string.secureURL,
            text: data["desc"].string,
            timestamp: data["pubdate"].int64,
            url: "https://www.bilibili.com/video/\(bvid)",
            medias: [media]
        )
    }

    private struct Dash { let video: String; let audio: String; let quality: Int }

    /// 视频轨取清晰度最高、音轨取码率最高；任何一步不对返回 nil，由调用方退回单文件
    private func dashStream(bvid: String, cid: Int64, cookie: String) async -> Dash? {
        guard let json = try? await VideoHTTP.getJSON(
            "\(playURL)?bvid=\(bvid)&cid=\(cid)&qn=120&fnval=4048&fnver=0&fourk=1",
            headers: headers(cookie), what: "B站取 DASH 直链"
        ) else { return nil }
        let dash = json["data"]["dash"]
        guard let video = dash["video"].array.max(by: { $0["id"].int < $1["id"].int }),
              let audio = dash["audio"].array.max(by: { $0["id"].int < $1["id"].int })
        else { return nil }
        let videoURL = video.string("baseUrl", "base_url")
        let audioURL = audio.string("baseUrl", "base_url")
        guard !videoURL.isEmpty, !audioURL.isEmpty else { return nil }
        return Dash(video: videoURL.secureURL, audio: audioURL.secureURL, quality: video["id"].int)
    }

    private func qualityLabel(_ qn: Int) -> String {
        switch qn {
        case 6, 7: return "240P"
        case 16: return "360P"
        case 32: return "480P"
        case 64: return "720P"
        case 74: return "720P60"
        case 80: return "1080P"
        case 112: return "1080P+"
        case 116: return "1080P60"
        case 120: return "4K"
        case 125: return "HDR"
        case 126: return "杜比视界"
        default: return qn > 0 ? "画质 \(qn)" : ""
        }
    }
}
