// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 115 网盘分享：share/snap 列目录（匿名可读）→ share/downurl 取直链（需要登录 Cookie + 115 客户端 UA）。
///
/// 下载时 CDN 同时校验「登录 Cookie」和「取链响应下发的 900 秒 CDN Cookie」，两份要拼在一起发。
final class Pan115Resolver: ShareResolver {
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    private let api = "https://webapi.115.com"
    private let lock = NSLock()
    private var clientVersion = "36.0.1"
    private var versionFetched = false

    private var clientUA: String { "Mozilla/5.0 115Browser/\(lock.withLock { clientVersion })" }

    private static func referer(_ code: String, _ pwd: String) -> String {
        pwd.isEmpty ? "https://115cdn.com/s/\(code)" : "https://115cdn.com/s/\(code)?password=\(pwd)&"
    }

    private static func headers(_ cookie: String, referer: String, ua: String = webUA) -> [String: String] {
        var h = ["User-Agent": ua, "Accept": "application/json, text/plain, */*", "X-Requested-With": "XMLHttpRequest", "Referer": referer]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    static func hasLogin(_ cookie: String) -> Bool {
        cookie.split(separator: ";").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("UID=") }
    }

    private static func checkState(_ json: JSON, _ fallback: String) throws {
        if json["state"].bool { return }
        let errno = json["errno"].exists ? json["errno"].int : json["errNo"].int
        let raw = json.string("error", "msg")
        let message: String
        switch errno {
        case 990001: message = "登录已过期，请在「账号」页重新登录 115 网盘"
        case 4100012: message = "该分享需要访问码，请填写访问码后重试"
        case 4100008: message = "访问码错误，请检查后重试"
        case 4100026: message = "分享链接不存在或已被删除"
        case 990009: message = "上一次操作还没完成，请稍后重试"
        case 50028: message = "115 拒绝向网页端下发该文件的直链（文件过大），请改用 115 官方客户端下载"
        case 50029: message = "115 判定当前标识版本过低、拒绝下发直链，请改用 115 官方客户端下载"
        default: message = raw.isEmpty ? fallback : raw
        }
        throw ResolveError(errno != 0 && !message.contains("\(errno)") ? "\(message)（errno=\(errno)）" : message)
    }

    static func fetchNickname(cookie: String) async -> String? {
        guard hasLogin(cookie),
              let r = try? await HTTPClient.shared.send("https://webapi.115.com/user/info?ct=json", headers: headers(cookie, referer: "https://115.com/")),
              let json = try? JSON(data: r.data), json["state"].bool else { return nil }
        return json["data"].isObject ? json["data"].string("user_name", "name") : json["data"].string
    }

    private struct SnapPage { let files: [ShareFile]; let total: Int; let userId: String; let title: String }

    private func snap(code: String, pwd: String, cid: String, cookie: String, offset: Int) async throws -> SnapPage {
        let url = "\(api)/share/snap?share_code=\(HTTPClient.queryEncode(code))&receive_code=\(HTTPClient.queryEncode(pwd))"
            + "&offset=\(offset)&limit=100&asc=0&cid=\(HTTPClient.queryEncode(cid.isEmpty ? "0" : cid))&format=json"
        let r = try await HTTPClient.shared.send(url, headers: Self.headers(cookie, referer: Self.referer(code, pwd)))
        guard let json = try? JSON(data: r.data) else { throw ResolveError("115 响应解析失败（HTTP \(r.status)）") }
        try Self.checkState(json, "获取分享列表失败")
        let data = json["data"]
        let files = data["list"].array.compactMap { item -> ShareFile? in
            let fid = item["fid"].string
            let isDir = (item["fc"].exists ? item["fc"].int : (fid.isEmpty ? 0 : 1)) == 0
            let id = isDir ? item["cid"].string : fid
            guard !id.isEmpty else { return nil }
            return ShareFile(id: id, name: item["n"].string, size: isDir ? 0 : item["s"].int64, isDir: isDir,
                             parentId: isDir ? item["pid"].string : item["cid"].string,
                             modified: Format.date(item["t"].int64))
        }
        return SnapPage(files: files, total: data["count"].int, userId: data["userinfo"]["user_id"].string,
                        title: data["shareinfo"]["share_title"].string)
    }

    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession {
        let code = pwd ?? ""
        let page = try await snap(code: share.shareId, pwd: code, cid: "0", cookie: cookie, offset: 0)
        return ShareSession(platform: .pan115, shareId: share.shareId, token: "\(code)|\(page.userId)",
                            title: page.title.isEmpty ? share.shareId : page.title, rootId: "0")
    }

