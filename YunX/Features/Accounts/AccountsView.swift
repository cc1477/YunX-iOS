// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI

struct AccountsView: View {
    @Environment(AccountStore.self) private var accounts
    @Environment(ToastCenter.self) private var toast

    @State private var loginTarget: LoginTarget?
    @State private var manualTarget: LoginTarget?
    @State private var passwordTarget: LoginTarget?
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
        var passwordLogin = false
        var id: String { key.storageKey }
    }

    private var driveEntries: [Entry] {
        SharePlatform.allCases.map {
            Entry(key: .drive($0), name: $0.displayName, logo: $0.logo, benefit: $0.loginBenefit,
                  available: $0.isAvailable, canLogin: $0.loginURL != nil || $0.usesPasswordLogin, manualOnly: false,
                  passwordLogin: $0.usesPasswordLogin)
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
            .sheet(item: $passwordTarget) { target in
                PasswordLoginView(key: target.key)
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
                        if entry.passwordLogin {
                            passwordTarget = LoginTarget(key: entry.key)
                        } else if entry.manualOnly {
                            manualTarget = LoginTarget(key: entry.key)
                        } else {
                            loginTarget = LoginTarget(key: entry.key)
                        }
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

/// 账号密码登录（123 云盘等不走网页登录的平台）
struct PasswordLoginView: View {
    let key: AccountKey
    @Environment(AccountStore.self) private var accounts
    @Environment(ToastCenter.self) private var toast
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PlatformLogo(name: key.logo, size: 64)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("手机号 / 邮箱", text: $account)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                        .textContentType(.password)
                } footer: {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red)
                    } else {
                        Text("账号密码只用于向 \(key.displayName) 官方服务器换取登录凭证，不会保存密码。")
                    }
                }
                Section {
                    Button {
                        Task { await login() }
                    } label: {
                        HStack {
                            Spacer()
                            if working { ProgressView() } else { Text("登录").bold() }
                            Spacer()
                        }
                    }
                    .disabled(working || account.trimmed.isEmpty || password.isEmpty)
                }
            }
            .navigationTitle("登录\(key.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }

    private func login() async {
        working = true
        errorText = nil
        defer { working = false }
        do {
            let token: String
            switch key {
            case .drive(.pan123): token = try await Pan123Resolver.passwordLogin(account: account, password: password)
            default: throw ResolveError("该平台不支持账号密码登录")
            }
            let nickname = await AccountStore.validate(key, cookie: token) ?? ""
            accounts.save(key, nickname: nickname, cookie: token)
            toast.show("\(key.displayName) 登录成功", .success)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
