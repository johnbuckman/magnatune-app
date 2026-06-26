import Foundation

/// Member streaming quality tier. Only applies to members (the free stream is always
/// the `_spoken` announcement file). Maps to a filename suffix on the no-voice AAC stem.
enum StreamQuality: String, CaseIterable, Identifiable {
    case normal              // ~160 kbps VBR AAC  -> "<stem>.m4a"
    case lossless            // 256 kbps AAC-LC    -> "<stem>_256.m4a"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal:   return "Normal"
        case .lossless: return "Lossless"
        }
    }

    /// Short bitrate description shown beside the label in the picker.
    var detail: String {
        switch self {
        case .normal:   return "~160 kbps AAC"
        case .lossless: return "256 kbps AAC-LC"
        }
    }

    /// Suffix appended to the member (no-voice) AAC stem.
    var memberSuffix: String {
        switch self {
        case .normal:   return ""
        case .lossless: return "_256"
        }
    }

    /// UserDefaults key for the persisted choice.
    static let defaultsKey = "stream.quality"

    /// The current persisted tier (defaults to `.normal`).
    static var current: StreamQuality {
        StreamQuality(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .normal
    }
}

/// Builds all Magnatune URLs (streams, cover art, artist photos, album downloads)
/// from the catalog fields, applying correct percent-encoding.
enum URLBuilder {
    static let he3 = "he3.magnatune.com"
    static let download = "download.magnatune.com"
    static let www = "magnatune.com"

    private static func url(host: String, path: String) -> URL? {
        var c = URLComponents()
        c.scheme = "http"
        c.host = host
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.url
    }

    // MARK: Streaming

    /// AAC (.m4a) stream from the per-album path. Members get the no-announcement file at
    /// the chosen quality — `<track>.m4a` (Normal, ~160 kbps) or `<track>_256.m4a`
    /// (Lossless, 256 kbps AAC-LC). Non-members get the free `<track>_spoken.m4a` (which has
    /// the spoken announcement at the end of the track) regardless of the quality setting.
    /// The stem comes from the catalog's `mp3` field (extension swapped).
    static func streamURL(artistName: String, albumName: String, song: Song,
                          isMember: Bool, quality: StreamQuality = .normal) -> URL? {
        let file = song.mp3                              // e.g. "01-Title-artist.mp3"
        let stem = file.hasSuffix(".mp3") ? String(file.dropLast(4)) : file
        // Both served by the fast he3 server. (he3 serves the member file without auth;
        // the app only requests it when membership is verified.)
        let suffix = isMember ? quality.memberSuffix : "_spoken"
        return url(host: he3, path: "/music/\(artistName)/\(albumName)/\(stem)\(suffix).m4a")
    }

    // MARK: Cover art

    /// Album cover thumbnails Magnatune generates as cover_<N>.jpg.
    /// Sizes available: 50, 75, 100, 150, 200, 300, 400, 600, 800, 1400.
    static func coverURL(artistName: String, albumName: String, size: Int) -> URL? {
        url(host: he3, path: "/music/\(artistName)/\(albumName)/cover_\(size).jpg")
    }

    // MARK: Artist photo

    /// Sized artist thumbnails (artist_<N>.jpg: 50, 200, 420, 840) that Magnatune
    /// generates into EACH of an artist's album directories. These are tiny (a few KB)
    /// versus the full-resolution original at `artists.photo` (which can be several MB),
    /// so they're the preferred source whenever any album name for the artist is known.
    static func artistPhotoURL(artistName: String, albumName: String, size: Int) -> URL? {
        url(host: he3, path: "/music/\(artistName)/\(albumName)/artist_\(size).jpg")
    }

    /// The single full-resolution original from `artists.photo`. Large; used only as a
    /// fallback when the artist has no album to source a sized thumbnail from.
    static func artistPhotoURL(_ artist: Artist) -> URL? {
        guard let p = artist.photo, !p.isEmpty else { return nil }
        return url(host: he3, path: p)
    }

    // MARK: Album download (zip per format)

    enum DownloadFormat: String, CaseIterable, Identifiable {
        case aac, mp3, flac, wav
        var id: String { rawValue }
        var label: String {
            switch self {
            case .aac: return "AAC (smaller, good quality)"
            case .mp3: return "MP3 (compatible)"
            case .flac: return "FLAC (lossless)"
            case .wav: return "WAV (lossless, large)"
            }
        }
    }

    static func albumDownloadURL(artistName: String, albumName: String, sku: String, format: DownloadFormat) -> URL? {
        url(host: download, path: "/music/\(artistName)/\(albumName)/\(sku)-\(format.rawValue).zip")
    }

    // MARK: Quality-resolved streaming (Lossless → Normal fallback)

    /// Best stream URL for a track, transparently falling back from Lossless (`_256.m4a`)
    /// to the Normal member AAC (`.m4a`) when the 256 kbps file hasn't been encoded on the
    /// server yet. Only Lossless members trigger a probe; everyone else resolves instantly.
    /// Availability is cached for the session by `LosslessProbe`.
    static func resolvedStreamURL(artistName: String, albumName: String, song: Song,
                                  isMember: Bool, quality: StreamQuality,
                                  authHeader: String?) async -> URL? {
        guard isMember, quality == .lossless else {
            return streamURL(artistName: artistName, albumName: albumName, song: song,
                             isMember: isMember, quality: quality)
        }
        guard let lossless = streamURL(artistName: artistName, albumName: albumName, song: song,
                                       isMember: true, quality: .lossless),
              let normal = streamURL(artistName: artistName, albumName: albumName, song: song,
                                     isMember: true, quality: .normal) else { return nil }
        let exists = await LosslessProbe.shared.exists(lossless, authHeader: authHeader)
        return exists ? lossless : normal
    }
}

/// Caches, for the lifetime of the session, which Lossless (`_256.m4a`) stream URLs exist
/// on the server. Lets the app fall back to the Normal member AAC for tracks the encoder
/// hasn't yet rebuilt at 256k, without 404-ing or re-probing the same file repeatedly.
actor LosslessProbe {
    static let shared = LosslessProbe()
    private var known: [String: Bool] = [:]

    /// True if the file exists. Probes once (HTTP HEAD) and caches the result. A network
    /// error resolves to `false` so playback safely falls back to the Normal stream.
    func exists(_ url: URL, authHeader: String?) async -> Bool {
        let key = url.absoluteString
        if let cached = known[key] { return cached }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 8
        if let authHeader { req.setValue(authHeader, forHTTPHeaderField: "Authorization") }
        let ok: Bool
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            ok = (resp as? HTTPURLResponse).map { (200...399).contains($0.statusCode) } ?? false
        } catch {
            ok = false
        }
        known[key] = ok
        return ok
    }
}
