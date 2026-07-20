import Foundation
import GRDB

/// Downloads and refreshes the catalog SQLite database.
///
/// Flow: GET magnatune.com/info/changed.txt (a CRC). If it differs from the
/// stored value (or no catalog exists yet), download sqlite_normalized.sql.gz —
/// a gzipped SQL dump, ~70% smaller on the wire than the uncompressed .db it
/// replaced — gunzip it, run the SQL into a fresh empty database to rebuild an
/// identical catalog, then atomically replace the on-disk catalog. A seed copy is
/// bundled so the app is usable offline on first launch.
final class CatalogSync {
    static let changedURL = URL(string: "https://magnatune.com/info/changed.txt")!
    /// Gzipped SQL `.dump` of the catalog. Smaller than the .db/.db.gz because it
    /// carries no index b-trees or page padding — we rebuild an identical sqlite
    /// locally by running the dump into an empty database.
    static let sqlDumpURL = URL(string: "https://magnatune.com/info/sqlite_normalized.sql.gz")!

    private let fm = FileManager.default
    private let crcKey = "catalog.crc"
    private let lastCheckKey = "catalog.lastCheck"
    private let seedSigKey = "catalog.seedSig"

    /// Where the live catalog db is stored in Application Support.
    static func catalogPath() -> String {
        let dir = try! FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        return dir.appendingPathComponent("magnatune_catalog.db").path
    }

    /// Ensure a catalog exists at the target path, seeding from the bundle when needed.
    ///
    /// Seeds on first launch, AND re-seeds whenever the app bundles a *different* catalog
    /// (its file size — used as a cheap signature — changed) than what we last seeded. That
    /// second case matters because the catalog content can change without the published
    /// `changed.txt` CRC moving (e.g. recommendations were added under the same CRC): without
    /// this, `refreshIfNeeded` sees crc == stored and never downloads, so a stale stored
    /// catalog would survive across app updates. After re-seeding we clear the stored CRC so
    /// the next online refresh re-evaluates against the live db (and re-pulls it if it's newer).
    func ensureSeeded() {
        let target = Self.catalogPath()
        guard let bundled = Bundle.main.url(forResource: "magnatune", withExtension: "db") else { return }
        let bundleSig = ((try? fm.attributesOfItem(atPath: bundled.path)[.size]) as? Int).map(String.init)
        let lastSig = UserDefaults.standard.string(forKey: seedSigKey)
        let haveFile = fm.fileExists(atPath: target)
        if haveFile, bundleSig != nil, bundleSig == lastSig { return }   // up to date
        do {
            try? fm.removeItem(at: URL(fileURLWithPath: target))
            try fm.copyItem(at: bundled, to: URL(fileURLWithPath: target))
            UserDefaults.standard.set(bundleSig, forKey: seedSigKey)
            UserDefaults.standard.removeObject(forKey: crcKey)   // re-check vs live next refresh
        } catch { /* keep whatever is already on disk */ }
    }

    /// Check the CRC and refresh if changed. Throttled to once / 24h unless `force`.
    /// Returns true if a new catalog was installed.
    @discardableResult
    func refreshIfNeeded(force: Bool = false) async -> Bool {
        let defaults = UserDefaults.standard
        if !force {
            let last = defaults.double(forKey: lastCheckKey)
            if last > 0, Date().timeIntervalSince1970 - last < 24 * 3600 { return false }
        }
        defaults.set(Date().timeIntervalSince1970, forKey: lastCheckKey)

        guard let crc = await fetchCRC() else { return false }
        let stored = defaults.string(forKey: crcKey)
        let haveFile = fm.fileExists(atPath: Self.catalogPath())
        guard force || crc != stored || !haveFile else { return false }

        if await downloadAndInstall() {
            defaults.set(crc, forKey: crcKey)
            return true
        }
        return false
    }

    /// Whether magnatune.com reports a newer release CRC than the installed catalog.
    /// Always hits the network (not throttled). Returns false if we can't tell yet
    /// (no stored CRC, or the check failed) to avoid a spurious "update available".
    func updateAvailable() async -> Bool {
        guard let stored = UserDefaults.standard.string(forKey: crcKey),
              let crc = await fetchCRC() else { return false }
        return crc != stored
    }

    private func fetchCRC() async -> String? {
        do {
            let (data, _) = try await URLSession.shared.data(from: Self.changedURL)
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch { return nil }
    }

    private func downloadAndInstall() async -> Bool {
        do {
            let (tmp, _) = try await URLSession.shared.download(from: Self.sqlDumpURL)
            let gz = try Data(contentsOf: tmp)
            let sqlData = try Self.gunzip(gz)
            guard let sql = String(data: sqlData, encoding: .utf8) else { return false }

            let target = URL(fileURLWithPath: Self.catalogPath())
            let staging = target.deletingLastPathComponent().appendingPathComponent("catalog_new.db")
            // clear the staging db and any stale sidecar files from a prior failed run
            for ext in ["", "-wal", "-shm", "-journal"] {
                try? fm.removeItem(at: URL(fileURLWithPath: staging.path + ext))
            }

            // Rebuild a fresh sqlite by running the SQL dump into an empty db. The
            // dump carries its own BEGIN/COMMIT, so run it WITHOUT a GRDB-managed
            // transaction (otherwise the dump's BEGIN errors as a nested txn).
            let albumCount = try Self.buildDatabase(at: staging, fromSQL: sql)
            guard albumCount > 0 else {                 // sanity check the rebuild
                try? fm.removeItem(at: staging); return false
            }

            _ = try? fm.replaceItemAt(target, withItemAt: staging)
            return true
        } catch {
            return false
        }
    }

    /// Build a SQLite database at `url` by running a SQL `.dump` script into it.
    /// Returns the album count as a cheap sanity check. The queue is released when
    /// this returns, closing the file so it can be atomically moved into place.
    private static func buildDatabase(at url: URL, fromSQL sql: String) throws -> Int {
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: sql)
        }
        return try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM albums") ?? 0
        }
    }

    /// Inflate a gzip (RFC 1952) blob. Apple's `.zlib` decompressor consumes a
    /// raw DEFLATE stream, so strip the gzip header (incl. optional fields) and
    /// the 8-byte CRC/size trailer first.
    static func gunzip(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1f, b[1] == 0x8b, b[2] == 0x08 else {
            throw GunzipError.notGzip
        }
        let flg = b[3]
        var i = 10
        if flg & 0x04 != 0 {                                   // FEXTRA
            guard i + 2 <= b.count else { throw GunzipError.truncated }
            i += 2 + (Int(b[i]) | (Int(b[i + 1]) << 8))
        }
        if flg & 0x08 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }  // FNAME
        if flg & 0x10 != 0 { while i < b.count, b[i] != 0 { i += 1 }; i += 1 }  // FCOMMENT
        if flg & 0x02 != 0 { i += 2 }                          // FHCRC
        guard i + 8 <= b.count else { throw GunzipError.truncated }
        let deflate = data.subdata(in: (data.startIndex + i) ..< (data.endIndex - 8))
        return try (deflate as NSData).decompressed(using: .zlib) as Data
    }

    enum GunzipError: Error { case notGzip, truncated }
}
