// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI

/// 网盘平台。[displayName] 是界面上唯一的展示名来源，别在 UI 层再各写一份。
enum SharePlatform: String, CaseIterable, Codable, Identifiable, Hashable {
    case quark, uc, xunlei, baidu, c139, pan123, pan115, guangya, ilanzou, lanzou

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .quark: return "夸克网盘"
        case .uc: return "UC 网盘"
        case .xunlei: return "迅雷网盘"
        case .baidu: return "百度网盘"
        case .c139: return "139 网盘"
        case .pan123: return "123 云盘"
        case .pan115: return "115 网盘"
        case .guangya: return "光鸭云盘"
        case .ilanzou: return "蓝奏云优享"
        case .lanzou: return "蓝奏云"
        }
    }

    var logo: String {
        switch self {
        case .quark: return "logo_quark"
        case .uc: return "logo_uc"
        case .xunlei: return "logo_xunlei"
        case .baidu: return "logo_baidu"
        case .c139: return "logo_c139"
        case .pan123: return "logo_123pan"
        case .pan115: return "logo_pan115"
        case .guangya: return "logo_guangya"
        case .ilanzou: return "logo_ilanzou"
        case .lanzou: return "logo_lanzou"
        }
    }

    var tint: Color {
        switch self {
        case .quark: return Color(hex: 0x3B6CF6)
        case .uc: return Color(hex: 0xF5821F)
        case .xunlei: return Color(hex: 0x2A8CF0)
        case .baidu: return Color(hex: 0x2468F2)
        case .c139: return Color(hex: 0x00A1E9)
        case .pan123: return Color(hex: 0x597DFC)
        case .pan115: return Color(hex: 0x2777F8)
        case .guangya: return Color(hex: 0x7B61FF)
        case .ilanzou: return Color(hex: 0x3A9BFF)
        case .lanzou: return Color(hex: 0x1E88E5)
        }
    }

    /// iOS 版已经移植完成的平台；其余平台链接能识别，但解析时会给出「即将支持」提示
    var isAvailable: Bool {
        switch self {
        case .quark, .lanzou: return true
        default: return false
        }
    }

    /// 网页登录页；nil = 该平台在 iOS 版暂不提供登录
    var loginURL: String? {
        switch self {
        case .quark: return "https://pan.quark.cn/?fr=pc&platform=pc"
        default: return nil
        }
    }

    var cookieDomain: String {
        switch self {
        case .quark: return "quark.cn"
        default: return ""
        }
    }

    /// 登录页 WebView 的 UA（夸克要求 PC 环境）
    var loginUserAgent: String { UserAgent.chrome }

    /// 认定「已登录」所需的 Cookie 名
    var requiredCookies: [String] {
        switch self {
        case .quark: return ["__pus"]
        default: return []
        }
    }

    var loginBenefit: String {
        switch self {
        case .quark: return "未登录可下载约 50MB 以内的文件；登录后免转存直接取链，不受大小限制"
        case .lanzou: return "蓝奏云分享无需登录即可解析下载"
        default: return "iOS 版正在移植中"
        }
    }
}

/// 视频平台。
enum VideoPlatform: String, CaseIterable, Codable, Identifiable, Hashable {
    case douyin, xhs, kuaishou, weibo, acfun, bilibili, pixiv

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .douyin: return "抖音"
        case .xhs: return "小红书"
        case .kuaishou: return "快手"
        case .weibo: return "微博"
        case .acfun: return "AcFun"
        case .bilibili: return "哔哩哔哩"
        case .pixiv: return "Pixiv"
        }
    }

    var logo: String {
        switch self {
        case .douyin: return "logo_douyin"
        case .xhs: return "logo_xhs"
        case .kuaishou: return "logo_kuaishou"
        case .weibo: return "logo_weibo"
        case .acfun: return "logo_acfun"
        case .bilibili: return "logo_bilibili"
        case .pixiv: return "logo_pixiv"
        }
    }

    var tint: Color {
        switch self {
        case .douyin: return Color(hex: 0x111111)
        case .xhs: return Color(hex: 0xFF2442)
        case .kuaishou: return Color(hex: 0xFF5000)
        case .weibo: return Color(hex: 0xE6162D)
        case .acfun: return Color(hex: 0xFD4C5D)
        case .bilibili: return Color(hex: 0xFB7299)
        case .pixiv: return Color(hex: 0x0096FA)
        }
    }

    var isAvailable: Bool {
        switch self {
        case .xhs, .pixiv: return false
        default: return true
        }
    }

    /// 网页登录页；nil = 无需登录（或只支持手动填写 Cookie）
    var loginURL: String? {
        switch self {
        case .bilibili: return "https://passport.bilibili.com/login"
        case .xhs: return "https://www.xiaohongshu.com/login"
        default: return nil
        }
    }

    var cookieDomain: String {
        switch self {
        case .bilibili: return "bilibili.com"
        case .xhs: return "xiaohongshu.com"
        case .pixiv: return "pixiv.net"
        default: return ""
        }
    }

    var requiredCookies: [String] {
        switch self {
        case .bilibili: return ["SESSDATA"]
        case .xhs: return ["web_session"]
        case .pixiv: return ["PHPSESSID"]
        default: return []
        }
    }

    /// Pixiv 的网页登录在 App 内 WebView 里过不了 reCAPTCHA，只支持手动粘贴 Cookie
    var manualCookieOnly: Bool { self == .pixiv }

    var needsLogin: Bool { loginURL != nil || manualCookieOnly }

    var loginBenefit: String {
        switch self {
        case .bilibili: return "登录后可解析 1080P 及以上清晰度（音视频分轨，下载后自动合并）"
        case .xhs: return "小红书网页端要求登录后才能查看笔记"
        case .pixiv: return "粘贴浏览器 Cookie 后可解析全部作品"
        default: return "无需登录，直接解析"
        }
    }
}

/// 账号存储用的统一键
enum AccountKey: Hashable, Codable {
    case drive(SharePlatform)
    case video(VideoPlatform)

    var storageKey: String {
        switch self {
        case .drive(let p): return "drive.\(p.rawValue)"
        case .video(let p): return "video.\(p.rawValue)"
        }
    }

    var displayName: String {
        switch self {
        case .drive(let p): return p.displayName
        case .video(let p): return p.displayName
        }
    }

    var logo: String {
        switch self {
        case .drive(let p): return p.logo
        case .video(let p): return p.logo
        }
    }

    var loginURL: String? {
        switch self {
        case .drive(let p): return p.loginURL
        case .video(let p): return p.loginURL
        }
    }

    var cookieDomain: String {
        switch self {
        case .drive(let p): return p.cookieDomain
        case .video(let p): return p.cookieDomain
        }
    }

    var requiredCookies: [String] {
        switch self {
        case .drive(let p): return p.requiredCookies
        case .video(let p): return p.requiredCookies
        }
    }

    var loginUserAgent: String {
        switch self {
        case .drive(let p): return p.loginUserAgent
        case .video: return UserAgent.chrome
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
