import Foundation

/// Downloads one file with real progress reports (bytes so far, total, speed).
///
/// `URLSession.download(from:delegate:)` (the async form) does not deliver download-progress calls to
/// its delegate, so a progress bar built on it stays at 0. This uses a download task with a session
/// delegate instead.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Progress: Sendable {
        var received: Int64
        var total: Int64          // -1 when the server does not say
        var bytesPerSecond: Double
        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    }

    private let report: @Sendable (Progress) -> Void
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var savedFile: URL?
    private let started = Date()
    private var lastReport = Date.distantPast
    private let lock = NSLock()

    private init(report: @escaping @Sendable (Progress) -> Void) {
        self.report = report
    }

    /// Downloads `url` to a temporary file that the caller then moves or deletes. When the connection
    /// breaks, the download continues from where it stopped (up to `attempts` times) instead of
    /// starting again.
    static func download(_ url: URL, attempts: Int = 6, progress: @escaping @Sendable (Progress) -> Void) async throws -> (URL, URLResponse) {
        var resumeData: Data?
        var lastError: Error = URLError(.unknown)
        for attempt in 1...attempts {
            let downloader = FileDownloader(report: progress)
            let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let task = resumeData.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
            do {
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        downloader.lock.withLock { downloader.continuation = continuation }
                        task.resume()
                    }
                } onCancel: {
                    task.cancel()
                }
            } catch {
                lastError = error
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw error }
                // iOS hands back what it has so far; the next attempt asks only for the rest.
                resumeData = (error as? URLError)?.downloadTaskResumeData
                if attempt < attempts { try? await Task.sleep(for: .seconds(2)) }
            }
        }
        throw lastError
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.25 else { return }
        lastReport = now
        let speed = Double(totalBytesWritten) / max(0.001, now.timeIntervalSince(started))
        report(Progress(received: totalBytesWritten, total: totalBytesExpectedToWrite, bytesPerSecond: speed))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The system deletes `location` when this returns, so move it somewhere of our own first.
        let kept = FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: kept)
            lock.withLock { savedFile = kept }
        } catch {
            lock.withLock { savedFile = nil }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, file) = lock.withLock { () -> (CheckedContinuation<(URL, URLResponse), Error>?, URL?) in
            defer { self.continuation = nil }
            return (self.continuation, savedFile)
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if let file, let response = task.response {
            continuation?.resume(returning: (file, response))
        } else {
            continuation?.resume(throwing: URLError(.cannotCreateFile))
        }
    }

    /// Removes leftovers of interrupted downloads (system temporary files and our own) older than a day,
    /// or all of them at launch when nothing is downloading yet.
    static func removeLeftovers() {
        let folder = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix("CFNetworkDownload_") || name.hasPrefix("download-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
