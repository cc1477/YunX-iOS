// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

// MARK: - 快手

/// 快手：读作品页 SSR 的 `window.INIT_STATE`（视频取 mainMvUrls，图集取 atlas cdn + list）。
struct KuaishouParser: VideoParser {
    let platform = VideoPlatform.kuaishou

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var headers = ["User-Agent": UserAgent.iPhone, "Referer": "https://v.kuaishou.com/"]
        if !cookie.isEmpty { headers["Cookie"] = cookie }

        var pageURL = link.url
        if let expanded = try? await VideoHTTP.expandRedirect(pageURL, headers: headers), !expanded.isEmpty {
            pageURL = expanded
        }
        pageURL = pageURL.replacingOccurrences(of: "/fw/long-video/", with: "/fw/photo/")

        let html = try await VideoHTTP.getText(pageURL, headers: headers, what: "快手作品页")
        guard let raw = VideoHTTP.extractInlineJSON(html, key: "window.INIT_STATE"), let state = JSON(text: raw) else {
            throw VideoParseError(.unknown, "快手页面里没有 window.INIT_STATE（作品可能已删除或页面改版）")
        }
        guard let photo = state.keys.lazy.map({ state[$0]["photo"] }).first(where: { $0.isObject }) else {
            throw VideoParseError(.unknown, "快手页面里没有作品数据")
        }

        let title = photo["caption"].string
        let base = fileBase(title, fallback: "kuaishou_\(link.id.isEmpty ? String(Int(Date().timeIntervalSince1970)) : link.id)")
        var medias: [VideoMedia] = []
        if let video = photo["mainMvUrls"].array.map({ $0["url"].string }).first(where: { !$0.isEmpty }) {
            medias.append(VideoMedia(url: video, kind: .video, fileName: "\(base).mp4", headers: headers))
        }
        let atlas = photo["ext_params"]["atlas"]
        let cdn = atlas["cdnList"][0]["cdn"].string
        if !cdn.isEmpty {
            for (index, route) in atlas["list"].array.map(\.string).filter({ !$0.isEmpty }).enumerated() {
                medias.append(VideoMedia(url: "https://\(cdn)/\(route)", kind: .image, fileName: "\(base)_\(index + 1).jpg", headers: headers))
            }
        }
        return VideoParseResult(
            platform: platform,
            title: title,
            author: photo["userName"].string.replacingOccurrences(of: "\u{3164}", with: "").trimmed,
            avatar: photo["headUrl"].string,
            cover: photo["coverUrls"].array.map({ $0["url"].string }).first(where: { !$0.isEmpty }) ?? "",
            timestamp: photo["timestamp"].int64 / 1000,
            url: link.url,
            medias: medias
        )
    }
}

// MARK: - AcFun

/// AcFun：页面内嵌 `window.videoInfo`，取 ksPlayJson 里的 m3u8（走 HLS 下载路径）。
struct AcFunParser: VideoParser {
    let platform = VideoPlatform.acfun

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var headers = ["User-Agent": UserAgent.chrome, "Referer": "https://www.acfun.cn/"]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let html = try await VideoHTTP.getText(
            "https://www.acfun.cn/v/ac\(link.id)?quickViewId=videoInfo_new&ajaxpipe=1",
            headers: headers, what: "AcFun 视频"
        )
        guard let raw = VideoHTTP.extractInlineJSON(html, key: "window.videoInfo") else {
            throw VideoParseError(.notFound, "AcFun 视频信息解析失败（页面里没有 videoInfo，可能已删除）")
        }
        // 内嵌 JSON 被转义了一层，按安卓版同样的方式手工还原
        let text = raw.replacingOccurrences(of: #"\\""#, with: #"\""#)
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\\/"#, with: "/")
        guard let info = JSON(text: text) else { throw VideoParseError(.unknown, "AcFun 视频信息解析失败") }

        let current = info["currentVideoInfo"]
        var play = current["ksPlayJson"]
        if !play.isObject { play = JSON(text: play.string) ?? JSON(nil) }
        let urls = play["adaptationSet"][0]["representation"].array.map { $0["url"].string }.filter { !$0.isEmpty }
        guard let m3u8 = urls.count > 3 ? urls[3] : urls.first else {
            throw VideoParseError(.unknown, "AcFun 未取到视频流地址")
        }
        let title = info["title"].string
        return VideoParseResult(
            platform: platform,
            title: title,
            author: info["user"]["name"].string,
            cover: info["coverUrl"].string,
            text: info["description"].string,
            url: link.url,
            medias: [VideoMedia(
                url: m3u8, kind: .video, fileName: "\(fileBase(title, fallback: "AcFun_\(link.id)")).ts",
                isHLS: true, headers: headers, quality: "HLS"
            )]
        )
    }
}

