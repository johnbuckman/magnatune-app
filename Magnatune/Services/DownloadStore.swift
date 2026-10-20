import Foundation

/// Persistent, never-evicted on-device store of fully downloaded tracks, keyed by
/// song id. Distinct from `AudioCache` (a 1 GB LRU cache of *streamed* files):
/// downloads live here so favorites stay playable offline and are never purged to
/// make room. Files are complete Opus (.opus) copies — the same format the app streams, so
/// offline favorites play Opus too. (Legacy AAC .m4a downloads are purged on launch and
/// re-downloaded as Opus.)
final class DownloadStore: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadStore()
    static let sessionID = "com.magnatune.player.downloads"

    private let dir: URL
    private let lock = NSLock()
    /// Song ids with a transfer queued or running on the background session.
    private var inProgress: Set<Int64> = []

    /// Main-queue callbacks: a song's first bytes arrived / its transfer ended
    /// (ok = the file is on disk; cancelled = we cancelled it, not a failure).
    var onStarted: ((Int64) -> Void)?
    var onFinished: ((Int64, _ ok: Bool, _ cancelled: Bool) -> Void)?
    /// Set by the app delegate when iOS relaunches us to deliver background-session events.
    var backgroundCompletionHandler: (() -> Void)?

    /// Background session: transfers keep running while the app is suspended and wait for
    /// connectivity instead of failing.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        let base = try! FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
        dir = base.appendingPathComponent("Downloads", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Purge legacy downloads (128k MP3 and AAC .m4a) now that downloads are Opus (.opus);
        // favorites re-download in the new format on demand.
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "mp3" || f.pathExtension == "m4a" {
                try? FileManager.default.removeItem(at: f)
            }
        }
    }

    private func file(for songID: Int64) -> URL {
        dir.appendingPathComponent("\(songID).opus")
    }

    /// Whether a non-empty download exists for this song.
    func isDownloaded(_ songID: Int64) -> Bool {
        let f = file(for: songID)
        guard let size = try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int else { return false }
        return size > 0
    }

    /// Local file URL for a downloaded song, or nil if not downloaded.
    func localURL(for songID: Int64) -> URL? {
        isDownloaded(songID) ? file(for: songID) : nil
    }

    /// The set of all currently-downloaded song ids (parsed from the directory).
    func downloadedIDs() -> Set<Int64> {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out = Set<Int64>()
        for f in files where f.pathExtension == "opus" {
            if let id = Int64(f.deletingPathExtension().lastPathComponent) { out.insert(id) }
        }
        return out
    }

    /// Queue one song for download on the background session. The system runs the transfer
    /// even while the app is suspended, and holds it until a network is available, so the
    /// queue survives airplane mode and app switches. Completion arrives via `onFinished`.
    /// No-op when it's already on disk or already queued.
    func enqueue(songID: Int64, remote: URL, authHeader: String?) {
        if isDownloaded(songID) { return }
        lock.lock()
        let fresh = inProgress.insert(songID).inserted
        lock.unlock()
        guard fresh else { return }
        var req = URLRequest(url: remote)
        if let authHeader { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        let task = session.downloadTask(with: req)
        task.taskDescription = String(songID)
        task.resume()
    }

    /// Cancel queued/running downloads for these songs (e.g. un-favorited).
    func cancel(_ songIDs: Set<Int64>) {
        guard !songIDs.isEmpty else { return }
        session.getAllTasks { tasks in
            for t in tasks where songIDs.contains(Int64(t.taskDescription ?? "") ?? -1) { t.cancel() }
        }
    }

    func cancelAll() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }

    /// Re-adopt transfers the system kept running while the app wasn't (so they aren't
    /// queued twice), then call back on the main queue with their song ids.
    func adoptPendingTasks(_ done: @escaping (Set<Int64>) -> Void) {
        session.getAllTasks { [weak self] tasks in
            let ids = Set(tasks.filter { $0.state != .completed }.compactMap { Int64($0.taskDescription ?? "") })
            self?.lock.lock(); self?.inProgress.formUnion(ids); self?.lock.unlock()
            DispatchQueue.main.async { done(ids) }
        }
    }

    // MARK: URLSessionDownloadDelegate (called on the session's delegate queue)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        // First bytes: report the song as actively downloading (not just queued).
        guard totalBytesWritten == bytesWritten, let id = Int64(downloadTask.taskDescription ?? "") else { return }
        DispatchQueue.main.async { self.onStarted?(id) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns, so move it into place now.
        guard let id = Int64(downloadTask.taskDescription ?? ""),
              let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200,
              ((try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int) ?? 0) > 1000
        else { return }
        let target = file(for: id)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.moveItem(at: location, to: target)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = Int64(task.taskDescription ?? "") else { return }
        lock.lock(); inProgress.remove(id); lock.unlock()
        let cancelled = (error as? URLError)?.code == .cancelled
        let ok = isDownloaded(id)
        DispatchQueue.main.async { self.onFinished?(id, ok, cancelled) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let handler = self.backgroundCompletionHandler
            self.backgroundCompletionHandler = nil
            handler?()
        }
    }

    func remove(_ songID: Int64) {
        try? FileManager.default.removeItem(at: file(for: songID))
    }

    func totalSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func count() -> Int {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "opus" }.count) ?? 0
    }

    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}

