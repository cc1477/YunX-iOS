// YunX iOS —— 移植自 CYQawa/YunX（Android），GNU AGPL-3.0-or-later
import Foundation

/// 暂停：携带 URLSession 的断点续传数据
struct DownloadPaused: Error {
    let resumeData: Data?
}

/// 基于 URLSessionDownloadTask 的单文件下载，包装成 async 接口：
/// - 进度通过闭包回调（后台线程）；
/// - 所在 Task 被取消时用 `cancel(byProducingResumeData:)` 产出续传数据并抛 [DownloadPaused]。
final class FileFetcher: NSObject, URLSessionDownloadDelegate {
    static let shared = FileFetcher()

    private final class Handler {
        let destination: URL
        let progress: (Int64, Int64) -> Void
        var continuation: CheckedContinuation<Void, Error>?
        var pending: Result<Void, Error>?
        var moveError: Error?
        var finished = false

        init(destination: URL, progress: @escaping (Int64, Int64) -> Void) {
            self.destination = destination
            self.progress = progress
        }
    }

    private var session: URLSession!
    private let lock = NSLock()
    private var handlers: [Int: Handler] = [:]

    private override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 24
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    func fetch(
        url: String,
        headers: [String: String],
        resumeData: Data?,
        to destination: URL,
        progress: @escaping (Int64, Int64) -> Void
    ) async throws {
        guard let target = URL(string: url) else { throw HTTPError.invalidURL(url) }
        var request = URLRequest(url: target)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: request)
        let handler = Handler(destination: destination, progress: progress)
        lock.withLock { handlers[task.taskIdentifier] = handler }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if let pending = handler.pending {
                    lock.unlock()
                    continuation.resume(with: pending)
                } else {
                    handler.continuation = continuation
                    lock.unlock()
                    task.resume()
                }
            }
        } onCancel: {
            task.cancel(byProducingResumeData: { [weak self] data in
                self?.complete(task.taskIdentifier, .failure(DownloadPaused(resumeData: data)))
            })
        }
    }

    private func complete(_ id: Int, _ result: Result<Void, Error>) {
        lock.lock()
        guard let handler = handlers[id], !handler.finished else { lock.unlock(); return }
        handler.finished = true
        handlers[id] = nil
        if let continuation = handler.continuation {
            handler.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            handler.pending = result
            lock.unlock()
        }
    }

    private func handler(_ id: Int) -> Handler? { lock.withLock { handlers[id] } }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        handler(downloadTask.taskIdentifier)?.progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let handler = handler(downloadTask.taskIdentifier) else { return }
        // 临时文件只在本回调内有效，必须同步移走
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            handler.moveError = HTTPError.network("服务器返回 HTTP \(http.statusCode)，直链可能已过期，请重新解析")
            return
        }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: handler.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: handler.destination.path) { try fm.removeItem(at: handler.destination) }
            try fm.moveItem(at: location, to: handler.destination)
        } catch {
            handler.moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error as? URLError, error.code == .cancelled {
            // 取消由 byProducingResumeData 回调收尾；这里兜底一次（无续传数据）
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.complete(task.taskIdentifier, .failure(DownloadPaused(resumeData: error.downloadTaskResumeData)))
            }
            return
        }
        if let error {
            let resume = (error as? URLError)?.downloadTaskResumeData
            complete(task.taskIdentifier, .failure(resume != nil ? DownloadFailure(message: error.localizedDescription, resumeData: resume) : error))
            return
        }
        let moveError = handler(task.taskIdentifier)?.moveError
        complete(task.taskIdentifier, moveError.map { .failure($0) } ?? .success(()))
    }
}

/// 失败但可续传（网络中断）
struct DownloadFailure: LocalizedError {
    let message: String
    let resumeData: Data?
    var errorDescription: String? { message }
}

extension URLError {
    var downloadTaskResumeData: Data? { userInfo[NSURLSessionDownloadTaskResumeData] as? Data }
}
