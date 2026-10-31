// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 单个视频平台的解析器。
///
/// 约定：失败一律抛 [VideoParseError]；产出的 `VideoMedia.headers` 要带上直链真正需要的 Referer/UA/Cookie。
protocol VideoParser {
    var platform: VideoPlatform { get }
    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult
    /// 保存登录态前的校验：返回昵称（拿不到昵称返回空串），Cookie 无效返回 nil
    func validateCookie(_ cookie: String) async -> String?
}

extension VideoParser {
    func validateCookie(_ cookie: String) async -> String? {
        cookie.trimmed.isEmpty ? nil : ""
    }

    func fileBase(_ title: String, fallback: String) -> String {
        let cleaned = title.sanitizedFileName.prefixString(80)
        return cleaned.isEmpty ? fallback : cleaned
    }
}

/// 视频解析共用的 HTTP 小工具：统一把状态码翻译成 [VideoParseError]、展开短链、抠内嵌 JSON。
enum VideoHTTP {
    static func request(
        _ url: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        followRedirects: Bool = true
    ) async throws -> RawResponse {
        do {
            return try await HTTPClient.shared.send(url, method: method, headers: headers, body: body, followRedirects: followRedirects)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VideoParseError(.network, "请求失败：\(url)")
        }
    }

    static func requireSuccess(_ response: RawResponse, _ what: String) throws {
        if response.isSuccess { return }
        switch response.status {
        case 403, 418, 429: throw VideoParseError(.blocked, "\(what) 被风控拦截（HTTP \(response.status)）")
        case 404, 410: throw VideoParseError(.notFound, "\(what) 不存在（HTTP \(response.status)）")
        default: throw VideoParseError(.unknown, "\(what) 请求失败（HTTP \(response.status)）")
        }
    }

    static func getText(_ url: String, headers: [String: String] = [:], what: String = "解析") async throws -> String {
        let response = try await request(url, headers: headers)
        try requireSuccess(response, what)
        return response.text
    }

    static func getJSON(_ url: String, headers: [String: String] = [:], what: String = "解析") async throws -> JSON {
        let response = try await request(url, headers: headers)
        try requireSuccess(response, what)
        guard let json = try? JSON(data: response.data) else {
            throw VideoParseError(.unknown, "\(what) 返回的不是合法 JSON")
        }
        return json
    }

    static func postForm(_ url: String, form: [(String, String)], headers: [String: String] = [:], what: String = "解析") async throws -> String {
        var merged = headers
        merged["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        let response = try await request(url, method: "POST", headers: merged, body: HTTPClient.formEncode(form))
        try requireSuccess(response, what)
        return response.text
    }

    /// 展开短链：只跟一次重定向；拿不到 Location 返回 nil
    static func expandRedirect(_ url: String, headers: [String: String] = [:]) async throws -> String? {
        let response = try await request(url, headers: headers, followRedirects: false)
        if (300..<400).contains(response.status) {
            guard let location = response.header("Location") else { return nil }
            if location.hasPrefix("http") { return location }
            if let base = URL(string: url), let resolved = URL(string: location, relativeTo: base) {
                return resolved.absoluteString
            }
            return location
        }
        if let final = response.finalURL?.absoluteString, final != url { return final }
        return nil
    }

    /// 从 HTML 里抠出 `window.XXX = {...}</script>` 形式的内嵌 JSON 文本
    static func extractInlineJSON(_ html: String, key: String, stopAt: String = "</script>") -> String? {
        let pattern = RX.escape(key) + #"\s*=\s*(.*?)"# + RX.escape(stopAt)
        guard let value = RX.first(pattern, in: html, options: [.dotMatchesLineSeparators]) else { return nil }
        return value.trimmed.trimmingTrailing(";").trimmed
    }
}

/// 解析入口：识别 → 展开短链 → 分发到平台解析器 → 直链统一升级 https
enum VideoParseService {
    static let parsers: [VideoPlatform: VideoParser] = [
        .douyin: DouyinParser(),
        .kuaishou: KuaishouParser(),
        .weibo: WeiboParser(),
        .acfun: AcFunParser(),
        .bilibili: BilibiliParser(),
    ]

    static func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var resolved = link
        if link.isShortLink { resolved = try await expandShortLink(link) }
        guard let parser = parsers[resolved.platform] else {
            throw VideoParseError(.unsupported, "iOS 版暂未支持解析\(resolved.platform.displayName)，敬请期待")
        }
        var result = try await parser.parse(resolved, cookie: cookie)
        result.medias = result.medias.map { media in
            var copy = media
            copy.url = media.url.secureURL
            copy.audioURL = media.audioURL.secureURL
            copy.motionURL = media.motionURL.secureURL
            return copy
        }
        result.cover = result.cover.secureURL
        result.avatar = result.avatar.secureURL
        return result
    }

    private static func expandShortLink(_ link: DetectedVideoLink) async throws -> DetectedVideoLink {
        var current = link
        let ua = (link.platform == .douyin || link.platform == .kuaishou) ? UserAgent.iPhone : UserAgent.chrome
        for _ in 0..<5 {
            guard let next = try await VideoHTTP.expandRedirect(current.url, headers: ["User-Agent": ua]) else { return current }
            guard let again = VideoLinkParser.parse(next) else {
                return DetectedVideoLink(platform: current.platform, kind: current.kind, id: current.id, url: next)
            }
            if !again.isShortLink { return again }
            current = again
        }
        return current
    }
}
