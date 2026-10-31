// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 轻量 JSON 访问器，语义对齐安卓版 org.json 的 `optXxx`：缺字段 / JSON null 一律给默认值，不抛错。
///
/// 各平台接口字段经常「有时是字符串、有时是数字」，所以 [string] 会把数字转成文本、[int] 会把数字串转成数字。
struct JSON {
    let raw: Any?

    init(_ raw: Any?) {
        self.raw = raw is NSNull ? nil : raw
    }

    init(data: Data) throws {
        self.init(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init?(text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }
        self.init(object)
    }

    subscript(key: String) -> JSON {
        JSON((raw as? [String: Any])?[key])
    }

    subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], array.indices.contains(index) else { return JSON(nil) }
        return JSON(array[index])
    }

    var exists: Bool { raw != nil }
    var isObject: Bool { raw is [String: Any] }

    var string: String {
        switch raw {
        case let s as String: return s == "null" ? "" : s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    var int: Int {
        switch raw {
        case let n as NSNumber: return n.intValue
        case let s as String: return Int(s) ?? Int(Double(s) ?? 0)
        default: return 0
        }
    }

    var int64: Int64 {
        switch raw {
        case let n as NSNumber: return n.int64Value
        case let s as String: return Int64(s) ?? Int64(Double(s) ?? 0)
        default: return 0
        }
    }

    var bool: Bool {
        switch raw {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return s == "true" || s == "1"
        default: return false
        }
    }

    var array: [JSON] { (raw as? [Any])?.map { JSON($0) } ?? [] }
    var keys: [String] { (raw as? [String: Any]).map { Array($0.keys) } ?? [] }

    /// 依次尝试多个键名，返回第一个非空字符串（抖音字段 snake/camel 两套命名并存）
    func string(_ keys: String...) -> String {
        for key in keys {
            let value = self[key].string
            if !value.isEmpty { return value }
        }
        return ""
    }

    /// 依次尝试多个键名，返回第一个存在的节点
    func first(_ keys: String...) -> JSON {
        for key in keys where self[key].exists { return self[key] }
        return JSON(nil)
    }
}