    private func decode(_ token: String) -> (pwd: String, userId: String) {
        guard let index = token.firstIndex(of: "|") else { return (token, "") }
        return (String(token[..<index]), String(token[token.index(after: index)...]))
    }

    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile] {
        let (pwd, _) = decode(session.token)
        var all: [ShareFile] = []
        var offset = 0
        for _ in 0..<200 {
            let page = try await snap(code: session.shareId, pwd: pwd, cid: dirId, cookie: cookie, offset: offset)
            all += page.files
            offset += page.files.count
            if page.files.count < 100 || (page.total > 0 && all.count >= page.total) { break }
        }
        return all
    }

    /// 客户端 UA 版本跟随官方最新版，版本过低会被拒发直链（50029）
    private func refreshClientVersion() async {
        guard !lock.withLock({ versionFetched }) else { return }
        lock.withLock { versionFetched = true }
        guard let r = try? await HTTPClient.shared.send("https://appversion.115.com/1/web/1.0/api/chrome", headers: ["User-Agent": Self.webUA]),
              let version = (try? JSON(data: r.data))?["data"]["win"]["version_code"].string,
              !version.isEmpty, version.count <= 16, version.allSatisfy({ $0.isNumber || $0 == "." }) else { return }
        lock.withLock { clientVersion = version }
    }

    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        guard Self.hasLogin(cookie) else { throw ResolveError("115 网盘需要登录后才能下载，请先在「账号」页登录") }
        let (pwd, userId) = decode(session.token)
        guard !userId.isEmpty else { throw ResolveError("缺少分享者标识，请重新解析分享链接") }
        await refreshClientVersion()
        var url = "\(api)/share/downurl?dl=1&user_id=\(HTTPClient.queryEncode(userId))&share_code=\(HTTPClient.queryEncode(session.shareId))"
            + "&file_id=\(HTTPClient.queryEncode(file.id))"
        if !pwd.isEmpty { url += "&receive_code=\(HTTPClient.queryEncode(pwd))" }
        let ua = clientUA
        let r = try await HTTPClient.shared.send(url, headers: Self.headers(cookie, referer: Self.referer(session.shareId, pwd), ua: ua))
        guard let json = try? JSON(data: r.data) else { throw ResolveError("115 响应解析失败（HTTP \(r.status)）") }
        try Self.checkState(json, "获取下载链接失败")
        let data = json["data"]
        let fileURL = [data["file_url_302"].string, data["file_url"].string, data["url"]["url"].string].first { !$0.isEmpty } ?? ""
        guard !fileURL.isEmpty else { throw ResolveError("115 未返回下载链接") }
        // CDN Cookie：优先 path 不是 "/" 的那一条
        let cdn = r.rawCookies.first { !$0.path.isEmpty && $0.path != "/" } ?? r.rawCookies.first
        let merged = [cookie, cdn.map { "\($0.name)=\($0.value)" } ?? ""].filter { !$0.isEmpty }.joined(separator: "; ")
        return DownloadLink(
            fileName: data["fn"].string.isEmpty ? file.name : data["fn"].string,
            url: fileURL,
            size: Int64(data["fs"].string) ?? file.size,
            headers: ["Cookie": merged, "User-Agent": ua, "Referer": "https://115.com/"]
        )
    }
}

/// 光鸭云盘分享：匿名取分享访问令牌 → 分页列目录 → 取签名直链（受限分享需要登录后转存，iOS 版暂不支持）。
final class GuangYaResolver: ShareResolver {
    static let webUA = UserAgent.chrome
    private let api = "https://api.guangyapan.com/userres/v1"
    private var pwds: [String: String] = [:]
    private let lock = NSLock()

