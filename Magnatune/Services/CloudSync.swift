import Foundation

/// Cloud storage of member settings (todo 10355013029) + per-member "Recommended" (10355065694).
///
/// The member's favorites / dislikes / recently-played / prefs live in the local SQLite user
/// store, so they don't follow the member across devices — and they don't reach the web player,
/// which keeps the same data in browser localStorage. This mirrors a client-neutral JSON blob to
/// the server (`/membership/settings`), pulled+merged on launch/login and pushed on change
/// (debounced, only-if-changed, at most once a minute). The web player and this app share the
/// SAME catalog with the SAME numeric ids, so the blob is portable between them.
///
/// SCOPE: this app syncs the portable, set-union keys — favorites, dislikes, recentlyPlayed, and
/// the scalar prefs it has (theme, hideDislikes). It does NOT try to merge the web's `playlists`
/// into its own auto-increment playlist ids (different id space — a blind union would corrupt
/// them); those keys are round-tripped untouched via `base` so the web keeps its playlists and
/// nothing is lost. Favorites/dislikes union and never delete, matching the web player exactly.
@MainActor
final class CloudSync: ObservableObject {
    private weak var userStore: UserStore?
    private let credentials: Credentials

    /// Cap on recently-played ids in the blob (matches the web player's RECENT_CAP).
    private let recentCap = 100
    /// Never POST more than once a minute.
    private let minInterval: TimeInterval = 60
    /// Scalar prefs and their defaults — a fresh device with a default value adopts the
    /// member's remote choice; an explicit local choice wins.
    private let scalarDefaults: [String: Any] = ["hideDislikes": true, "theme": "system"]

    private var rev = 0
    private var lastHash = ""
    private var base: [String: Any] = [:]
    private var lastPush = Date.distantPast
    private var pushTask: Task<Void, Never>?
    private var pulling = false

    /// Called on the main actor after a pull adopts remote scalar prefs, so the live UI values
    /// (AppModel.hideDislikes, the appearance @AppStorage) update immediately. Set by AppModel.
    var onAdoptScalars: ((_ theme: String, _ hideDislikes: Bool) -> Void)?

    init(userStore: UserStore, credentials: Credentials) {
        self.userStore = userStore
        self.credentials = credentials
        rev = UserDefaults.standard.integer(forKey: "sync.rev")
        lastHash = UserDefaults.standard.string(forKey: "sync.hash") ?? ""
        base = (UserDefaults.standard.dictionary(forKey: "sync.base")) ?? [:]
    }

    private var settingsURL: URL? { URL(string: "https://\(URLBuilder.host)/membership/settings") }

    // MARK: Blob build / merge / adopt

    /// The synced keys as a plain JSON object built from the local stores + prefs. schema=1.
    private func localBlob() -> [String: Any] {
        guard let u = userStore else { return ["schema": 1] }
        return [
            "schema": 1,
            "favorites": [
                "song": u.favoriteIDs(kind: "song"),
                "album": u.favoriteIDs(kind: "album"),
                "artist": u.favoriteIDs(kind: "artist"),
            ],
            "dislikes": [
                "song": u.dislikeIDs(kind: "song"),
                "album": u.dislikeIDs(kind: "album"),
                "artist": u.dislikeIDs(kind: "artist"),
                "genre": u.dislikeIDs(kind: "genre"),
            ],
            "hideDislikes": localHideDislikes,
            "theme": localTheme,
            "recentlyPlayed": u.recentlyPlayedSongIDs(limit: recentCap),
        ]
    }

    /// What we upload: last-known remote (preserves keys other clients set, e.g. the web's
    /// playlists / download-format prefs) with our own known keys overlaid.
    private func buildBlob() -> [String: Any] {
        var m = base
        for (k, v) in localBlob() { m[k] = v }
        return m
    }

    private var localTheme: String { UserDefaults.standard.string(forKey: AppAppearance.key) ?? "system" }
    private var localHideDislikes: Bool { UserDefaults.standard.object(forKey: AppModel.hideDislikesKey) as? Bool ?? true }

    /// Merge a remote blob (from another device) into local. Sets union; recently-played
    /// recency-merged (local first — this device is "now"); scalars keep an explicit local
    /// choice but adopt remote when local is still the default.
    private func merge(local: [String: Any], remote: [String: Any]) -> [String: Any] {
        var m = remote                              // start from remote so unknown keys survive
        for (k, v) in local { m[k] = v }            // local overrides its own known keys
        m["schema"] = 1
        m["favorites"] = unionKinds(local["favorites"], remote["favorites"], ["song", "album", "artist"])
        m["dislikes"]  = unionKinds(local["dislikes"],  remote["dislikes"],  ["song", "album", "artist", "genre"])
        m["recentlyPlayed"] = Array(uniqInts(intArray(local["recentlyPlayed"]) + intArray(remote["recentlyPlayed"])).prefix(recentCap))
        for k in ["hideDislikes", "theme"] {
            let lv = local[k], rv = remote[k]
            let isDefault = lv == nil || anyEqual(lv, scalarDefaults[k])
            m[k] = (!isDefault) ? lv! : (rv ?? lv ?? scalarDefaults[k]!)
        }
        return m
    }

    /// Overwrite local stores/prefs from a merged blob (union import — never deletes local data).
    private func adopt(_ b: [String: Any]) {
        guard let u = userStore else { return }
        if let fav = b["favorites"] as? [String: Any] {
            for k in ["song", "album", "artist"] { u.importFavorites(kind: k, ids: intArray(fav[k])) }
        }
        if let dis = b["dislikes"] as? [String: Any] {
            for k in ["song", "album", "artist", "genre"] { u.importDislikes(kind: k, ids: intArray(dis[k])) }
        }
        u.importRecentlyPlayed(songIDs: intArray(b["recentlyPlayed"]))
        let theme = (b["theme"] as? String) ?? "system"
        let hide = (b["hideDislikes"] as? Bool) ?? true
        UserDefaults.standard.set(theme, forKey: AppAppearance.key)          // @AppStorage picks this up
        UserDefaults.standard.set(hide, forKey: AppModel.hideDislikesKey)
        onAdoptScalars?(theme, hide)
    }

