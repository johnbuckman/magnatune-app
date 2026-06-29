import Foundation
import GRDB

// MARK: - Catalog records (read-only, from the downloaded magnatune SQLite db)

struct Artist: Identifiable, Codable, Hashable, FetchableRecord, TableRecord {
    static let databaseTableName = "artists"
    var id: Int64
    var name: String
    var description: String?
    var homepage: String?
    var bio: String?
    var photo: String?
    var society: String?
    var page: String?          // artist URL slug (e.g. "beth_quist"); optional → safe pre/post catalog regen

    enum CodingKeys: String, CodingKey {
        case id = "artists_id"
        case name, description, homepage, bio, photo, society, page
    }
}

struct Album: Identifiable, Codable, Hashable, FetchableRecord, TableRecord {
    static let databaseTableName = "albums"
    var id: Int64
    var artistId: Int64
    var name: String
    var description: String?
    var sku: String
    var releaseDate: Int64?
    var popularity: Int?
    var itunesBuyUrl: String?

    enum CodingKeys: String, CodingKey {
        case id = "album_id"
        case artistId = "artist_id"
        case name, description, sku
        case releaseDate = "release_date"
        case popularity
        case itunesBuyUrl = "itunes_buy_url"
    }

    var releaseDateValue: Date? {
        guard let releaseDate, releaseDate > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(releaseDate))
    }
}

struct Song: Identifiable, Codable, Hashable, FetchableRecord, TableRecord {
    static let databaseTableName = "songs"
    var id: Int64
    var albumId: Int64
    var name: String
    var trackNo: Int?
    var duration: Int?
    var mp3: String

    enum CodingKeys: String, CodingKey {
        case id = "song_id"
        case albumId = "album_id"
        case name
        case trackNo = "track_no"
        case duration, mp3
    }

    var durationText: String {
        guard let duration, duration > 0 else { return "--:--" }
        return String(format: "%d:%02d", duration / 60, duration % 60)
    }
}

struct Genre: Identifiable, Codable, Hashable, FetchableRecord, TableRecord {
    static let databaseTableName = "genres"
    var id: Int64
    var name: String
    enum CodingKeys: String, CodingKey { case id = "genre_id", name }
}

/// A "tag" in the UI — the website's "Tagged as:" values live in the collections table.
struct Tag: Identifiable, Codable, Hashable, FetchableRecord, TableRecord {
    static let databaseTableName = "collections"
    var id: Int64
    var name: String
    enum CodingKeys: String, CodingKey { case id = "collections_id", name }
}

/// A Magnatune-curated playlist from the catalog (distinct from the user's own playlists).
struct CatalogPlaylist: Identifiable, Codable, Hashable, FetchableRecord, TableRecord {
    static let databaseTableName = "playlists"
    var id: Int64
    var name: String
    var sortOrder: Int?
    var ownerId: Int64?
    enum CodingKeys: String, CodingKey {
        case id = "playlist_id", name
        case sortOrder = "sort_order"
        case ownerId = "owner_id"
    }
}

// A song joined with the context needed to build URLs and Now Playing info.
struct PlayableTrack: Identifiable, Hashable {
    var song: Song
    var album: Album
    var artistName: String
    var id: Int64 { song.id }
}

/// Navigation target: open an album's detail page and scroll-to / highlight one song
/// (used when tapping a song in search results). Distinct from navigating to the bare Album.
struct AlbumSong: Hashable {
    var album: Album
    var songID: Int64
}
