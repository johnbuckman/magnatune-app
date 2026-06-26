import Foundation
import AVFoundation
import MediaPlayer
import Combine
import Kingfisher

/// Dual-AVPlayer playback engine with an explicit queue, HTTP Basic auth streaming,
/// on-device caching, next-track prefetch, optional crossfade, and full Now Playing /
/// remote-command integration.
@MainActor
final class AudioPlayer: ObservableObject {
    private let players = [AVPlayer(), AVPlayer()]
    private var activeIdx = 0
    private var active: AVPlayer { players[activeIdx] }
    private var inactive: AVPlayer { players[1 - activeIdx] }

    private let credentials: Credentials
    private weak var userStore: UserStore?

    @Published private(set) var queue: [PlayableTrack] = []
    @Published private(set) var index: Int = 0
    @Published private(set) var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published private(set) var outputRouteName: String = ""
    @Published private(set) var isExternalRoute = false
    /// Persistent shuffle mode. When on, starting playback shuffles the queue.
    @Published var shuffleEnabled: Bool = UserDefaults.standard.bool(forKey: "shuffle.enabled") {
        didSet { UserDefaults.standard.set(shuffleEnabled, forKey: "shuffle.enabled") }
    }
    /// App-level output volume (0...1), persisted. Applied on top of the crossfade ramp.
    @Published var volume: Float = Float(min(1.0, max(0.0, UserDefaults.standard.object(forKey: "audio.volume") as? Double ?? 1.0))) {
        didSet {
            UserDefaults.standard.set(Double(volume), forKey: "audio.volume")
            if !crossfading { active.volume = volume }
        }
    }

    var current: PlayableTrack? { queue.indices.contains(index) ? queue[index] : nil }

    /// Called whenever the playback state or current track changes, so the peer
    /// service can broadcast a fresh snapshot to other Magnatune instances.
    var onPlaybackChange: (() -> Void)?

    /// Compact snapshot shared with peers (resolved against the shared catalog by song id).
    var peerState: PeerPlaybackState { current == nil ? .idle : (isPlaying ? .playing : .paused) }

    private var ticker: Timer?
    private var fadeTimer: Timer?
    private var crossfading = false
    private var endObserver: NSObjectProtocol?

    /// User-configurable crossfade length (seconds), clamped to 1...10. Read live so a
    /// change in Settings applies to the next crossfade without restarting.
    private var crossfadeDuration: Double {
        let v = UserDefaults.standard.object(forKey: "crossfade.duration") as? Double ?? 6
        return min(10, max(1, v))
    }
    private var hasNext: Bool { index + 1 < queue.count }

    private var cacheEnabled: Bool { UserDefaults.standard.object(forKey: "audio.cache.enabled") as? Bool ?? true }
    private var crossfadeEnabled: Bool { UserDefaults.standard.object(forKey: "crossfade.enabled") as? Bool ?? true }

