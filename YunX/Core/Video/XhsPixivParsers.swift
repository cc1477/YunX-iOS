// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

// MARK: - 小红书

/// 小红书：网页端笔记页对未登录会话一律拦截，必须带 web_session。
/// 先试 explore 页（桌面 UA），失败再试 discovery 页（移动 UA）；图片尽量换成去水印原图，探测不到时回退平台地址。
struct XhsParser: VideoParser {
    let platform = VideoPlatform.xhs

    private let home = "https://www.xiaohongshu.com"
    private let imageCDN = "https://sns-img-bd.xhscdn.com"
    private let accept = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"
    private let loginMarkers = ["/login", "website-login", "captcha"]

    private func media(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": UserAgent.chrome, "Referer": "\(home)/"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    func validateCookie(_ cookie: String) async -> String? {
        guard !cookie.isEmpty,
              let r = try? await VideoHTTP.request("\(home)/explore", headers: ["User-Agent": UserAgent.chrome, "accept": accept, "Cookie": cookie])
        else { return nil }
        let final = r.finalURL?.absoluteString ?? ""
        return loginMarkers.contains(where: { final.contains($0) }) ? nil : ""
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        guard !cookie.isEmpty else {
            throw VideoParseError(.unsupported, "小红书要求登录后才能查看笔记，请先到「账号」页登录小红书")
        }
        let query = link.url.contains("?") ? "?" + (link.url.split(separator: "?", maxSplits: 1).last.map(String.init) ?? "") : ""
        var exploreError: Error?
        do {
            var h = media(cookie)
            h["accept"] = accept
            let state = try await initialState("\(home)/explore/\(link.id)\(query)", headers: h)
            let note = state["note"]["noteDetailMap"][link.id]["note"]
            if note.isObject { return try await build(note, link: link, cookie: cookie, authorKey: "nickname") }
            exploreError = VideoParseError(.notFound, "小红书页面里没有该笔记数据")
        } catch let error as VideoParseError where error.kind == .unsupported {
            throw error
        } catch {
            exploreError = error
        }
        var h = media(cookie)
        h["User-Agent"] = UserAgent.iPhone
        h["accept"] = accept
        h["origin"] = home
        let state = try await initialState("\(home)/discovery/item/\(link.id)\(query)", headers: h)
        let note = state["noteData"]["data"]["noteData"]
        guard note.isObject else { throw exploreError ?? VideoParseError(.notFound, "小红书分享链接失效或内容已删除") }
        return try await build(note, link: link, cookie: cookie, authorKey: "nickName")
    }

    private func initialState(_ url: String, headers: [String: String]) async throws -> JSON {
        let r = try await VideoHTTP.request(url, headers: headers)
        try VideoHTTP.requireSuccess(r, "小红书笔记")
        let final = r.finalURL?.absoluteString ?? ""
        if loginMarkers.contains(where: { final.contains($0) }) {
            throw VideoParseError(.unsupported, "小红书登录已失效或被风控，请到「账号」页重新登录小红书")
        }
        guard let raw = VideoHTTP.extractInlineJSON(r.text, key: "window.__INITIAL_STATE__"),
              let json = JSON(text: raw.replacingOccurrences(of: "undefined", with: "null")) else {
            throw VideoParseError(.unknown, "小红书页面里没有笔记数据（可能被风控拦截或页面改版）")
        }
        return json
    }

    private func build(_ note: JSON, link: DetectedVideoLink, cookie: String, authorKey: String) async throws -> VideoParseResult {
        let headers = media(cookie)
        let title = note["title"].string
        let base = fileBase(title, fallback: "小红书_\(link.id)")
        let raw = note["imageList"].array.map { $0.string("urlDefault", "url") }.filter { !$0.isEmpty }
        var medias: [VideoMedia] = []
        var cover = ""
        var notice = ""
        let stream = note["video"]["media"]["stream"]
        var video: (String, String)?
        for (key, label) in [("h265", "H.265"), ("h264", "H.264"), ("av1", "AV1"), ("h266", "H.266")] {
            let url = stream[key][0].string("masterUrl", "master_url")
            if !url.isEmpty { video = (url, label); break }
        }
        if let video {
            cover = clean(raw.first ?? "")
            medias.append(VideoMedia(url: video.0, kind: .video, fileName: "\(base).mp4", headers: headers, quality: video.1))
        } else if note["video"].isObject {
            throw VideoParseError(.unknown, "小红书视频笔记没有取到视频直链")
        } else {
            let resolved = await resolveImages(raw, headers: headers)
            for (index, url) in resolved.urls.enumerated() {
                medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(index + 1).jpg", headers: headers, quality: "原图"))
            }
            if resolved.fallback > 0 { notice = "\(resolved.fallback) 张图片没有可用的去水印原图，已改用平台地址（可能带水印）" }
            cover = resolved.urls.first ?? ""
        }
        return VideoParseResult(
            platform: platform, title: title, author: note["user"][authorKey].string, avatar: note["user"]["avatar"].string,
            cover: cover, text: note["desc"].string, timestamp: note["time"].int64 / 1000, url: link.url,
            medias: medias, notice: notice
        )
    }

