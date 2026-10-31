// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// UC 网盘分享解析：与夸克同一套接口结构，域名 / 参数 / UA 不同。
///
/// - 列目录必须用 `transfer_share/detail`（带 stoken），返回的 share_fid_token 与 stoken 绑定，download 才能通过校验；
/// - 取链无需转存；登录态下视频优先走 `video_preview` 取原画直链（绕过非会员下载被换成宣传片）；
/// - 未登录走游客态：服务端随响应下发 `__pugs`，下载时必须带上（缺了 CDN 403）。
final class UCResolver: ShareResolver {
    static let webUA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    static let guestUA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) uc-cloud-drive/2.5.20 Chrome/100.0.4896.160 Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    static let guestSecChUa = #""Not=A?Brand";v="99", "Chromium";v="100", "Google Chrome";v="100""#
    private let base = "https://pc-api.uc.cn/1/clouddrive"
    private let origin = "https://drive.uc.cn"
    private let videoExts: Set<String> = ["mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "m3u8", "wmv", "rmvb"]
    private let lock = NSLock()
    private var guestPugs = ""

    static func fetchNickname(cookie: String) async -> String? {
        guard let response = try? await HTTPClient.shared.send(
            "https://drive.uc.cn/account/info", headers: ["Cookie": cookie, "User-Agent": webUA]
        ), let json = try? JSON(data: response.data), json["success"].bool else { return nil }
        return json["data"]["nickname"].string
    }

    private func checked(_ response: RawResponse) throws -> JSON {
        guard let json = try? JSON(data: response.data) else {
            throw ResolveError("UC 响应解析失败（HTTP \(response.status)）")
        }
        guard json["status"].int == 200 || (json["code"].exists && json["code"].int == 0) else {
            switch json["code"].int {
            case 31001: throw ResolveError("该分享需要登录 UC 网盘后才能下载")
            case 23018: throw ResolveError("该文件超出游客可获取的大小上限，请先在「账号」页登录 UC 网盘")
            case 14001: throw ResolveError("分享已失效或提取码有误，请重新解析")
            case 41020: throw ResolveError("文件令牌已过期，请重新解析分享")
            default:
                let message = json["message"].string
                throw ResolveError(message.isEmpty ? "UC 请求失败" : "UC：\(message)")
            }
        }
        return json
    }

    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession {
        var headers = ["User-Agent": Self.webUA]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let body: [String: Any] = ["pwd_id": share.shareId, "passcode": pwd ?? "", "share_for_transfer": true]
        let response = try await HTTPClient.shared.postJSON("\(base)/share/sharepage/token?pr=UCBrowser&fr=pc", object: body, headers: headers)
        let data = try checked(response)["data"]
        let stoken = data["stoken"].string
        guard !stoken.isEmpty else { throw ResolveError("UC 未返回分享凭证，请检查提取码") }
        return ShareSession(platform: .uc, shareId: share.shareId, token: stoken,
                            title: data["title"].string.isEmpty ? "UC 分享" : data["title"].string, rootId: "0")
    }

    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile] {
        var headers = ["User-Agent": Self.webUA, "Origin": "https://fast.uc.cn", "Referer": "https://fast.uc.cn/"]
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        var all: [ShareFile] = []
        let size = 50
        for page in 1...100 {
            let url = "\(base)/transfer_share/detail?entry=ft&fr=pc&pr=UCBrowser&pwd_id=\(session.shareId)&pdir_fid=\(dirId)"
                + "&fetch_file_list=1&passcode=&_page=\(page)&_size=\(size)&_fetch_total=1&_fetch_task=1&_fetch_share=1&_sort="
                + "&stoken=\(HTTPClient.queryEncode(session.token))"
            let response = try await HTTPClient.shared.send(url, headers: headers)
            let data = try checked(response)["data"]
            let items = data["list"].exists ? data["list"].array : data["detail_info"]["list"].array
            all += items.map { item in
                ShareFile(
                    id: item["fid"].string, name: item["file_name"].string, size: item["size"].int64,
                    isDir: item["dir"].bool, parentId: item["pdir_fid"].string,
                    token: item["share_fid_token"].string, modified: Format.date(item["updated_at"].int64 / 1000)
                )
            }
            if items.count < size { break }
        }
        return all
    }

    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        let isGuest = cookie.isEmpty
        let ext = (file.name as NSString).pathExtension.lowercased()
        if !isGuest, videoExts.contains(ext), let preview = await videoPreview(session, file: file, cookie: cookie) {
            return preview
        }
        let body: [String: Any] = ["fids": [file.id], "pwd_id": session.shareId, "stoken": session.token, "fids_token": [file.token]]
        var headers: [String: String]
        if isGuest {
            headers = ["User-Agent": Self.guestUA, "Sec-Ch-Ua": Self.guestSecChUa]
            let pugs = lock.withLock { guestPugs }
            if !pugs.isEmpty { headers["Cookie"] = pugs }
        } else {
            headers = ["User-Agent": Self.webUA, "Cookie": cookie]
        }
        let response = try await HTTPClient.shared.postJSON("\(base)/file/download?entry=ft&fr=pc&pr=UCBrowser", object: body, headers: headers)
        if let pugs = response.cookies["__pugs"], !pugs.isEmpty {
            lock.withLock { guestPugs = "__pugs=\(pugs)" }
        }
        let item = try checked(response)["data"][0]
        let url = item["download_url"].string
        guard !url.isEmpty else { throw ResolveError("UC 未返回下载链接") }
        return DownloadLink(
            fileName: file.name.isEmpty ? item["file_name"].string : file.name,
            url: url,
            size: item["size"].int64 > 0 ? item["size"].int64 : file.size,
            headers: downloadHeaders(cookie: isGuest ? lock.withLock { guestPugs } : cookie, guest: isGuest)
        )
    }

    /// OSS 直链按 Referer 档位限速：缺 Referer 被限到 ~100KB/s，补官方 Web 客户端同款 Referer/Origin 即满速
    private func downloadHeaders(cookie: String, guest: Bool) -> [String: String] {
        var h = ["Referer": "\(origin)/", "Origin": origin]
        if guest {
            h["User-Agent"] = Self.guestUA
            h["Sec-Ch-Ua"] = Self.guestSecChUa
        } else {
            h["User-Agent"] = Self.webUA
        }
        if !cookie.isEmpty { h["Cookie"] = cookie }
        return h
    }

    private func videoPreview(_ session: ShareSession, file: ShareFile, cookie: String) async -> DownloadLink? {
        let url = "\(base)/share/sharepage/video_preview?pr=UCBrowser&fr=h5"
            + "&pwd_id=\(HTTPClient.queryEncode(session.shareId))&stoken=\(HTTPClient.queryEncode(session.token))"
            + "&fid=\(HTTPClient.queryEncode(file.id))&fid_token=\(HTTPClient.queryEncode(file.token))"
        guard let response = try? await HTTPClient.shared.send(url, headers: [
            "Cookie": cookie, "User-Agent": Self.webUA, "Origin": origin, "Referer": "\(origin)/",
        ]), let json = try? JSON(data: response.data),
              json["status"].int == 200 || json["code"].int == 0 else { return nil }
        let info = json["data"]["play_info"]
        let direct = info["url"].string
        guard !direct.isEmpty else { return nil }
        return DownloadLink(fileName: file.name, url: direct, size: info["size"].int64 > 0 ? info["size"].int64 : file.size,
                            headers: downloadHeaders(cookie: cookie, guest: false))
    }
}
