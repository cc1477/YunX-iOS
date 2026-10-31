// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 百度网盘分享：verify（randsk）→ xpan share list → 转存到临时目录 → locatedownload 取 appall CDN 直链 → 删除转存。
///
/// 浏览公共分享无需登录；取直链必须登录（BDUSS），直链只需 Cookie + 网盘客户端 UA 即可满速。
final class BaiduResolver: ShareResolver {
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
    static let netdiskUA = "netdisk;12.24.6;piano;android-android;16;JSbridge4.4.0;jointBridge;1.1.0"
    private static let appId = "250528"
    private static let tempDir = "/YunX临时转存"

    private let lock = NSLock()
    private var bdstoken: String?
    private var shareInfo: [String: (shareId: String, uk: String)] = [:]

    // MARK: 账号

    private static func templateVariable(_ cookie: String, _ fields: String) async -> JSON? {
        let url = "https://pan.baidu.com/api/gettemplatevariable?clienttype=0&app_id=\(appId)&web=1&fields=\(HTTPClient.queryEncode(fields))"
        guard let r = try? await HTTPClient.shared.send(url, headers: ["Cookie": cookie, "User-Agent": webUA]),
              let json = try? JSON(data: r.data), json["errno"].int == 0 else { return nil }
        return json["result"]
    }

    static func fetchNickname(cookie: String) async -> String? {
        guard cookie.contains("BDUSS="), let result = await templateVariable(cookie, #"["username"]"#) else { return nil }
        return result["username"].string
    }

    private func token(_ cookie: String) async throws -> String {
        if let cached = lock.withLock({ bdstoken }), !cached.isEmpty { return cached }
        guard let value = await Self.templateVariable(cookie, #"["bdstoken"]"#)?["bdstoken"].string, !value.isEmpty else {
            throw ResolveError("获取 bdstoken 失败，请在「账号」页重新登录百度网盘")
        }
        lock.withLock { bdstoken = value }
        return value
    }

    private static func checkErrno(_ json: JSON, _ fallback: String) throws {
        let errno = json["errno"].int
        guard errno == 0 else {
            let message = json.string("err_msg", "show_msg")
            throw ResolveError("\(message.isEmpty ? fallback : message)（errno=\(errno)）")
        }
    }

    private static func json(_ r: RawResponse) throws -> JSON {
        guard let json = try? JSON(data: r.data) else { throw ResolveError("百度响应解析失败（HTTP \(r.status)）") }
        return json
    }

    // MARK: ShareResolver

    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession {
        var sekey = ""
        if let pwd, !pwd.isEmpty {
            let r = try await HTTPClient.shared.postForm(
                "https://pan.baidu.com/share/verify?surl=\(share.shareId)",
                fields: [("pwd", pwd), ("vcode_str", ""), ("vcode", "")],
                headers: ["Cookie": cookie, "User-Agent": Self.webUA, "Referer": "https://pan.baidu.com/s/\(share.shareId)"]
            )
            let json = try Self.json(r)
            try Self.checkErrno(json, "验证提取码失败")
            sekey = json["randsk"].string
            guard !sekey.isEmpty else { throw ResolveError("百度未返回分享密钥") }
        }
        let first = try await page(surl: share.shareId, sekey: sekey, dir: "/", cookie: cookie, page: 1)
        let title = first.title.isEmpty ? (first.files.count == 1 ? first.files[0].name : "百度分享") : first.title
        return ShareSession(platform: .baidu, shareId: share.shareId, token: sekey, title: title, rootId: "/")
    }

    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        for index in 1...100 {
            let result = try await page(surl: session.shareId, sekey: session.token, dir: dirId, cookie: cookie, page: index)
            all += result.files
            if result.files.count < 100 { break }
        }
        return all
    }

    private func page(surl: String, sekey: String, dir: String, cookie: String, page: Int) async throws -> (title: String, files: [ShareFile]) {
        let isRoot = dir.isEmpty || dir == "/"
        var url = "https://pan.baidu.com/rest/2.0/xpan/share?method=list&shorturl=\(surl)&page=\(page)&num=100"
            + "&root=\(isRoot ? 1 : 0)&dir=\(HTTPClient.queryEncode(isRoot ? "/" : dir))"
        if !sekey.isEmpty { url += "&sekey=\(sekey)" }
        var authCookie = cookie
        if !sekey.isEmpty && !cookie.contains("BDCLND=") { authCookie = cookie.isEmpty ? "BDCLND=\(sekey)" : "\(cookie); BDCLND=\(sekey)" }
        var headers = ["User-Agent": Self.webUA, "Referer": "https://pan.baidu.com/s/\(surl)"]
        if !authCookie.isEmpty { headers["Cookie"] = authCookie }
        let response = try await HTTPClient.shared.send(url, headers: headers)
        let json = try Self.json(response)
        let errno = json["errno"].int
        if errno != 0 {
            if sekey.isEmpty {
                throw ResolveError(errno == -6 ? "该分享需要提取码，或需要先在「账号」页登录百度网盘" : "该分享需要提取码（errno=\(errno)）")
            }
            try Self.checkErrno(json, "获取分享文件列表失败")
        }
        lock.withLock { shareInfo[surl] = (json["share_id"].string, json["uk"].string) }
        let files = json["list"].array.map { item -> ShareFile in
            let isDir = item["isdir"].string == "1"
            let path = item["path"].string
            return ShareFile(id: isDir ? path : item["fs_id"].string, name: item["server_filename"].string,
                             size: item["size"].int64, isDir: isDir, parentId: path, token: path,
                             modified: Format.date(item["server_mtime"].int64))
        }
        return (json["title"].string, files)
    }

    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        guard cookie.contains("BDUSS=") else { throw ResolveError("百度网盘需要登录后才能下载，请先在「账号」页登录") }
        var info = lock.withLock { shareInfo[session.shareId] }
        if info == nil {
            _ = try await page(surl: session.shareId, sekey: session.token, dir: "/", cookie: cookie, page: 1)
            info = lock.withLock { shareInfo[session.shareId] }
        }
        guard let info, !info.shareId.isEmpty else { throw ResolveError("百度分享信息缺失，请重新解析") }
        let bdstoken = try await token(cookie)
        let dir = await ensureTempDir(cookie: cookie, bdstoken: bdstoken)

