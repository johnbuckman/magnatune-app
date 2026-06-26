import Foundation

/// Persistent, never-evicted on-device store of fully downloaded tracks, keyed by
/// song id. Distinct from `AudioCache` (a 1 GB LRU cache of *streamed* files):
/// downloads live here so favorites stay playable offline and are never purged to
/// make room. Files are the same complete AAC (.m4a) files the streamer plays.
final class DownloadStore {
    static let shared = DownloadStore()

    private let dir: URL
    private let lock = NSLock()
    private var inProgress: Set<Int64> = []

    private init() {
        let base = try! FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
        dir = base.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Purge obsolete 128k MP3 downloads now that streams/downloads are AAC (.m4a);
        // favorites re-download in the new format on demand.
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "mp3" { try? FileManager.default.removeItem(at: f) }
        }
    }

    private func file(for songID: Int64) -> URL {
        dir.appendingPathComponent("\(songID).m4a")
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
        for f in files where f.pathExtension == "m4a" {
            if let id = Int64(f.deletingPathExtension().lastPathComponent) { out.insert(id) }
        }
        return out
    }

    /// Download one song's file to permanent storage. Returns true on success
    /// (or if already present). Safe to call concurrently — duplicates are skipped.
    @discardableResult
    func downloadAsync(songID: Int64, remote: URL, authHeader: String?) async -> Bool {
        if isDownloaded(songID) { return true }

        lock.lock()
        if inProgress.contains(songID) { lock.unlock(); return false }
        inProgress.insert(songID)
        lock.unlock()
        defer { lock.lock(); inProgress.remove(songID); lock.unlock() }

        var req = URLRequest(url: remote)
        if let authHeader { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        do {
            let (tmp, resp) = try await URLSession.shared.download(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let target = file(for: songID)
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: tmp, to: target)
            return true
        } catch {
            return false
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
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "m4a" }.count) ?? 0
    }

    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }
}
