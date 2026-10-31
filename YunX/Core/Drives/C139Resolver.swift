// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import CommonCrypto
import CryptoKit
import Foundation

/// 139 网盘（和彩云）分享：请求体 AES-128-CBC 加密（随机 IV 拼在密文前），响应同样加密、可能再 gzip 一层。
///
/// 列目录匿名可用；取直链（dlFromOutLinkV3）需要登录账号 + Authorization，并带 mcloud-sign 签名头。
final class C139Resolver: ShareResolver {
    static let pcUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    private static let mobileUA = "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Mobile Safari/537.36"
    private static let key = Array("PVGDwmcvfs1uV3d1".utf8)
    private static let base = "https://share-kd-njs.yun.139.com/yun-share/richlifeApp/devapp/IOutLink"

    // MARK: 登录态

    private static func cookieValue(_ cookie: String, _ name: String) -> String? {
        for part in cookie.split(separator: ";") {
            let kv = part.trimmingCharacters(in: .whitespaces)
            if kv.hasPrefix("\(name)=") {
                let value = String(kv.dropFirst(name.count + 1))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    static func isValidCookie(_ cookie: String) -> Bool {
        cookieValue(cookie, "authorization") != nil || (cookieValue(cookie, "Os_SSo_Sid") != nil && cookieValue(cookie, "RMKEY") != nil)
    }

    static func authorization(_ cookie: String) -> String? { cookieValue(cookie, "authorization") }

    private static func base64Decode(_ text: String) -> String? {
        var t = text.removingPercentEncoding ?? text
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func account(_ cookie: String) -> String? {
        if let encrypted = cookieValue(cookie, "ORCHES-I-ACCOUNT-ENCRYPT"), let decoded = base64Decode(encrypted), !decoded.isEmpty {
            return decoded
        }
        if let auth = authorization(cookie),
           let decoded = base64Decode(auth.replacingOccurrences(of: "Basic", with: "").trimmed) {
            let parts = decoded.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count > 1, !parts[1].isEmpty { return String(parts[1]) }
        }
        return cookieValue(cookie, "Login_UserNumber")
    }

    // MARK: 加解密 / 签名

    private static func aes(_ op: CCOperation, _ input: [UInt8], iv: [UInt8]) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &out, out.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(moved))
    }

    static func encrypt(_ plain: String) -> String {
        var iv = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &iv)
        let ct = aes(CCOperation(kCCEncrypt), Array(plain.utf8), iv: iv) ?? []
        return Data(iv + ct).base64EncodedString()
    }

    static func decrypt(_ b64: String) -> String? {
        guard let raw = Data(base64Encoded: b64.trimmed), raw.count > 16 else { return nil }
        let bytes = Array(raw)
        guard var plain = aes(CCOperation(kCCDecrypt), Array(bytes[16...]), iv: Array(bytes[..<16])) else { return nil }
        if plain.count > 2, plain[0] == 0x1f, plain[1] == 0x8b, let inflated = gunzip(plain) { plain = inflated }
        return String(bytes: plain, encoding: .utf8)
    }

    /// 去掉 gzip 头尾后用系统 raw DEFLATE 解压
    private static func gunzip(_ data: [UInt8]) -> [UInt8]? {
        guard data.count > 18 else { return nil }
        let flags = data[3]
        var index = 10
        if flags & 0x04 != 0, data.count > index + 2 { index += 2 + (Int(data[index]) | (Int(data[index + 1]) << 8)) }
        if flags & 0x08 != 0 { while index < data.count, data[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x10 != 0 { while index < data.count, data[index] != 0 { index += 1 }; index += 1 }
        if flags & 0x02 != 0 { index += 2 }
        guard index < data.count - 8 else { return nil }
        let deflated = Data(data[index..<(data.count - 8)]) as NSData
        return (try? deflated.decompressed(using: .zlib)).map { Array($0 as Data) }
    }

    private static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 与 JS encodeURIComponent 一致（Java URLEncoder + 若干替换），注意 `~` 会被编码
    private static func encodeURIComponent(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.*!'()")
        allowed = allowed.intersection(CharacterSet(charactersIn: Unicode.Scalar(0)...Unicode.Scalar(127)))
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    static func sign(_ body: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let ts = formatter.string(from: Date())
        let pool = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let rand = String((0..<16).map { _ in pool.randomElement()! })
        let sorted = String(encodeURIComponent(body).sorted())
        let b64 = Data(sorted.utf8).base64EncodedString()
        return "\(ts),\(rand),\(md5(md5(b64) + md5("\(ts):\(rand)")).uppercased())"
    }

    private func post(_ path: String, _ object: [String: Any], authorization: String? = nil, signed: Bool = false) async throws -> JSON {
        let plainData = try JSONSerialization.data(withJSONObject: object)
        let plain = String(decoding: plainData, as: UTF8.self)
        var headers = [
            "hcy-cool-flag": "1", "x-deviceinfo": "||3|12.27.0|||||chrome 150.0.0.0|360X444|zh-cn|||",
            "x-huawei-channelsrc": "10245500", "x-mm-source": "0002",
            "Content-Type": "application/json;charset=UTF-8", "User-Agent": Self.mobileUA,
            "Origin": "https://yun.139.com", "Referer": "https://yun.139.com/", "Accept": "application/json, text/plain, */*",
        ]
        if let authorization, !authorization.isEmpty { headers["Authorization"] = authorization }
        if signed { headers["mcloud-sign"] = Self.sign(plain) }
        let r = try await HTTPClient.shared.send("\(Self.base)/\(path)", method: "POST", headers: headers, body: Data(Self.encrypt(plain).utf8))
        if let decrypted = Self.decrypt(r.text), let json = JSON(text: decrypted) { return json }
        guard let json = try? JSON(data: r.data) else { throw ResolveError("139 响应解析失败（HTTP \(r.status)）") }
        return json
    }

    private static func check(_ json: JSON, _ fallback: String) throws {
        let code = json["resultCode"].string
        if (!code.isEmpty && code != "0") || (json["success"].exists && !json["success"].bool) {
            let desc = json["desc"].string
            throw ResolveError(desc.isEmpty ? "\(fallback)（\(code)）" : "139：\(desc)")
        }
    }

    // MARK: ShareResolver

    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession {
        let json = try await post("getOutLinkGeneral", ["getOutLinkGeneralReq": ["linkID": share.shareId, "isPasswd": 1, "account": ""] as [String: Any]])
        let general = json["data"]["getOutLinkGeneralResp"]["outLinkGeneral"][0]
        // 分享接口会直接回带提取码，用户没填时用它
        let code = (pwd ?? "").isEmpty ? general["passwd"].string : pwd!
        let title = general["lkName"].string
        return ShareSession(platform: .c139, shareId: share.shareId, token: code, title: title.isEmpty ? share.shareId : title, rootId: "root")
    }

    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile] {
        let pca = dirId.isEmpty || dirId == "0" ? "root" : dirId
        var all: [ShareFile] = []
        var begin = 1
        while begin <= 20_000 {
            let json = try await post("getOutLinkInfoV6", ["getOutLinkInfoReq": [
                "account": "", "linkID": session.shareId, "passwd": session.token, "caSrt": 1, "coSrt": 1,
                "srtDr": 0, "bNum": begin, "pCaID": pca, "eNum": begin + 199,
            ] as [String: Any]])
            try Self.check(json, "获取文件列表失败")
            let data = json["data"]
            let folders = data["caLst"].array.map {
                ShareFile(id: $0["caID"].string, name: $0["caName"].string, size: 0, isDir: true, parentId: pca,
                          modified: $0.string("udTime", "ctTime"))
            }
            let files = data["coLst"].array.map {
                ShareFile(id: $0["coID"].string, name: $0["coName"].string, size: $0["coSize"].int64,
                          isDir: $0["isdir"].exists ? $0["isdir"].bool : $0["coType"].int == 2, parentId: pca,
                          modified: $0.string("udTime", "ctTime"))
            }
            all += folders + files
            if folders.count + files.count < 200 { break }
            begin += 200
        }
        return all
    }

    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        guard let account = Self.account(cookie) else { throw ResolveError("139 网盘需要登录后才能下载，请先在「账号」页登录") }
        let json = try await post("dlFromOutLinkV3", ["dlFromOutLinkReqV3": [
            "account": account, "linkID": session.shareId, "coIDLst": ["item": [file.id]],
            "commonAccountInfo": ["account": account, "accountType": 1] as [String: Any],
        ] as [String: Any]], authorization: Self.authorization(cookie), signed: true)
        try Self.check(json, "获取下载链接失败")
        let url = json["data"]["redrUrl"].string
        guard !url.isEmpty else { throw ResolveError("139 未返回下载链接") }
        return DownloadLink(fileName: file.name, url: url, size: file.size, headers: ["User-Agent": Self.pcUA])
    }
}
