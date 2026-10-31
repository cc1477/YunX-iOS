// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 蓝奏云分享解析（匿名，无需登录）：
/// 分享页 HTML → 文件夹分页（filemoreajax）/ 单文件 → 下载参数（ajaxm/ajaxfile）→ HEAD 探测直链（含 acw_sc__v2 人机校验与「验证并下载」）。
final class LanzouResolver: ShareResolver {
    private struct FolderParams { let lx: String; let fid: String; let t: String; let k: String }

    private struct SharePage {
        let shareURL: String
        let origin: String
        let title: String
        let isFolder: Bool
        let needsPwd: Bool
        let fileId: String?
        let folder: FolderParams?
        let html: String
        let singleFile: ShareFile?
    }

    static let webUA = UserAgent.chrome
    private let lock = NSLock()
    private var pages: [String: SharePage] = [:]
    private var jar: [String: [String: String]] = [:]

    // MARK: Cookie 罐（按 host）

    private func setCookie(_ host: String, _ name: String, _ value: String) {
        lock.withLock { jar[host, default: [:]][name] = value }
    }

    private func cookieHeader(_ host: String, extra: String? = nil) -> String {
        let stored = lock.withLock { jar[host] ?? [:] }
        var parts = stored.map { "\($0.key)=\($0.value)" }
        if let extra, !extra.isEmpty { parts.append(extra) }
        return parts.joined(separator: "; ")
    }

    private static func host(_ url: String) -> String { URL(string: url)?.host ?? "" }

