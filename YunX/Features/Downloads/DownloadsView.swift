// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import QuickLook
import SwiftUI

struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(ToastCenter.self) private var toast
    @Environment(SettingsStore.self) private var settings

    enum Segment: String, CaseIterable { case active = "进行中", completed = "已完成" }

    @State private var segment: Segment = .active
    @State private var previewURL: URL?
    @State private var confirmClear = false

    private var list: [DownloadItem] { segment == .active ? downloads.active : downloads.completed }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    summary
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Picker("", selection: $segment) {
                        ForEach(Segment.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                Section {
                    if list.isEmpty {
                        ContentUnavailableView(
                            segment == .active ? "没有进行中的任务" : "还没有下载完成的文件",
                            systemImage: segment == .active ? "arrow.down.circle.dotted" : "tray",
                            description: Text(segment == .active ? "在「解析」页粘贴链接，选择文件即可开始下载" : "下载完成的文件也可以在「文件」App › 我的 iPhone › 云析 中找到")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(list) { item in
                            DownloadRow(item: item, speed: downloads.speeds[item.id] ?? 0) {
                                if item.state == .completed {
                                    previewURL = downloads.localURL(item)
                                } else {
                                    downloads.toggle(item)
                                }
                            }
                            .contextMenu { menu(item) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    withAnimation { downloads.delete(item.id) }
                                } label: { Label("删除", systemImage: "trash") }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("下载")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { downloads.resumeAll() } label: { Label("全部开始", systemImage: "play.fill") }
                        Button { downloads.pauseAll() } label: { Label("全部暂停", systemImage: "pause.fill") }
                        Divider()
                        Button(role: .destructive) { confirmClear = true } label: { Label("清空已完成", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .quickLookPreview($previewURL)
            .confirmationDialog("清空已完成的任务", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("仅清除记录") { downloads.clearCompleted(removeFiles: false) }
                Button("清除记录并删除文件", role: .destructive) { downloads.clearCompleted(removeFiles: true) }
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().stroke(.primary.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: overallProgress)
                    .stroke(settings.accent.gradient, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut, value: overallProgress)
                Image(systemName: downloads.runningCount > 0 ? "arrow.down" : "checkmark")
                    .font(.headline)
                    .foregroundStyle(settings.accent.color)
                    .symbolEffect(.bounce, value: downloads.runningCount)
            }
            .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(downloads.runningCount > 0 ? "\(downloads.runningCount) 个任务下载中" : "下载空闲")
                    .font(.headline)
                Text(downloads.runningCount > 0 ? Format.speed(downloads.totalSpeed).ifEmpty("连接中…") : "已完成 \(downloads.completed.count) 个文件")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var overallProgress: Double {
        let running = downloads.items.filter { $0.state == .running }
        guard !running.isEmpty else { return downloads.active.isEmpty ? 1 : 0 }
        return running.map(\.progress).reduce(0, +) / Double(running.count)
    }

    @ViewBuilder
    private func menu(_ item: DownloadItem) -> some View {
        if item.state == .completed, let url = downloads.localURL(item) {
            Button { previewURL = url } label: { Label("预览", systemImage: "eye") }
            ShareLink(item: url) { Label("分享 / 存储到文件", systemImage: "square.and.arrow.up") }
            if item.fileKind == .image || item.fileKind == .video {
                Button {
                    Task {
                        do {
                            try await PhotoSaver.save(url, kind: item.fileKind)
                            toast.show("已存入相册", .success)
                        } catch {
                            toast.show(error.localizedDescription, .error)
                        }
                    }
                } label: { Label("存入相册", systemImage: "photo.on.rectangle") }
            }
        } else {
            Button { downloads.toggle(item) } label: {
                item.state == .running || item.state == .queued
                    ? Label("暂停", systemImage: "pause")
                    : Label(item.state == .failed ? "重试" : "继续", systemImage: "play")
            }
            Button { UIPasteboard.general.string = item.url } label: { Label("复制直链", systemImage: "link") }
        }
        Button(role: .destructive) { withAnimation { downloads.delete(item.id) } } label: { Label("删除", systemImage: "trash") }
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let speed: Double
    let action: () -> Void
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        HStack(spacing: 12) {
            FileIcon(kind: item.fileKind, size: 44)
                .overlay(alignment: .bottomTrailing) {
                    PlatformLogo(name: item.sourceLogo, size: 18).offset(x: 4, y: 4)
                }
            VStack(alignment: .leading, spacing: 6) {
                Text(item.fileName).font(.subheadline.weight(.medium)).lineLimit(2)
                if item.state != .completed {
                    ProgressCapsule(value: item.progress, indeterminate: item.state == .running && item.progress == 0)
                }
                HStack(spacing: 6) {
                    statusText
                    Spacer()
                    if item.state == .running, speed > 0 {
                        Text(Format.speed(speed)).monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(item.state == .failed ? Color.orange : settings.accent.color)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if item.state == .completed { action() } }
    }

    private var icon: String {
        switch item.state {
        case .running: return "pause.circle.fill"
        case .queued: return "clock.fill"
        case .paused: return "play.circle.fill"
        case .failed: return "arrow.clockwise.circle.fill"
        case .completed: return "eye.circle.fill"
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch item.state {
        case .completed:
            Text("\(Format.bytes(item.totalBytes)) · \(item.source)")
        case .failed:
            Text(item.errorMessage.isEmpty ? "下载失败" : item.errorMessage).foregroundStyle(.orange).lineLimit(2)
        default:
            if item.kind == .hls, item.stepTotal > 0 {
                Text("\(item.state.label) · 分片 \(item.stepDone)/\(item.stepTotal)")
            } else if item.kind == .dash {
                Text("\(item.state.label) · \(dashStage) · \(Format.bytes(item.receivedBytes))")
            } else if item.totalBytes > 0 {
                Text("\(item.state.label) · \(Format.bytes(item.receivedBytes)) / \(Format.bytes(item.totalBytes))")
            } else {
                Text(item.state.label)
            }
        }
    }

    private var dashStage: String {
        switch item.stepDone {
        case 0: return "视频轨"
        case 1: return "音频轨"
        default: return "合轨中"
        }
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
