// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 分享解析公共接口：打开分享 → 列目录 → 取直链。
///
/// 安卓版还有「转存到自己网盘」「临时目录清理」等能力，iOS 首版只做免转存取链。
protocol ShareResolver {
    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession
    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile]
    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink
}

enum ShareResolvers {
    static let lanzou = LanzouResolver()
    static let quark = QuarkResolver()
    static let uc = UCResolver()
    static let pan123 = Pan123Resolver()
    static let baidu = BaiduResolver()
    static let pan115 = Pan115Resolver()
    static let guangya = GuangYaResolver()
    static let c139 = C139Resolver()
    static let xunlei = XunleiResolver()

    static func resolver(for platform: SharePlatform) throws -> ShareResolver {
        switch platform {
        case .lanzou: return lanzou
        case .quark: return quark
        case .uc: return uc
        case .pan123: return pan123
        case .baidu: return baidu
        case .pan115: return pan115
        case .guangya: return guangya
        case .c139: return c139
        case .xunlei: return xunlei
        default: throw ResolveError("\(platform.displayName)暂无可用的分享解析接口（Android 版同样不支持）")
        }
    }
}
