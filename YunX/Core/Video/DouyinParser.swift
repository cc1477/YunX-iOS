// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 抖音：
/// 1. 先走 SSR：注册 ttwid → 读 iesdouyin 分享页的 `window._ROUTER_DATA` → 视频再探测 aweme play 接口的最高清晰度；
/// 2. SSR 拿不到（风控 / 图集为空）时，用无界面 WKWebView 打开网页版，拦截 aweme/detail 响应兜底。
struct DouyinParser: VideoParser {
    let platform = VideoPlatform.douyin

    private let referer = "https://www.iesdouyin.com/"
    private let ratios = ["1080p", "720p", "540p", "360p"]

    func parse(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        var ssrError: Error?
        do {
            let result = try await parseSSR(link, cookie: cookie)
            if !result.medias.isEmpty { return result }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            ssrError = error
        }
        if let result = await parseWebView(link) { return result }
        throw ssrError ?? VideoParseError(.unknown, "抖音没有返回该作品的媒体地址")
    }

    // MARK: SSR

    private func pathType(_ link: DetectedVideoLink) -> String {
        RX.first(#"/(?:share/)?(video|note|slides)/"#, in: link.url) == "note" ? "note" : "video"
    }

    private func parseSSR(_ link: DetectedVideoLink, cookie: String) async throws -> VideoParseResult {
        let shareURL = "https://www.iesdouyin.com/share/\(pathType(link))/\(link.id)/"
        let ttwid = try await TtwidCache.shared.get()
        let html = try await VideoHTTP.getText(shareURL, headers: [
            "User-Agent": UserAgent.iPhone,
            "Referer": referer,
            "Cookie": cookie.isEmpty ? ttwid : "\(ttwid); \(cookie)",
        ], what: "抖音分享页")
        guard let raw = VideoHTTP.extractInlineJSON(html, key: "window._ROUTER_DATA"), let router = JSON(text: raw) else {
            await TtwidCache.shared.reset()
            throw VideoParseError(.unknown, "抖音分享页里没有作品数据（作品可能已删除或页面改版）")
        }
        let loader = router["loaderData"]
        let page = loader["video_(id)/page"].isObject ? loader["video_(id)/page"] : loader["note_(id)/page"]
        let item = page.first("videoInfoRes", "video_info_res").first("item_list", "itemList")[0]
        guard item.isObject else {
            throw VideoParseError(.unknown, "抖音没有返回该作品的数据（作品可能已删除、不可见或被风控）")
        }

        let mediaHeaders = ["User-Agent": UserAgent.iPhone, "Referer": shareURL]
        let title = item.string("desc")
        let base = fileBase(title, fallback: "douyin_\(link.id)")
        var medias: [VideoMedia] = []
        var cover = ""

        let images = item["images"].array
        if !images.isEmpty {
            for (index, image) in images.enumerated() {
                guard let url = firstURL(image) else { continue }
                if cover.isEmpty { cover = url }
                medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(index + 1).jpg",
                                         headers: mediaHeaders, quality: "原图"))
            }
        } else if item["video"].isObject {
            let video = item["video"]
            cover = firstURL(video["cover"]) ?? ""
            let playAddr = video.first("play_addr", "playAddr")
            if let resolved = await resolveVideo(playAddr, headers: mediaHeaders) {
                medias.append(VideoMedia(url: resolved.url, kind: .video, fileName: "\(base).mp4",
                                         size: resolved.size, headers: mediaHeaders))
            }
        }
        let author = item["author"]
        return VideoParseResult(
            platform: platform,
            title: title,
            author: author.string("nickname"),
            avatar: firstURL(author.first("avatar_thumb", "avatar_medium")) ?? "",
            cover: cover,
            timestamp: item.first("create_time", "createTime").int64,
            url: link.url,
            medias: medias
        )
    }

    private func firstURL(_ node: JSON) -> String? {
        node.first("url_list", "urlList").array.map(\.string).first { !$0.isEmpty }
    }

    /// 用 video_id 逐档探测 play 接口，取体积最大（= 清晰度最高）的一档；都失败退回去水印的 playwm 地址
    private func resolveVideo(_ playAddr: JSON, headers: [String: String]) async -> (url: String, size: Int64)? {
        var token = playAddr["uri"].string
        if token.isEmpty {
            token = playAddr.first("url_list", "urlList").array
                .compactMap { RX.first(#"[?&]video_id=([^&\s]+)"#, in: $0.string) }
                .first ?? ""
        }
        if !token.isEmpty {
            var best: (url: String, size: Int64)?
            for ratio in ratios {
                let url = "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(token)&ratio=\(ratio)"
                var probeHeaders = headers
                probeHeaders["Range"] = "bytes=0-1"
                guard let response = try? await VideoHTTP.request(url, headers: probeHeaders), response.isSuccess else { continue }
                var size: Int64 = 0
                if let range = response.header("Content-Range"), let total = RX.first(#"/(\d+)\s*$"#, in: range) {
                    size = Int64(total) ?? 0
                } else {
                    size = Int64(response.header("Content-Length") ?? "") ?? 0
                }
                guard size > 0 else { continue }
                let finalURL = response.finalURL?.absoluteString ?? url
                if best == nil || size > best!.size { best = (finalURL, size) }
            }
            if let best { return best }
        }
        guard let fallback = firstURL(playAddr)?.replacingOccurrences(of: "playwm", with: "play") else { return nil }
        return (fallback, -1)
    }

    // MARK: WebView 兜底

    @MainActor
    private func extractWithWebView(_ url: String) async -> String? {
        await HeadlessWebView.loadAndExtract(
            url: url, userAgent: UserAgent.chrome,
            readyCheckJS: Self.readyCheckJS, extractJS: Self.extractJS,
            documentStartJS: [Self.xhrHookJS], timeout: 30
        )
    }

    private func parseWebView(_ link: DetectedVideoLink) async -> VideoParseResult? {
        let pageURL = "https://www.douyin.com/\(pathType(link))/\(link.id)"
        guard let text = await extractWithWebView(pageURL), let payload = JSON(text: text), payload["error"].string.isEmpty else {
            return nil
        }
        let images = payload["images"].array.map(\.string).filter { !$0.isEmpty }
        let motions = payload["motions"].array.map(\.string)
        let video = payload["video"].string
        guard !images.isEmpty || !video.isEmpty else { return nil }

        let headers = ["User-Agent": UserAgent.iPhone, "Referer": "https://www.douyin.com/"]
        let title = payload["title"].string
        let base = fileBase(title, fallback: "douyin_\(link.id)")
        var medias: [VideoMedia] = []
        if !images.isEmpty {
            for (index, url) in images.enumerated() {
                let motion = index < motions.count ? motions[index] : ""
                medias.append(VideoMedia(url: url, kind: .image, fileName: "\(base)_\(index + 1).jpg", headers: headers,
                                         quality: motion.isEmpty ? "" : "动图", motionURL: motion))
            }
        } else {
            medias.append(VideoMedia(url: video, kind: .video, fileName: "\(base).mp4", headers: headers))
        }
        return VideoParseResult(
            platform: platform, title: title, author: payload["author"].string,
            cover: payload["cover"].string.isEmpty ? (images.first ?? "") : payload["cover"].string,
            url: link.url, medias: medias
        )
    }

    private static let xhrHookJS = """
    (function () {
      try {
        if (window.__yunxHook) return; window.__yunxHook = true;
        var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function (m, u) { this.__u = String(u || ''); return open.apply(this, arguments); };
        XMLHttpRequest.prototype.send = function () {
          var x = this;
          x.addEventListener('load', function () {
            try {
              if ((x.__u || '').indexOf('aweme/v1/web/aweme/detail') < 0 || x.status !== 200) return;
              var t = x.responseText || '';
              if (t) window.__yunxAwemeDetail = t;
            } catch (e) {}
          });
          return send.apply(this, arguments);
        };
      } catch (e) {}
    })();
    """

    private static let readyCheckJS = """
    (function () {
      if (typeof window.__yunxAwemeDetail === 'string' && window.__yunxAwemeDetail.length) return 'true';
      var imgs = document.querySelectorAll('img');
      for (var i = 0; i < imgs.length; i++) {
        var s = imgs[i].src || '';
        if (s.indexOf('douyinpic.com') >= 0 && s.indexOf('WEBPC_RELATED') < 0 &&
            (s.indexOf('biz_tag=aweme_images') >= 0 || s.indexOf('tplv-dy-aweme-images') >= 0)) return 'true';
      }
      return 'false';
    })()
    """

    private static let extractJS = """
    (function () {
      try {
        function first(n) { if (!n) return ''; var l = n.url_list || n.urlList; return (l && l.length) ? String(l[0] || '') : ''; }
        function motion(it) {
          var v = it && it.video; if (!v) return '';
          return first(v.playAddr) || first(v.play_addr) || first(v.play_addr_h264) || first(v.download_addr) || '';
        }
        var hooked = null;
        try {
          var r = JSON.parse(window.__yunxAwemeDetail || 'null');
          hooked = r && (r.aweme_detail || r.awemeDetail || (r.data && r.data.aweme_detail));
        } catch (e) {}
        var ssr = null;
        try {
          var node = document.querySelector('#RENDER_DATA');
          if (node) { var app = JSON.parse(decodeURIComponent(node.textContent)).app; ssr = app && app.videoDetail; }
        } catch (e) {}
        var d = hooked || ssr;
        var list = (ssr && ssr.images) || (hooked && hooked.images) ||
                   (hooked && hooked.image_post_info && hooked.image_post_info.images) || [];
        var images = [], motions = [];
        for (var i = 0; i < list.length; i++) {
          var u = first(list[i]) || first(list[i].display_image) || first(list[i].owner_watermark_image);
          if (u) { images.push(u); motions.push(motion(list[i])); }
        }
        if (!images.length) {
          var all = document.querySelectorAll('img');
          for (var j = 0; j < all.length; j++) {
            var s = all[j].src || '';
            if (s.indexOf('douyinpic') >= 0 && s.indexOf('WEBPC_RELATED') < 0 &&
                (s.indexOf('biz_tag=aweme_images') >= 0 || s.indexOf('tplv-dy-aweme-images') >= 0) &&
                images.indexOf(s) < 0) { images.push(s); motions.push(''); }
          }
        }
        var v = (hooked && hooked.video) || (ssr && ssr.video) || null, video = '';
        if (v) {
          video = first(v.play_addr) || first(v.playAddr) || first(v.play_addr_h264);
          if (!video && v.bit_rate) for (var k = 0; k < v.bit_rate.length; k++) { video = first(v.bit_rate[k].play_addr); if (video) break; }
          video = video.replace('/playwm/', '/play/');
        }
        var author = (d && d.author && (d.author.nickname || d.author.unique_id)) ||
                     (d && d.authorInfo && (d.authorInfo.nickname || d.authorInfo.nickName)) || '';
        var title = (d && d.desc) || (document.title || '').replace(/ - 抖音$/, '');
        return { title: title, author: author, video: video, images: images, motions: motions,
                 cover: (v && (first(v.cover) || first(v.origin_cover))) || '' };
      } catch (e) { return { error: 'js: ' + e }; }
    })()
    """
}

/// ttwid 是抖音分享页的匿名访客凭证：进程内缓存一份，SSR 失败时作废重注册
actor TtwidCache {
    static let shared = TtwidCache()
    private var cached: String?

    func get() async throws -> String {
        if let cached { return cached }
        let value = try await register()
        cached = value
        return value
    }

    func reset() { cached = nil }

    private func register() async throws -> String {
        let body: [String: Any] = ["region": "cn", "aid": 1768, "needFid": false, "service": "www.iesdouyin.com", "union": true, "fid": ""]
        let headers = ["User-Agent": UserAgent.iPhone, "Referer": "https://www.iesdouyin.com/"]
        let response: RawResponse
        do {
            response = try await HTTPClient.shared.postJSON("https://ttwid.bytedance.com/ttwid/union/register/", object: body, headers: headers)
        } catch {
            throw VideoParseError(.network, "ttwid 注册请求失败")
        }
        guard response.isSuccess else { throw VideoParseError(.unknown, "ttwid 注册失败（HTTP \(response.status)）") }
        let redirect = (try? JSON(data: response.data))?["redirect_url"].string ?? ""
        if !redirect.isEmpty,
           let callback = try? await HTTPClient.shared.send(redirect, headers: headers, followRedirects: false),
           let ttwid = callback.cookies["ttwid"], !ttwid.isEmpty {
            return "ttwid=\(ttwid)"
        }
        if let ttwid = response.cookies["ttwid"], !ttwid.isEmpty { return "ttwid=\(ttwid)" }
        throw VideoParseError(.unknown, "ttwid 注册未返回可用 Cookie")
    }
}