    // MARK: Pull / push

    /// Pull the member's cloud settings, merge into local, and push the union back.
    func pull() async {
        guard credentials.isMember, !pulling, let url = settingsURL, let auth = credentials.basicAuthHeader() else { return }
        pulling = true
        defer { pulling = false }
        var req = URLRequest(url: url)
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["ok"] as? Bool == true else { return }
        rev = (obj["rev"] as? Int) ?? 0
        if let remote = obj["data"] as? [String: Any] {
            base = remote
            adopt(merge(local: localBlob(), remote: remote))
        } else {
            base = [:]
        }
        lastHash = ""                    // force a reconcile push if local adds anything
        persistMeta()
        await push(immediate: true)      // push the merged union back up
    }

    /// Note that a synced value changed; schedules a debounced push (members only).
    func markDirty() { schedulePush() }

    private func schedulePush() {
        guard credentials.isMember else { return }
        guard hash(buildBlob()) != lastHash else { return }
        let wait = max(0, minInterval - Date().timeIntervalSince(lastPush))
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            if Task.isCancelled { return }
            await self?.push(immediate: false)
        }
    }

    /// Flush any pending change now (called when the app backgrounds).
    func flush() { Task { await push(immediate: true) } }

    private func push(immediate: Bool) async {
        guard credentials.isMember, let url = settingsURL, let auth = credentials.basicAuthHeader() else { return }
        let blob = buildBlob()
        let h = hash(blob)
        guard h != lastHash else { return }
        guard let json = try? JSONSerialization.data(withJSONObject: blob, options: [.sortedKeys]),
              let jsonStr = String(data: json, encoding: .utf8) else { return }
        lastPush = Date()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("rev=\(rev)&data=\(formEncode(jsonStr))".utf8)
        req.timeoutInterval = 20
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        if r["ok"] as? Bool == true {
            rev = (r["rev"] as? Int) ?? rev
            base = blob
            lastHash = h
            persistMeta()
        } else if r["conflict"] as? Bool == true {
            // Another device advanced the row — merge its blob and retry.
            rev = (r["rev"] as? Int) ?? 0
            if let remote = r["data"] as? [String: Any] { base = remote; adopt(merge(local: localBlob(), remote: remote)) }
            lastHash = ""
            persistMeta()
            await push(immediate: true)
        }
    }

    private func persistMeta() {
        UserDefaults.standard.set(rev, forKey: "sync.rev")
        UserDefaults.standard.set(lastHash, forKey: "sync.hash")
        UserDefaults.standard.set(base, forKey: "sync.base")
    }

    // MARK: JSON helpers

    private func intArray(_ any: Any?) -> [Int64] {
        guard let arr = any as? [Any] else { return [] }
        return arr.compactMap { ($0 as? NSNumber)?.int64Value ?? ($0 as? Int).map(Int64.init) }
    }

    private func uniqInts(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>(), out: [Int64] = []
        for id in ids where seen.insert(id).inserted { out.append(id) }
        return out
    }

    private func unionKinds(_ a: Any?, _ b: Any?, _ kinds: [String]) -> [String: [Int64]] {
        let da = a as? [String: Any] ?? [:]
        let db = b as? [String: Any] ?? [:]
        var out: [String: [Int64]] = [:]
        for k in kinds { out[k] = uniqInts(intArray(da[k]) + intArray(db[k])) }
        return out
    }

    private func anyEqual(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case let (x as Bool, y as Bool): return x == y
        case let (x as String, y as String): return x == y
        case let (x as NSNumber, y as NSNumber): return x == y
        default: return false
        }
    }

    /// Stable content hash of the blob (sorted-keys JSON), to skip no-op pushes. Uses a fixed
    /// FNV-1a over the bytes — NOT Swift's per-process-seeded `hashValue`, so the persisted
    /// `lastHash` still matches on the next launch and we don't push an unchanged blob every time.
    private func hash(_ obj: [String: Any]) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "" }
        var h: UInt64 = 1469598103934665603
        for b in d { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "\(d.count):\(h)"
    }

    private func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// Per-member "Recommended" — server-side recs built from the member's Recently Played,
/// reusing the same album-similarity as "You might also like" (server `/membership/recommended`).
/// Members only, honors dislikes; the server caches per member for 24h so this just POSTs the
/// seeds+exclusions and maps the returned SKUs back to catalog albums.
enum Recommendations {
    /// POST the seeds and exclusion lists; return the recommended album SKUs in server order,
    /// or nil on any failure (so the caller can show a friendly message).
    static func fetch(seeds: [String], excludeAlbums: [String], excludeArtists: [String],
                      excludeGenres: [String], credentials: Credentials) async -> [String]? {
        guard credentials.isMember,
              let url = URL(string: "https://\(URLBuilder.host)/membership/recommended"),
              let auth = credentials.basicAuthHeader() else { return nil }
        func enc(_ list: [String]) -> String {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return (list.joined(separator: "|")).addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("seeds=\(enc(seeds))&xalbums=\(enc(excludeAlbums))&xartists=\(enc(excludeArtists))&xgenres=\(enc(excludeGenres))".utf8)
        req.timeoutInterval = 25
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["ok"] as? Bool == true else { return nil }
        let albums = obj["albums"] as? [[String: Any]] ?? []
        return albums.compactMap { $0["sku"] as? String }
    }
}
