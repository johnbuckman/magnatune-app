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
    /// Human label of the audio format/bitrate currently playing (e.g. "Opus · 192 kbps"),
    /// shown under the title in the Now Playing view. Empty when nothing is playing locally.
    @Published private(set) var currentFormat: String = ""
    @Published private(set) var outputRouteName: String = ""
    @Published private(set) var isExternalRoute = false
    /// Persistent shuffle mode. When on, starting playback shuffles the queue.
    @Published var shuffleEnabled: Bool = UserDefaults.standard.bool(forKey: "shuffle.enabled") {
        didSet { UserDefaults.standard.set(shuffleEnabled, forKey: "shuffle.enabled") }
    }
    /// Persistent repeat mode. When on, the queue (the last thing Play was pressed on) loops
    /// forever. After the first pass, tracks replay from the on-device AudioCache → no network.
    @Published var repeatEnabled: Bool = UserDefaults.standard.bool(forKey: "repeat.enabled") {
        didSet { UserDefaults.standard.set(repeatEnabled, forKey: "repeat.enabled") }
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
    /// True once the upcoming track has been buffered onto the inactive player (muted,
    /// paused) ahead of the fade window, but before the audible ramp has begun.
    private var crossfadePrepared = false
    private var preparedNextSongID: Int64?
    /// Format label of the buffered crossfade track, promoted to `currentFormat` on finalize.
    private var preparedNextFormat: String?
    private var fadeStep = 0
    /// Start buffering the incoming track this many seconds before the fade window so it
    /// can begin playing the instant the ramp starts — otherwise the first second(s) of
    /// the fade are silent while the incoming item buffers.
    private let crossfadeLead: Double = 3
    private var endObserver: NSObjectProtocol?
    /// KVO on the audible item's `status`, so a failed Opus stream can fall back to AAC.
    private var statusObs: NSKeyValueObservation?
    /// Set once an Opus stream fails to play on this device (e.g. AVFoundation can't decode
    /// Ogg Opus). Once tripped, the session streams AAC only, so the failing track and every
    /// later one transparently fall back. Session-scoped: Opus is re-tried on next launch.
    private var opusDisabledThisSession = false

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
        // Migrate the retired "lossless" (256 kbps AAC) quality selection to High (192 kbps Opus),
        // so the Settings picker and the player agree for anyone who had picked it.
        if UserDefaults.standard.string(forKey: StreamQuality.defaultsKey) == "lossless" {
            UserDefaults.standard.set(StreamQuality.high.rawValue, forKey: StreamQuality.defaultsKey)
        }
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
        guard hasNext else {
            // End of queue: loop it forever when repeat is on (tracks replay from AudioCache,
            // so no network is used after the first pass); otherwise stop.
            if repeatEnabled, !queue.isEmpty {
                index = 0
                loadCurrent(autoPlay: true)
            } else {
                active.pause(); isPlaying = false; onPlaybackChange?()
            }
            return
        }
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

    /// A resolved asset plus the human label of the audio it will actually play.
    private struct PreparedAsset { let asset: AVURLAsset; let format: String }

    /// Build an asset for a track, preferring the on-device cache. Async because it may probe
    /// the server to resolve the Opus → AAC fallback for member streams. Also reports the
    /// format/bitrate label of the resolved source (shown under the title in Now Playing).
    private func makeAsset(for track: PlayableTrack) async -> PreparedAsset? {
        // Prefer a permanent download (auto-downloaded favorite) — plays offline and saves
        // bandwidth. Downloads are Opus; skip one once Opus has failed on this device so the
        // AAC stream fallback can take over instead of replaying an undecodable local file.
        if let downloaded = DownloadStore.shared.localURL(for: track.song.id),
           !(opusDisabledThisSession && downloaded.pathExtension.lowercased() == "opus") {
            let codec = downloaded.pathExtension.lowercased() == "opus" ? "Opus" : "AAC"
            return PreparedAsset(asset: AVURLAsset(url: downloaded), format: codec)
        }
        guard let url = URLBuilder.resolvedStreamURL(
            artistName: track.artistName, albumName: track.album.name, song: track.song,
            isMember: credentials.isMember, quality: StreamQuality.current,
            allowOpus: !opusDisabledThisSession) else { return nil }
        let format = URLBuilder.formatLabel(forStreamURL: url)
        if cacheEnabled, let local = AudioCache.shared.cached(for: url) {
            return PreparedAsset(asset: AVURLAsset(url: local), format: format)
        }
        var options: [String: Any] = [:]
        if let auth = credentials.basicAuthHeader() {
            options["AVURLAssetHTTPHeaderFieldsKey"] = ["Authorization": auth]
        }
        if cacheEnabled { AudioCache.shared.store(remote: url, authHeader: credentials.basicAuthHeader()) }
        return PreparedAsset(asset: AVURLAsset(url: url, options: options), format: format)
    }

    private func loadCurrent(autoPlay: Bool) {
        guard let track = current else { return }
        Task { @MainActor in
            guard let prepared = await makeAsset(for: track) else { return }
            // The user may have skipped while we were resolving/probing — ignore stale loads.
            guard self.current?.song.id == track.song.id, !self.crossfading else { return }
            let item = AVPlayerItem(asset: prepared.asset)
            self.active.volume = self.volume
            self.active.replaceCurrentItem(with: item)
            self.currentFormat = prepared.format
            self.observe(item: item, for: track)
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
            guard let url = URLBuilder.resolvedStreamURL(
                artistName: track.artistName, albumName: track.album.name, song: track.song,
                isMember: credentials.isMember, quality: StreamQuality.current,
                allowOpus: !opusDisabledThisSession) else { return }
            AudioCache.shared.store(remote: url, authHeader: self.credentials.basicAuthHeader())
        }
    }

    // MARK: Crossfade

    /// Phase 1: load the upcoming track onto the inactive player (muted, paused) ahead of
    /// the fade window, so it's buffered and ready to play the moment the ramp begins.
    /// Resolving/probing the stream URL happens here — outside the fade — so it can't eat
    /// into the fade time.
    private func prepareCrossfade() {
        guard hasNext, !crossfadePrepared, !crossfading else { return }
        // Claim it up front so the ticker doesn't re-enter while we resolve/probe.
        crossfadePrepared = true
        let nextTrack = queue[index + 1]
        let startIndex = index
        Task { @MainActor in
            guard let prepared = await makeAsset(for: nextTrack) else { self.crossfadePrepared = false; return }
            // Bail if anything changed while resolving (skip, stop, queue change, cancel).
            guard self.crossfadePrepared, !self.crossfading, self.index == startIndex, self.hasNext,
                  self.queue[self.index + 1].song.id == nextTrack.song.id else { return }
            let item = AVPlayerItem(asset: prepared.asset)
            self.inactive.volume = 0
            self.inactive.replaceCurrentItem(with: item)
            self.inactive.seek(to: .zero, completionHandler: { _ in })
            self.preparedNextSongID = nextTrack.song.id
            self.preparedNextFormat = prepared.format
        }
    }

    /// Phase 2: begin the audible crossfade. The volume ramp is driven by the outgoing
    /// track's *remaining time*, so it spans the full configured duration and completes
    /// exactly as the outgoing track ends — regardless of timer jitter or how long the
    /// incoming track took to buffer.
    private func beginCrossfade() {
        guard crossfadePrepared, hasNext, !crossfading,
              inactive.currentItem != nil,
              preparedNextSongID == queue[index + 1].song.id else { return }
        // If the buffered incoming item already failed (e.g. an Opus file this device can't
        // decode), fall back to AAC instead of fading into silence.
        if inactive.currentItem?.status == .failed, let item = inactive.currentItem {
            handleItemFailure(item: item, track: queue[index + 1]); return
        }
        crossfading = true
        fadeStep = 0
        // The incoming track owns the end/failure observer from here on.
        if let item = inactive.currentItem { observe(item: item, for: queue[index + 1]) }
        if isPlaying { inactive.play() }

        let interval = 0.05
        // Hard cap so a stall near the end can't hang the fade forever.
        let maxSteps = Int((crossfadeDuration + 1.5) / interval)
        fadeTimer?.invalidate()
        fadeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.crossfading else { return }
                self.fadeStep += 1
                let remaining = self.duration - self.active.currentTime().seconds
                // f goes 0 → 1 across the configured crossfade length, pinned to the song end.
                let f = min(1.0, max(0.0, (self.crossfadeDuration - remaining) / self.crossfadeDuration))
                self.active.volume = Float(1 - f) * self.volume
                self.inactive.volume = Float(f) * self.volume
                if f >= 1.0 || remaining <= 0.05 || self.fadeStep >= maxSteps {
                    self.finalizeCrossfade()
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
        crossfadePrepared = false
        preparedNextSongID = nil
        currentFormat = preparedNextFormat ?? currentFormat
        preparedNextFormat = nil
        if let track = current {
            duration = TimeInterval(track.song.duration ?? 0)
            userStore?.recordPlay(songID: track.song.id)
        }
        updateNowPlaying()
        prefetchNext()
    }

    /// Tear down any in-progress OR prepared (buffered-but-not-yet-ramping) crossfade and
    /// restore the active player to full volume. Called on every manual queue change.
    private func cancelCrossfade() {
        guard crossfading || crossfadePrepared else { return }
        fadeTimer?.invalidate(); fadeTimer = nil
        crossfading = false
        crossfadePrepared = false
        preparedNextSongID = nil
        preparedNextFormat = nil
        inactive.pause()
        inactive.replaceCurrentItem(with: nil)
        inactive.volume = 1
        active.volume = volume
        // re-attach the end/failure observer to the (still-current) active item
        if let item = active.currentItem, let track = current { observe(item: item, for: track) }
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

        guard isPlaying, crossfadeEnabled, hasNext, duration > crossfadeDuration + 1 else { return }
        let remaining = duration - currentTime
        guard remaining > 0 else { return }
        // Phase 1: buffer the next track a few seconds before the fade window.
        if !crossfadePrepared, !crossfading, remaining <= crossfadeDuration + crossfadeLead {
            prepareCrossfade()
        }
        // Phase 2: start the audible ramp exactly `crossfadeDuration` from the end.
        if crossfadePrepared, !crossfading, remaining <= crossfadeDuration {
            beginCrossfade()
        }
    }

    // MARK: End-of-track

    /// Observe the audible item for end-of-track (advance/crossfade) and for load/playback
    /// failure (the Opus → AAC fallback).
    private func observe(item: AVPlayerItem, for track: PlayableTrack) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleItemEnd() }
        }
        statusObs?.invalidate()
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard it.status == .failed else { return }
            Task { @MainActor in self?.handleItemFailure(item: it, track: track) }
        }
    }

    /// A stream item failed to load or play. If it was an Opus stream, disable Opus for the
    /// rest of the session and reload as AAC — so a device (or a single file) that Opus doesn't
    /// work on transparently falls back, and later tracks skip Opus entirely. The `.opus` guard
    /// means an AAC failure (a real network/auth problem) does not pointlessly disable Opus.
    private func handleItemFailure(item: AVPlayerItem, track: PlayableTrack) {
        guard !opusDisabledThisSession,
              (item.asset as? AVURLAsset)?.url.pathExtension.lowercased() == "opus" else { return }
        opusDisabledThisSession = true
        NSLog("Magnatune: Opus stream failed for \"%@\" — falling back to AAC for this session (%@)",
              track.song.name, String(describing: item.error))
        if item === active.currentItem {
            // The audible track failed: reload it in place as AAC.
            loadCurrent(autoPlay: isPlaying)
        } else {
            // A prepared/crossfading Opus item failed: drop the crossfade so the advance into
            // this track (and every later load) resolves to AAC.
            cancelCrossfade()
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
