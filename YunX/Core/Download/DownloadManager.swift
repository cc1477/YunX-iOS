// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation
import Observation
import UIKit

enum DownloadState: String, Codable {
    case queued, running, paused, completed, failed

    var label: String {
        switch self {
        case .queued: return "等待中"
        case .running: return "下载中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        case .failed: return "失败"
        }
    }
}

enum DownloadKind: String, Codable { case file, hls, dash }

struct DownloadItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var fileName: String
    var url: String
    var headers: [String: String]
    var kind: DownloadKind = .file
    var audioURL: String = ""
    var audioHeaders: [String: String] = [:]
    var source: String
    var sourceLogo: String
    var totalBytes: Int64 = 0
    var receivedBytes: Int64 = 0
    var state: DownloadState = .queued
    var errorMessage: String = ""
    var createdAt = Date()
    var completedAt: Date?
    /// 相对下载目录的文件名（完成后才有）
    var localName: String = ""
    var resumeData: Data?
    /// HLS 已完成分片数 / DASH 已完成阶段
    var stepDone: Int = 0
    var stepTotal: Int = 0

    var progress: Double {
        if kind == .hls, stepTotal > 0 { return Double(stepDone) / Double(stepTotal) }
        guard totalBytes > 0 else { return 0 }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    var fileKind: FileKind { FileKind(fileName: fileName) }
}

/// 下载管理：排队调度、并发上限、暂停/续传（URLSession resumeData）、HLS 分片、DASH 合轨，任务列表持久化为 JSON。
///
/// 下载目录在 Documents/云析 下，开启了 UIFileSharingEnabled，用户可在「文件」App 里直接看到。
@MainActor
@Observable
final class DownloadManager {
    private(set) var items: [DownloadItem] = []
    private(set) var speeds: [UUID: Double] = [:]

    @ObservationIgnored var maxConcurrent: @MainActor () -> Int = { 3 }
    @ObservationIgnored var autoSaveToPhotos: @MainActor () -> Bool = { false }
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastTick: [UUID: (time: Date, bytes: Int64)] = [:]
    @ObservationIgnored private let stateFile: URL