    private static var deviceId: String {
        let key = "guangya.deviceid"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let value = (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private static func hex(_ n: Int) -> String { (0..<n).map { _ in String("0123456789abcdef".randomElement()!) }.joined() }

    private func post(_ path: String, _ body: [String: Any]) async throws -> JSON {
        let headers = [
            "Accept": "application/json, text/plain, */*", "User-Agent": Self.webUA,
            "Origin": "https://www.guangyapan.com", "Referer": "https://www.guangyapan.com/",
            "dt": "4", "traceparent": "00-\(Self.hex(32))-\(Self.hex(16))-01", "did": Self.deviceId,
        ]
        let r = try await HTTPClient.shared.postJSON("\(api)/\(path)", object: body, headers: headers)
        guard let json = try? JSON(data: r.data) else { throw ResolveError("光鸭响应解析失败（HTTP \(r.status)）") }
        return json
    }

    private static func check(_ json: JSON, _ fallback: String) throws {
        let code = json["code"].string
        let ok = (!json["success"].exists || json["success"].bool) && json["error"].string.isEmpty && (code.isEmpty || code == "0")
        if ok { return }
        switch code {
        case "209": throw ResolveError("光鸭分享提取码错误或缺失")
        case "200", "201", "202": throw ResolveError("光鸭分享已取消、过期或不可访问")
        case "205", "206", "207", "504": throw ResolveError("光鸭分享下载受限（需要登录后转存，iOS 版暂不支持），请在官网确认下载权限")
        default:
            let message = json.string("msg", "message", "error_description")
            throw ResolveError(message.isEmpty ? "\(fallback)（code=\(code)）" : message)
        }
    }

    private func accessToken(_ shareId: String, _ pwd: String) async throws -> String {
        let json = try await post("get_share_access_token", ["shareId": shareId, "code": pwd])
        try Self.check(json, "获取分享访问令牌失败")
        let data = json["data"].exists ? json["data"] : json
        let token = data.string("accessToken", "access_token")
        guard !token.isEmpty else { throw ResolveError("光鸭分享链接无效") }
        return token
    }

    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession {
        let code = pwd ?? ""
        lock.withLock { pwds[share.shareId] = code }
        let token = try await accessToken(share.shareId, code)
        var title = "光鸭分享"
        if let summary = try? await post("get_share_summary", ["shareId": share.shareId]) {
            let data = summary["data"].exists ? summary["data"] : summary
            let t = data.string("title", "shareName")
            if !t.isEmpty { title = t }
        }
        return ShareSession(platform: .guangya, shareId: share.shareId, token: token, title: title, rootId: "")
    }

    /// 访问令牌有时效：每次列目录 / 取链前刷新一次，失败再用会话里那份
    private func freshToken(_ session: ShareSession) async -> String {
        let pwd = lock.withLock { pwds[session.shareId] ?? "" }
        return (try? await accessToken(session.shareId, pwd)) ?? session.token
    }

    private func parse(_ item: JSON) -> ShareFile {
        let name = item.string("fileName", "name", "filename", "dirName", "title")
        let resType = item["resType"].string
        let isDir: Bool
        switch resType {
        case "2": isDir = true
        case "1": isDir = false
        default:
            isDir = item["isDir"].bool || item["isdir"].bool || item["dir"].bool || item["isFolder"].bool
                || !item["dirName"].string.isEmpty
                || ["folder", "dir", "directory", "0"].contains(item["type"].string.lowercased())
                || (!name.contains(".") && item["dirType"].string == "1")
        }
        return ShareFile(
            id: item.string("fileId", "file_id", "id", "resId", "resourceId"), name: name,
            size: Int64(item.string("fileSize", "size", "file_size")) ?? 0, isDir: isDir,
            parentId: item.string("parentId", "parentFileId", "parent_id"),
            modified: item.string("updatedAt", "updateAt", "updateTime", "mtime", "createdAt", "createTime")
        )
    }

    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile] {
        let token = await freshToken(session)
        var all: [ShareFile] = []
        var seen = Set<String>()
        var cursor: String?
        for _ in 0..<1000 {
            var body: [String: Any] = ["parentId": dirId, "pageSize": 100, "orderBy": 0, "sortType": 0, "accessToken": token]
            if let cursor { body["cursor"] = Int64(cursor).map { $0 as Any } ?? cursor }
            let json = try await post("get_share_page_files_list", body)
            try Self.check(json, "获取分享文件列表失败")
            let data = json["data"].exists ? json["data"] : json
            let items = data.first("list", "items", "files", "records", "content").array.map(parse)
            for f in items where seen.insert(f.id).inserted { all.append(f) }
            let next = data["cursor"].string
            let hasMore: Bool
            if data["hasMore"].exists {
                hasMore = data["hasMore"].bool
            } else if data["total"].exists {
                hasMore = data["total"].int > 0 && (Int(next) ?? all.count) < data["total"].int
            } else {
                hasMore = items.count >= 100 && !next.isEmpty
            }
            guard hasMore, !next.isEmpty else { break }
            cursor = next
        }
        return all
    }

    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        let json = try await post("get_share_download_url", ["fileId": file.id, "accessToken": await freshToken(session)])
        try Self.check(json, "获取下载地址失败")
        let data = json["data"].exists ? json["data"] : json
        let url = data.string("signedURL", "signedUrl", "downloadUrl", "download_url", "url", "cdnUrl")
        guard !url.isEmpty else { throw ResolveError("光鸭未返回有效下载地址，请确认下载权限") }
        return DownloadLink(fileName: file.name, url: url, size: Int64(data["size"].string) ?? file.size,
                            headers: ["User-Agent": Self.webUA, "Referer": "https://www.guangyapan.com/"])
    }
}
