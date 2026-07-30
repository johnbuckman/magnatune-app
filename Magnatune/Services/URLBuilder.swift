import Foundation

/// Member streaming quality tier. Only applies to members (the free stream is always the
/// `_spoken` announcement file). Both tiers stream Ogg Opus (the server's `.opus` / `_hi.opus`),
/// which AVFoundation on this OS decodes — so iOS uses the same Opus tiers as the web and
/// Android clients. AAC is only a fallback, applied by `AudioPlayer` if Opus fails to play.
enum StreamQuality: String, CaseIterable, Identifiable {
    case normal              // 96 kbps Opus  -> "<stem>.opus"     (falls back to "<stem>.m4a")
    case high                // 192 kbps Opus -> "<stem>_hi.opus"  (falls back to "<stem>.m4a")

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .high:   return "High"
        }
    }

    /// Short format/bitrate description shown beside the label in the picker.
    var detail: String {
        switch self {
        case .normal: return "96 kbps Opus"
        case .high:   return "192 kbps Opus"
        }
    }

    /// The Opus file the app streams for members at this tier. (AAC is only the fallback,
    /// applied by `AudioPlayer` if the Opus stream fails to play — see `handleItemFailure`.)
    var memberFile: (suffix: String, ext: String) {
        switch self {
        case .normal: return ("", "opus")     // 96 kbps Opus
        case .high:   return ("_hi", "opus")  // 192 kbps Opus
        }
    }

    /// The AAC (`.m4a`) file streamed as the fallback when Opus can't play on this device
    /// (`AudioPlayer` sets `allowOpus: false` after an Opus item fails). Not used unless the
    /// tier's Opus file fails to decode.
    var aacFallbackFile: (suffix: String, ext: String) {
        switch self {
        case .normal: return ("", "m4a")       // 185 kbps AAC
        case .high:   return ("_256", "m4a")   // 256 kbps AAC
        }
    }

    /// Non-member (free) stream: the end-of-track announcement. Opus (40 kbps) is streamed by
    /// default — same as the member tiers — with the AAC file as the playback-failure fallback
    /// (`AudioPlayer` sets `allowOpus: false` after an Opus item fails to decode).
    static let freeOpusFile: (suffix: String, ext: String) = ("_spoken", "opus")  // 40 kbps Opus advert
    static let freeFile:     (suffix: String, ext: String) = ("_spoken", "m4a")   // AAC advert (Opus fallback)

    /// UserDefaults key for the persisted choice.
    static let defaultsKey = "stream.quality"

    /// The current persisted tier. Defaults to **Normal** (96 kbps Opus); the retired
    /// "lossless" (256 kbps AAC) selection is treated as High.
    static var current: StreamQuality {
        switch UserDefaults.standard.string(forKey: defaultsKey) {
        case "high", "lossless": return .high
        default:                 return .normal   // "normal", unset, or anything else
        }
    }
}

/// Builds all Magnatune URLs (streams, cover art, artist photos, album downloads)
/// from the catalog fields, applying correct percent-encoding.
enum URLBuilder {
    /// Everything is served same-origin over HTTPS by navim4's `/music` handler on
    /// magnatune.com — the old `he3.magnatune.com` / `download.magnatune.com` hosts are retired.
    /// Cover art, artist photos and the `_spoken` advert stream are free; the clean member
    /// audio and album downloads are gated behind HTTP Basic (see `Credentials`).
    static let host = "magnatune.com"

    private static func url(path: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"
        c.host = host
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.url
    }

    // MARK: Streaming

    /// Build a media URL for a track from a `(suffix, extension)` file spec — e.g.
    /// `("_hi", "opus")` → `<stem>_hi.opus`, `("", "m4a")` → `<stem>.m4a`. The stem comes from
    /// the catalog's `mp3` field (extension swapped). Same-origin on magnatune.com; the clean
    /// member files are HTTP Basic gated (see `Credentials`), the `_spoken` advert is free.
    private static func mediaURL(artistName: String, albumName: String, song: Song,
                                 suffix: String, ext: String) -> URL? {
        let file = song.mp3                              // e.g. "01-Title-artist.mp3"
        let stem = file.hasSuffix(".mp3") ? String(file.dropLast(4)) : file
        return url(path: "/music/\(artistName)/\(albumName)/\(stem)\(suffix).\(ext)")
    }

    // MARK: Cover art

    /// Album cover thumbnails Magnatune generates as cover_<N>.jpg.
    /// Sizes available: 50, 75, 100, 150, 200, 300, 400, 600, 800, 1400.
    static func coverURL(artistName: String, albumName: String, size: Int) -> URL? {
        url(path: "/music/\(artistName)/\(albumName)/cover_\(size).jpg")
    }

