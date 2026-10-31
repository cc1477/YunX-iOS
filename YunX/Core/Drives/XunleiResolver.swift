// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import CryptoKit
import Foundation

/// 迅雷网盘分享：
/// - 浏览：匿名即可（drive/v1/share、share/detail）；
/// - 下载：需要网页登录态（pan.xunlei.com 的 localStorage 凭证），转存到临时目录 → 取文件直链 → 删除转存。
///
/// 每个需要登录的接口都要带 X-Captcha-Token：用网页端 client_id + 盐表签名向 shield/captcha/init 换取，约 4.5 分钟有效。
final class XunleiResolver: ShareResolver {
    static let webClientId = "Xqp0kJBXWhwaTpB6"
    private static let webVersion = "1.93.10"
    private static let webHost = "pan.xunlei.com"
    private static let salts = [
        "DVM8BRQfJWDsIE0JbH5GCUM0z0jU1yGymBTj4Eyloazv1F+w0G7ig", "T", "a1fUxfjOO1/dW++DpGupRgw9P93L",
        "aktKbp+/lQc3MvlMHIupt65LjAgJOL6ttMFvTKK+7+WKubSf9rT", "SB/ne9FQUnQmWz4Wuv9KqKfGOBOCUubpHpECxOHfD4hNoMclYA2Yq",
        "sOZFBQ8IMFy3OFjAIf/eA65iqFvS9TIKzLyrhiT6", "ZhJdLgL7MGh2GanboB0yk", "Osf", "v",
    ]
    static let appUA = "ANDROID-com.xunlei.downloadprovider/8.31.0.9726 netWorkType/5G appid/40 deviceName/Xiaomi_M2004j7ac deviceModel/M2004J7AC OSVersion/12 protocolVersion/301 platformVersion/10 sdkVersion/512000 Oauth2Client/0.9 (Linux 4_14_186-perf-gddfs8vbb238b) (JAVA 0)"
    private static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    private let pan = "https://api-pan.xunlei.com/drive/v1"
    private let lock = NSLock()
    private var captchas: [String: (token: String, expires: Date)] = [:]
    private var passCodes: [String: String] = [:]

    /// 在登录页里读 localStorage 凭证（返回 encodeURIComponent 过的 JSON；没登录返回空串）
    static let readScript = """
    (function(){try{
      var prefix='credentials_\(webClientId)';
      var sub=localStorage.getItem('current_sub');
      var raw=sub?localStorage.getItem(prefix+'@'+sub):localStorage.getItem(prefix);
      if(!raw)return '';
      var data=JSON.parse(raw);
      if(!data||typeof data!=='object'||Array.isArray(data))return '';
      try{var c=JSON.parse(localStorage.getItem('captcha_\(webClientId)')||'{}');
        if(c&&c.token&&Date.parse(c.expires_at)>Date.now())data.captcha_token=c.token;}catch(e){}
      try{var all=document.cookie.split(';');
        for(var i=0;i<all.length;i++){var s=all[i].trim();if(s.indexOf('deviceid=')!==0)continue;
          var d=decodeURIComponent(s.slice(9));data.device_id=(d.indexOf('.')>-1&&d.length>32)?d.split('.')[1].slice(0,32):d;break;}}catch(e){}
      return encodeURIComponent(JSON.stringify(data));
    }catch(e){return ''}})()
    """

    struct Tokens {
        let access: String
        let deviceId: String
        let captcha: String
        let sub: String
        let nickname: String
    }

    static func tokens(_ stored: String) -> Tokens? {
        let text = stored.removingPercentEncoding ?? stored
        guard let json = JSON(text: text) else { return nil }
        let access = json.string("access_token", "accessToken")
        guard !access.isEmpty else { return nil }
        var sub = json.string("sub", "user_id", "userId")
        if sub.isEmpty { sub = jwtField(access, "sub") }
        return Tokens(access: access, deviceId: json.string("device_id", "deviceId"),
                      captcha: json.string("captcha_token", "captchaToken"), sub: sub,
                      nickname: json.string("nick_name", "nickname", "name", "user_name"))
    }

