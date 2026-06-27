import Foundation
import GRDB

/// Read-only access to the downloaded Magnatune catalog database.
/// The file is replaced wholesale on catalog refresh; never written to here.
final class CatalogStore {
    private let dbQueue: DatabaseQueue

    init(path: String) throws {
        var config = Configuration()
        config.readonly = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
    }

    private func read<T>(_ block: @escaping (Database) throws -> T) -> T? {
        try? dbQueue.read(block)
    }

    // MARK: Artists

    func allArtists() -> [Artist] {
        read { try Artist.order(sql: "name COLLATE NOCASE").fetchAll($0) } ?? []
    }

    func artist(id: Int64) -> Artist? {
        read { try Artist.fetchOne($0, key: id) } ?? nil
    }

    /// All artist id -> name (cheap; ~700 rows). Useful for album grids.
    func artistNames() -> [Int64: String] {
        let pairs = read { db -> [(Int64, String)] in
            try Row.fetchAll(db, sql: "SELECT artists_id, name FROM artists").map { ($0["artists_id"], $0["name"]) }
        } ?? []
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    // MARK: Albums

    func allAlbums() -> [Album] {
        read { try Album.order(sql: "name COLLATE NOCASE").fetchAll($0) } ?? []
    }

    func album(id: Int64) -> Album? {
        read { try Album.fetchOne($0, key: id) } ?? nil
    }

    func albums(forArtist artistId: Int64) -> [Album] {
        read {
            try Album.filter(sql: "artist_id = ?", arguments: [artistId])
                .order(sql: "release_date DESC")
                .fetchAll($0)
        } ?? []
    }

    /// One representative album name for an artist (most popular), used to build the
    /// sized artist-photo URL — those thumbnails live in the album directories.
    /// nil if the artist has no albums.
    func firstAlbumName(forArtist artistId: Int64) -> String? {
        read {
            try String.fetchOne($0,
                sql: "SELECT name FROM albums WHERE artist_id = ? ORDER BY popularity DESC, release_date DESC LIMIT 1",
                arguments: [artistId])
        } ?? nil
    }

    func newReleases(limit: Int = 40) -> [Album] {
        read {
            try Album.order(sql: "release_date DESC").limit(limit).fetchAll($0)
        } ?? []
    }

    func popularAlbums(limit: Int = 40) -> [Album] {
        read {
            try Album.order(sql: "popularity DESC").limit(limit).fetchAll($0)
        } ?? []
    }

    /// All albums ordered most-popular first.
    func albumsByPopularity() -> [Album] {
        read { try Album.order(sql: "popularity DESC, name COLLATE NOCASE").fetchAll($0) } ?? []
    }

    // MARK: Songs

    /// All songs by an artist (across their albums), in album order.
    func songs(forArtist artistId: Int64) -> [Song] {
        albums(forArtist: artistId).flatMap { songs(forAlbum: $0.id) }
    }

    func songs(forAlbum albumId: Int64) -> [Song] {
        read {
            try Song.filter(sql: "album_id = ?", arguments: [albumId])
                .order(sql: "track_no")
                .fetchAll($0)
        } ?? []
    }

    func song(id: Int64) -> Song? {
        read { try Song.fetchOne($0, key: ["song_id": id]) } ?? nil
    }

    // MARK: Genres

    func allGenres() -> [Genre] {
        read { try Genre.order(sql: "name COLLATE NOCASE").fetchAll($0) } ?? []
    }

    func albums(forGenre genreId: Int64) -> [Album] {
        read {
            try Album.fetchAll($0, sql: """
                SELECT a.* FROM albums a
                JOIN genres_albums ga ON ga.album_id = a.album_id
                WHERE ga.genre_id = ?
                ORDER BY a.popularity DESC
                """, arguments: [genreId])
        } ?? []
    }

    /// Artists who have at least one album in the given genre.
    func artists(forGenre genreId: Int64) -> [Artist] {
        read {
            try Artist.fetchAll($0, sql: """
                SELECT DISTINCT ar.* FROM artists ar
                JOIN albums a ON a.artist_id = ar.artists_id
                JOIN genres_albums ga ON ga.album_id = a.album_id
                WHERE ga.genre_id = ?
                ORDER BY ar.name COLLATE NOCASE
                """, arguments: [genreId])
        } ?? []
    }

    /// Newest albums across one or more genres (for the Home page's per-genre rows).
    func newReleases(genreIDs: [Int64], limit: Int = 15) -> [Album] {
        guard !genreIDs.isEmpty else { return [] }
        let ph = genreIDs.map { _ in "?" }.joined(separator: ",")
        return read {
            try Album.fetchAll($0, sql: """
                SELECT DISTINCT a.* FROM albums a
                JOIN genres_albums ga ON ga.album_id = a.album_id
                WHERE ga.genre_id IN (\(ph))
                ORDER BY a.release_date DESC LIMIT ?
                """, arguments: StatementArguments(genreIDs + [Int64(limit)]))
        } ?? []
    }

    // MARK: Tags (collections)

    func allTags() -> [Tag] {
        read { try Tag.order(sql: "name COLLATE NOCASE").fetchAll($0) } ?? []
    }

    func albums(forTag tagId: Int64) -> [Album] {
        read {
            try Album.fetchAll($0, sql: """
                SELECT a.* FROM albums a
                JOIN collections_albums ca ON ca.album_id = a.album_id
                WHERE ca.collection_id = ?
                ORDER BY a.popularity DESC
                """, arguments: [tagId])
        } ?? []
    }

    /// The genres + tags (collections) shown as chips on an album.
    func genresAndTags(forAlbum albumId: Int64) -> (genres: [Genre], tags: [Tag]) {
        let genres = read { db in
            try Genre.fetchAll(db, sql: """
                SELECT g.* FROM genres g JOIN genres_albums ga ON ga.genre_id = g.genre_id
                WHERE ga.album_id = ? ORDER BY g.name COLLATE NOCASE
                """, arguments: [albumId])
        } ?? []
        let tags = read { db in
            try Tag.fetchAll(db, sql: """
                SELECT c.* FROM collections c JOIN collections_albums ca ON ca.collection_id = c.collections_id
                WHERE ca.album_id = ? ORDER BY c.name COLLATE NOCASE
                """, arguments: [albumId])
        } ?? []
        return (genres, tags)
    }

    // MARK: Catalog playlists (Magnatune-curated)

    func catalogPlaylists() -> [CatalogPlaylist] {
        read { try CatalogPlaylist.order(sql: "sort_order, name COLLATE NOCASE").fetchAll($0) } ?? []
    }

    func songs(forCatalogPlaylist playlistId: Int64) -> [Song] {
        read {
            try Song.fetchAll($0, sql: """
                SELECT s.* FROM songs s
                JOIN playlist_songs ps ON ps.song_id = s.song_id
                WHERE ps.playlist_id = ?
                ORDER BY ps.sort_order
                """, arguments: [playlistId])
        } ?? []
    }

    // MARK: Search

    func searchArtists(_ q: String, limit: Int = 50) -> [Artist] {
        let like = "%\(q)%"
        return read {
            try Artist.filter(sql: "name LIKE ? OR description LIKE ? OR bio LIKE ?", arguments: [like, like, like])
                .order(sql: "name COLLATE NOCASE").limit(limit).fetchAll($0)
        } ?? []
    }

    func searchAlbums(_ q: String, limit: Int = 50) -> [Album] {
        let like = "%\(q)%"
        return read {
            try Album.filter(sql: "name LIKE ? OR description LIKE ?", arguments: [like, like])
                .order(sql: "name COLLATE NOCASE").limit(limit).fetchAll($0)
        } ?? []
    }

    func searchSongs(_ q: String, limit: Int = 100) -> [Song] {
        let like = "%\(q)%"
        return read {
            try Song.filter(sql: "name LIKE ?", arguments: [like])
                .order(sql: "name COLLATE NOCASE").limit(limit).fetchAll($0)
        } ?? []
    }

    // MARK: Downloaded-content lookups (for offline filtering)

    /// Run a "SELECT DISTINCT id ... WHERE col IN (?)" query in chunks (to stay
    /// under SQLite's bound-variable limit) and union the results.
    private func distinctIDs(_ ids: [Int64], chunkSize: Int = 800, sql: @escaping (String) -> String) -> Set<Int64> {
        guard !ids.isEmpty else { return [] }
        var out = Set<Int64>()
        var i = 0
        while i < ids.count {
            let chunk = Array(ids[i..<min(i + chunkSize, ids.count)])
            let ph = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = read { try Int64.fetchAll($0, sql: sql(ph), arguments: StatementArguments(chunk)) } ?? []
            out.formUnion(rows)
            i += chunkSize
        }
        return out
    }

    /// The album ids and artist ids that the given songs belong to.
    func albumAndArtistIDs(forSongs songIDs: [Int64]) -> (albums: Set<Int64>, artists: Set<Int64>) {
        guard !songIDs.isEmpty else { return ([], []) }
        var albums = Set<Int64>(); var artists = Set<Int64>()
        var i = 0
        while i < songIDs.count {
            let chunk = Array(songIDs[i..<min(i + 800, songIDs.count)])
            let ph = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = read { db in
                try Row.fetchAll(db, sql: """
                    SELECT DISTINCT s.album_id AS aid, a.artist_id AS arid
                    FROM songs s JOIN albums a ON a.album_id = s.album_id
                    WHERE s.song_id IN (\(ph))
                    """, arguments: StatementArguments(chunk))
            } ?? []
            for r in rows { albums.insert(r["aid"]); artists.insert(r["arid"]) }
            i += 800
        }
        return (albums, artists)
    }

    func genreIDs(forAlbums albumIDs: [Int64]) -> Set<Int64> {
        distinctIDs(albumIDs) { "SELECT DISTINCT genre_id FROM genres_albums WHERE album_id IN (\($0))" }
    }

    func tagIDs(forAlbums albumIDs: [Int64]) -> Set<Int64> {
        distinctIDs(albumIDs) { "SELECT DISTINCT collection_id FROM collections_albums WHERE album_id IN (\($0))" }
    }

    func catalogPlaylistIDs(forSongs songIDs: [Int64]) -> Set<Int64> {
        distinctIDs(songIDs) { "SELECT DISTINCT playlist_id FROM playlist_songs WHERE song_id IN (\($0))" }
    }

    // MARK: Helpers for playback context

    func makePlayable(songs: [Song]) -> [PlayableTrack] {
        // Cache album + artist lookups for the batch.
        var albumCache: [Int64: Album] = [:]
        var artistCache: [Int64: String] = [:]
        var out: [PlayableTrack] = []
        for s in songs {
            let alb: Album
            if let cached = albumCache[s.albumId] {
                alb = cached
            } else if let fetched = album(id: s.albumId) {
                alb = fetched; albumCache[s.albumId] = fetched
            } else { continue }
            let artistName: String
            if let cached = artistCache[alb.artistId] {
                artistName = cached
            } else {
                let n = artist(id: alb.artistId)?.name ?? ""
                artistName = n; artistCache[alb.artistId] = n
            }
            out.append(PlayableTrack(song: s, album: alb, artistName: artistName))
        }
        return out
    }
}