/// Per-song state of the favorites auto-download queue, for the UI.
enum DownloadState {
    case downloaded, downloading, queued, failed
}

/// Observable status of the favorites auto-download queue, driven by
/// `AppModel.syncAutoDownloads`. A separate object (not on `AppModel`) so the frequent
/// queue updates only re-render views that show download status.
@MainActor
final class DownloadProgress: ObservableObject {
    /// Every song the favorites imply, in favorites order (songs, then albums, then artists).
    @Published private(set) var targetIDs: [Int64] = []
    @Published private(set) var downloadedIDs: Set<Int64> = []
    @Published private(set) var queuedIDs: Set<Int64> = []
    @Published private(set) var failedIDs: Set<Int64> = []
    @Published private(set) var downloadingIDs: Set<Int64> = []
    /// True while songs are waiting but there's no network to fetch them.
    @Published private(set) var pausedOffline = false

    func state(of songID: Int64) -> DownloadState? {
        if downloadingIDs.contains(songID) { return .downloading }
        if downloadedIDs.contains(songID) { return .downloaded }
        if failedIDs.contains(songID) { return .failed }
        if queuedIDs.contains(songID) { return .queued }
        return nil
    }

    /// Roll-up for a group of songs (an album or artist): how many of those the favorites
    /// keep are downloaded. Nil when none of them is a download target.
    func summary(of songIDs: [Int64]) -> (done: Int, total: Int, failed: Int)? {
        var done = 0, total = 0, failed = 0
        for id in songIDs {
            guard let s = state(of: id) else { continue }
            total += 1
            if s == .downloaded { done += 1 } else if s == .failed { failed += 1 }
        }
        return total == 0 ? nil : (done, total, failed)
    }

    var pendingCount: Int { queuedIDs.count + failedIDs.count + downloadingIDs.count }

    func setTargets(_ ids: [Int64], downloaded: Set<Int64>) {
        targetIDs = ids
        downloadedIDs = downloaded
        let wanted = Set(ids)
        failedIDs.formIntersection(wanted)
        downloadingIDs.formIntersection(wanted)
        downloadingIDs.subtract(downloaded)
        queuedIDs = wanted.subtracting(downloaded).subtracting(failedIDs).subtracting(downloadingIDs)
    }
    func begin(_ id: Int64) {
        guard targetIDs.contains(id) else { return }
        downloadingIDs.insert(id); queuedIDs.remove(id); failedIDs.remove(id)
    }
    func finish(_ id: Int64, ok: Bool) {
        downloadingIDs.remove(id)
        queuedIDs.remove(id)
        if ok { downloadedIDs.insert(id) } else if targetIDs.contains(id) { failedIDs.insert(id) }
    }
    func retryFailed() { queuedIDs.formUnion(failedIDs); failedIDs = [] }
    func setPausedOffline(_ v: Bool) { if pausedOffline != v { pausedOffline = v } }
    func clear() {
        targetIDs = []; downloadedIDs = []; queuedIDs = []; failedIDs = []
        downloadingIDs = []; pausedOffline = false
    }
}
