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

    // MARK: Catalog-derived genre membership (drives the browse-screen genre filters)
    // Rebuilt in `openCatalog()` so they track the CURRENT catalog and stay correct across a
    // background refresh / hot-swap (no per-view @State caching that could go stale).
    /// artist_id → genre ids the artist belongs to (via their albums).
    @Published private(set) var genresByArtist: [Int64: Set<Int64>] = [:]
    /// album_id → genre ids it belongs to.
    @Published private(set) var genresByAlbum: [Int64: Set<Int64>] = [:]

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

    // MARK: Dislikes (suppress-from-UI)
    static let hideDislikesKey = "dislike.hide.enabled"
    /// When on, songs/albums/artists the user disliked are hidden everywhere. Turn off to
    /// see them again (and un-dislike via the same icon). Default on.
    @Published var hideDislikes: Bool = UserDefaults.standard.object(forKey: "dislike.hide.enabled") as? Bool ?? true
    /// Disliked ids expanded through the catalog: a disliked artist also suppresses its
    /// albums and songs; a disliked album also suppresses its songs.
    @Published private(set) var suppressedArtistIDs: Set<Int64> = []
    @Published private(set) var suppressedAlbumIDs: Set<Int64> = []
    @Published private(set) var suppressedSongIDs: Set<Int64> = []
    /// Disliked genres themselves (hidden from the Genres list + Popular's per-genre rows).
    /// Their albums + songs are folded into the album/song suppression sets above so they
    /// also vanish from the albums overview, the songs list, and playlists.
    @Published private(set) var suppressedGenreIDs: Set<Int64> = []
    /// Featured (catalog) playlists left with no visible songs once dislikes are hidden —
    /// dropped from the Featured list so empty playlists don't show.
    @Published private(set) var suppressedCatalogPlaylistIDs: Set<Int64> = []
    /// Tags (collections) left with no visible album once dislikes are hidden — dropped
    /// from the Tags list so empty tags don't show.
    @Published private(set) var suppressedTagIDs: Set<Int64> = []

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

    static let localNetworkPromptedKey = "peer.localNetworkPrompted"
    /// Whether we've already shown our explainer and triggered the iOS Local Network
    /// permission prompt at least once. We never trigger that system prompt at launch
    /// before the UI is on screen (it would appear over a blank window).
    private var hasRequestedLocalNetwork = UserDefaults.standard.bool(forKey: "peer.localNetworkPrompted")
    /// Drives the in-app explainer shown when Local Network access isn't granted.
    @Published var showLocalNetworkPrimer = false
    /// When the explainer is showing: false = first-time priming (OK triggers the iOS
    /// prompt), true = permission was actively denied (button deep-links to Settings).
    @Published var localNetworkDenied = false
    /// Whether Local Network access is currently granted. Drives the Settings indicator.
    /// Optimistic default so the warning doesn't flash before the first probe completes.
    @Published var localNetworkGranted = true
    private let lnAuth = LocalNetworkAuthorization()

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

        // On any favorites/dislikes change: drop redundant favorites, refresh the dislike
        // suppression sets, then sync downloads.
        favoritesObserver = userStore.objectWillChange
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] in
                self?.deduplicateFavorites()
                self?.recomputeDislikeSuppression()
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

        // NB: we do NOT start advertising/browsing here. Starting the Bonjour
        // listener/browser is what triggers the iOS Local Network permission prompt, and at
        // launch the UI isn't on screen yet — the prompt would appear over a blank window.
        // The UI calls `startPeerSharingIfNeeded()` once it's visible (see RootView).
    }

    /// Called once the main UI is on screen. Decides whether to start peer sharing or to
    /// show the explainer, based on the *actual* Local Network permission state:
    ///  • never asked  → show the priming explainer (OK triggers the iOS prompt). We can't
    ///    probe this state without iOS showing the prompt itself, so it's gated by a flag.
    ///  • asked before → probe the OS (no prompt): granted ⇒ start silently; denied ⇒ show
    ///    the explainer with a Settings deep-link.
    func startPeerSharingIfNeeded() {
        guard peerSharingEnabled else { return }
        guard hasRequestedLocalNetwork else {
            localNetworkDenied = false
            showLocalNetworkPrimer = true
            return
        }
        lnAuth.check { [weak self] granted in
            guard let self else { return }
            self.localNetworkGranted = granted
            if granted {
                self.peerService.start(); self.startHeartbeat()
            } else if self.isOnline {
                // Only treat a failed probe as a real denial when there's a network path —
                // otherwise (airplane mode / no Wi-Fi) the probe also can't see services and
                // we'd wrongly nag the user to change Settings.
                self.localNetworkDenied = true
                self.showLocalNetworkPrimer = true
            }
        }
    }

    /// Re-evaluate Local Network permission for the Settings indicator (no prompt, no
    /// explainer). Called when the Settings screen appears.
    func refreshLocalNetworkStatus() {
        guard peerSharingEnabled else { localNetworkGranted = true; return }
        guard hasRequestedLocalNetwork else { localNetworkGranted = false; return }
        lnAuth.check { [weak self] granted in self?.localNetworkGranted = granted }
    }

    /// Action for the Settings "Requires device permission" button: ask iOS the first time,
    /// or deep-link to Settings if it was already denied, then refresh the indicator.
    func requestLocalNetworkAccess() {
        if hasRequestedLocalNetwork {
            openLocalNetworkSettings()           // already decided & not granted → Settings
        } else {
            markLocalNetworkRequested()
            peerService.start(); startHeartbeat()  // first ask → iOS prompt
        }
        scheduleLocalNetworkRefresh()
    }

    private func scheduleLocalNetworkRefresh() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.refreshLocalNetworkStatus()
        }
    }

    /// User tapped OK on the first-time explainer: remember we've asked, then start peer
    /// sharing — which triggers the iOS Local Network permission prompt.
    func confirmLocalNetworkPrimer() {
        showLocalNetworkPrimer = false
        markLocalNetworkRequested()
        peerService.start(); startHeartbeat()
    }

    /// User declined the first-time explainer: turn sharing off so we don't keep nagging
    /// and the stored state matches reality.
    func declineLocalNetworkPrimer() {
        showLocalNetworkPrimer = false
        setPeerSharingEnabled(false)
    }

    /// Just dismiss the explainer (used by the "denied" variant, leaving the Share toggle
    /// as-is so the user can grant access in Settings and have it take effect next launch).
    func dismissLocalNetworkPrimer() {
        showLocalNetworkPrimer = false
    }

    /// Deep-link to this app's Settings page so the user can enable Local Network access.
    func openLocalNetworkSettings() {
        showLocalNetworkPrimer = false
        #if canImport(UIKit)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #endif
    }

    private func markLocalNetworkRequested() {
        guard !hasRequestedLocalNetwork else { return }
        hasRequestedLocalNetwork = true
        UserDefaults.standard.set(true, forKey: Self.localNetworkPromptedKey)
    }

    func setPeerSharingEnabled(_ on: Bool) {
        peerSharingEnabled = on
        UserDefaults.standard.set(on, forKey: Self.peerSharingKey)
        if on {
            // Toggled on from Settings — the UI is already visible, so request directly.
            markLocalNetworkRequested()
            peerService.start(); startHeartbeat(); broadcastPlaybackState()
            scheduleLocalNetworkRefresh()
        } else {
            peerService.stop(); stopHeartbeat(); remoteFocus = nil
            localNetworkGranted = true   // feature off → hide the permission warning
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
        // Rebuild genre-membership maps from the freshly-opened catalog so the browse-screen
        // genre filters stay correct after a background refresh / hot-swap.
        genresByArtist = catalog?.genresByArtist() ?? [:]
        genresByAlbum = catalog?.genresByAlbum() ?? [:]
        recomputeDislikeSuppression()
    }

    // MARK: Dislikes

    func setHideDislikes(_ on: Bool) {
        hideDislikes = on
        UserDefaults.standard.set(on, forKey: Self.hideDislikesKey)
    }

    /// Rebuild the suppressed-id sets from the user's dislikes, expanded through the
    /// catalog (disliked artist ⇒ its albums + songs; disliked album ⇒ its songs). Cheap
    /// because the number of disliked items is small.
    func recomputeDislikeSuppression() {
        guard let c = catalog else {
            suppressedArtistIDs = []; suppressedAlbumIDs = []; suppressedSongIDs = []
            suppressedGenreIDs = []; suppressedCatalogPlaylistIDs = []; suppressedTagIDs = []
            return
        }
        var artists = Set(userStore.dislikeIDs(kind: "artist"))
        let genres = Set(userStore.dislikeIDs(kind: "genre"))
        var albums = Set(userStore.dislikeIDs(kind: "album"))
        var songs = Set(userStore.dislikeIDs(kind: "song"))
        for aid in artists {
            for al in c.albums(forArtist: aid) { albums.insert(al.id) }
        }
        // A disliked genre hides every album in that genre (and, below, their songs).
        // Track the genre-hidden albums + the artists who have one, so we can also hide
        // any artist whose *entire* catalog falls in disliked genres.
        var genreAlbums = Set<Int64>()
        var genreArtistCandidates = Set<Int64>()
        for gid in genres {
            for al in c.albums(forGenre: gid) {
                albums.insert(al.id)
                genreAlbums.insert(al.id)
                genreArtistCandidates.insert(al.artistId)
            }
        }
        // Hide an artist from the Artists list when every one of their albums is in a
        // disliked genre (no remaining album to browse to).
        for aid in genreArtistCandidates where !artists.contains(aid) {
            let theirAlbums = c.albums(forArtist: aid)
            if !theirAlbums.isEmpty && theirAlbums.allSatisfy({ genreAlbums.contains($0.id) }) {
                artists.insert(aid)
            }
        }
        // Every suppressed album drags its songs along, so the songs vanish from the
        // songs list and playlists too.
        for alid in albums {
            for s in c.songs(forAlbum: alid) { songs.insert(s.id) }
        }
        // A Featured (catalog) playlist with no song left after suppression is hidden.
        var emptyPlaylists = Set<Int64>()
        for pl in c.catalogPlaylists() {
            let plSongs = c.songs(forCatalogPlaylist: pl.id)
            if plSongs.allSatisfy({ songs.contains($0.id) }) { emptyPlaylists.insert(pl.id) }
        }
        // A tag (collection) whose every album is suppressed is hidden from the Tags list.
        var emptyTags = Set<Int64>()
        for tag in c.allTags() {
            let tagAlbums = c.albums(forTag: tag.id)
            if tagAlbums.allSatisfy({ albums.contains($0.id) }) { emptyTags.insert(tag.id) }
        }
        suppressedArtistIDs = artists
        suppressedAlbumIDs = albums
        suppressedSongIDs = songs
        suppressedGenreIDs = genres
        suppressedCatalogPlaylistIDs = emptyPlaylists
        suppressedTagIDs = emptyTags
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
        var r = isOnline ? albums : albums.filter { downloadedAlbumIDs.contains($0.id) }
        if hideDislikes { r = r.filter { !suppressedAlbumIDs.contains($0.id) } }
        return r
    }
    func visibleArtists(_ artists: [Artist]) -> [Artist] {
        var r = isOnline ? artists : artists.filter { downloadedArtistIDs.contains($0.id) }
        if hideDislikes { r = r.filter { !suppressedArtistIDs.contains($0.id) } }
        return r
    }
    func visibleSongs(_ songs: [Song]) -> [Song] {
        var r = isOnline ? songs : songs.filter { downloadedSongIDs.contains($0.id) }
        if hideDislikes { r = r.filter { !suppressedSongIDs.contains($0.id) } }
        return r
    }
    func visibleTracks(_ tracks: [PlayableTrack]) -> [PlayableTrack] {
        var r = isOnline ? tracks : tracks.filter { downloadedSongIDs.contains($0.song.id) }
        if hideDislikes { r = r.filter { !suppressedSongIDs.contains($0.song.id) } }
        return r
    }
    func visibleGenres(_ genres: [Genre]) -> [Genre] {
        var r = isOnline ? genres : genres.filter { downloadedGenreIDs.contains($0.id) }
        if hideDislikes { r = r.filter { !suppressedGenreIDs.contains($0.id) } }
        return r
    }
    func visibleTags(_ tags: [Tag]) -> [Tag] {
        var r = isOnline ? tags : tags.filter { downloadedTagIDs.contains($0.id) }
        if hideDislikes { r = r.filter { !suppressedTagIDs.contains($0.id) } }
        return r
    }
    func visibleCatalogPlaylists(_ playlists: [CatalogPlaylist]) -> [CatalogPlaylist] {
        var r = isOnline ? playlists : playlists.filter { downloadedCatalogPlaylistIDs.contains($0.id) }
        if hideDislikes { r = r.filter { !suppressedCatalogPlaylistIDs.contains($0.id) } }
        return r
    }

    // MARK: Dislike-aware counts (for browse-list row counts)
    // These mirror the dislike suppression used by the `visible*` filters so a row's count
    // matches what the user would actually see. When `hideDislikes` is off they're full totals.

    /// Number of albums in a genre, excluding disliked-suppressed albums when hiding dislikes.
    func visibleAlbumCount(forGenre genreID: Int64) -> Int {
        guard let c = catalog else { return 0 }
        let albums = c.albums(forGenre: genreID)
        guard hideDislikes else { return albums.count }
        return albums.reduce(0) { $0 + (suppressedAlbumIDs.contains($1.id) ? 0 : 1) }
    }

    /// Number of albums carrying a tag (collection), excluding disliked-suppressed albums.
    func visibleAlbumCount(forTag tagID: Int64) -> Int {
        guard let c = catalog else { return 0 }
        let albums = c.albums(forTag: tagID)
        guard hideDislikes else { return albums.count }
        return albums.reduce(0) { $0 + (suppressedAlbumIDs.contains($1.id) ? 0 : 1) }
    }

    /// Number of tracks in a Magnatune-curated playlist, excluding disliked-suppressed songs.
    func visibleTrackCount(forCatalogPlaylist playlistID: Int64) -> Int {
        guard let c = catalog else { return 0 }
        let songs = c.songs(forCatalogPlaylist: playlistID)
        guard hideDislikes else { return songs.count }
        return songs.reduce(0) { $0 + (suppressedSongIDs.contains($1.id) ? 0 : 1) }
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