    private static func jwtField(_ token: String, _ key: String) -> String {
        let parts = token.split(separator: ".")
        guard parts.count > 1 else { return "" }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload), let json = try? JSON(data: data) else { return "" }
        return json[key].string
    }

    /// 保存前校验：拿到凭证且 access_token 未过期
    static func validate(_ stored: String) -> String? {
        guard let t = tokens(stored) else { return nil }
        let exp = Int64(jwtField(t.access, "exp")) ?? 0
        if exp > 0 && exp < Int64(Date().timeIntervalSince1970) { return nil }
        return t.nickname
    }

    private static var guestDeviceId: String {
        let key = "xunlei.deviceid"
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty { return saved }
        let value = (0..<32).map { _ in String("0123456789abcdef".randomElement()!) }.joined()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    // MARK: 验证码令牌

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func captcha(deviceId: String, action: String, sub: String, fallback: String, force: Bool = false) async -> String {
        if !force, let cached = lock.withLock({ captchas[deviceId] }), cached.expires > Date() { return cached.token }
        let ts = Int64(Date().timeIntervalSince1970 * 1000)
        var h = "\(Self.webClientId)\(Self.webVersion)\(Self.webHost)\(deviceId)\(ts)"
        for salt in Self.salts { h = Self.md5(h + salt) }
        let body: [String: Any] = [
            "client_id": Self.webClientId, "action": action, "device_id": deviceId,
            "meta": ["username": "", "phone_number": "", "email": "", "package_name": Self.webHost,
                     "client_version": Self.webVersion, "captcha_sign": "1.\(h)", "timestamp": "\(ts)", "user_id": sub] as [String: Any],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let r = try? await HTTPClient.shared.send(
                  "https://xluser-ssl.xunlei.com/v1/shield/captcha/init", method: "POST",
                  headers: ["Accept": "*/*", "Content-Type": "text/plain;charset=UTF-8", "Origin": "https://pan.xunlei.com",
                            "Referer": "https://pan.xunlei.com/", "User-Agent": UserAgent.chrome],
                  body: data),
              let json = try? JSON(data: r.data), !json["captcha_token"].string.isEmpty else { return fallback }
        let token = json["captcha_token"].string
        let ttl = max(60, json["expires_in"].exists ? json["expires_in"].int : 300)
        lock.withLock { captchas[deviceId] = (token, Date().addingTimeInterval(TimeInterval(ttl - 30))) }
        return token
    }

    // MARK: 请求

    private func call(_ url: String, method: String = "GET", body: [String: Any]? = nil, action: String, tokens: Tokens?) async throws -> JSON {
        let deviceId = tokens?.deviceId.isEmpty == false ? tokens!.deviceId : Self.guestDeviceId
        var captchaToken = ""
        if let tokens {
            captchaToken = await captcha(deviceId: deviceId, action: action, sub: tokens.sub, fallback: tokens.captcha)
        }
        for attempt in 0..<2 {
            var headers = [
                "User-Agent": Self.webUA, "X-Device-Id": deviceId, "X-Client-Version": "8.31.0.9726",
                "Content-Type": "application/json", "Origin": "https://pan.xunlei.com", "Referer": "https://pan.xunlei.com/",
            ]
            if let tokens { headers["Authorization"] = "Bearer \(tokens.access)" }
            if !captchaToken.isEmpty { headers["X-Captcha-Token"] = captchaToken }
            let payload = try body.map { try JSONSerialization.data(withJSONObject: $0) }
            let r = try await HTTPClient.shared.send(url, method: method, headers: headers, body: payload)
            guard let json = try? JSON(data: r.data) else { throw ResolveError("迅雷响应解析失败（HTTP \(r.status)）") }
            let error = json["error"].string
            if r.isSuccess && error.isEmpty { return json["data"].isObject ? json["data"] : json }
            if r.status == 401 || error == "unauthenticated" {
                throw ResolveError("迅雷登录已过期，请在「账号」页重新登录")
            }
            if error == "captcha_invalid", attempt == 0, let tokens {
                captchaToken = await captcha(deviceId: deviceId, action: action, sub: tokens.sub, fallback: "", force: true)
                if !captchaToken.isEmpty { continue }
            }
            let message = json.string("error_description", "message")
            throw ResolveError(message.isEmpty ? (error.isEmpty ? "迅雷请求失败（HTTP \(r.status)）" : error) : "迅雷：\(message)")
        }
        throw ResolveError("迅雷验证码刷新后仍失败，请稍后重试")
    }

    private static func files(_ data: JSON) -> [ShareFile] {
        data["files"].array.map {
            ShareFile(id: $0["id"].string, name: $0["name"].string, size: $0["size"].int64,
                      isDir: $0["kind"].string == "drive#folder", parentId: $0["parent_id"].string,
                      modified: String($0["modified_time"].string.prefix(16)).replacingOccurrences(of: "T", with: " "))
        }
    }

    private func sharePage(_ shareId: String, pwd: String, pageToken: String, tokens: Tokens?) async throws -> JSON {
        let url = "\(pan)/share?share_id=\(shareId)&pass_code=\(HTTPClient.queryEncode(pwd))&limit=100"
            + "&page_token=\(HTTPClient.queryEncode(pageToken))&thumbnail_size=SIZE_SMALL"
        let data = try await call(url, action: "GET:/drive/v1/share", tokens: tokens)
        switch data["share_status"].string {
        case "PASS_CODE_EMPTY", "PASS_CODE_NEED": throw ResolveError("该迅雷分享需要提取码")
        case "PASS_CODE_ERROR": throw ResolveError("迅雷提取码错误")
        default: return data
        }
    }

    // MARK: ShareResolver

    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession {
        let code = pwd ?? ""
        lock.withLock { passCodes[share.shareId] = code }
        let data = try await sharePage(share.shareId, pwd: code, pageToken: "", tokens: Self.tokens(cookie))
        let title = data["title"].string
        return ShareSession(platform: .xunlei, shareId: share.shareId, token: data["pass_code_token"].string,
                            title: title.isEmpty ? "迅雷分享" : title, rootId: "")
    }

    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile] {
        let tokens = Self.tokens(cookie)
        let pwd = lock.withLock { passCodes[session.shareId] ?? "" }
        var all: [ShareFile] = []
        var pageToken = ""
        for _ in 0..<100 {
            let data: JSON
            if dirId.isEmpty || dirId == "0" {
                data = try await sharePage(session.shareId, pwd: pwd, pageToken: pageToken, tokens: tokens)
            } else {
                let url = "\(pan)/share/detail?share_id=\(session.shareId)&parent_id=\(dirId)"
                    + "&pass_code_token=\(HTTPClient.queryEncode(session.token))&limit=100"
                    + "&page_token=\(HTTPClient.queryEncode(pageToken))&thumbnail_size=SIZE_SMALL"
                data = try await call(url, action: "GET:/drive/v1/share/detail", tokens: tokens)
            }
            all += Self.files(data)
            pageToken = data["next_page_token"].string
            if pageToken.isEmpty { break }
        }
        return all
    }

    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        guard let tokens = Self.tokens(cookie) else { throw ResolveError("迅雷网盘需要登录后才能下载，请先在「账号」页登录") }
        // ① 临时目录
        let filter = HTTPClient.queryEncode(#"{"trashed":{"eq":false}}"#)
        let root = try await call("\(pan)/files?parent_id=&page_token=&limit=100&with_audit=true&filters=\(filter)",
                                  action: "GET:/drive/v1/files", tokens: tokens)
        var dirId = Self.files(root).first { $0.isDir && $0.name == "YunX临时转存" }?.id ?? ""
        if dirId.isEmpty {
            let created = try await call("\(pan)/files", method: "POST",
                                         body: ["kind": "drive#folder", "name": "YunX临时转存", "parent_id": "", "space": ""],
                                         action: "POST:/drive/v1/files", tokens: tokens)
            dirId = created["id"].string
        }
        guard !dirId.isEmpty else { throw ResolveError("迅雷创建临时目录失败") }
        // ② 转存
        let restored = try await call("\(pan)/share/restore", method: "POST", body: [
            "share_id": session.shareId, "pass_code_token": session.token, "parent_id": dirId,
            "ancestor_ids": [String](), "file_ids": [file.id], "specify_parent_id": true,
        ], action: "POST:/drive/v1/share/restore", tokens: tokens)
        var newId = ""
        if let trace = JSON(text: restored["params"]["trace_file_ids"].string) { newId = trace[file.id].string }
        if newId.isEmpty { newId = restored["file_id"].string }
        guard !newId.isEmpty else { throw ResolveError("迅雷转存失败（网盘空间不足时也会失败）") }
        // ③ 取直链（转存是异步的，直链为空时稍等重试）
        var url = ""
        var size = file.size
        for attempt in 0..<6 {
            if attempt > 0 { try await Task.sleep(nanoseconds: 1_000_000_000) }
            let detail = try await call("\(pan)/files/\(newId)?_magic=2021&usage=PLAY&thumbnail_size=SIZE_LARGE&with=task",
                                        action: "GET:/drive/v1/files/\(newId)", tokens: tokens)
            url = detail["links"]["application/octet-stream"]["url"].string
            if url.isEmpty { url = detail["web_content_link"].string }
            if detail["size"].int64 > 0 { size = detail["size"].int64 }
            if !url.isEmpty { break }
        }
        _ = try? await call("\(pan)/files:batchDelete", method: "POST", body: ["ids": [newId], "space": ""],
                            action: "POST:/drive/v1/files:batchDelete", tokens: tokens)
        guard !url.isEmpty else { throw ResolveError("迅雷未返回下载链接，请稍后重试") }
        // 迅雷直链必须用官方 App UA，浏览器 UA 会被 CDN 降级
        return DownloadLink(fileName: file.name, url: url, size: size, headers: ["User-Agent": Self.appUA])
    }
}