    /// 去水印原图：取图片 id（路径第 3 段起，去掉 ! 之后的样式）拼到原图 CDN
    private func clean(_ raw: String) -> String {
        guard let range = raw.range(of: "://") else { return raw }
        let path = raw[range.upperBound...].split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        let id = path.dropFirst(2).joined(separator: "/").split(separator: "!", maxSplits: 1).first.map(String.init) ?? ""
        return id.isEmpty ? raw : "\(imageCDN)/\(id)"
    }

    private func resolveImages(_ raw: [String], headers: [String: String]) async -> (urls: [String], fallback: Int) {
        await withTaskGroup(of: (Int, String, Bool).self) { group in
            for (index, url) in raw.enumerated() {
                group.addTask {
                    let cleaned = clean(url)
                    if cleaned == url { return (index, url, false) }
                    let status = (try? await VideoHTTP.request(cleaned, method: "HEAD", headers: headers))?.status ?? 200
                    return [404, 410].contains(status) ? (index, url, true) : (index, cleaned, false)
                }
            }
            var results = Array(repeating: "", count: raw.count)
            var fallback = 0
            for await (index, url, missing) in group {
                results[index] = url
                if missing { fallback += 1 }
            }
            return (results, fallback)
        }
    }
}

// MARK: - Pixiv

/// Pixiv：ajax/illust 取作品信息 + pages 取每一页原图；R18 / 受限作品需要粘贴浏览器 Cookie（PHPSESSID）。
struct PixivParser: VideoParser {
    let platform = VideoPlatform.pixiv

    private func headers(_ cookie: String, json: Bool) -> [String: String] {
        var h = ["User-Agent": UserAgent.chrome, "Referer": "https://www.pixiv.net/"]
        if json { h["Accept"] = "application/json" }
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    func validateCookie(_ cookie: String) async -> String? {
        guard !cookie.isEmpty else { return nil }
        guard let r = try? await VideoHTTP.request("https://www.pixiv.net/dashboard/works", headers: headers(cookie, json: true), followRedirects: false),
              (300..<400).contains(r.status) else { return "" }
        let location = r.header("Location") ?? ""
        return location.contains("return_to=") || location.contains("/login") || location.contains("accounts.pixiv.net") ? nil : ""
    }

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let info = try await VideoHTTP.getJSON("https://www.pixiv.net/ajax/illust/\(link.id)", headers: headers(cookie, json: true), what: "Pixiv 作品信息")
        if info["error"].bool {
            let message = info["message"].string
            let lower = message.lowercased()
            if lower.contains("not found") { throw VideoParseError(.notFound, message) }
            if lower.contains("login") || lower.contains("session") || cookie.isEmpty {
                throw VideoParseError(.unsupported, cookie.isEmpty
                    ? "该作品需要登录后才能解析（多为 R18 或受限作品），请在「账号」页粘贴浏览器里的 Cookie"
                    : "Pixiv 登录态已失效，请到「账号」页重新粘贴 Cookie")
            }
            throw VideoParseError(.blocked, "Pixiv 作品信息返回错误：\(message)")
        }
        let body = info["body"]
        if body["illustType"].int == 2 { throw VideoParseError(.unsupported, "Pixiv 动图（ugoira）需要合成 GIF，当前版本暂不支持") }
        let title = body["title"].string
        let base = fileBase(title, fallback: "pixiv_\(link.id)")
        let pages = (try? await VideoHTTP.getJSON("https://www.pixiv.net/ajax/illust/\(link.id)/pages", headers: headers(cookie, json: true), what: "Pixiv 原图列表"))?["body"].array ?? []
        var urls = pages.map { $0["urls"]["original"].string }.filter { !$0.isEmpty }
        if urls.isEmpty, !body["urls"]["original"].string.isEmpty { urls = [body["urls"]["original"].string] }
        guard !urls.isEmpty else { throw VideoParseError(.notFound, "Pixiv 未返回任何可下载的原图") }
        let medias = urls.enumerated().map { index, url -> VideoMedia in
            let ext = (url.split(separator: "?").first.map(String.init) ?? url).split(separator: ".").last.map(String.init)?.lowercased() ?? "jpg"
            let name = urls.count == 1 ? "\(base).\(ext.count <= 4 ? ext : "jpg")" : "\(base)_\(index + 1).\(ext.count <= 4 ? ext : "jpg")"
            return VideoMedia(url: url, kind: .image, fileName: name, headers: headers(cookie, json: false), quality: "原图")
        }
        let formatter = ISO8601DateFormatter()
        return VideoParseResult(
            platform: platform, title: title, author: body["userName"].string, cover: urls[0],
            text: WeiboParser.cleanHTML(body["description"].string),
            timestamp: Int64(formatter.date(from: body["createDate"].string)?.timeIntervalSince1970 ?? 0),
            url: "https://www.pixiv.net/artworks/\(link.id)", medias: medias
        )
    }
}
