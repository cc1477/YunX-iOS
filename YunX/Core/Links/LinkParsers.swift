// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 从整段分享文案中提取 share_id 与提取码（规则逐条对齐安卓版 ShareLinkParser）。
enum ShareLinkParser {
    private static let trailing = "。，,；;)]}\"'"
    private static let pwdInURL = #"[?&]pwd=([A-Za-z0-9]+)"#
    private static let pwdIn115URL = #"[?&]password=([A-Za-z0-9]+)"#
    private static let pwdInLanzouURL = #"[?&](?:pwd|pass|passcode|password)=([A-Za-z0-9]+)"#
    private static let pwdInText = #"(?:提取码|访问码|密码)[：:]\s*([A-Za-z0-9]{4,8})"#

    private struct Rule {
        let platform: SharePlatform
        let pattern: String
        let pwdPattern: String
        /// 部分平台的 id 需要再加工（百度去掉开头的 1）
        var transform: (String) -> String = { $0 }
    }

    /// 顺序即优先级：蓝奏云优享版必须先于蓝奏云判断，避免 ilanzou.com 被误判
    private static let rules: [Rule] = [
        Rule(platform: .quark, pattern: #"pan\.quark\.cn/s/([A-Za-z0-9]+)"#, pwdPattern: pwdInURL),
        Rule(platform: .uc, pattern: #"drive\.uc\.cn/s/([A-Za-z0-9]+)"#, pwdPattern: pwdInURL),
        Rule(platform: .xunlei, pattern: #"pan\.xunlei\.com/s/([A-Za-z0-9_-]+)"#, pwdPattern: pwdInURL),
        Rule(platform: .baidu, pattern: #"pan\.baidu\.com/s/(1[A-Za-z0-9_-]+)"#, pwdPattern: pwdInURL,
             transform: { String($0.dropFirst()) }),
        Rule(platform: .c139, pattern: #"yun\.139\.com/shareweb/.*?/w/i/([A-Za-z0-9_-]+)"#, pwdPattern: pwdInURL),
        Rule(platform: .pan123, pattern: #"123(?:865|pan)\.(?:com|cn)/s/([A-Za-z0-9]+-[A-Za-z0-9]+)"#, pwdPattern: pwdInURL),
        Rule(platform: .pan123, pattern: #"share\.123pan\.cn/123pan/([A-Za-z0-9-]+)"#, pwdPattern: pwdInURL),
        Rule(platform: .pan123, pattern: #"api/srr\?sk=([A-Za-z0-9-]+)"#, pwdPattern: pwdInURL),
        Rule(platform: .pan115, pattern: #"115(?:cdn|rc)?\.com/s/(sw[A-Za-z0-9]+)"#, pwdPattern: pwdIn115URL),
        Rule(platform: .guangya, pattern: #"guangyapan\.com/s/([A-Za-z0-9_-]+)"#, pwdPattern: pwdInURL),
        Rule(platform: .ilanzou, pattern: #"(?:^|[/.])ilanzou\.(?:com|net|org|cn)/s/([A-Za-z0-9_-]+)"#, pwdPattern: pwdInLanzouURL),
        Rule(platform: .lanzou,
             pattern: #"(?:^|[/.])(?:lanzou[a-z0-9-]*|lan[zs]o[ux]|lanzn)\.(?:com|net|org|cn)/([A-Za-z0-9]+)"#,
             pwdPattern: pwdInLanzouURL),
    ]

    static func extractURL(_ text: String) -> String? {
        RX.first(#"https?://[^\s]+"#, in: text.trimmed, group: 0, options: [])?.trimmingTrailing(trailing)
    }

    static func parse(_ text: String) -> ParsedShare? {
        guard let url = extractURL(text) else { return nil }
        for rule in rules {
            guard let id = RX.first(rule.pattern, in: url) else {
                // 115 口令形式 https://115.com/sws8lxs36jf-n307/（code-提取码）
                if rule.platform == .pan115,
                   let command = RX.groups(#"115(?:cdn|rc)?\.com/(sw[A-Za-z0-9]{8,})-([A-Za-z0-9]{4,8})"#, in: url) {
                    return ParsedShare(shareId: command[1], pwd: command[2], platform: .pan115, url: url)
                }
                continue
            }
            let pwd = RX.first(rule.pwdPattern, in: url, options: []) ?? RX.first(pwdInText, in: text, options: [])
            return ParsedShare(shareId: rule.transform(id), pwd: pwd, platform: rule.platform, url: url)
        }
        return nil
    }
}

/// 从任意文本里识别视频平台链接（规则对齐安卓版 VideoLinkParser）。
///
/// ★ 只在**链接**上匹配，不看链接外的文案：抖音/快手的分享文案里常带一堆数字，拿整段文本匹配必然误判。
enum VideoLinkParser {
    private static let trailing = "。，,；;)]}\"'、！？…"

    private struct Rule {
        let platform: VideoPlatform
        let kind: String
        let pattern: String
    }

    /// 顺序即优先级：短链优先于长链
    private static let rules: [Rule] = [
        // 抖音
        Rule(platform: .douyin, kind: "short", pattern: #"v\.douyin\.com/[A-Za-z0-9_\-]+"#),
        Rule(platform: .douyin, kind: "short", pattern: #"jx\.douyin\.com/[A-Za-z0-9_\-]+"#),
        Rule(platform: .douyin, kind: "video", pattern: #"(?:www\.)?douyin\.com/(video|note)/(\d{10,})"#),
        Rule(platform: .douyin, kind: "video", pattern: #"douyin\.com/[^\s]*[?&]modal_id=(\d{10,})"#),
        Rule(platform: .douyin, kind: "video", pattern: #"iesdouyin\.com/share/(?:slides|video|note)/(\d{10,})"#),
        Rule(platform: .douyin, kind: "video", pattern: #"m\.douyin\.com/share/(?:slides|video|note)/(\d{10,})"#),
        Rule(platform: .douyin, kind: "video", pattern: #"jingxuan\.douyin\.com/m/(?:slides|video|note)/(\d{10,})"#),
        // 小红书
        Rule(platform: .xhs, kind: "short", pattern: #"xhslink\.(?:com|cn)/[A-Za-z0-9._?%&+=/#@\-]+"#),
        Rule(platform: .xhs, kind: "note", pattern: #"xiaohongshu\.com/(?:explore|discovery/item|discovery)/([0-9a-zA-Z]{10,})"#),
        // 快手
        Rule(platform: .kuaishou, kind: "short", pattern: #"v\.kuaishou\.com/[A-Za-z\d._?%&+\-=/#]+"#),
        Rule(platform: .kuaishou, kind: "photo", pattern: #"(?:www\.)?kuaishou\.com/(?:short-video|fw/photo|fw/long-video)/([A-Za-z\d]+)"#),
        Rule(platform: .kuaishou, kind: "photo", pattern: #"(?:www\.)?kuaishou\.com/f/([A-Za-z\d]+)"#),
        Rule(platform: .kuaishou, kind: "photo", pattern: #"(?:v\.m\.)?chenzhongtech\.com/fw/(?:photo|long-video)/([A-Za-z\d]+)"#),
        // 微博
        Rule(platform: .weibo, kind: "tv", pattern: #"weibo\.com/tv/show/\d{4}:\d+\?mid=(\d+)"#),
        Rule(platform: .weibo, kind: "fid", pattern: #"video\.weibo\.com/show\?fid=(\d+:\d+)"#),
        Rule(platform: .weibo, kind: "status", pattern: #"weibo\.cn/(?:status|statuses|detail)/([0-9a-zA-Z]+)"#),
        Rule(platform: .weibo, kind: "status", pattern: #"weibo\.com/\d+/([0-9a-zA-Z]{6,})"#),
        // AcFun
        Rule(platform: .acfun, kind: "ac", pattern: #"acfun\.cn/.*(?:ac=|/ac)(\d+)"#),
        // 哔哩哔哩
        Rule(platform: .bilibili, kind: "short", pattern: #"b23\.tv/[A-Za-z\d]+"#),
        Rule(platform: .bilibili, kind: "short", pattern: #"bili2233\.cn/[A-Za-z\d]+"#),
        Rule(platform: .bilibili, kind: "video", pattern: #"bilibili\.com/video/(BV[0-9a-zA-Z]{10}|av\d+)"#),
        // Pixiv
        Rule(platform: .pixiv, kind: "artwork", pattern: #"pixiv\.net/(?:[a-z]{2}/)?artworks/(\d+)"#),
        Rule(platform: .pixiv, kind: "artwork", pattern: #"pixiv\.net/member_illust\.php\?[^\s]*illust_id=(\d+)"#),
    ]

    static func parse(_ text: String) -> DetectedVideoLink? {
        guard let raw = RX.first(#"https?://[^\s]+"#, in: text.trimmed, group: 0, options: []) else { return nil }
        let url = raw.trimmingTrailing(trailing)
        for rule in rules {
            guard let groups = RX.groups(rule.pattern, in: url) else { continue }
            let isShort = rule.kind == "short"
            let id = groups.dropFirst().last(where: { !$0.isEmpty }) ?? ""
            return DetectedVideoLink(
                platform: rule.platform,
                kind: rule.kind,
                id: isShort ? "" : id,
                url: url.hasPrefix("http") ? url : "https://\(url)"
            )
        }
        return nil
    }
}

/// 解析页统一入口：先视频、再网盘
enum DetectedLink: Hashable {
    case share(ParsedShare)
    case video(DetectedVideoLink)

    static func detect(_ text: String) -> DetectedLink? {
        if let video = VideoLinkParser.parse(text) { return .video(video) }
        if let share = ShareLinkParser.parse(text) { return .share(share) }
        return nil
    }

    var displayName: String {
        switch self {
        case .share(let s): return s.platform.displayName
        case .video(let v): return v.platform.displayName
        }
    }

    var logo: String {
        switch self {
        case .share(let s): return s.platform.logo
        case .video(let v): return v.platform.logo
        }
    }

    var isAvailable: Bool {
        switch self {
        case .share(let s): return s.platform.isAvailable
        case .video(let v): return v.platform.isAvailable
        }
    }
}