    init(credentials: Credentials, userStore: UserStore?) {
        self.credentials = credentials
        self.userStore = userStore
        configureSession()
        setupRemoteCommands()
        startTicker()
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        updateRoute()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateRoute() }
        }
    }

    private func updateRoute() {
        let out = AVAudioSession.sharedInstance().currentRoute.outputs.first
        outputRouteName = out?.portName ?? ""
        isExternalRoute = out != nil && out?.portType != .builtInSpeaker
    }

    // MARK: Queue control

    func play(tracks: [PlayableTrack], startAt: Int = 0) {
        guard !tracks.isEmpty else { return }
        cancelCrossfade()
        var ordered = tracks
        var start = max(0, min(startAt, tracks.count - 1))
        if shuffleEnabled {
            // Play the chosen track first, then the rest in random order.
            let chosen = ordered.remove(at: start)
            ordered.shuffle()
            ordered.insert(chosen, at: 0)
            start = 0
        }
        queue = ordered
        index = start
        loadCurrent(autoPlay: true)
    }

    func playSingle(_ track: PlayableTrack) { play(tracks: [track], startAt: 0) }

    func toggle() {
        if isPlaying { active.pause(); if crossfading { inactive.pause() }; isPlaying = false }
        else { active.play(); if crossfading { inactive.play() }; isPlaying = true }
        updateNowPlaying()
    }

    func next() {
        cancelCrossfade()
        guard hasNext else { active.pause(); isPlaying = false; onPlaybackChange?(); return }
        index += 1
        loadCurrent(autoPlay: true)
    }

    func previous() {
        cancelCrossfade()
        if currentTime > 3 { seek(to: 0); return }
        guard index > 0 else { seek(to: 0); return }
        index -= 1
        loadCurrent(autoPlay: true)
    }

    func seek(to seconds: Double) {
        cancelCrossfade()
        active.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        currentTime = seconds
        updateNowPlaying()
    }

    // MARK: Loading

    /// Build an asset for a track, preferring the on-device cache. Async because it may probe
    /// the server to resolve the Lossless → Normal fallback for member streams.
    private func makeAsset(for track: PlayableTrack) async -> AVURLAsset? {
        // Prefer a permanent download (e.g. auto-downloaded favorite) — plays offline.
        if let downloaded = DownloadStore.shared.localURL(for: track.song.id) {
            return AVURLAsset(url: downloaded)
        }
        guard let url = await URLBuilder.resolvedStreamURL(
            artistName: track.artistName, albumName: track.album.name, song: track.song,
            isMember: credentials.isMember, quality: StreamQuality.current,
            authHeader: credentials.basicAuthHeader()) else { return nil }
        if cacheEnabled, let local = AudioCache.shared.cached(for: url) {
            return AVURLAsset(url: local)
        }
        var options: [String: Any] = [:]
        if let auth = credentials.basicAuthHeader() {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": auth]
        }
        if cacheEnabled { AudioCache.shared.store(remote: url, authHeader: credentials.basicAuthHeader()) }
        return AVURLAsset(url: url, options: options)
    }

    private func loadCurrent(autoPlay: Bool) {
        guard let track = current else { return }
        Task { @MainActor in
            guard let asset = await makeAsset(for: track) else { return }
            // The user may have skipped while we were resolving/probing — ignore stale loads.
            guard self.current?.song.id == track.song.id, !self.crossfading else { return }
            let item = AVPlayerItem(asset: asset)
            self.active.volume = self.volume
            self.active.replaceCurrentItem(with: item)
            self.observeEnd(item: item)
            self.duration = TimeInterval(track.song.duration ?? 0)
            self.currentTime = 0
            if autoPlay { self.active.play(); self.isPlaying = true }
            self.userStore?.recordPlay(songID: track.song.id)
            self.updateNowPlaying()
            self.prefetchNext()
        }
    }

    /// Download the next track into the cache so the crossfade / next-tap is instant.
    private func prefetchNext() {
        guard cacheEnabled, hasNext else { return }
        let track = queue[index + 1]
        // Already on disk as a permanent download — no need to prefetch over the network.
        if DownloadStore.shared.localURL(for: track.song.id) != nil { return }
        Task { @MainActor in
            guard let url = await URLBuilder.resolvedStreamURL(
                artistName: track.artistName, albumName: track.album.name, song: track.song,
                isMember: credentials.isMember, quality: StreamQuality.current,
                authHeader: credentials.basicAuthHeader()) else { return }
            AudioCache.shared.store(remote: url, authHeader: self.credentials.basicAuthHeader())
        }
    }

    // MARK: Crossfade

    private func beginCrossfade() {
        guard hasNext, !crossfading else { return }
        let nextTrack = queue[index + 1]
        let startIndex = index
        // Claim the crossfade up front so the ticker doesn't re-enter while we resolve/probe.
        crossfading = true
        Task { @MainActor in
            guard let asset = await makeAsset(for: nextTrack) else { self.crossfading = false; return }
            // Bail if anything changed while resolving (skip, stop, queue change).
            guard self.crossfading, self.index == startIndex, self.hasNext,
                  self.queue[self.index + 1].song.id == nextTrack.song.id else { return }

            let item = AVPlayerItem(asset: asset)
            self.inactive.volume = 0
            self.inactive.replaceCurrentItem(with: item)
            self.inactive.seek(to: .zero, completionHandler: { _ in })
            // The upcoming track owns the end-of-track observer from here on.
            self.observeEnd(item: item)
            if self.isPlaying { self.inactive.play() }

            let interval = 0.05
            let totalSteps = max(1, Int(self.crossfadeDuration / interval))
            var step = 0
            self.fadeTimer?.invalidate()
            self.fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.crossfading else { return }
                    step += 1
                    let f = min(1.0, Double(step) / Double(totalSteps))
                    self.active.volume = Float(1 - f) * self.volume
                    self.inactive.volume = Float(f) * self.volume
                    if f >= 1.0 { self.finalizeCrossfade() }
                }
            }
        }
    }

    private func finalizeCrossfade() {
        fadeTimer?.invalidate(); fadeTimer = nil
        active.pause()
        active.replaceCurrentItem(with: nil)
        active.volume = 1
        activeIdx = 1 - activeIdx          // the faded-in player becomes active
        active.volume = volume
        index += 1
        crossfading = false
        if let track = current {
            duration = TimeInterval(track.song.duration ?? 0)
            userStore?.recordPlay(songID: track.song.id)
        }
        updateNowPlaying()
        prefetchNext()
    }

    private func cancelCrossfade() {
        guard crossfading else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        inactive.pause()
        inactive.replaceCurrentItem(with: nil)
        inactive.volume = 1
        active.volume = volume
        crossfading = false
        // re-attach the end observer to the (still-current) active item
        if let item = active.currentItem { observeEnd(item: item) }
    }

    // MARK: Progress ticker

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard active.currentItem != nil else { return }
        let t = active.currentTime().seconds
        if t.isFinite { currentTime = t }
        if let d = active.currentItem?.duration.seconds, d.isFinite, d > 0 { duration = d }

        if isPlaying, !crossfading, crossfadeEnabled, hasNext, duration > crossfadeDuration + 1 {
            let remaining = duration - currentTime
            if remaining > 0, remaining <= crossfadeDuration { beginCrossfade() }
        }
    }

    // MARK: End-of-track

    private func observeEnd(item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleItemEnd() }
        }
    }

    private func handleItemEnd() {
        // If a crossfade is running, advancing is handled by the fade.
        guard !crossfading else { return }
        next()
    }

    // MARK: Now Playing + remote commands

    private func updateNowPlaying() {
        guard let track = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.song.name,
            MPMediaItemPropertyArtist: track.artistName,
            MPMediaItemPropertyAlbumTitle: track.album.name,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        onPlaybackChange?()

        if let url = URLBuilder.coverURL(artistName: track.artistName, albumName: track.album.name, size: 300) {
            KingfisherManager.shared.retrieveImage(with: url) { result in
                if case .success(let value) = result {
                    let art = MPMediaItemArtwork(boundsSize: value.image.size) { _ in value.image }
                    info[MPMediaItemPropertyArtwork] = art
                    Task { @MainActor in
                        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
                    }
                }
            }
        }
    }

    private func setupRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime); return .success
        }
    }

    private func resume() { active.play(); if crossfading { inactive.play() }; isPlaying = true; updateNowPlaying() }
    private func pause() { active.pause(); if crossfading { inactive.pause() }; isPlaying = false; updateNowPlaying() }
}