    // MARK: Artist photo

    /// Sized artist thumbnails (artist_<N>.jpg: 50, 200, 420, 840) that Magnatune
    /// generates into EACH of an artist's album directories. These are tiny (a few KB)
    /// versus the full-resolution original at `artists.photo` (which can be several MB),
    /// so they're the preferred source whenever any album name for the artist is known.
    static func artistPhotoURL(artistName: String, albumName: String, size: Int) -> URL? {
        url(path: "/music/\(artistName)/\(albumName)/artist_\(size).jpg")
    }

    /// The single full-resolution original from `artists.photo`. Large; used only as a
    /// fallback when the artist has no album to source a sized thumbnail from.
    static func artistPhotoURL(_ artist: Artist) -> URL? {
        guard let p = artist.photo, !p.isEmpty else { return nil }
        return url(path: p)
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
        url(path: "/music/\(artistName)/\(albumName)/\(sku)-\(format.rawValue).zip")
    }

    /// Whole-album download via the magnatune membership endpoint (opens in a browser, which
    /// handles the member login). format ∈ vbr/mp3/aac/alac/flac/ogg/wav.
    static func albumMembershipDownloadURL(sku: String, format: String) -> URL? {
        var c = URLComponents()
        c.scheme = "https"; c.host = host; c.path = "/membership/download3"
        c.queryItems = [URLQueryItem(name: "sku", value: sku), URLQueryItem(name: "format", value: format)]
        return c.url
    }

    /// Single-song download — the per-track file (ext ∈ mp3/ogg/wav/flac/m4a). Member-gated
    /// by the same-origin /music handler, so it opens in a browser that can authenticate.
    static func songDownloadURL(artistName: String, albumName: String, song: Song, ext: String) -> URL? {
        let file = song.mp3
        let stem = file.hasSuffix(".mp3") ? String(file.dropLast(4)) : file
        return url(path: "/music/\(artistName)/\(albumName)/\(stem).\(ext)")
    }

    // MARK: Quality-resolved streaming (Opus, with AAC fallback on playback failure)

    /// The stream URL for a track. Members get the Opus file for their tier; non-members get
    /// the free `_spoken.opus` advert (also Opus now). When `allowOpus` is false — set by
    /// `AudioPlayer` after an Opus stream has actually failed to play on this device — members
    /// get the tier's AAC file and non-members get the `_spoken.m4a` advert instead. There is deliberately NO pre-flight existence probe: a genuinely missing or
    /// undecodable Opus file is caught by the playback-failure fallback in
    /// `AudioPlayer.handleItemFailure`, which tests real playback (not just a HEAD), adds no
    /// latency, and — unlike a HEAD probe — can't be defeated by an auth/transport hiccup that
    /// would otherwise wrongly demote every track to AAC.
    static func resolvedStreamURL(artistName: String, albumName: String, song: Song,
                                  isMember: Bool, quality: StreamQuality,
                                  allowOpus: Bool = true) -> URL? {
        let file: (suffix: String, ext: String)
        if isMember {
            file = allowOpus ? quality.memberFile : quality.aacFallbackFile
        } else {
            file = allowOpus ? StreamQuality.freeOpusFile : StreamQuality.freeFile
        }
        return mediaURL(artistName: artistName, albumName: albumName, song: song, suffix: file.suffix, ext: file.ext)
    }

    /// Permanent-download URL for a track: the Opus file for the tier, matching what the app
    /// streams so offline "keep" copies play the same format. `DownloadStore` stores it under
    /// the file's real extension (`.opus`).
    static func downloadStreamURL(artistName: String, albumName: String, song: Song,
                                  quality: StreamQuality) -> URL? {
        let f = quality.memberFile
        return mediaURL(artistName: artistName, albumName: albumName, song: song, suffix: f.suffix, ext: f.ext)
    }

    /// Human label of the audio actually being streamed, derived from the resolved file name:
    /// `_hi.opus` → "Opus · 192 kbps", plain `.opus` → "Opus · 96 kbps",
    /// `_256.m4a` → "AAC · 256 kbps", plain `.m4a` → "AAC · 185 kbps",
    /// `_spoken.*` → "… · preview" (the free advert stream).
    static func formatLabel(forStreamURL url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let isOpus = url.pathExtension.lowercased() == "opus"
        let codec = isOpus ? "Opus" : "AAC"
        if stem.hasSuffix("_spoken") { return "\(codec) · preview" }
        let kbps = stem.hasSuffix("_hi") ? 192
                 : stem.hasSuffix("_256") ? 256
                 : (isOpus ? 96 : 185)
        return "\(codec) · \(kbps) kbps"
    }
}