        // 转存
        let authCookie = cookie.contains("BDCLND=") || session.token.isEmpty ? cookie : "\(cookie); BDCLND=\(session.token)"
        let transferURL = "https://pan.baidu.com/share/transfer?shareid=\(info.shareId)&from=\(info.uk)&channel=chunlei"
            + "&sekey=\(session.token)&ondup=newcopy&web=1&app_id=\(Self.appId)&bdstoken=\(bdstoken)&clienttype=0"
        let transferResponse = try await HTTPClient.shared.postForm(
            transferURL, fields: [("fsidlist", "[\"\(file.id)\"]"), ("path", dir)],
            headers: ["Cookie": authCookie, "User-Agent": Self.webUA, "Origin": "https://pan.baidu.com", "Referer": "https://pan.baidu.com/s/"]
        )
        let transfer = try Self.json(transferResponse)
        try Self.checkErrno(transfer, "转存失败（百度网盘空间不足或文件过多时会失败）")
        let saved = transfer["extra"]["list"][0]
        let savedPath = saved["to"].string.isEmpty ? "\(dir)/\(file.name)" : saved["to"].string

        // locatedownload：返回 appallNN.baidupcs.com 直链，自带签名，删除转存后仍有效
        let time = Int(Date().timeIntervalSince1970)
        let locateURL = "https://d.pcs.baidu.com/rest/2.0/pcs/file?method=locatedownload&app_id=\(Self.appId)&clienttype=17&ver=4.0"
            + "&ant=1&check_blue=1&es=1&esl=1&apn_id=1_-1&freeisp=0&queryfree=0&use=1&dtype=1&eck=1&ehps=1&err_ver=1.0"
            + "&network_type=WIFI&channel=0&path=\(HTTPClient.queryEncode(savedPath))&time=\(time)"
            + "&rand=5ed606e9da222cde0474cdf70eda884b&devuid=0F1E9FC2E084472DA5A61C4CF4C759AF&cuid=0F1E9FC2E084472DA5A61C4CF4C759AF"
            + "&deviceid=348642637967375013&psign=860a071f77c860e8cea06e4e54c518f3&version=2.2.111.34&version_app=12.24.6&vip=0"
        let locateResponse = try await HTTPClient.shared.send(
            locateURL, method: "POST",
            headers: ["Cookie": cookie, "User-Agent": Self.netdiskUA, "Content-Type": "application/x-www-form-urlencoded"],
            body: Data("0".utf8)
        )
        let located = try Self.json(locateResponse)
        defer { Task { await self.delete(path: savedPath, cookie: cookie, bdstoken: bdstoken) } }
        try Self.checkErrno(located, "获取高速下载链接失败")
        let candidates = located["urls"].array.filter { !$0["url"].string.isEmpty }
        let direct = candidates.first { $0["encrypt"].exists && $0["encrypt"].int == 0 && $0["url"].string.hasPrefix("https") }
            ?? candidates.first { $0["encrypt"].exists && $0["encrypt"].int == 0 }
            ?? candidates.first { $0["url"].string.hasPrefix("https") }
            ?? candidates.first
        guard let url = direct?["url"].string, !url.isEmpty else { throw ResolveError("百度未返回下载链接") }
        return DownloadLink(fileName: file.name, url: url, size: file.size,
                            headers: ["Cookie": cookie, "User-Agent": Self.netdiskUA])
    }

    /// 已存在则复用；不存在则创建；创建失败回退根目录
    private func ensureTempDir(cookie: String, bdstoken: String) async -> String {
        let listURL = "https://yun.baidu.com/api/list?clienttype=0&app_id=\(Self.appId)&web=1&order=time&desc=1&dir=%2F&num=100&page=1"
        if let r = try? await HTTPClient.shared.send(listURL, headers: ["Cookie": cookie, "User-Agent": Self.netdiskUA]),
           let json = try? JSON(data: r.data), json["list"].array.contains(where: { $0["path"].string == Self.tempDir }) {
            return Self.tempDir
        }
        let createURL = "https://pan.baidu.com/api/create?a=commit&channel=chunlei&web=1&app_id=\(Self.appId)&clienttype=0&bdstoken=\(bdstoken)"
        if let r = try? await HTTPClient.shared.postForm(
            createURL, fields: [("path", Self.tempDir), ("isdir", "1"), ("size", ""), ("block_list", "[]"), ("method", "post"), ("dataType", "json")],
            headers: ["Cookie": cookie, "User-Agent": Self.netdiskUA, "Referer": "https://yun.baidu.com/disk/main"]
        ), let json = try? JSON(data: r.data), json["errno"].int == 0 {
            return Self.tempDir
        }
        return "/"
    }

    private func delete(path: String, cookie: String, bdstoken: String) async {
        let url = "https://pan.baidu.com/api/filemanager?async=2&onnest=fail&opera=delete&bdstoken=\(bdstoken)&newVerify=1&clienttype=0&app_id=\(Self.appId)&web=1"
        _ = try? await HTTPClient.shared.postForm(url, fields: [("filelist", "[\"\(path)\"]")],
                                                  headers: ["Cookie": cookie, "User-Agent": Self.netdiskUA])
    }
}
