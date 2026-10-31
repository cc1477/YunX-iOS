// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation
import Observation
import Security
import SwiftUI

// MARK: - 账号（Cookie 存钥匙串）

struct Account: Codable, Hashable {
    var nickname: String
    var cookie: String
    var savedAt: Date
}

@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [String: Account] = [:]

    @ObservationIgnored private let service = "com.yunx.ios.accounts"
    @ObservationIgnored private let itemKey = "all"

    init() { load() }

    func account(_ key: AccountKey) -> Account? { accounts[key.storageKey] }
    func cookie(_ key: AccountKey) -> String { accounts[key.storageKey]?.cookie ?? "" }

    func save(_ key: AccountKey, nickname: String, cookie: String) {
        accounts[key.storageKey] = Account(nickname: nickname, cookie: cookie, savedAt: Date())
        persist()
    }

    func remove(_ key: AccountKey) {
        accounts[key.storageKey] = nil
        persist()
    }

    /// 校验 Cookie 是否有效，返回昵称；平台没有校验接口时只校验非空
    static func validate(_ key: AccountKey, cookie: String) async -> String? {
        switch key {
        case .drive(.quark): return await QuarkResolver.fetchNickname(cookie: cookie)
        case .drive(.uc): return await UCResolver.fetchNickname(cookie: cookie)
        case .drive(.pan123): return await Pan123Resolver.fetchNickname(token: cookie)
        case .drive(.baidu): return await BaiduResolver.fetchNickname(cookie: cookie)
        case .drive(.pan115): return await Pan115Resolver.fetchNickname(cookie: cookie)
        case .video(let platform):
            if let parser = VideoParseService.parsers[platform] { return await parser.validateCookie(cookie) }
            return cookie.trimmed.isEmpty ? nil : ""
        default: return cookie.trimmed.isEmpty ? nil : ""
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: itemKey]
    }

    private func load() {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let decoded = try? JSONDecoder().decode([String: Account].self, from: data) else { return }
        accounts = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(q as CFDictionary, nil)
        }
    }
}

// MARK: - 设置

enum AccentTheme: String, CaseIterable, Identifiable {
    case cloud, violet, mint, coral, amber, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .cloud: return "云蓝"
        case .violet: return "星紫"
        case .mint: return "薄荷"
        case .coral: return "珊瑚"
        case .amber: return "琥珀"
        case .graphite: return "石墨"
        }
    }

    var color: Color {
        switch self {
        case .cloud: return Color(hex: 0x4C8BF5)
        case .violet: return Color(hex: 0x7C5CFF)
        case .mint: return Color(hex: 0x14B8A6)
        case .coral: return Color(hex: 0xFF6B6B)
        case .amber: return Color(hex: 0xF59E0B)
        case .graphite: return Color(hex: 0x64748B)
        }
    }

    /// 渐变的第二个色（同色系偏移，避免花哨）
    var secondary: Color {
        switch self {
        case .cloud: return Color(hex: 0x7B61FF)
        case .violet: return Color(hex: 0xE056FD)
        case .mint: return Color(hex: 0x3B82F6)
        case .coral: return Color(hex: 0xF59E0B)
        case .amber: return Color(hex: 0xEF4444)
        case .graphite: return Color(hex: 0x1E293B)
        }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: [color, secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var name: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    @ObservationIgnored private let defaults = UserDefaults.standard

    // 被观察的存储属性 + 对外的计算属性（setter 里落盘），不依赖 @Observable 下 didSet 的行为
    private var storedAccent: AccentTheme
    private var storedAppearance: AppearanceMode
    private var storedMaxConcurrent: Int
    private var storedClipboardDetect: Bool
    private var storedAutoSaveToPhotos: Bool
    private var storedHasSeenNotice: Bool

    var accent: AccentTheme {
        get { storedAccent }
        set { storedAccent = newValue; defaults.set(newValue.rawValue, forKey: "accent") }
    }
    var appearance: AppearanceMode {
        get { storedAppearance }
        set { storedAppearance = newValue; defaults.set(newValue.rawValue, forKey: "appearance") }
    }
    var maxConcurrent: Int {
        get { storedMaxConcurrent }
        set { storedMaxConcurrent = newValue; defaults.set(newValue, forKey: "maxConcurrent") }
    }
    var clipboardDetect: Bool {
        get { storedClipboardDetect }
        set { storedClipboardDetect = newValue; defaults.set(newValue, forKey: "clipboardDetect") }
    }
    var autoSaveToPhotos: Bool {
        get { storedAutoSaveToPhotos }
        set { storedAutoSaveToPhotos = newValue; defaults.set(newValue, forKey: "autoSaveToPhotos") }
    }
    var hasSeenNotice: Bool {
        get { storedHasSeenNotice }
        set { storedHasSeenNotice = newValue; defaults.set(newValue, forKey: "hasSeenNotice") }
    }

    init() {
        let defaults = UserDefaults.standard
        storedAccent = AccentTheme(rawValue: defaults.string(forKey: "accent") ?? "") ?? .cloud
        storedAppearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        let stored = defaults.integer(forKey: "maxConcurrent")
        storedMaxConcurrent = stored == 0 ? 3 : stored
        storedClipboardDetect = defaults.object(forKey: "clipboardDetect") as? Bool ?? true
        storedAutoSaveToPhotos = defaults.bool(forKey: "autoSaveToPhotos")
        storedHasSeenNotice = defaults.bool(forKey: "hasSeenNotice")
    }
}

// MARK: - 解析历史

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var text: String
    var title: String
    var platformName: String
    var logo: String
    var date: Date
}

@MainActor
@Observable
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    @ObservationIgnored private let key = "history"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    func add(text: String, title: String, link: DetectedLink) {
        entries.removeAll { $0.text == text }
        entries.insert(HistoryEntry(text: text, title: title, platformName: link.displayName, logo: link.logo, date: Date()), at: 0)
        if entries.count > 30 { entries.removeLast(entries.count - 30) }
        persist()
    }

    func remove(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
    }
}
