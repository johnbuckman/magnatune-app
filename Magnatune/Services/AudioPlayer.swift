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

    /// This device's own channel setting (Settings → Speaker channel), persisted. Lets one
    /// iPad be tested as "left only" without a partner.
    @Published var soloChannelMode: ChannelMode = ChannelMode(rawValue: UserDefaults.standard.string(forKey: ChannelMode.defaultsKey) ?? "") ?? .normal {
        didSet {
            UserDefaults.standard.set(soloChannelMode.rawValue, forKey: ChannelMode.defaultsKey)
            applyChannelModeToCurrentItems()
        }
    }
    /// Set by StereoPair while paired; overrides the solo setting.
    var pairChannelOverride: ChannelMode? { didSet { applyChannelModeToCurrentItems() } }
    var channelMode: ChannelMode { pairChannelOverride ?? soloChannelMode }

    // MARK: Stereo pair (synchronized playback across two devices)

    /// One shared playback timeline: `position` (seconds into song `songIDs[index]`) is heard
    /// from the speaker at host-clock time `hostTime` (seconds, this device's clock). Both
    /// paired devices hold the same anchor (converted to their own clocks) and schedule
    /// against it, so they play in lock step.
    struct StereoSyncState {
        var songIDs: [Int64]
        var index: Int
        var position: Double
        var hostTime: Double
        var playing: Bool
    }

    /// True while paired. Disables crossfade and routes every transport action through a
    /// shared anchor that is sent to the partner via `onStereoSyncOut`.
    @Published private(set) var stereoPaired = false
    /// Whether this device advances the queue at the end of a track (the other one waits for
    /// the leader's sync so both switch tracks at the same instant).
    var stereoIsLeader = false
    /// Outbound anchor for the partner (host time is in THIS device's clock).
    var onStereoSyncOut: ((StereoSyncState) -> Void)?
    /// Last measured timeline error (ms, + = this device is ahead), for the Settings readout.
    @Published private(set) var stereoDriftMs: Double = 0
    private var stereoAnchor: StereoSyncState?
    private var loadedSongID: Int64?
    private var anchorGeneration = 0
    private var driftTickCount = 0
    /// Host time the current scheduled start takes effect; drift checks wait until after it.
    private var stereoStartHost: Double = .infinity
    /// How far ahead a synced start is scheduled, leaving time for the partner to receive
    /// the message, load and preroll.
    private let stereoLead: Double = 1.0

    /// Host-clock seconds — the clock `AVPlayer.setRate(_:time:atHostTime:)` schedules on.
    nonisolated static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
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
        if stereoPaired { stereoStart(index: start, position: 0, playing: true); return }
        loadCurrent(autoPlay: true)
    }

    func playSingle(_ track: PlayableTrack) { play(tracks: [track], startAt: 0) }

    func toggle() {
        if stereoPaired {
            let t = active.currentTime().seconds
            stereoStart(index: index, position: t.isFinite ? t : currentTime, playing: !isPlaying)
            return
        }
        if isPlaying { active.pause(); if crossfading { inactive.pause() }; isPlaying = false }
        else { active.play(); if crossfading { inactive.play() }; isPlaying = true }
        updateNowPlaying()
    }

    func next() {
        cancelCrossfade()
        if stereoPaired {
            if hasNext { stereoStart(index: index + 1, position: 0, playing: true) }
            else if repeatEnabled, !queue.isEmpty { stereoStart(index: 0, position: 0, playing: true) }
            else { stereoStart(index: index, position: currentTime, playing: false) }
            return
        }
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

    /// Jump straight to a track in the current queue (from the Now Playing "Up Next" panel).
    func jump(to newIndex: Int) {
        guard queue.indices.contains(newIndex) else { return }
        cancelCrossfade()
        if stereoPaired { stereoStart(index: newIndex, position: 0, playing: true); return }
        index = newIndex
        loadCurrent(autoPlay: true)
    }

    func previous() {
        cancelCrossfade()
        if currentTime > 3 { seek(to: 0); return }
        guard index > 0 else { seek(to: 0); return }
        if stereoPaired { stereoStart(index: index - 1, position: 0, playing: true); return }
        index -= 1
        loadCurrent(autoPlay: true)
    }

    func seek(to seconds: Double) {
        cancelCrossfade()
        if stereoPaired { stereoStart(index: index, position: seconds, playing: isPlaying); return }
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
            let mix = await ChannelTap.audioMix(for: prepared.asset, mode: self.channelMode)
            guard self.current?.song.id == track.song.id, !self.crossfading else { return }
            item.audioMix = mix
            if self.stereoPaired {
                // Varispeed keeps drift-correction rate nudges glitch-free; scheduling with
                // setRate(_:time:atHostTime:) requires waitsToMinimizeStalling = false.
                item.audioTimePitchAlgorithm = .varispeed
                self.active.automaticallyWaitsToMinimizeStalling = false
            } else {
                self.active.automaticallyWaitsToMinimizeStalling = true
            }
            self.active.volume = self.volume
            self.active.replaceCurrentItem(with: item)
            self.loadedSongID = track.song.id
            self.currentFormat = prepared.format
            self.observe(item: item, for: track)
            self.duration = TimeInterval(track.song.duration ?? 0)
            self.currentTime = 0
            if self.stereoPaired {
                self.scheduleAnchor()
            } else if autoPlay { self.active.play(); self.isPlaying = true }
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
            item.audioMix = await ChannelTap.audioMix(for: prepared.asset, mode: self.channelMode)
            guard self.crossfadePrepared, !self.crossfading, self.index == startIndex else { return }
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

        if stereoPaired {
            driftTickCount += 1
            if driftTickCount % 4 == 0 { correctStereoDrift() }   // once a second
            return                                                // no crossfade while paired
        }
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
        if stereoPaired {
            // Only the leader advances; the follower waits for its sync so both switch tracks
            // together. (Both reach the end at the same moment anyway.)
            if stereoIsLeader { next() } else { isPlaying = false }
            return
        }
        next()
    }

    // MARK: Stereo pair engine

    /// Enter / leave paired mode. Leaving keeps playing locally from the current position.
    func setStereoPaired(_ on: Bool) {
        guard on != stereoPaired else { return }
        anchorGeneration += 1
        stereoPaired = on
        stereoAnchor = nil
        stereoDriftMs = 0
        if on {
            cancelCrossfade()
            active.automaticallyWaitsToMinimizeStalling = false
            active.currentItem?.audioTimePitchAlgorithm = .varispeed
        } else {
            active.automaticallyWaitsToMinimizeStalling = true
            if isPlaying { active.rate = 1 }
        }
    }

    /// The current state as an anchor `lead` seconds from now (used when pairing, so the
    /// partner can join what this device is already playing).
    func currentStereoState(lead: Double? = nil) -> StereoSyncState? {
        guard current != nil else { return nil }
        let l = lead ?? stereoLead
        let pos = isPlaying ? currentTime + l : currentTime
        return StereoSyncState(songIDs: queue.map { $0.song.id }, index: index,
                               position: pos, hostTime: Self.hostNow() + l, playing: isPlaying)
    }

    /// A local transport action while paired: build an anchor `stereoLead` ahead, apply it
    /// here and send it to the partner.
    private func stereoStart(index newIndex: Int, position: Double, playing: Bool) {
        guard queue.indices.contains(newIndex) else { return }
        let state = StereoSyncState(songIDs: queue.map { $0.song.id }, index: newIndex,
                                    position: max(0, position),
                                    hostTime: Self.hostNow() + (playing ? stereoLead : 0),
                                    playing: playing)
        applyStereoSync(state, tracks: queue)
        onStereoSyncOut?(state)
    }

    /// Adopt a shared anchor (from the partner, with host time already converted to this
    /// device's clock, or from a local action). `tracks` must match `state.songIDs`.
    func applyStereoSync(_ state: StereoSyncState, tracks: [PlayableTrack]) {
        guard stereoPaired, tracks.indices.contains(state.index) else { return }
        cancelCrossfade()
        if tracks.map({ $0.song.id }) != queue.map({ $0.song.id }) { queue = tracks }
        stereoAnchor = state
        anchorGeneration += 1
        isPlaying = state.playing
        let targetSong = tracks[state.index].song.id
        if index != state.index || loadedSongID != targetSong || active.currentItem == nil {
            index = state.index
            loadCurrent(autoPlay: false)            // calls scheduleAnchor() once loaded
        } else {
            scheduleAnchor()
        }
        updateNowPlaying()
    }

    /// The partner-clock → local-clock conversion improved: shift the anchor's host time.
    /// No reschedule; the once-a-second drift correction absorbs the change smoothly.
    func retimeStereoAnchor(hostTime: Double) {
        guard stereoPaired, stereoAnchor != nil else { return }
        stereoAnchor?.hostTime = hostTime
    }

    /// Make the active player follow `stereoAnchor`: pause at the anchor position, or seek +
    /// preroll and start at the exact host time that puts the anchor position at the speaker
    /// at the anchor's moment (compensating this device's output latency).
    private func scheduleAnchor(attempt: Int = 0) {
        guard stereoPaired, let a = stereoAnchor, let item = active.currentItem else { return }
        let gen = anchorGeneration
        stereoStartHost = .infinity
        if !a.playing {
            active.pause()
            active.seek(to: CMTime(seconds: a.position, preferredTimescale: 48000),
                        toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = a.position
            isPlaying = false
            updateNowPlaying()
            return
        }
        guard item.status == .readyToPlay else {
            // Not loaded yet: retry shortly (the anchor is in the future, or we join late).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.anchorGeneration == gen else { return }
                self.scheduleAnchor(attempt: attempt)
            }
            return
        }
        let latency = AVAudioSession.sharedInstance().outputLatency
        let minLead = 0.25 * Double(attempt + 1)     // time for seek + preroll
        let target = max(a.hostTime, Self.hostNow() + minLead)   // speaker time
        let itemTime = a.position + (target - a.hostTime)
        active.pause()
        active.cancelPendingPrerolls()
        active.seek(to: CMTime(seconds: itemTime, preferredTimescale: 48000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.anchorGeneration == gen else { return }
                self.active.preroll(atRate: 1) { _ in
                    Task { @MainActor in
                        guard self.anchorGeneration == gen else { return }
                        let startHost = target - latency
                        if startHost < Self.hostNow() + 0.01 {
                            // Seek/preroll took too long: try again with more lead.
                            if attempt < 4 { self.scheduleAnchor(attempt: attempt + 1) }
                            else { self.stereoStartHost = Self.hostNow(); self.active.play() }
                            return
                        }
                        self.stereoStartHost = startHost
                        self.active.setRate(1, time: .invalid,
                                            atHostTime: CMTime(seconds: startHost, preferredTimescale: 1_000_000_000))
                        self.isPlaying = true
                        self.currentTime = itemTime
                        self.updateNowPlaying()
                    }
                }
            }
        }
    }

    /// Once a second: compare where the player actually is with where the anchor says it
    /// should be. Small error → nudge the rate (±1% max, corrects ~10 ms/s); large error →
    /// reschedule from the anchor (an audible blip, but rare).
    private func correctStereoDrift() {
        guard let a = stereoAnchor, a.playing, isPlaying, active.rate != 0,
              let item = active.currentItem, item.status == .readyToPlay,
              index == a.index, loadedSongID == a.songIDs[a.index] else { return }
        let now = Self.hostNow()
        guard now > stereoStartHost + 0.5 else { return }   // let the scheduled start settle
        let actual = active.currentTime().seconds
        guard actual.isFinite else { return }
        let latency = AVAudioSession.sharedInstance().outputLatency
        let expected = a.position + (now + latency - a.hostTime)
        let err = actual - expected                 // + = ahead of the shared timeline
        stereoDriftMs = err * 1000
        if abs(err) > 0.1 {
            stereoAnchor = a
            anchorGeneration += 1
            scheduleAnchor()
        } else if abs(err) > 0.003 {
            active.rate = Float(1 - max(-0.01, min(0.01, err)))
        } else if active.rate != 1 {
            active.rate = 1
        }
    }

    /// Re-apply the channel mode to the item(s) already loaded (Settings change or pairing).
    private func applyChannelModeToCurrentItems() {
        let mode = channelMode
        for p in players {
            guard let item = p.currentItem else { continue }
            Task { @MainActor in
                let mix = await ChannelTap.audioMix(for: item.asset, mode: mode)
                guard p.currentItem === item, self.channelMode == mode else { return }
                item.audioMix = mix
            }
        }
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

    private func resume() {
        if stereoPaired { if !isPlaying { toggle() }; return }
        active.play(); if crossfading { inactive.play() }; isPlaying = true; updateNowPlaying() }
    private func pause() {
        if stereoPaired { if isPlaying { toggle() }; return }
        active.pause(); if crossfading { inactive.pause() }; isPlaying = false; updateNowPlaying() }
}
