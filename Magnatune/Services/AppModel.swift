import Foundation
import SwiftUI
import Combine
import Network
import Kingfisher

/// Central object that owns the stores and services and exposes high-level actions.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var catalog: CatalogStore?
    let userStore: UserStore
    let credentials: Credentials
    let audio: AudioPlayer
    private let sync = CatalogSync()

    @Published var catalogReady = false
    @Published var isRefreshing = false

    // MARK: Connectivity + offline state
    /// Whether the device currently has a usable network path. When false the UI
    /// hides everything that hasn't been downloaded and greys the browse sections.
    @Published private(set) var isOnline = true

    // MARK: Downloaded-content sets (drive offline filtering)
    @Published private(set) var downloadedSongIDs: Set<Int64> = []
    @Published private(set) var downloadedAlbumIDs: Set<Int64> = []
    @Published private(set) var downloadedArtistIDs: Set<Int64> = []
    @Published private(set) var downloadedGenreIDs: Set<Int64> = []
    @Published private(set) var downloadedTagIDs: Set<Int64> = []
    @Published private(set) var downloadedCatalogPlaylistIDs: Set<Int64> = []

    /// Whether favorites are auto-downloaded for offline listening.
    static let autoDownloadKey = "autodownload.favorites"
    @Published var autoDownloadFavorites: Bool = UserDefaults.standard.object(forKey: "autodownload.favorites") as? Bool ?? false

    private let pathMonitor = NWPathMonitor()
    private var favoritesObserver: AnyCancellable?
    private var autoDownloadTask: Task<Void, Never>?

    init() {
        AppModel.configureImageCache()
        credentials = Credentials()
        let userPath = AppModel.userDBPath()
        userStore = (try? UserStore(path: userPath)) ?? AppModel.makeFallbackUserStore()
        audio = AudioPlayer(credentials: credentials, userStore: userStore)

        sync.ensureSeeded()
        openCatalog()
        refreshDownloadedSets()
        startNetworkMonitor()

        // Re-run auto-download whenever the favorites change (if the toggle is on).
        favoritesObserver = userStore.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in self?.syncAutoDownloads() }

        if autoDownloadFavorites { syncAutoDownloads() }
    }

    private func openCatalog() {
        catalog = try? CatalogStore(path: CatalogSync.catalogPath())
        catalogReady = (catalog != nil)
    }

    func refreshCatalog(force: Bool = false) async {
        isRefreshing = true
        let changed = await sync.refreshIfNeeded(force: force)
        if changed { openCatalog() }
        isRefreshing = false
    }

    // MARK: Connectivity

    private func startNetworkMonitor() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.setOnline(path.status == .satisfied) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.magnatune.netmonitor"))
    }

    private func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        // Coming back online: pick up any favorites added while offline.
        if online, autoDownloadFavorites { syncAutoDownloads() }
    }

    // MARK: Auto-download of favorites

    func setAutoDownloadFavorites(_ on: Bool) {
        autoDownloadFavorites = on
        UserDefaults.standard.set(on, forKey: Self.autoDownloadKey)
        if on { syncAutoDownloads() } else { autoDownloadTask?.cancel() }
    }

    /// Recompute the downloaded-content id sets from disk + catalog so the offline
    /// filters and Settings counts stay current.
    func refreshDownloadedSets() {
        let songIDs = DownloadStore.shared.downloadedIDs()
        downloadedSongIDs = songIDs
        guard let c = catalog, !songIDs.isEmpty else {
            downloadedAlbumIDs = []; downloadedArtistIDs = []
            downloadedGenreIDs = []; downloadedTagIDs = []; downloadedCatalogPlaylistIDs = []
            return
        }
        let ids = Array(songIDs)
        let aa = c.albumAndArtistIDs(forSongs: ids)
        downloadedAlbumIDs = aa.albums
        downloadedArtistIDs = aa.artists
        let albumIDs = Array(aa.albums)
        downloadedGenreIDs = c.genreIDs(forAlbums: albumIDs)
        downloadedTagIDs = c.tagIDs(forAlbums: albumIDs)
        downloadedCatalogPlaylistIDs = c.catalogPlaylistIDs(forSongs: ids)
    }

    /// Reconcile downloads with the current favorites: download every song implied
    /// by the favorites (favorited songs, plus all songs of favorited albums and
    /// artists) that isn't on disk yet, and delete any downloaded track that is no
    /// longer implied by *any* favorite (so un-favoriting removes its files, unless
    /// another favorite still keeps the song).
    func syncAutoDownloads() {
        guard autoDownloadFavorites, let c = catalog else { return }
        autoDownloadTask?.cancel()
        autoDownloadTask = Task { [weak self] in
            guard let self else { return }
            let targets = self.favoriteSongs(using: c)
            let targetIDs = Set(targets.map { $0.id })

            // Delete downloads no longer kept by any favorite.
            let stale = DownloadStore.shared.downloadedIDs().subtracting(targetIDs)
            if !stale.isEmpty {
                for id in stale { DownloadStore.shared.remove(id) }
                self.refreshDownloadedSets()
            }

            // Download anything newly favorited that isn't on disk.
            var didChange = false
            for song in targets {
                if Task.isCancelled { break }
                if DownloadStore.shared.isDownloaded(song.id) { continue }
                guard let url = URLBuilder.streamURL(for: song, isMember: self.credentials.isMember) else { continue }
                let ok = await DownloadStore.shared.downloadAsync(
                    songID: song.id, remote: url, authHeader: self.credentials.basicAuthHeader())
                if ok { didChange = true; self.refreshDownloadedSets() }
            }
            if didChange { self.refreshDownloadedSets() }
        }
    }

    /// All distinct songs implied by the user's favorites.
    private func favoriteSongs(using c: CatalogStore) -> [Song] {
        var byID: [Int64: Song] = [:]
        for id in userStore.favoriteIDs(kind: "song") { if let s = c.song(id: id) { byID[s.id] = s } }
        for id in userStore.favoriteIDs(kind: "album") { for s in c.songs(forAlbum: id) { byID[s.id] = s } }
        for id in userStore.favoriteIDs(kind: "artist") { for s in c.songs(forArtist: id) { byID[s.id] = s } }
        return Array(byID.values)
    }

    // MARK: Offline visibility filters
    // When online these are pass-throughs; when offline they keep only downloaded items.

    func visibleAlbums(_ albums: [Album]) -> [Album] {
        isOnline ? albums : albums.filter { downloadedAlbumIDs.contains($0.id) }
    }
    func visibleArtists(_ artists: [Artist]) -> [Artist] {
        isOnline ? artists : artists.filter { downloadedArtistIDs.contains($0.id) }
    }
    func visibleSongs(_ songs: [Song]) -> [Song] {
        isOnline ? songs : songs.filter { downloadedSongIDs.contains($0.id) }
    }
    func visibleTracks(_ tracks: [PlayableTrack]) -> [PlayableTrack] {
        isOnline ? tracks : tracks.filter { downloadedSongIDs.contains($0.song.id) }
    }
    func visibleGenres(_ genres: [Genre]) -> [Genre] {
        isOnline ? genres : genres.filter { downloadedGenreIDs.contains($0.id) }
    }
    func visibleTags(_ tags: [Tag]) -> [Tag] {
        isOnline ? tags : tags.filter { downloadedTagIDs.contains($0.id) }
    }
    func visibleCatalogPlaylists(_ playlists: [CatalogPlaylist]) -> [CatalogPlaylist] {
        isOnline ? playlists : playlists.filter { downloadedCatalogPlaylistIDs.contains($0.id) }
    }

    // MARK: High-level playback actions

    func playAlbum(_ album: Album, startAt index: Int = 0) {
        guard let catalog else { return }
        let songs = catalog.songs(forAlbum: album.id)
        let tracks = catalog.makePlayable(songs: songs)
        audio.play(tracks: tracks, startAt: index)
    }

    func playSongs(_ songs: [Song], startAt index: Int = 0) {
        guard let catalog else { return }
        let tracks = catalog.makePlayable(songs: songs)
        audio.play(tracks: tracks, startAt: index)
    }

    func tracks(for songs: [Song]) -> [PlayableTrack] {
        catalog?.makePlayable(songs: songs) ?? []
    }

    // MARK: Paths

    /// Album art and artist photos are immutable, so cache them on disk
    /// permanently (capped) rather than Kingfisher's default 1-week expiry.
    static func configureImageCache() {
        let cache = ImageCache.default
        cache.diskStorage.config.expiration = .never
        cache.diskStorage.config.sizeLimit = 600 * 1024 * 1024   // 600 MB on disk
        cache.memoryStorage.config.expiration = .seconds(600)
        cache.memoryStorage.config.countLimit = 300
    }

    static func userDBPath() -> String {
        let dir = try! FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        return dir.appendingPathComponent("magnatune_user.db").path
    }

    private static func makeFallbackUserStore() -> UserStore {
        // last resort: in temp dir, so the app still runs
        let p = NSTemporaryDirectory() + "magnatune_user_fallback.db"
        return try! UserStore(path: p)
    }
}