    static var downloadDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("云析", isDirectory: true)
    }

    private static var workDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("YunXWork", isDirectory: true)
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Self.downloadDirectory, withIntermediateDirectories: true)
        stateFile = support.appendingPathComponent("downloads.json")
        if let data = try? Data(contentsOf: stateFile), let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            // 上次被杀进程时仍在下载的任务，恢复为暂停
            items = decoded.map { item in
                var copy = item
                if copy.state == .running || copy.state == .queued { copy.state = .paused }
                return copy
            }
        }
    }

    var active: [DownloadItem] { items.filter { $0.state != .completed } }
    var completed: [DownloadItem] { items.filter { $0.state == .completed }.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) } }
    var runningCount: Int { items.filter { $0.state == .running }.count }
    var totalSpeed: Double { speeds.values.reduce(0, +) }

    func localURL(_ item: DownloadItem) -> URL? {
        guard !item.localName.isEmpty else { return nil }
        return Self.downloadDirectory.appendingPathComponent(item.localName)
    }

    // MARK: 入队

    @discardableResult
    func enqueue(_ link: DownloadLink, source: String, logo: String) -> DownloadItem {
        let item = DownloadItem(fileName: link.fileName.sanitizedFileName.isEmpty ? "download" : link.fileName.sanitizedFileName,
                                url: link.url, headers: link.headers, source: source, sourceLogo: logo, totalBytes: max(0, link.size))
        return add(item)
    }

    func enqueue(_ media: VideoMedia, result: VideoParseResult) {
        let name = media.fileName.isEmpty ? "\(result.platform.displayName)_\(Int(Date().timeIntervalSince1970))" : media.fileName
        var item = DownloadItem(fileName: name.sanitizedFileName, url: media.url, headers: media.headers,
                                source: result.platform.displayName, sourceLogo: result.platform.logo, totalBytes: max(0, media.size))
        if media.isHLS {
            item.kind = .hls
        } else if !media.audioURL.isEmpty {
            item.kind = .dash
            item.audioURL = media.audioURL
            item.audioHeaders = media.audioHeaders
            item.stepTotal = 3
        }
        add(item)
        // 动图：iOS 端把动态部分作为独立视频一并下载
        if !media.motionURL.isEmpty {
            let base = (name as NSString).deletingPathExtension
            add(DownloadItem(fileName: "\(base)_live.mp4".sanitizedFileName, url: media.motionURL, headers: media.headers,
                             source: result.platform.displayName, sourceLogo: result.platform.logo))
        }
    }

    @discardableResult
    private func add(_ item: DownloadItem) -> DownloadItem {
        items.insert(item, at: 0)
        persist()
        schedule()
        return item
    }

    // MARK: 控制

    func pause(_ id: UUID) {
        if let task = tasks[id] {
            task.cancel()
        } else {
            update(id) { $0.state = .paused }
            persist()
        }
    }

    func resume(_ id: UUID) {
        update(id) {
            $0.state = .queued
            $0.errorMessage = ""
        }
        persist()
        schedule()
    }

    func toggle(_ item: DownloadItem) {
        switch item.state {
        case .running, .queued: pause(item.id)
        case .paused, .failed: resume(item.id)
        case .completed: break
        }
    }

    func pauseAll() { items.filter { $0.state == .running || $0.state == .queued }.forEach { pause($0.id) } }
    func resumeAll() { items.filter { $0.state == .paused || $0.state == .failed }.forEach { resume($0.id) } }

    func delete(_ id: UUID, removeFile: Bool = true) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if removeFile, let item = items.first(where: { $0.id == id }), let url = localURL(item) {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0.id == id }
        speeds[id] = nil
        persist()
        schedule()
    }

    func clearCompleted(removeFiles: Bool) {
        completed.forEach { delete($0.id, removeFile: removeFiles) }
    }

    // MARK: 调度

    private func schedule() {
        let limit = max(1, maxConcurrent())
        while tasks.count < limit, let next = items.last(where: { $0.state == .queued && tasks[$0.id] == nil }) {
            start(next)
        }
    }

    private func start(_ item: DownloadItem) {
        update(item.id) { $0.state = .running }
        lastTick[item.id] = (Date(), item.receivedBytes)
        let id = item.id
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                let finalURL: URL
                switch item.kind {
                case .file: finalURL = try await self.runFile(item)
                case .hls: finalURL = try await self.runHLS(item)
                case .dash: finalURL = try await self.runDash(item)
                }
                self.finish(id, at: finalURL)
            } catch let paused as DownloadPaused {
                self.update(id) {
                    $0.state = .paused
                    $0.resumeData = paused.resumeData
                }
            } catch is CancellationError {
                self.update(id) { $0.state = .paused }
            } catch let failure as DownloadFailure {
                self.update(id) {
                    $0.state = .failed
                    $0.errorMessage = failure.message
                    $0.resumeData = failure.resumeData
                }
            } catch {
                self.update(id) {
                    $0.state = .failed
                    $0.errorMessage = error.localizedDescription
                    $0.resumeData = nil
                }
            }
            self.tasks[id] = nil
            self.speeds[id] = nil
            self.persist()
            self.schedule()
        }
        persist()
    }

    private func runFile(_ item: DownloadItem) async throws -> URL {
        let temp = Self.workDirectory.appendingPathComponent(item.id.uuidString)
        let id = item.id
        let resume = item.resumeData
        update(id) { $0.resumeData = nil }
        try await FileFetcher.shared.fetch(url: item.url, headers: item.headers, resumeData: resume, to: temp) { [weak self] written, expected in
            Task { @MainActor in self?.progress(id, received: written, total: expected) }
        }
        return temp
    }

    private func runHLS(_ item: DownloadItem) async throws -> URL {
        let temp = Self.workDirectory.appendingPathComponent(item.id.uuidString + ".ts")
        let playlist = try await HLSDownloader.playlist(url: item.url, headers: item.headers)
        let id = item.id
        update(id) { $0.stepTotal = playlist.segments.count }
        try await HLSDownloader.download(playlist, headers: item.headers, to: temp, startIndex: item.stepDone) { [weak self] done, total, bytes in
            await MainActor.run {
                self?.update(id) {
                    $0.stepDone = done
                    $0.stepTotal = total
                }
                self?.progress(id, received: bytes, total: 0)
            }
        }
        return temp
    }

    /// DASH：① 视频轨 ② 音轨 ③ 合轨；每一阶段完成后记录，暂停后从未完成的阶段继续
    private func runDash(_ item: DownloadItem) async throws -> URL {
        let work = Self.workDirectory
        let videoFile = work.appendingPathComponent("\(item.id.uuidString)_v.mp4")
        let audioFile = work.appendingPathComponent("\(item.id.uuidString)_a.m4a")
        let output = work.appendingPathComponent("\(item.id.uuidString)_out.mp4")
        let id = item.id
        var resume = item.resumeData
        update(id) { $0.resumeData = nil }

        if item.stepDone < 1 || !FileManager.default.fileExists(atPath: videoFile.path) {
            try await FileFetcher.shared.fetch(url: item.url, headers: item.headers, resumeData: resume, to: videoFile) { [weak self] w, e in
                Task { @MainActor in self?.progress(id, received: w, total: e) }
            }
            resume = nil
            update(id) { $0.stepDone = 1 }
        }
        if item.stepDone < 2 || !FileManager.default.fileExists(atPath: audioFile.path) {
            let videoSize = (try? FileManager.default.attributesOfItem(atPath: videoFile.path)[.size] as? Int64) ?? 0
            try await FileFetcher.shared.fetch(url: item.audioURL, headers: item.audioHeaders, resumeData: item.stepDone == 1 ? resume : nil, to: audioFile) { [weak self] w, e in
                Task { @MainActor in self?.progress(id, received: videoSize + w, total: e > 0 ? videoSize + e : 0) }
            }
            update(id) { $0.stepDone = 2 }
        }
        try await DashMuxer.mux(video: videoFile, audio: audioFile, output: output)
        try? FileManager.default.removeItem(at: videoFile)
        try? FileManager.default.removeItem(at: audioFile)
        update(id) { $0.stepDone = 3 }
        return output
    }

    private func progress(_ id: UUID, received: Int64, total: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .running else { return }
        items[index].receivedBytes = received
        if total > 0 { items[index].totalBytes = total }
        let now = Date()
        if let last = lastTick[id] {
            let interval = now.timeIntervalSince(last.time)
            if interval >= 0.8 {
                let instant = Double(max(0, received - last.bytes)) / interval
                speeds[id] = (speeds[id] ?? instant) * 0.4 + instant * 0.6
                lastTick[id] = (now, received)
            }
        } else {
            lastTick[id] = (now, received)
        }
    }

    private func finish(_ id: UUID, at temp: URL) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        let destination = uniqueDestination(for: item.fileName)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            update(id) {
                $0.state = .failed
                $0.errorMessage = "保存文件失败：\(error.localizedDescription)"
            }
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? item.receivedBytes
        update(id) {
            $0.state = .completed
            $0.localName = destination.lastPathComponent
            $0.completedAt = Date()
            $0.totalBytes = size
            $0.receivedBytes = size
            $0.resumeData = nil
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        let kind = item.fileKind
        if autoSaveToPhotos(), kind == .image || kind == .video {
            Task { try? await PhotoSaver.save(destination, kind: kind) }
        }
    }

    private func uniqueDestination(for name: String) -> URL {
        let dir = Self.downloadDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = dir.appendingPathComponent(name)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }

    private func update(_ id: UUID, _ change: (inout DownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: stateFile, options: .atomic)
    }
}
