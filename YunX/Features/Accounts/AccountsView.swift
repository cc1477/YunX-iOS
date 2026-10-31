// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI

struct AccountsView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(ToastCenter.self) private var toast

    @State private var loginTarget: LoginTarget?
    @State private var manualTarget: LoginTarget?
    @State private var logoutTarget: AccountKey?

    struct LoginTarget: Identifiable {
        let key: AccountKey
        var id: String { key.storageKey }
    }

    private struct Entry: Identifiable {
        let key: AccountKey
        let name: String
        let logo: String
        let benefit: String
        let available: Bool
        let canLogin: Bool
        let manualOnly: Bool
        var id: String { key.storageKey }
    }

    private var driveEntries: [Entry] {
        SharePlatform.allCases.map {
            Entry(key: .drive($0), name: $0.displayName, logo: $0.logo, benefit: $0.loginBenefit,
                  available: $0.isAvailable, canLogin: $0.loginURL != nil, manualOnly: false)
        }
        .sorted { $0.available && !$1.available }
    }

    private var videoEntries: [Entry] {
        VideoPlatform.allCases.map {
            Entry(key: .video($0), name: $0.displayName, logo: $0.logo, benefit: $0.loginBenefit,
                  available: $0.isAvailable, canLogin: $0.needsLogin, manualOnly: $0.manualCookieOnly)
        }
        .sorted { ($0.available ? 0 : 1, $0.canLogin ? 1 : 0) < ($1.available ? 0 : 1, $1.canLogin ? 1 : 0) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(driveEntries) { row($0) }
                } header: {
                    Text("网盘")
                } footer: {
                    Text("登录信息仅保存在本机钥匙串中，不会上传到任何服务器。")
                }
                Section("视频平台") {
                    ForEach(videoEntries) { row($0) }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("账号")
            .sheet(item: $loginTarget) { target in
                WebLoginView(key: target.key) { manualTarget = target }
            }
            .sheet(item: $manualTarget) { target in
                ManualCookieView(key: target.key)
            }
            .confirmationDialog("退出登录", isPresented: Binding(get: { logoutTarget != nil }, set: { if !$0 { logoutTarget = nil } }), titleVisibility: .visible) {
                Button("退出", role: .destructive) {
                    if let key = logoutTarget {
                        accounts.remove(key)
                        toast.show("已退出\(key.displayName)", .info)
                    }
                }
            } message: {
                Text("将删除本机保存的登录信息")
            }
        }
    }

    private func row(_ entry: Entry) -> some View {
        let account = accounts.account(entry.key)
        return HStack(spacing: 14) {
            PlatformLogo(name: entry.logo, size: 44, dimmed: !entry.available)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.name).font(.body.weight(.semibold))
                    if !entry.available { Tag(text: "即将支持", color: .orange) }
                    if let account {
                        Tag(text: account.nickname.isEmpty ? "已登录" : account.nickname, color: .green)
                    }
                }
                Text(entry.benefit).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if entry.available && entry.canLogin {
                if account != nil {
                    Button("退出") { logoutTarget = entry.key }
                        .buttonStyle(ChipButtonStyle(tint: .red))
                } else {
                    Button("登录") {
                        if entry.manualOnly { manualTarget = LoginTarget(key: entry.key) } else { loginTarget = LoginTarget(key: entry.key) }
                    }
                    .buttonStyle(ChipButtonStyle())
                }
            } else if entry.available {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

/// 手动填写 Cookie（Pixiv 只能这样登录；其它平台作为网页登录失败时的备用方案）
struct ManualCookieView: View {
    let key: AccountKey
    @Environment(AccountStore.self) private var accounts
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss
    @State private var cookie = ""
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $cookie)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(minHeight: 180)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Cookie")
                } footer: {
                    Text("在电脑浏览器登录 \(key.displayName) 后，打开开发者工具 › 网络，复制任意请求头里的完整 Cookie 粘贴到这里。"
                         + (key.requiredCookies.isEmpty ? "" : "需要包含 \(key.requiredCookies.joined(separator: "、"))。"))
                }
            }
            .navigationTitle("填写 \(key.displayName) Cookie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if checking {
                        ProgressView()
                    } else {
                        Button("保存") { Task { await save() } }.disabled(cookie.trimmed.isEmpty)
                    }
                }
            }
        }
    }

    private func save() async {
        let value = cookie.trimmed.replacingOccurrences(of: "\n", with: "")
        checking = true
        defer { checking = false }
        guard let nickname = await AccountStore.validate(key, cookie: value) else {
            toast.show("Cookie 校验未通过，请确认已登录且复制完整", .error)
            return
        }
        accounts.save(key, nickname: nickname, cookie: value)
        toast.show("\(key.displayName) 登录成功", .success)
        dismiss()
    }
}
