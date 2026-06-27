import Foundation
import GRDB

/// Read-write store for the user's own data: favorites, playlists, play history,
/// and download records. Lives in a separate file from the catalog so a catalog
/// refresh never destroys personal data.
final class UserStore: ObservableObject {
    let dbQueue: DatabaseQueue

    @Published private(set) var favoriteSongIDs: Set<Int64> = []
    @Published private(set) var favoriteAlbumIDs: Set<Int64> = []
    @Published private(set) var favoriteArtistIDs: Set<Int64> = []

    @Published private(set) var dislikedSongIDs: Set<Int64> = []
    @Published private(set) var dislikedAlbumIDs: Set<Int64> = []
    @Published private(set) var dislikedArtistIDs: Set<Int64> = []

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try Self.migrator.migrate(dbQueue)
        reloadFavorites()
        reloadDislikes()
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "favorites") { t in
                t.column("kind", .text).notNull()      // "song" | "album" | "artist"
                t.column("ref_id", .integer).notNull()
                t.column("created_at", .double).notNull()
                t.primaryKey(["kind", "ref_id"])
            }
            try db.create(table: "playlist") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("created_at", .double).notNull()
            }
            try db.create(table: "playlist_item") { t in
                t.column("playlist_id", .integer).notNull()
                    .references("playlist", onDelete: .cascade)
                t.column("song_id", .integer).notNull()
                t.column("position", .integer).notNull()
            }
            try db.create(table: "play_history") { t in
                t.column("song_id", .integer).notNull()
                t.column("played_at", .double).notNull()
            }
            try db.create(table: "download") { t in
                t.column("album_id", .integer).notNull()
                t.column("format", .text).notNull()
                t.column("state", .text).notNull()   // queued|downloading|done|failed
                t.column("local_dir", .text)
                t.column("created_at", .double).notNull()
                t.primaryKey(["album_id", "format"])
            }
        }
        m.registerMigration("v2_dislikes") { db in
            try db.create(table: "dislikes") { t in
                t.column("kind", .text).notNull()      // "song" | "album" | "artist"
                t.column("ref_id", .integer).notNull()
                t.column("created_at", .double).notNull()
                t.primaryKey(["kind", "ref_id"])
            }
        }
        return m
    }

    // MARK: Favorites

    private func reloadFavorites() {
        favoriteSongIDs = ids(kind: "song")
        favoriteAlbumIDs = ids(kind: "album")
        favoriteArtistIDs = ids(kind: "artist")
    }

    private func ids(kind: String) -> Set<Int64> {
        let rows = (try? dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT ref_id FROM favorites WHERE kind = ?", arguments: [kind])
        }) ?? []
        return Set(rows)
    }

    func isFavorite(kind: String, id: Int64) -> Bool {
        switch kind {
        case "song": return favoriteSongIDs.contains(id)
        case "album": return favoriteAlbumIDs.contains(id)
        case "artist": return favoriteArtistIDs.contains(id)
        default: return false
        }
    }

    func toggleFavorite(kind: String, id: Int64) {
        let now = Date().timeIntervalSince1970
        let exists = isFavorite(kind: kind, id: id)
        try? dbQueue.write { db in
            if exists {
                try db.execute(sql: "DELETE FROM favorites WHERE kind = ? AND ref_id = ?", arguments: [kind, id])
            } else {
                try db.execute(sql: "INSERT OR REPLACE INTO favorites (kind, ref_id, created_at) VALUES (?,?,?)",
                               arguments: [kind, id, now])
                // Can't both love and dislike the same thing.
                try db.execute(sql: "DELETE FROM dislikes WHERE kind = ? AND ref_id = ?", arguments: [kind, id])
            }
        }
        reloadFavorites()
        reloadDislikes()
    }

    /// Delete several favorites in one transaction (used to remove redundant favorites).
    func removeFavorites(_ items: [(kind: String, id: Int64)]) {
        guard !items.isEmpty else { return }
        try? dbQueue.write { db in
            for (kind, id) in items {
                try db.execute(sql: "DELETE FROM favorites WHERE kind = ? AND ref_id = ?", arguments: [kind, id])
            }
        }
        reloadFavorites()
    }

    func favoriteIDs(kind: String) -> [Int64] {
        (try? dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT ref_id FROM favorites WHERE kind = ? ORDER BY created_at DESC", arguments: [kind])
        }) ?? []
    }

    // MARK: Dislikes ("I dislike this" — suppressed from the UI)

    private func reloadDislikes() {
        dislikedSongIDs = dislikedIds(kind: "song")
        dislikedAlbumIDs = dislikedIds(kind: "album")
        dislikedArtistIDs = dislikedIds(kind: "artist")
    }

    private func dislikedIds(kind: String) -> Set<Int64> {
        let rows = (try? dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT ref_id FROM dislikes WHERE kind = ?", arguments: [kind])
        }) ?? []
        return Set(rows)
    }

    func isDisliked(kind: String, id: Int64) -> Bool {
        switch kind {
        case "song": return dislikedSongIDs.contains(id)
        case "album": return dislikedAlbumIDs.contains(id)
        case "artist": return dislikedArtistIDs.contains(id)
        default: return false
        }
    }

    func toggleDislike(kind: String, id: Int64) {
        let now = Date().timeIntervalSince1970
        let exists = isDisliked(kind: kind, id: id)
        try? dbQueue.write { db in
            if exists {
                try db.execute(sql: "DELETE FROM dislikes WHERE kind = ? AND ref_id = ?", arguments: [kind, id])
            } else {
                try db.execute(sql: "INSERT OR REPLACE INTO dislikes (kind, ref_id, created_at) VALUES (?,?,?)",
                               arguments: [kind, id, now])
                // Disliking removes any favorite — opposite reactions can't coexist.
                try db.execute(sql: "DELETE FROM favorites WHERE kind = ? AND ref_id = ?", arguments: [kind, id])
            }
        }
        reloadDislikes()
        reloadFavorites()
    }

    func dislikeIDs(kind: String) -> [Int64] {
        (try? dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT ref_id FROM dislikes WHERE kind = ? ORDER BY created_at DESC", arguments: [kind])
        }) ?? []
    }

    // MARK: Play history

    func recordPlay(songID: Int64) {
        let now = Date().timeIntervalSince1970
        try? dbQueue.write { db in
            try db.execute(sql: "INSERT INTO play_history (song_id, played_at) VALUES (?,?)", arguments: [songID, now])
        }
    }

    func recentlyPlayedSongIDs(limit: Int = 30) -> [Int64] {
        (try? dbQueue.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT song_id FROM play_history
                GROUP BY song_id ORDER BY MAX(played_at) DESC LIMIT ?
                """, arguments: [limit])
        }) ?? []
    }

    // MARK: Playlists

    struct PlaylistRow: Identifiable, FetchableRecord {
        var id: Int64
        var name: String
        var count: Int
        init(row: Row) { id = row["id"]; name = row["name"]; count = row["count"] }
    }

    func playlists() -> [PlaylistRow] {
        (try? dbQueue.read { db in
            try PlaylistRow.fetchAll(db, sql: """
                SELECT p.id, p.name, COUNT(pi.song_id) AS count
                FROM playlist p LEFT JOIN playlist_item pi ON pi.playlist_id = p.id
                GROUP BY p.id ORDER BY p.created_at DESC
                """)
        }) ?? []
    }

    @discardableResult
    func createPlaylist(name: String) -> Int64 {
        let now = Date().timeIntervalSince1970
        return (try? dbQueue.write { db in
            try db.execute(sql: "INSERT INTO playlist (name, created_at) VALUES (?,?)", arguments: [name, now])
            return db.lastInsertedRowID
        }) ?? -1
    }

    func deletePlaylist(id: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM playlist WHERE id = ?", arguments: [id])
        }
    }

    func addSong(_ songID: Int64, toPlaylist playlistID: Int64) {
        try? dbQueue.write { db in
            let pos = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(position),-1)+1 FROM playlist_item WHERE playlist_id = ?", arguments: [playlistID]) ?? 0
            try db.execute(sql: "INSERT INTO playlist_item (playlist_id, song_id, position) VALUES (?,?,?)",
                           arguments: [playlistID, songID, pos])
        }
    }

    func songIDs(inPlaylist playlistID: Int64) -> [Int64] {
        (try? dbQueue.read { db in
            try Int64.fetchAll(db, sql: "SELECT song_id FROM playlist_item WHERE playlist_id = ? ORDER BY position", arguments: [playlistID])
        }) ?? []
    }

    func removeItem(songID: Int64, fromPlaylist playlistID: Int64) {
        try? dbQueue.write { db in
            try db.execute(sql: "DELETE FROM playlist_item WHERE playlist_id = ? AND song_id = ?", arguments: [playlistID, songID])
        }
    }
}
