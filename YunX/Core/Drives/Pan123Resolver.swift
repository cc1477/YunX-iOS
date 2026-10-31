// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 123 云盘：分享列表匿名可读；取直链需要登录（账号密码换 JWT）+ auth-key/auth-value 签名。
final class Pan123Resolver: ShareResolver {
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"
    static let dartUA = "Dart/3.12 (dart:io)"
    static let referer = "https://yun.123pan.cn/"
    private static let signTable = Array("adefghlmyijnopkqrstubcvwsz")

    /// 设备标识：同一设备长期不变、不参与签名
    static var loginUUID: String {
        let key = "pan123.loginuuid"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let value = (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    // MARK: 签名

    static func crc32Hex(_ text: String) -> String {
        String(CRC32.checksum(Data(text.utf8)), radix: 16)
    }

    /// auth-key = crc32(把 UTC「ts+16h」的 yyyyMMddHHmm 逐位查表替换)；auth-value = "ts-random-crc32(ts|random|path|web|3|auth-key)"
    static func makeSign(path: String, ts: Int = Int(Date().timeIntervalSince1970)) -> (key: String, value: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmm"
        let minute = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts + 57600)))
        let substituted = String(minute.compactMap { $0.wholeNumberValue.map { signTable[$0] } })
        let authKey = crc32Hex(substituted)
        let random = Int.random(in: 0..<10_000_000)
        let value = "\(ts)-\(random)-\(crc32Hex("\(ts)|\(random)|\(path)|web|3|\(authKey)"))"
        return (authKey, value)
    }

    private static func authHeaders(path: String, token: String, platform: String = "web", appVersion: String = "3") -> [String: String] {
        let sign = makeSign(path: path)
        return [
            "platform": platform, "app-version": appVersion, "authorization": "Bearer \(token)",
            "loginuuid": loginUUID, "auth-key": sign.key, "auth-value": sign.value,
            "User-Agent": webUA, "Accept": "application/json, text/plain, */*",
        ]
    }

    private static func checkOK(_ json: JSON, _ fallback: String) throws {
        let code = json["code"].exists ? json["code"].int : -1
        guard code == 0 else {
            let message = json["message"].string
            throw ResolveError("\(message.isEmpty ? fallback : message)（code=\(code)）")
        }
    }

    // MARK: 账号

    /// 账号密码登录：user.123pan.cn（另一个站），成功判定是 code == 200
    static func passwordLogin(account: String, password: String) async throws -> String {
        let passport = account.trimmed
        guard !passport.isEmpty, !password.isEmpty else { throw ResolveError("请输入账号和密码") }
        let headers = [
            "platform": "web", "app-version": "132", "loginuuid": loginUUID,
            "Origin": "https://user.123pan.cn", "Referer": "https://user.123pan.cn/", "User-Agent": webUA,
        ]
        let response: RawResponse
        do {
            response = try await HTTPClient.shared.postJSON(
                "https://user.123pan.cn/api/user/sign_in",
                object: ["passport": passport, "password": password, "remember": false], headers: headers
            )
        } catch {
            throw ResolveError("网络异常，无法连接 123 登录服务，请稍后重试")
        }
        let json = try? JSON(data: response.data)
        let token = json?["data"]["token"].string ?? ""
        if response.isSuccess, json?["code"].int == 200, !token.isEmpty { return token }
        let message = (json?["message"].string ?? "").lowercased()
        if response.status == 429 || ["频繁", "频率", "次数", "稍后"].contains(where: { message.contains($0) }) {
            throw ResolveError("123 登录请求过于频繁，请稍后重试")
        }
        if ["验证码", "滑块", "安全验证", "captcha", "verify"].contains(where: { message.contains($0) }) {
            throw ResolveError("123 要求额外安全验证，请稍后重试或在官方 App 登录一次")
        }
        if ["冻结", "封禁", "封停", "注销", "禁用"].contains(where: { message.contains($0) }) {
            throw ResolveError("123 账号暂时不可登录，请先在官方客户端检查账号状态")
        }
        throw ResolveError("123 登录失败，请检查账号和密码后重试")
    }

    static func fetchNickname(token: String) async -> String? {
        guard let response = try? await HTTPClient.shared.send(
            "https://yun.123pan.cn/b/api/user/info", headers: authHeaders(path: "/b/api/user/info", token: token)
        ), let json = try? JSON(data: response.data), json["code"].int == 0, json["data"].isObject else { return nil }
        return json["data"]["Nickname"].string
    }

    // MARK: ShareResolver

    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession {
        let code = pwd ?? ""
        let (files, _) = try await page(shareKey: share.shareId, pwd: code, parent: "0", page: 1)
        let title = files.count == 1 ? files[0].name : share.shareId
        return ShareSession(platform: .pan123, shareId: share.shareId, token: code, title: title.isEmpty ? "123 分享" : title, rootId: "0")
    }

    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        for index in 1..<50 {
            let (files, hasMore) = try await page(shareKey: session.shareId, pwd: session.token, parent: dirId, page: index)
            all += files
            if files.isEmpty || !hasMore { break }
        }
        return all
    }

    /// 分享列表（匿名、无签名）：Next == "-1" 无下一页；无提取码时不能传 SharePwd（传空会 400）
    private func page(shareKey: String, pwd: String, parent: String, page: Int) async throws -> ([ShareFile], Bool) {
        var url = "https://yun.123pan.cn/b/api/share/get?limit=100&next=0&orderBy=file_name&orderDirection=asc"
            + "&shareKey=\(HTTPClient.queryEncode(shareKey))&ParentFileId=\(parent)&Page=\(page)"
        if !pwd.isEmpty { url += "&SharePwd=\(HTTPClient.queryEncode(pwd))" }
        let response = try await HTTPClient.shared.send(url, headers: ["User-Agent": Self.dartUA])
        guard let json = try? JSON(data: response.data) else { throw ResolveError("123 响应解析失败（HTTP \(response.status)）") }
        try Self.checkOK(json, "获取文件列表失败")
        let data = json["data"]
        if data["Expired"].bool { throw ResolveError("分享已失效") }
        let files = data["InfoList"].array.map { item in
            ShareFile(
                id: item["FileId"].string, name: item["FileName"].string, size: item["Size"].int64,
                isDir: item["Type"].int == 1, parentId: item["ParentFileId"].string,
                // 取链需要 S3KeyFlag + Etag，编码进 token
                token: "\(item["S3KeyFlag"].string)|\(item["Etag"].string)",
                modified: String(item["UpdateAt"].string.prefix(16)).replacingOccurrences(of: "T", with: " ")
            )
        }
        return (files, data["Next"].string != "-1")
    }

    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        guard !cookie.isEmpty else { throw ResolveError("123 云盘需要登录后才能下载，请先在「账号」页登录") }
        let parts = file.token.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        let body: [String: Any] = [
            "ShareKey": session.shareId, "FileID": file.id,
            "S3KeyFlag": parts.first ?? "", "Size": file.size, "Etag": parts.count > 1 ? parts[1] : "",
        ]
        let path = "/b/api/share/download/info"
        let response = try await HTTPClient.shared.postJSON(
            "https://www.123865.com\(path)", object: body,
            headers: Self.authHeaders(path: path, token: cookie, platform: "android", appVersion: "39")
        )
        guard let json = try? JSON(data: response.data) else { throw ResolveError("123 响应解析失败（HTTP \(response.status)）") }
        if json["code"].int == 401 { throw ResolveError("123 登录已过期，请在「账号」页重新登录") }
        try Self.checkOK(json, "获取下载链接失败")
        let raw = json["data"]["DownloadURL"].string
        guard !raw.isEmpty else { throw ResolveError("123 未返回下载链接") }
        let real = await followRedirect(Self.decodeDownloadURL(raw) ?? raw)
        return DownloadLink(fileName: file.name, url: real, size: file.size,
                            headers: ["User-Agent": Self.webUA, "Referer": Self.referer])
    }

    /// 下载地址有两种形态：整段 base64，或 download-v2?params=<URL-safe base64>
    static func decodeDownloadURL(_ raw: String) -> String? {
        let trimmed = raw.trimmed
        func decode(_ value: String) -> String? {
            var normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while normalized.count % 4 != 0 { normalized += "=" }
            return Data(base64Encoded: normalized).map { String(decoding: $0, as: UTF8.self) }
        }
        if !trimmed.contains("://") {
            return decode(trimmed).flatMap { $0.lowercased().hasPrefix("http") ? $0 : nil }
        }
        guard let range = trimmed.range(of: "params=") else { return nil }
        let params = String(trimmed[range.upperBound...].split(separator: "&").first ?? "")
        return decode(params)
    }

    /// 带 auto_redirect=0 的直链 GET 回来是小 JSON：{"data":{"redirect_url":...}}，可能多跳
    private func followRedirect(_ start: String) async -> String {
        var url = start
        for _ in 0..<5 {
            guard let response = try? await HTTPClient.shared.send(url, headers: ["Referer": Self.referer, "User-Agent": Self.dartUA, "Range": "bytes=0-8191"]),
                  response.data.count <= 8192, response.text.trimmed.hasPrefix("{"),
                  let next = (try? JSON(data: response.data))?["data"]["redirect_url"].string, !next.isEmpty
            else { return url }
            url = next
        }
        return url
    }
}

/// 标准 CRC-32（IEEE 802.3）
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var c = UInt32(index)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}
