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
    let peerService: PeerService
    private let sync = CatalogSync()

    @Published var catalogReady = false
    /// True while a newer catalog is being downloaded/installed in the background.
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
    @Published var autoDownloadFavorites: Bool = UserDefaults.standard.object(forKey: "autodownload.favorites") as? Bool ?? true

    // MARK: Local-network peer sync
    static let peerSharingKey = "peer.sharing.enabled"
    static let autoStopKey = "peer.autostop.enabled"
    /// Whether this instance advertises/controls on the local network.
    @Published var peerSharingEnabled: Bool = UserDefaults.standard.object(forKey: "peer.sharing.enabled") as? Bool ?? true
    /// When on, starting playback here pauses other Magnatune apps that were already
    /// playing (most-recent play wins). Both sides must have it on.
    @Published var autoStopOtherMusic: Bool = UserDefaults.standard.object(forKey: "peer.autostop.enabled") as? Bool ?? true
    /// The peer we're currently showing/controlling because local audio is idle (most
    /// recently active remote instance). Nil when we're playing locally or no peer is active.
    @Published private(set) var remoteFocus: Peer?

    private let pathMonitor = NWPathMonitor()
    private var favoritesObserver: AnyCancellable?
    private var membershipObserver: AnyCancellable?
    private var autoDownloadTask: Task<Void, Never>?
    private var peerCancellables: Set<AnyCancellable> = []
    private var heartbeatTimer: Timer?
    /// Wall-clock when local playback last started (for most-recent-play-wins auto-stop).
    private var localPlayStartedAt: Date?
    private var wasPlaying = false

    init() {
        AppModel.configureImageCache()
        credentials = Credentials()
        let userPath = AppModel.userDBPath()
        userStore = (try? UserStore(path: userPath)) ?? AppModel.makeFallbackUserStore()
        audio = AudioPlayer(credentials: credentials, userStore: userStore)
        peerService = PeerService(deviceName: AppModel.currentDeviceName())

        sync.ensureSeeded()
        openCatalog()
        refreshDownloadedSets()
        startNetworkMonitor()

        // On any favorites change: drop redundant (more-precise) favorites, then sync.
        favoritesObserver = userStore.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.deduplicateFavorites()
                self?.syncAutoDownloads()
            }

        // Signing in/out changes whether favorites should be downloaded.
        membershipObserver = credentials.$isMember
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncAutoDownloads() }

        deduplicateFavorites()
        if autoDownloadFavorites { syncAutoDownloads() }
        setupPeerSync()
    }

    /// Keep favorites non-redundant: if a song is favorited and so is its album (or its
    /// artist), drop the song; if an album is favorited and so is its artist, drop the
    /// album. The broadest favorite is kept; the more-precise one is removed.
    func deduplicateFavorites() {
        guard let c = catalog else { return }
        let favSongs = userStore.favoriteIDs(kind: "song")
        let favAlbums = Set(userStore.favoriteIDs(kind: "album"))
        let favArtists = Set(userStore.favoriteIDs(kind: "artist"))
        var toRemove: [(kind: String, id: Int64)] = []

        for sid in favSongs {
            guard let song = c.song(id: sid) else { continue }
            let artistCovered = c.album(id: song.albumId).map { favArtists.contains($0.artistId) } ?? false
            if favAlbums.contains(song.albumId) || artistCovered {
                toRemove.append((kind: "song", id: sid))
            }
        }
        for aid in favAlbums {
            if let album = c.album(id: aid), favArtists.contains(album.artistId) {
                toRemove.append((kind: "album", id: aid))
            }
        }
        if !toRemove.isEmpty { userStore.removeFavorites(toRemove) }
    }

    // MARK: Local-network peer sync

    private func setupPeerSync() {
        // Inbound transport commands drive our own player (we are being controlled).
        peerService.onControl = { [weak self] cmd in
            guard let self else { return }
            switch cmd {
            case .playPause: self.audio.toggle()
            case .next: self.audio.next()
            case .prev: self.audio.previous()
            }
        }
        // Broadcast our state whenever playback changes.
        audio.onPlaybackChange = { [weak self] in self?.broadcastPlaybackState() }
        // Recompute which remote peer to surface when peers change or local play state flips.
        peerService.$peers
            .receive(on: RunLoop.main)
            .sink { [weak self] peers in
                self?.recomputeRemoteFocus(peers)
                self?.applyAutoStop(peers)
            }
            .store(in: &peerCancellables)
        audio.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recomputeRemoteFocus() }
            .store(in: &peerCancellables)

        if peerSharingEnabled { peerService.start(); startHeartbeat() }
    }

    func setPeerSharingEnabled(_ on: Bool) {
        peerSharingEnabled = on
        UserDefaults.standard.set(on, forKey: Self.peerSharingKey)
        if on {
            peerService.start(); startHeartbeat(); broadcastPlaybackState()
        } else {
            peerService.stop(); stopHeartbeat(); remoteFocus = nil
        }
    }

    /// An automatic, human-friendly device name for the local network, e.g.
    /// "Gill's iPad Pro 11" or "Gill's iPad A16". UIDevice.name is generic on iOS 16+,
    /// so we combine the owner (from the network host name) with the hardware model.
    static func currentDeviceName() -> String {
        #if targetEnvironment(macCatalyst)
        // `Host` is unavailable on Catalyst; the host name is the Mac's network name.
        let host = ProcessInfo.processInfo.hostName
        let name = host.hasSuffix(".local") ? String(host.dropLast(6)) : host
        return name.isEmpty ? "Mac" : name
        #else
        let model = marketingModelName(modelIdentifier())
        if let owner = ownerFromHostName() { return "\(owner)'s \(model)" }
        return model
        #endif
    }

    /// First component of the network host name, capitalized — usually the owner,
    /// e.g. "gill-ipad-2.local" → "Gill". Nil if it isn't a recognizable owner token.
    private static func ownerFromHostName() -> String? {
        let host = ProcessInfo.processInfo.hostName
        let base = host.split(separator: ".").first.map(String.init) ?? host
        guard let first = base.split(separator: "-").first.map(String.init), !first.isEmpty else { return nil }
        let lower = first.lowercased()
        guard lower != "ipad", lower != "iphone", lower != "ipod", lower != "localhost" else { return nil }
        return first.prefix(1).uppercased() + first.dropFirst().lowercased()
    }

    /// Hardware model identifier, e.g. "iPad14,3".
    static func modelIdentifier() -> String {
        var s = utsname(); uname(&s)
        return Mirror(reflecting: s.machine).children.reduce(into: "") { acc, e in
            if let v = e.value as? Int8, v != 0 { acc.append(Character(UnicodeScalar(UInt8(v)))) }
        }
    }

    /// Friendly model name for the identifiers we ship to. Falls back to a generic family.
    private static func marketingModelName(_ id: String) -> String {
        switch id {
        case "iPad14,3", "iPad14,4": return "iPad Pro 11"
        case "iPad14,5", "iPad14,6": return "iPad Pro 12.9"
        case "iPad15,7", "iPad15,8": return "iPad A16"
        case "iPad13,16", "iPad13,17": return "iPad Air"
        case "iPad13,18", "iPad13,19": return "iPad 10"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        case "iPhone16,2": return "iPhone 15 Pro Max"
        default:
            if id.hasPrefix("iPad") { return "iPad" }
            if id.hasPrefix("iPhone") { return "iPhone" }
            return UIDevice.current.name
        }
    }

    /// Send the current local playback snapshot to peers. Also doubles as the heartbeat
    /// (re-sent on a timer) so remote scrubbers stay in sync.
    private func broadcastPlaybackState() {
        guard peerSharingEnabled else { return }
        let playing = audio.peerState == .playing
        if playing && !wasPlaying { localPlayStartedAt = Date() }
        if !playing { localPlayStartedAt = nil }
        wasPlaying = playing
        let snap = PeerNowPlaying(state: audio.peerState, songID: audio.current?.song.id,
                                  position: audio.currentTime, startedAt: localPlayStartedAt)
        peerService.updateLocalState(snap)
        recomputeRemoteFocus()
    }

    /// Most-recent play wins: if we're playing and a peer is playing something it started
    /// more recently than us, pause ourselves. Both sides must have the setting on.
    private func applyAutoStop(_ peers: [Peer]) {
        guard autoStopOtherMusic, audio.isPlaying, let myStart = localPlayStartedAt else { return }
        for p in peers where p.nowPlaying.state == .playing {
            if let theirStart = p.nowPlaying.startedAt, theirStart > myStart.addingTimeInterval(0.5) {
                audio.toggle()                 // pause — they started after us
                localPlayStartedAt = nil
                wasPlaying = false
                return
            }
        }
    }

    func setAutoStopOtherMusic(_ on: Bool) {
        autoStopOtherMusic = on
        UserDefaults.standard.set(on, forKey: Self.autoStopKey)
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.broadcastPlaybackState() }
        }
    }

    private func stopHeartbeat() { heartbeatTimer?.invalidate(); heartbeatTimer = nil }

    /// Local playback always wins. Otherwise surface the most-recently-active peer that is
    /// playing — and stick with it (even if it pauses) until it goes idle or disconnects.
    private func recomputeRemoteFocus(_ peers: [Peer]? = nil) {
        let list = peers ?? peerService.peers
        if audio.isPlaying { remoteFocus = nil; return }
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if let cur = remoteFocus, let still = byID[cur.id], still.nowPlaying.state != .idle {
            remoteFocus = still
            return
        }
        let playing = list.filter { $0.nowPlaying.state == .playing }
        remoteFocus = playing.max(by: { $0.lastActiveAt < $1.lastActiveAt })
    }

    /// Build a playable track from a song id (used to render a peer's now-playing locally).
    func playableTrack(songID: Int64) -> PlayableTrack? {
        guard let c = catalog, let s = c.song(id: songID) else { return nil }
        return c.makePlayable(songs: [s]).first
    }

    private func openCatalog() {
        catalog = try? CatalogStore(path: CatalogSync.catalogPath())
        catalogReady = (catalog != nil)
    }

    func refreshCatalog(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let changed = await sync.refreshIfNeeded(force: force)
        if changed { openCatalog(); refreshDownloadedSets() }
        isRefreshing = false
    }

    /// If magnatune.com reports a newer catalog, download and install it automatically
    /// in the background. Safe to call on launch and when opening Settings.
    func checkCatalogUpdate() async {
        guard !isRefreshing, await sync.updateAvailable() else { return }
        await refreshCatalog(force: true)
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
        // Auto-download is members-only: non-members get nothing, and any existing
        // downloads are removed (e.g. after a membership lapses or signs out).
        guard credentials.isMember else {
            autoDownloadTask?.cancel()
            if DownloadStore.shared.count() > 0 {
                DownloadStore.shared.clear()
                refreshDownloadedSets()
            }
            return
        }
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
                guard let album = c.album(id: song.albumId), let artist = c.artist(id: album.artistId),
                      let url = await URLBuilder.resolvedStreamURL(
                        artistName: artist.name, albumName: album.name, song: song,
                        isMember: self.credentials.isMember, quality: StreamQuality.current,
                        authHeader: self.credentials.basicAuthHeader()) else { continue }
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
