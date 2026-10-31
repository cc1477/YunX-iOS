// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(DownloadManager.self) private var downloads
    @Environment(HistoryStore.self) private var history
    @Environment(ToastCenter.self) private var toast

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "1.0") (\(info?["CFBundleVersion"] as? String ?? "1"))"
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    aboutCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                Section("外观") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("主题色")
                        HStack(spacing: 0) {
                            ForEach(AccentTheme.allCases) { theme in
                                Button {
                                    withAnimation(.snappy) { settings.accent = theme }
                                } label: {
                                    VStack(spacing: 6) {
                                        Circle()
                                            .fill(theme.gradient)
                                            .frame(width: 34, height: 34)
                                            .overlay {
                                                if settings.accent == theme {
                                                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                                                }
                                            }
                                            .overlay(Circle().strokeBorder(.white.opacity(settings.accent == theme ? 0.9 : 0), lineWidth: 2))
                                            .shadow(color: theme.color.opacity(settings.accent == theme ? 0.5 : 0), radius: 6, y: 3)
                                        Text(theme.name).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    Picker("深色模式", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { Text($0.name).tag($0) }
                    }
                }

                Section {
                    Stepper(value: $settings.maxConcurrent, in: 1...6) {
                        LabeledContent("同时下载", value: "\(settings.maxConcurrent) 个")
                    }
                    Toggle("完成后自动存入相册", isOn: $settings.autoSaveToPhotos)
                    LabeledContent("保存位置", value: "文件 › 我的 iPhone › 云析")
                } header: {
                    Text("下载")
                } footer: {
                    Text("图片和视频开启自动存入相册后，下载完成会同时保存一份到系统相册。")
                }

                Section("解析") {
                    Toggle("识别剪贴板中的链接", isOn: $settings.clipboardDetect)
                    Button("清空解析历史", role: .destructive) {
                        history.clear()
                        toast.show("已清空解析历史", .success)
                    }
                    .disabled(history.entries.isEmpty)
                }

                Section("关于") {
                    LabeledContent("版本", value: version)
                    Link(destination: URL(string: "https://github.com/CYQawa/YunX")!) {
                        LabeledContent("原项目（Android）") { Image(systemName: "arrow.up.right.square") }
                    }
                    LabeledContent("开源协议", value: "GNU AGPL-3.0")
                }

                Section {
                    Text("云析永远免费开源。如果你是在任何地方「花钱买到」的，说明你被骗了，请立即退款。本应用仅供学习交流，所解析内容的版权归原作者及平台所有，请遵守各平台用户协议。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("设置")
        }
    }

    private var aboutCard: some View {
        HStack(spacing: 14) {
            Image("AppLogo")
                .resizable()
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("云析 YunX").font(.title3.bold())
                Text("网盘 / 视频解析下载 · iOS 版").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Tag(text: "已完成 \(downloads.completed.count)", color: settings.accent.color)
                    Tag(text: "开源免费", color: .green)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(settings.accent.gradient.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
