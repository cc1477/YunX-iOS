// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 夸克网盘分享解析：token → sharepage/detail 分页列目录 → file/download 取直链。
///
/// 取直链统一走「免转存」：body 带分享凭证（fids / fids_token / pwd_id / stoken），
/// - 已登录：Cookie 用账号态，不受大小限制，也不会在用户网盘里留临时目录；
/// - 未登录：游客态，服务端随响应下发 `__pugs`，下载时必须带上（缺了 CDN 返回 412），约 50MB 上限。
final class QuarkResolver: ShareResolver {
    static let apiUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 Safari/537.36 Channel/pckk_other_ch"
    private let base = "https://drive-pc.quark.cn/1/clouddrive"
    private let lock = NSLock()
    private var guestPugs = ""

    private func headers(_ cookie: String) -> [String: String] {
        var h = ["User-Agent": Self.apiUA, "Origin": "https://pan.quark.cn", "Referer": "https://pan.quark.cn/"]
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    /// 登录态校验：返回昵称，无效返回 nil
    static func fetchNickname(cookie: String) async -> String? {
        guard let response = try? await HTTPClient.shared.send(
            "https://pan.quark.cn/account/info", headers: ["Cookie": cookie, "User-Agent": apiUA]
        ), let json = try? JSON(data: response.data), json["success"].bool else { return nil }
        return json["data"]["nickname"].string
    }

    private func checked(_ response: RawResponse) throws -> JSON {
        guard let json = try? JSON(data: response.data) else {
            throw ResolveError("夸克响应解析失败（HTTP \(response.status)）")
        }
        guard json["status"].int == 200 || (json["code"].exists && json["code"].int == 0) else {
            let message = json["message"].string
            switch json["code"].int {
            case 23018: throw ResolveError("该文件超出游客可获取的大小上限（约 50MB），请先在「账号」页登录夸克网盘")
            case 31001: throw ResolveError("该分享需要登录夸克网盘后才能下载")
            default: throw ResolveError(message.isEmpty ? "夸克请求失败" : "夸克：\(message)")
            }
        }
        return json
    }

    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession {
        let body: [String: Any] = ["pwd_id": share.shareId, "passcode": pwd ?? "", "support_visit_limit_private_share": true]
        let response = try await HTTPClient.shared.postJSON("\(base)/share/sharepage/token?pr=ucpro&fr=pc", object: body, headers: headers(cookie))
        let data = try checked(response)["data"]
        let stoken = data["stoken"].string
        guard !stoken.isEmpty else { throw ResolveError("夸克未返回分享凭证，请检查提取码") }
        return ShareSession(platform: .quark, shareId: share.shareId, token: stoken,
                            title: data["title"].string.isEmpty ? "夸克分享" : data["title"].string, rootId: "0")
    }

    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile] {
        var all: [ShareFile] = []
        var page = 1
        let size = 100
        while page <= 50 {
            let url = "\(base)/share/sharepage/detail?pr=ucpro&fr=pc&pwd_id=\(session.shareId)"
                + "&stoken=\(HTTPClient.queryEncode(session.token))&pdir_fid=\(dirId)&ver=2&force=0"
                + "&_page=\(page)&_size=\(size)&_fetch_banner=0&_fetch_share=0&fetch_relate_conversation=0"
                + "&_fetch_total=1&_sort=file_type:asc,file_name:asc"
            let response = try await HTTPClient.shared.send(url, headers: headers(cookie))
            let json = try checked(response)
            let items = json["data"]["list"].array
            all += items.map { item in
                ShareFile(
                    id: item["fid"].string,
                    name: item["file_name"].string,
                    size: item["size"].int64,
                    isDir: item["dir"].bool,
                    parentId: item["pdir_fid"].string,
                    token: item["share_fid_token"].string,
                    modified: Format.date(item["updated_at"].int64 / 1000)
                )
            }
            let total = json["metadata"]["_total"].int
            if items.count < size || (total > 0 && all.count >= total) { break }
            page += 1
        }
        return all
    }

    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        let body: [String: Any] = [
            "fids": [file.id], "fids_token": [file.token], "pwd_id": session.shareId,
            "stoken": session.token, "speedup_session": "", "token": "",
        ]
        let isGuest = cookie.isEmpty
        let requestCookie = isGuest ? lock.withLock { guestPugs } : cookie
        var h = ["User-Agent": Self.apiUA]
        if !requestCookie.isEmpty { h["Cookie"] = requestCookie }
        let response = try await HTTPClient.shared.postJSON(
            "\(base)/file/download?pr=ucpro&fr=pc&sys=win32&ve=3.23.2", object: body, headers: h
        )
        // 游客态令牌与本次直链同响应绑定，必须用这次下发的那一份
        if let pugs = response.cookies["__pugs"], !pugs.isEmpty {
            lock.withLock { guestPugs = "__pugs=\(pugs)" }
        }
        let item = try checked(response)["data"][0]
        let url = item["download_url"].string
        guard !url.isEmpty else { throw ResolveError("夸克未返回下载链接") }
        let downloadCookie = isGuest ? lock.withLock { guestPugs } : cookie
        var downloadHeaders = ["User-Agent": Self.apiUA, "Referer": "https://pan.quark.cn/"]
        if !downloadCookie.isEmpty { downloadHeaders["Cookie"] = downloadCookie }
        return DownloadLink(
            fileName: item["file_name"].string.isEmpty ? file.name : item["file_name"].string,
            url: url,
            size: item["size"].int64 > 0 ? item["size"].int64 : file.size,
            headers: downloadHeaders
        )
    }
}