    private static func isLanzouHost(_ host: String) -> Bool {
        RX.first(#"^(?:[a-z0-9-]+\.)*(?:lanzou[a-z0-9-]*|lan[zs]o[ux]|lanzn)\.(?:com|net|org|cn)$"#, in: host, group: 0) != nil
    }

    // MARK: ShareResolver

    func open(_ share: ParsedShare, pwd: String?, cookie: String) async throws -> ShareSession {
        let page = try await resolveShare(share.url)
        if page.needsPwd && (pwd ?? "").isEmpty {
            throw ResolveError("此蓝奏分享需要提取码，请填写后重新解析")
        }
        lock.withLock { pages[page.shareURL] = page }
        return ShareSession(platform: .lanzou, shareId: page.shareURL, token: pwd ?? "", title: page.title, rootId: "")
    }

    func list(_ session: ShareSession, dirId: String, cookie: String) async throws -> [ShareFile] {
        guard let page = lock.withLock({ pages[session.shareId] }) else {
            throw ResolveError("蓝奏分享会话已失效，请重新解析")
        }
        if page.isFolder { return try await listFolder(page, pwd: session.token) }
        return page.singleFile.map { [$0] } ?? []
    }

    func downloadLink(_ session: ShareSession, file: ShareFile, cookie: String) async throws -> DownloadLink {
        guard let page = lock.withLock({ pages[session.shareId] }) else {
            throw ResolveError("蓝奏分享会话已失效，请重新解析")
        }
        return try await shareDownloadLink(page, file: file, pwd: session.token.isEmpty ? nil : session.token)
    }

    // MARK: 分享页

    private func resolveShare(_ shareURL: String) async throws -> SharePage {
        var normalized = shareURL.trimmed
        if normalized.lowercased().hasPrefix("http://") { normalized = "https://" + normalized.dropFirst(7) }
        normalized = String(normalized.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        normalized = normalized.trimmingTrailing("/")

        let html = try await fetchPageFollowing(normalized)
        guard let url = URL(string: normalized), let host = url.host else { throw ResolveError("蓝奏分享链接无效") }
        let origin = "\(url.scheme ?? "https")://\(host)"
        let title = Self.extractTitle(html)
        let needsPwd = html.contains("请输入密码") || html.contains("id=\"pwbox\"") || html.contains("input_password")
            || html.contains("密码不正确") || html.contains("function down_p(")
        let isFolder = html.contains("filemoreajax") || html.contains("class=\"filemore\"") || html.contains("file_more")
        let fileId = RX.first(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
            ?? RX.first(#"name=["']file["']\s+value=["'](\d+)["']"#, in: html)
            ?? RX.first(#"file=(\d+)"#, in: html)
        var folder: FolderParams?
        if isFolder, let lx = Self.jsVar(html, "lx"), let t = Self.jsVar(html, "t"), let k = Self.jsVar(html, "k") {
            folder = FolderParams(lx: lx, fid: Self.jsVar(html, "fid") ?? url.lastPathComponent, t: t, k: k)
        }
        var single: ShareFile?
        if !isFolder {
            var size: Int64 = 0
            if let m = RX.groups(#"(?:文件大小|大小)\s*[:：]\s*([\d.]+)\s*([KMGT]?)(?:i?B)?"#, in: html) {
                size = Format.parseDisplaySize("\(m[1]) \(m[2])")
            }
            single = ShareFile(id: url.lastPathComponent, name: title, size: size, isDir: false)
        }
        return SharePage(shareURL: normalized, origin: origin, title: title.isEmpty ? "蓝奏分享" : title,
                         isFolder: isFolder, needsPwd: needsPwd, fileId: fileId, folder: folder, html: html, singleFile: single)
    }

    private func listFolder(_ page: SharePage, pwd: String) async throws -> [ShareFile] {
        guard let params = page.folder else { throw ResolveError("蓝奏分享分页异常，请重试") }
        var all: [ShareFile] = []
        var seen = Set<String>()
        var pg = 1
        var retries = 0
        while pg <= 500 {
            if pg > 1 || retries > 0 {
                let delay: UInt64 = retries > 0 ? UInt64(600 * (retries + 1)) : 250
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            }
            let body: JSON
            do {
                body = try await formPost("\(page.origin)/filemoreajax.php", fields: [
                    ("lx", params.lx), ("fid", params.fid), ("t", params.t), ("k", params.k), ("pwd", pwd), ("pg", "\(pg)"),
                ], referer: page.shareURL, origin: page.origin)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                retries += 1
                if retries > 2 { throw ResolveError("蓝奏请求过于频繁，请稍后再试") }
                continue
            }
            switch body["zt"].int {
            case 4:
                retries += 1
                if retries > 2 { throw ResolveError("蓝奏请求过于频繁，请稍后再试") }
                continue
            case 2: return all
            case 3: throw ResolveError("蓝奏提取码错误，请检查后重新解析")
            case 1: break
            default: throw ResolveError("蓝奏解析失败，请确认分享链接和提取码后重试")
            }
            retries = 0
            let items = body["text"].array
            if items.isEmpty { break }
            var added = 0
            for item in items {
                let reference = item["id"].string
                let id = String(reference.split(separator: "?").first ?? "")
                guard !id.isEmpty, seen.insert(id).inserted else { continue }
                let name = item["name_all"].string.isEmpty ? item["name"].string : item["name_all"].string
                all.append(ShareFile(
                    id: id, name: name.trimmed, size: Format.parseDisplaySize(item["size"].string), isDir: false,
                    token: reference.contains("?") ? "\(page.origin)/\(reference)" : "",
                    modified: item["time"].string
                ))
                added += 1
            }
            if added == 0 { throw ResolveError("蓝奏分页重复，请重新打开目录") }
            pg += 1
        }
        return all
    }

    // MARK: 取直链

    private func shareDownloadLink(_ page: SharePage, file: ShareFile, pwd: String?) async throws -> DownloadLink {
        let origin = page.origin
        let memberURL: String? = file.token.isEmpty ? nil : file.token
        var referer = memberURL ?? page.shareURL
        var html: String
        if let memberURL {
            html = try await fetchPageFollowing(memberURL)
        } else if page.isFolder {
            // 文件夹成员没有带参数的地址时，按 /<id> 打开成员分享页
            let memberPage = "\(origin)/\(file.id)"
            referer = memberPage
            html = try await fetchPageFollowing(memberPage)
        } else {
            html = page.html
        }
        if let src = RX.first(#"<iframe[^>]+src=["']([^"']+)["']"#, in: html) {
            let iframe = Self.absolutize(origin, src)
            guard Self.host(iframe).lowercased() == Self.host(referer).lowercased() else {
                throw ResolveError("蓝奏下载页面地址异常，请检查分享链接")
            }
            html = try await fetchPage(iframe, referer: referer)
            referer = iframe
        }
        let fileId = (page.isFolder ? nil : page.fileId)
            ?? RX.first(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
            ?? RX.first(#"file=(\d+)"#, in: html)
        guard let fileId else { throw ResolveError("蓝奏解析失败，请确认分享链接和提取码后重试") }

        let passwordRequired = page.needsPwd || html.contains("function down_p(")
        if passwordRequired && (pwd ?? "").isEmpty { throw ResolveError("此蓝奏分享需要提取码，请填写后重新解析") }
        let withPwd = passwordRequired && !(pwd ?? "").isEmpty
        let ajaxURL = Self.resolveAjaxURL(html, origin: origin, fileId: fileId, withPwd: withPwd)
        let downData = Self.dataObjects(html).last { $0["action"] == "downprocess" && !($0["sign"] ?? "").isEmpty }
        guard let sign = downData?["sign"] ?? Self.jsVar(html, "wp_sign") ?? Self.jsVar(html, "sign") ?? Self.inputValue(html, "sign") else {
            throw ResolveError("蓝奏分享页缺少下载参数，请重新解析")
        }
        var fields: [(String, String)] = [("action", "downprocess"), ("sign", sign)]
        if withPwd, let pwd {
            fields += [("p", pwd), ("kd", "1")]
        } else {
            let ajaxData = Self.jsVar(html, "ajaxdata") ?? downData?["signs"] ?? ""
            var key = downData?["websignkey"] ?? ""
            if key.isEmpty { key = ajaxData.isEmpty ? (Self.jsVar(html, "websignkey") ?? Self.inputValue(html, "websignkey") ?? "") : ajaxData }
            guard !key.isEmpty else { throw ResolveError("蓝奏分享页缺少下载参数，请重新解析") }
            if !ajaxData.isEmpty { fields.append(("signs", ajaxData)) }
            fields += [("websignkey", key), ("websign", downData?["websign"] ?? Self.jsVar(html, "websign") ?? ""), ("kd", "1"), ("ves", "1")]
        }
        let json = try await formPost(ajaxURL, fields: fields, referer: referer, origin: origin)
        try Self.validateAjax(json)
        let dom = json["dom"].string
        let rel = json["url"].string
        guard !dom.isEmpty, !rel.isEmpty, !rel.hasPrefix("/"), !rel.contains("://"),
              let domURL = URL(string: dom), let domHost = domURL.host else {
            throw ResolveError("蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let jump = "\(domURL.scheme ?? "https")://\(domHost)/file/\(rel)"
        let (finalURL, size) = try await probeAndVerify(jump, shareOrigin: origin)
        return DownloadLink(
            fileName: file.name.isEmpty ? json["inf"].string : file.name,
            url: finalURL,
            size: size > 0 ? size : file.size,
            headers: ["User-Agent": Self.webUA, "Referer": "\(origin)/", "Cookie": cookieHeader(Self.host(finalURL), extra: "down_ip=1")]
        )
    }

    private func probeAndVerify(_ jump: String, shareOrigin: String) async throws -> (String, Int64) {
        var url = jump
        setCookie(Self.host(jump), "down_ip", "1")
        var confirmed = Set<String>()
        var challenged = Set<String>()
        var visited = Set<String>()
        for _ in 0..<8 {
            let host = Self.host(url)
            guard !host.isEmpty else { throw ResolveError("蓝奏下载地址暂时不可用，请稍后重试") }
            guard visited.insert(url).inserted else { throw ResolveError("蓝奏下载地址循环跳转，请重新解析") }
            let response = try await HTTPClient.shared.send(url, method: "HEAD", headers: downloadHeaders(url, shareOrigin), followRedirects: false)
            switch response.status {
            case 300..<400:
                guard let location = response.header("Location") else { throw ResolveError("蓝奏下载地址暂时不可用，请稍后重试") }
                url = Self.absolutize(url, location)
            case 200, 206:
                if (response.header("Content-Type") ?? "").contains("text/html") {
                    let body = try await HTTPClient.shared.send(url, headers: downloadHeaders(url, shareOrigin)).text
                    if let challenge = Self.challengeCookie(body) {
                        guard challenged.insert(host).inserted else { throw ResolveError("蓝奏需要进一步验证，请在分享页完成验证后重试") }
                        setCookie(host, "acw_sc__v2", challenge)
                        visited.remove(url)
                        continue
                    }
                    if body.contains("验证并下载"), confirmed.insert(host).inserted, let verified = try await submitVerify(url, html: body, shareOrigin: shareOrigin) {
                        url = verified
                        continue
                    }
                    throw ResolveError("蓝奏返回的是验证页面，请稍后重试")
                }
                var size = Self.sizeFrom(response)
                if size <= 0 { size = try await rangeProbe(url, shareOrigin: shareOrigin) }
                return (url, size)
            case 403, 404, 410: throw ResolveError("蓝奏下载地址已失效，请稍后重新解析")
            case 429: throw ResolveError("蓝奏下载请求过于频繁，请稍后再试")
            default:
                let size = try await rangeProbe(url, shareOrigin: shareOrigin)
                if size > 0 { return (url, size) }
                throw ResolveError("蓝奏下载地址暂时不可用，请稍后重试")
            }
        }
        throw ResolveError("蓝奏下载地址暂时不可用，请稍后重试")
    }

    /// 提交「验证并下载」，返回新的直链地址
    private func submitVerify(_ nodeURL: String, html: String, shareOrigin: String) async throws -> String? {
        guard let node = URL(string: nodeURL), let host = node.host else { return nil }
        let data = RX.all(#"data\s*:\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}"#, in: html, options: [.dotMatchesLineSeparators])
            .map { $0[1] }
            .first { $0.contains("'file'") || $0.contains("\"file\"") }
        guard let file = data.flatMap({ RX.first(#"['"]?file['"]?\s*:\s*['"]([^'"]+)['"]"#, in: $0) })
                ?? RX.first(#"name=["']file["'][^>]*value=["']([^"']+)["']"#, in: html),
              let sign = data.flatMap({ RX.first(#"['"]?sign['"]?\s*:\s*['"]([^'"]+)['"]"#, in: $0) })
                ?? Self.jsVar(html, "sign") ?? Self.inputValue(html, "sign")
        else { return nil }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let ajax = URL(string: "ajax.php", relativeTo: node)?.absoluteString ?? "\(node.scheme ?? "https")://\(host)/ajax.php"
        guard let json = try? await formPost(ajax, fields: [("file", file), ("el", "2"), ("sign", sign)],
                                             referer: nodeURL, origin: "\(node.scheme ?? "https")://\(host)") else {
            throw ResolveError("蓝奏下载验证服务暂时不可用，请稍后重试")
        }
        let url = json["url"].string
        guard json["zt"].int == 1, !url.isEmpty else { throw ResolveError(url.isEmpty ? "蓝奏需要进一步验证，请稍后重试" : url) }
        if url == "?SignError" { throw ResolveError("蓝奏下载验证已过期，请重新解析") }
        return url
    }

    private func downloadHeaders(_ url: String, _ shareOrigin: String) -> [String: String] {
        ["User-Agent": Self.webUA, "Referer": "\(shareOrigin)/", "Cookie": cookieHeader(Self.host(url), extra: "down_ip=1")]
    }

    private func rangeProbe(_ url: String, shareOrigin: String) async throws -> Int64 {
        var headers = downloadHeaders(url, shareOrigin)
        headers["Range"] = "bytes=0-0"
        let response = try await HTTPClient.shared.send(url, headers: headers, followRedirects: false)
        guard let range = response.header("Content-Range"), let total = range.split(separator: "/").last else { return 0 }
        return Int64(total) ?? 0
    }

    private static func sizeFrom(_ response: RawResponse) -> Int64 {
        if let range = response.header("Content-Range"), let total = range.split(separator: "/").last {
            return Int64(total) ?? 0
        }
        return response.status == 200 ? Int64(response.header("Content-Length") ?? "") ?? 0 : 0
    }

    // MARK: 页面请求

    private func fetchPageFollowing(_ start: String) async throws -> String {
        var current = start
        var challenged = Set<String>()
        for _ in 0..<8 {
            let host = Self.host(current)
            var headers = ["User-Agent": Self.webUA, "Referer": current]
            let cookie = cookieHeader(host)
            if !cookie.isEmpty { headers["Cookie"] = cookie }
            let response = try await HTTPClient.shared.send(current, headers: headers, followRedirects: false)
            if (300..<400).contains(response.status) {
                guard let location = response.header("Location") else { throw ResolveError("蓝奏页面跳转次数过多，请重新解析") }
                let next = Self.absolutize(current, location)
                guard Self.isLanzouHost(Self.host(next)) else { throw ResolveError("蓝奏分享链接无效") }
                current = next
                continue
            }
            let body = response.text
            if let challenge = Self.challengeCookie(body) {
                guard challenged.insert(host).inserted else { throw ResolveError("蓝奏需要进一步验证，请稍后重试") }
                setCookie(host, "acw_sc__v2", challenge)
                continue
            }
            if body.contains("文件已取消") || body.contains("不存在") { throw ResolveError("蓝奏文件已取消分享或不存在") }
            if body.contains("请求过于频繁") || body.contains("稍后再试") { throw ResolveError("蓝奏请求过于频繁，请稍后再试") }
            return body
        }
        throw ResolveError("蓝奏页面跳转次数过多，请重新解析")
    }

    private func fetchPage(_ url: String, referer: String) async throws -> String {
        var headers = ["User-Agent": Self.webUA, "Referer": referer]
        let cookie = cookieHeader(Self.host(url))
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let response = try await HTTPClient.shared.send(url, headers: headers)
        guard response.isSuccess else { throw ResolveError("蓝奏文件已取消分享或不存在") }
        return response.text
    }

    private func formPost(_ url: String, fields: [(String, String)], referer: String, origin: String) async throws -> JSON {
        var headers = ["User-Agent": Self.webUA, "Referer": referer, "Origin": origin, "X-Requested-With": "XMLHttpRequest"]
        let cookie = cookieHeader(Self.host(url))
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let response = try await HTTPClient.shared.postForm(url, fields: fields, headers: headers, followRedirects: false)
        if response.status == 429 { throw ResolveError("蓝奏请求过于频繁，请稍后再试") }
        guard let json = try? JSON(data: response.data), json.isObject else {
            if response.text.trimmed.hasPrefix("<") { throw ResolveError("蓝奏返回了验证页面，请稍后重试") }
            throw ResolveError("蓝奏解析服务响应异常（HTTP \(response.status)），请稍后重试")
        }
        return json
    }

    private static func validateAjax(_ json: JSON) throws {
        if json["zt"].int == 1 { return }
        let inf = json["inf"].string
        if inf.contains("密码") || inf.contains("提取码") { throw ResolveError("蓝奏提取码错误，请检查后重新解析") }
        if ["不存在", "取消", "过期", "删除"].contains(where: { inf.contains($0) }) { throw ResolveError("蓝奏文件已取消分享或不存在") }
        if ["频繁", "次数", "稍后"].contains(where: { inf.contains($0) }) { throw ResolveError("蓝奏请求过于频繁，请稍后再试") }
        throw ResolveError("蓝奏解析失败，请确认分享链接和提取码后重试")
    }

    // MARK: 页面字段提取

    private static func extractTitle(_ html: String) -> String {
        if let title = RX.first(#"<title>([^<]*)</title>"#, in: html) {
            let clean = title.replacingOccurrences(of: " - 蓝奏云", with: "").replacingOccurrences(of: "蓝奏云", with: "").trimmed
            if !clean.isEmpty && !clean.contains("密码") { return clean }
        }
        if let name = RX.first(#"class=["']n["']>([^<]+)<"#, in: html) { return name.trimmed }
        return RX.first(#"var\s+filename\s*=\s*['"]([^'"]+)['"]"#, in: html) ?? ""
    }

    private static func jsVar(_ html: String, _ name: String) -> String? {
        guard let groups = RX.groups(#"(?:(?:var|let|const)\s+)?\#(name)\s*=\s*['"]([^'"]*)['"]"#, in: html, options: []) else { return nil }
        return groups[1]
    }

    private static func inputValue(_ html: String, _ name: String) -> String? {
        RX.first(#"<input[^>]*name=["']\#(name)["'][^>]*value=["']([^"']*)["']"#, in: html)
            ?? RX.first(#"<input[^>]*value=["']([^"']*)["'][^>]*name=["']\#(name)["']"#, in: html)
    }

    /// 下载接口地址：脚本里显式给出的 → domain1/domain2 → 页面里的绝对地址 → 最后才回退同源
    private static func resolveAjaxURL(_ html: String, origin: String, fileId: String, withPwd: Bool) -> String {
        if let fromScript = RX.first(#"['"]?url['"]?\s*:\s*['"]((?:\./)?[^'"]*ajax(?:m|file)\.php\?file=\d+[^'"]*)['"]"#, in: html, options: []) {
            return absolutize(origin, fromScript)
        }
        if let d1 = jsVar(html, "domain1"), d1.contains("/ajax") { return d1 }
        if let d2 = jsVar(html, "domain2"), d2.contains("/ajax") { return d2 }
        if let absolute = RX.first(#"https?://[^'"\s]+/(?:ajaxm|ajaxfile)\.php\?file=\d+"#, in: html, group: 0, options: []) { return absolute }
        return withPwd ? "\(origin)/ajaxfile.php?file=\(fileId)" : "\(origin)/ajaxm.php?file=\(fileId)"
    }

    /// 解析页面里 `data : { … }` 形式的 JS 对象（值可以是字符串、数字或同页 var 变量名）
    private static func dataObjects(_ html: String) -> [[String: String]] {
        RX.all(#"\bdata\s*:\s*\{([^{}]*)\}"#, in: html, options: [.dotMatchesLineSeparators]).map { match in
            var result: [String: String] = [:]
            let props = RX.all(#"(?:['"]([A-Za-z_][\w]*)['"]|([A-Za-z_][\w]*))\s*:\s*('(?:\\.|[^'\\])*'|"(?:\\.|[^"\\])*"|[A-Za-z_][\w]*|\d+)"#,
                               in: match[1], options: [])
            for prop in props {
                let key = prop[1].isEmpty ? prop[2] : prop[1]
                let raw = prop[3]
                if raw.hasPrefix("'") || raw.hasPrefix("\"") {
                    result[key] = String(raw.dropFirst().dropLast())
                } else if raw.allSatisfy(\.isNumber) {
                    result[key] = raw
                } else if let value = jsVar(html, raw) {
                    result[key] = value
                }
            }
            return result
        }
    }

    private static func absolutize(_ base: String, _ target: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
        guard let url = URL(string: base), let host = url.host else { return target }
        let scheme = url.scheme ?? "https"
        if target.hasPrefix("//") { return "\(scheme):\(target)" }
        if target.hasPrefix("/") { return "\(scheme)://\(host)\(target)" }
        if target.hasPrefix("?") { return "\(scheme)://\(host)\(url.path)\(target)" }
        return URL(string: target, relativeTo: URL(string: "\(scheme)://\(host)/"))?.absoluteString ?? "\(scheme)://\(host)/\(target)"
    }

    /// 页面若是 acw_sc__v2 校验页，返回应设置的 Cookie 值
    private static func challengeCookie(_ source: String) -> String? {
        guard let arg1 = RX.first(#"\barg1\s*=\s*'([0-9A-Fa-f]{40})'"#, in: source, options: []) else { return nil }
        return acwScV2(arg1)
    }

    /// 计算 acw_sc__v2（固定公开变换：按固定位置重排 40 位十六进制后与掩码逐字节异或）
    static func acwScV2(_ arg1: String) -> String {
        let pos = [15, 35, 29, 24, 33, 16, 1, 38, 10, 9, 19, 31, 40, 27, 22, 23, 25, 13, 6, 11,
                   39, 18, 20, 8, 14, 21, 32, 26, 2, 30, 7, 4, 17, 5, 3, 28, 34, 37, 12, 36]
        let mask = Array("3000176000856006061501533003690027800375")
        let chars = Array(arg1)
        var q = Array(repeating: Character("0"), count: pos.count)
        for x in chars.indices {
            for z in pos.indices where pos[z] == x + 1 { q[z] = chars[x] }
        }
        var output = ""
        var i = 0
        while i + 2 <= q.count && i + 2 <= mask.count {
            let a = Int(String(q[i..<i + 2]), radix: 16) ?? 0
            let b = Int(String(mask[i..<i + 2]), radix: 16) ?? 0
            output += String(format: "%02x", a ^ b)
            i += 2
        }
        return output
    }
}
