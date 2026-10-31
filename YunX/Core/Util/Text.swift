// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 正则小工具：安卓版大量用 Kotlin Regex 抠字段，这里给 NSRegularExpression 包一层同样顺手的接口。
enum RX {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression? {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let compiled = try? NSRegularExpression(pattern: pattern, options: options)
        cache[key] = compiled
        return compiled
    }

    /// 第一个匹配的全部分组（下标 0 为整体匹配；未参与匹配的分组为空串）
    static func groups(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> [String]? {
        guard let regex = regex(pattern, options) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            let range = match.range(at: index)
            return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
    }

    /// 第一个匹配的第 [group] 个分组
    static func first(
        _ pattern: String,
        in text: String,
        group: Int = 1,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> String? {
        guard let groups = groups(pattern, in: text, options: options), groups.indices.contains(group) else { return nil }
        let value = groups[group]
        return value.isEmpty && group > 0 ? nil : value
    }

    /// 全部匹配，每个匹配返回分组数组
    static func all(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [.caseInsensitive]
    ) -> [[String]] {
        guard let regex = regex(pattern, options) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : ns.substring(with: range)
            }
        }
    }

    static func escape(_ text: String) -> String { NSRegularExpression.escapedPattern(for: text) }
}

extension String {
    func trimmingTrailing(_ characters: String) -> String {
        var result = self
        while let last = result.last, characters.contains(last) { result.removeLast() }
        return result
    }

    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 文件名清洗：去掉非法字符与首尾空白、点号（对齐安卓 DownloadPathPolicy.sanitizeName）
    var sanitizedFileName: String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = components(separatedBy: illegal).joined(separator: "_")
        return cleaned.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
    }

    /// 截断到指定字符数（标题做文件名时用）
    func prefixString(_ count: Int) -> String { String(prefix(count)) }

    /// 协议相对 / 明文 http 统一升级为 https（各平台 CDN 同域都提供 https）
    var secureURL: String {
        if hasPrefix("//") { return "https:" + self }
        if hasPrefix("http://") { return "https://" + dropFirst("http://".count) }
        return self
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    static func date(_ seconds: Int64) -> String {
        guard seconds > 0 else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    /// 蓝奏「1.2 M」这类展示大小 → 字节数
    static func parseDisplaySize(_ text: String) -> Int64 {
        guard let groups = RX.groups(#"([\d.]+)\s*([KMGT]?)"#, in: text.trimmed),
              let value = Double(groups[1]) else { return 0 }
        let factor: Double
        switch groups[2].uppercased() {
        case "K": factor = 1024
        case "M": factor = 1024 * 1024
        case "G": factor = 1024 * 1024 * 1024
        case "T": factor = 1024 * 1024 * 1024 * 1024
        default: factor = 1
        }
        return Int64(value * factor)
    }
}
