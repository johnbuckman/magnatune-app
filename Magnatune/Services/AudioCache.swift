import Foundation
import CryptoKit

/// On-device cache of streamed track files, so replays don't re-download.
/// Tracks are complete MP3/M4A files (not HLS), so we store the whole file keyed
/// by its stream URL and play it from disk next time.
final class AudioCache {
    static let shared = AudioCache()

    private let dir: URL
    private let lock = NSLock()
    private var inProgress: Set<String> = []
    private let sizeLimit: Int64 = 1_024 * 1_024 * 1_024   // 1 GB

    private init() {
        let base = try! FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true)
        dir = base.appendingPathComponent("AudioCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func filename(for remote: URL) -> String {
        let hash = SHA256.hash(data: Data(remote.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let ext = remote.pathExtension.isEmpty ? "mp3" : remote.pathExtension
        return "\(hash).\(ext)"
    }

    /// Local file URL if this stream is already cached (and non-empty).
    func cached(for remote: URL) -> URL? {
        let f = dir.appendingPathComponent(filename(for: remote))
        guard let size = try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int,
              size > 0 else { return nil }
        // touch access time for LRU eviction
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: f.path)
        return f
    }

    /// Download and store the track (if not cached / already downloading).
    func store(remote: URL, authHeader: String?) {
        let key = filename(for: remote)
        let target = dir.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: target.path) { return }

        lock.lock()
        if inProgress.contains(key) { lock.unlock(); return }
        inProgress.insert(key)
        lock.unlock()

        var req = URLRequest(url: remote)
        if let authHeader { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }

        URLSession.shared.downloadTask(with: req) { [weak self] tmp, resp, _ in
            guard let self else { return }
            defer { self.lock.lock(); self.inProgress.remove(key); self.lock.unlock() }
            guard let tmp,
                  let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return }
            try? FileManager.default.removeItem(at: target)
            do {
                try FileManager.default.moveItem(at: tmp, to: target)
                self.enforceLimit()
            } catch { }
        }.resume()
    }

    func totalSize() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    func clear() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for f in files { try? FileManager.default.removeItem(at: f) }
    }

    /// Evict least-recently-used files until under the size limit.
    private func enforceLimit() {
        guard var files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var total = totalSize()
        guard total > sizeLimit else { return }
        files.sort {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b   // oldest first
        }
        for f in files {
            if total <= sizeLimit { break }
            let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: f)
            total -= size
        }
    }
}
