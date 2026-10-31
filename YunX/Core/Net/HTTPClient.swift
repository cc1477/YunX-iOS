// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 一次请求的原始响应（需要读 Location / Set-Cookie / Content-Range 时用）。
struct RawResponse {
    let status: Int
    let data: Data
    /// 响应头，键统一小写
    let headers: [String: String]
    let finalURL: URL?
    /// 拆分后的 Set-Cookie（name=value）
    let cookies: [String: String]

    var text: String { String(decoding: data, as: UTF8.self) }
    var isSuccess: Bool { (200..<300).contains(status) }
    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

enum HTTPError: LocalizedError {
    case invalidURL(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的地址：\(url)"
        case .network(let message): return "网络请求失败：\(message)"
        }
    }
}

/// 全局 HTTP 客户端。
///
/// ★ 不使用系统 Cookie 存储：各平台的 Cookie 由调用方显式拼进请求头（与安卓版 OkHttp 一致），
///   否则 A 平台下发的 Cookie 会悄悄带到 B 平台请求里，排查起来非常痛苦。
final class HTTPClient {
    static let shared = HTTPClient()

    private let follow: URLSession
    private let noFollow: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 90
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        follow = URLSession(configuration: config)
        noFollow = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func send(
        _ urlString: String,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil,
        followRedirects: Bool = true,
        timeout: TimeInterval = 20
    ) async throws -> RawResponse {
        guard let url = URL(string: urlString) else { throw HTTPError.invalidURL(urlString) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.httpBody = body
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let session = followRedirects ? follow : noFollow
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw HTTPError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.network("非 HTTP 响应")
        }
        var lowered: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            lowered["\(key)".lowercased()] = "\(value)"
        }
        var cookies: [String: String] = [:]
        let fields = http.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: url) {
            cookies[cookie.name] = cookie.value
        }
        return RawResponse(status: http.statusCode, data: data, headers: lowered, finalURL: http.url, cookies: cookies)
    }

    /// POST application/x-www-form-urlencoded
    func postForm(
        _ url: String,
        fields: [(String, String)],
        headers: [String: String] = [:],
        followRedirects: Bool = true
    ) async throws -> RawResponse {
        var merged = headers
        merged["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        return try await send(url, method: "POST", headers: merged, body: Self.formEncode(fields), followRedirects: followRedirects)
    }

    /// POST application/json
    func postJSON(
        _ url: String,
        object: Any,
        headers: [String: String] = [:]
    ) async throws -> RawResponse {
        var merged = headers
        merged["Content-Type"] = "application/json"
        let body = try JSONSerialization.data(withJSONObject: object)
        return try await send(url, method: "POST", headers: merged, body: body)
    }

    static func formEncode(_ fields: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let text = fields.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
        return Data(text.utf8)
    }

    static func queryEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 常用 UA
enum UserAgent {
    /// 桌面 Chrome：多数站点的分享页用桌面 UA 返回完整 SSR
    static let chrome =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    /// iPhone Safari：抖音分享页走 iOS UA 返回的 SSR 结构最稳
    static let iPhone =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}