// MARK: - 微博

/// 微博：m 站 statuses/show JSON（视频 + 图集 + 动图）；视频号 fid 走 h5.video 组件接口。
struct WeiboParser: VideoParser {
    let platform = VideoPlatform.weibo

    private func mediaHeaders(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": UserAgent.chrome, "Referer": "https://weibo.com/"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        switch link.kind {
        case "status": return try await parseStatus(link, id: link.id, cookie: cookie)
        case "tv": return try await parseStatus(link, id: Self.mid2id(link.id), cookie: cookie)
        case "fid": return try await parseFid(link, cookie: cookie)
        default: throw VideoParseError(.unsupported, "不支持的微博链接形态")
        }
    }

    private func parseStatus(_ link: DetectedVideoLink, id: String, cookie: String) async throws -> VideoParseResult {
        var headers = [
            "accept": "application/json, text/plain, */*",
            "referer": "https://m.weibo.cn/detail/\(id)",
            "origin": "https://m.weibo.cn",
            "x-requested-with": "XMLHttpRequest",
            "mweibo-pwa": "1",
            "User-Agent": UserAgent.chrome,
        ]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let response = try await VideoHTTP.request("https://m.weibo.cn/statuses/show?id=\(id)&_=\(ts)", headers: headers, followRedirects: false)
        switch response.status {
        case 200: break
        case 403, 418, 429: throw VideoParseError(.blocked, "微博被风控拦截")
        case 404, 410: throw VideoParseError(.notFound, "微博内容不存在或已删除")
        default: throw VideoParseError(.unknown, "微博数据获取失败（HTTP \(response.status)）")
        }
        guard (response.header("content-type") ?? "").contains("application/json") else {
            throw VideoParseError(.blocked, "微博接口返回的不是 JSON，多半被风控拦截")
        }
        guard let json = try? JSON(data: response.data), json["data"].isObject else {
            throw VideoParseError(.notFound, "微博内容不存在或已删除")
        }
        return build(link, data: json["data"], cookie: cookie, allowRetweet: true)
    }

    private func build(_ link: DetectedVideoLink, data: JSON, cookie: String, allowRetweet: Bool) -> VideoParseResult {
        let headers = mediaHeaders(cookie)
        let pageInfo = data["page_info"]
        let title = pageInfo["title"].string
        let base = fileBase(title, fallback: "微博_\(link.id)")
        var medias: [VideoMedia] = []

        let urls = pageInfo["urls"]
        let video = [urls["mp4_720p_mp4"].string, urls["mp4_hd_mp4"].string, urls["mp4_ld_mp4"].string].first { !$0.isEmpty }
        if let video {
            medias.append(VideoMedia(url: video.secureURL, kind: .video, fileName: "\(base).mp4", headers: headers))
        }
        var imageIndex = 0
        for pic in data["pics"].array {
            let url = pic["large"]["url"].string
            guard !url.isEmpty else { continue }
            imageIndex += 1
            let motion = pic["videoSrc"].string
            medias.append(VideoMedia(
                url: url, kind: .image, fileName: "\(base)_\(imageIndex).jpg", headers: headers,
                quality: motion.isEmpty ? "原图" : "动图", motionURL: motion
            ))
        }
        if medias.isEmpty, allowRetweet, data["retweeted_status"].isObject {
            return build(link, data: data["retweeted_status"], cookie: cookie, allowRetweet: false)
        }
        let user = data["user"]
        let bid = data["bid"].string
        let uid = user["id"].int64
        return VideoParseResult(
            platform: platform,
            title: title,
            author: user["screen_name"].string,
            avatar: user["profile_image_url"].string,
            cover: pageInfo["page_pic"]["url"].string,
            text: Self.cleanHTML(data["text"].string),
            timestamp: Self.parseWeiboTime(data["created_at"].string),
            url: uid > 0 && !bid.isEmpty ? "https://weibo.com/\(uid)/\(bid)" : link.url,
            medias: medias
        )
    }

    private func parseFid(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var headers = ["Referer": "https://h5.video.weibo.com/show/\(link.id)", "User-Agent": UserAgent.chrome]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let text = try await VideoHTTP.postForm(
            "https://h5.video.weibo.com/api/component?page=/show/\(link.id)",
            form: [("data", #"{"Component_Play_Playinfo":{"oid":"\#(link.id)"}}"#)],
            headers: headers, what: "微博视频"
        )
        guard let json = JSON(text: text), json["data"]["Component_Play_Playinfo"].isObject else {
            throw VideoParseError(.notFound, "微博视频数据为空（作品可能已删除）")
        }
        let data = json["data"]["Component_Play_Playinfo"]
        let title = data["title"].string
        let urls = data["urls"]
        // JSONSerialization 不保序：按键名排序后取第一个（键名形如「高清 1080P」）
        let firstKey = urls.keys.sorted().first
        let video = (firstKey.map { urls[$0].string } ?? data["stream_url"].string).secureURL
        var medias: [VideoMedia] = []
        if !video.isEmpty {
            medias.append(VideoMedia(url: video, kind: .video, fileName: "\(fileBase(title, fallback: "微博_\(link.id)")).mp4", headers: mediaHeaders(cookie)))
        }
        return VideoParseResult(
            platform: platform,
            title: title,
            author: data["reward"]["user"]["name"].string,
            avatar: data["reward"]["user"]["profile_image_url"].string,
            cover: data["cover_image"].string.secureURL,
            text: Self.cleanHTML(data["text"].string),
            url: link.url,
            medias: medias
        )
    }

    static func cleanHTML(_ raw: String) -> String {
        let withBreaks = raw.replacingOccurrences(of: "<br />", with: "\n")
        guard let regex = RX.regex("<[^>]*>", []) else { return withBreaks }
        let ns = withBreaks as NSString
        return regex.stringByReplacingMatches(in: withBreaks, range: NSRange(location: 0, length: ns.length), withTemplate: "").trimmed
    }

    static func parseWeiboTime(_ text: String) -> Int64 {
        guard !text.isEmpty else { return 0 }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return Int64(formatter.date(from: text)?.timeIntervalSince1970 ?? 0)
    }

    private static func base62(_ number: Int64) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        if number == 0 { return "0" }
        var value = number
        var result = ""
        while value > 0 {
            result.insert(alphabet[Int(value % 62)], at: result.startIndex)
            value /= 62
        }
        return result
    }

    /// 微博 mid（纯数字）→ 62 进制 id：倒序每 7 位一段分别编码
    static func mid2id(_ mid: String) -> String {
        let reversed = Array(mid.reversed())
        guard !reversed.isEmpty else { return "" }
        let size = (reversed.count + 6) / 7
        var chunks: [String] = []
        for i in 0..<size {
            let end = min((i + 1) * 7, reversed.count)
            let piece = String(reversed[(i * 7)..<end].reversed())
            var encoded = base62(Int64(piece) ?? 0)
            if i < size - 1 && encoded.count < 4 {
                encoded = String(repeating: "0", count: 4 - encoded.count) + encoded
            }
            chunks.append(encoded)
        }
        return chunks.reversed().joined()
    }
}
