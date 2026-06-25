import Foundation

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

    /// 128 kbps MP3 stream. Members get the no-announcement (_nospeech) version;
    /// everyone else gets the free (with-announcement) file.
    static func streamURL(for song: Song, isMember: Bool) -> URL? {
        let file = song.mp3                              // e.g. "01-Title-artist.mp3"
        let stem = file.hasSuffix(".mp3") ? String(file.dropLast(4)) : file
        if isMember {
            return url(host: download, path: "/all/\(stem)_nospeech.mp3")
        } else {
            return url(host: he3, path: "/all/\(file)")
        }
    }

    // MARK: Cover art

    /// Sizes available: 50, 100, 200, 300, 600, 1400.
    static func coverURL(artistName: String, albumName: String, size: Int) -> URL? {
        url(host: he3, path: "/music/\(artistName)/\(albumName)/cover_\(size).jpg")
    }

    // MARK: Artist photo

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
}
