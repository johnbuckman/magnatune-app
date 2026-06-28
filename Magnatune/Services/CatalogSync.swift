import Foundation

/// Downloads and refreshes the catalog SQLite database.
///
/// Flow: GET magnatune.com/info/changed.txt (a CRC). If it differs from the stored
/// value (or no catalog exists yet), download sqlite_normalized.db.gz, gunzip, and
/// atomically replace the on-disk catalog. A seed copy is bundled so the app is
/// usable offline on first launch.
final class CatalogSync {
    static let changedURL = URL(string: "http://he3.magnatune.com/info/changed.txt")!
    // Plain (uncompressed) db avoids needing a gunzip step; ~7MB on refresh.
    static let dbURL = URL(string: "http://he3.magnatune.com/info/sqlite_normalized.db")!

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
            let (tmp, _) = try await URLSession.shared.download(from: Self.dbURL)
            let raw = try Data(contentsOf: tmp)
            let target = URL(fileURLWithPath: Self.catalogPath())
            let staging = target.deletingLastPathComponent().appendingPathComponent("catalog_new.db")
            try? fm.removeItem(at: staging)
            try raw.write(to: staging)
            // basic sanity check: SQLite header
            if raw.count < 100 || !raw.prefix(15).elementsEqual(Array("SQLite format 3".utf8)) {
                try? fm.removeItem(at: staging); return false
            }
            _ = try? fm.replaceItemAt(target, withItemAt: staging)
            return true
        } catch {
            return false
        }
    }
}
