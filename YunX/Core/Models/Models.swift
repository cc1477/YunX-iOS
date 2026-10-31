// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

// MARK: - 网盘

/// 识别结果：share_id + 提取码 + 平台
struct ParsedShare: Hashable {
    let shareId: String
    let pwd: String?
    let platform: SharePlatform
    /// 原始链接（蓝奏这类以完整 URL 为会话 key 的平台要用）
    let url: String
}

/// 一次分享解析会话
struct ShareSession: Hashable {
    let platform: SharePlatform
    let shareId: String
    /// 分享访问凭证（夸克 stoken / 蓝奏提取码）
    let token: String
    let title: String
    let rootId: String
}

/// 分享文件/目录项
struct ShareFile: Identifiable, Hashable {
    let id: String
    let name: String
    let size: Int64
    let isDir: Bool
    let parentId: String
    /// 平台附加凭证（夸克 share_fid_token / 蓝奏成员页地址）
    let token: String
    let modified: String

    init(id: String, name: String, size: Int64, isDir: Bool, parentId: String = "", token: String = "", modified: String = "") {
        self.id = id
        self.name = name
        self.size = size
        self.isDir = isDir
        self.parentId = parentId
        self.token = token
        self.modified = modified
    }

    var fileKind: FileKind { FileKind(fileName: name, isDir: isDir) }
}

/// 下载直链：逐条自带请求头（Referer / Cookie / UA），下载器原样使用
struct DownloadLink: Hashable {
    let fileName: String
    let url: String
    let size: Int64
    let headers: [String: String]
}

struct ResolveError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - 视频

enum VideoMediaKind: String, Codable, Hashable { case video, image, audio }

struct VideoMedia: Identifiable, Hashable {
    let id = UUID()
    var url: String
    var kind: VideoMediaKind
    var fileName: String = ""
    var size: Int64 = -1
    /// m3u8 流（AcFun）
    var isHLS: Bool = false
    var headers: [String: String] = [:]
    /// 清晰度/规格标签，仅用于展示
    var quality: String = ""
    /// 需要合轨的音轨（哔哩哔哩 DASH）；空 = 单文件直链
    var audioURL: String = ""
    var audioHeaders: [String: String] = [:]
    /// 动图（Live Photo）的视频部分；iOS 端下载为独立视频文件
    var motionURL: String = ""
}

struct VideoParseResult: Identifiable, Hashable {
    let id = UUID()
    var platform: VideoPlatform
    var title: String
    var author: String = ""
    var avatar: String = ""
    var cover: String = ""
    var text: String = ""
    var timestamp: Int64 = 0
    var url: String = ""
    var medias: [VideoMedia] = []
    /// 非致命提示（解析成功但部分内容降级）
    var notice: String = ""

    var videos: [VideoMedia] { medias.filter { $0.kind == .video } }
    var images: [VideoMedia] { medias.filter { $0.kind == .image } }
}

struct DetectedVideoLink: Hashable {
    let platform: VideoPlatform
    /// 平台内资源类型（video / note / photo / status / fid / tv / ac / artwork / short）
    let kind: String
    let id: String
    let url: String
    var isShortLink: Bool { kind == "short" }
}

enum VideoParseErrorKind { case blocked, notFound, network, unsupported, unknown }

/// 视频解析异常：上层靠 [kind] 决定提示文案，不要把 HTTP 状态码甩给用户
struct VideoParseError: LocalizedError {
    let kind: VideoParseErrorKind
    let detail: String

    init(_ kind: VideoParseErrorKind, _ detail: String) {
        self.kind = kind
        self.detail = detail
    }

    var errorDescription: String? {
        switch kind {
        case .blocked: return "平台风控拦截了本次请求，请稍后重试"
        case .notFound: return "内容不存在、已删除或不可见"
        case .network: return "网络请求失败，请检查网络后重试"
        case .unsupported: return detail.isEmpty ? "暂不支持该链接" : detail
        case .unknown: return detail.isEmpty ? "解析失败，请稍后重试" : detail
        }
    }
}

// MARK: - 文件类型

enum FileKind {
    case folder, video, image, audio, archive, document, apk, code, other

    init(fileName: String, isDir: Bool = false) {
        if isDir { self = .folder; return }
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "mp4", "mkv", "mov", "avi", "flv", "wmv", "m4v", "ts", "webm", "rmvb": self = .video
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff", "avif": self = .image
        case "mp3", "flac", "wav", "aac", "m4a", "ogg", "ape", "wma": self = .audio
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "iso", "dmg": self = .archive
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "epub", "csv": self = .document
        case "apk", "ipa", "exe", "msi", "deb", "pkg": self = .apk
        case "json", "xml", "html", "js", "py", "swift", "kt", "java", "c", "cpp", "sh", "yml", "yaml": self = .code
        default: self = .other
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .video: return "play.rectangle.fill"
        case .image: return "photo.fill"
        case .audio: return "music.note"
        case .archive: return "doc.zipper"
        case .document: return "doc.text.fill"
        case .apk: return "shippingbox.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "doc.fill"
        }
    }

    var isMedia: Bool { self == .video || self == .image || self == .audio }
}
