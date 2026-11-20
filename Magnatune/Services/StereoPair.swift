import Foundation
import Combine
import os

/// Two devices running Magnatune play one song in lock step, one as the LEFT speaker and
/// one as the RIGHT. No audio crosses the network: each device fetches the same file from
/// magnatune.com itself. Over the existing PeerService link they exchange only:
///   * clock probes (ping/pong) → `offset`, how far the partner's host clock is ahead of ours
///   * a shared playback anchor (song, position, host time) whenever either side acts
/// AudioPlayer then schedules against the anchor with setRate(_:time:atHostTime:) and trims
/// drift with small rate nudges.
@MainActor
final class StereoPair: ObservableObject {
    /// The partner's instance id while paired.
    @Published private(set) var partnerID: String?
    /// The channel THIS device plays while paired.
    @Published private(set) var myChannel: ChannelMode = .left
    /// Best clock-probe round trip (ms) and whether the clock offset is usable yet.
    @Published private(set) var bestRTTms: Double = 0
    @Published private(set) var clockReady = false

    private let peers: PeerService
    private let audio: AudioPlayer
    private let resolveTracks: ([Int64]) -> [PlayableTrack]
    private let log = Logger(subsystem: "com.magnatune.player", category: "stereo")

    /// Partner host clock minus ours (seconds): partnerTime = ourTime + offset.
    private var offset: Double = 0
    /// Recent probe results (rtt, offset); the lowest-RTT sample wins, as in NTP.
    private var samples: [(rtt: Double, offset: Double)] = []
    private var probeTimer: Timer?
    private var probeCount = 0
    /// Our requested channel while waiting for the partner's pairAck.
    private var pendingPair: (peerID: String, channel: ChannelMode)?
    /// The partner-clock time of the anchor we're following, if it came from the partner, so
    /// it can be re-converted as the offset estimate improves.
    private var remoteAnchorAt: Double?

    var isPaired: Bool { partnerID != nil }

    init(peers: PeerService, audio: AudioPlayer, resolveTracks: @escaping ([Int64]) -> [PlayableTrack]) {
        self.peers = peers
        self.audio = audio
        self.resolveTracks = resolveTracks
        peers.onStereoMessage = { [weak self] id, msg, arrived in self?.handle(id, msg, arrived) }
        peers.onPeerGone = { [weak self] id in
            guard let self, self.partnerID == id || self.pendingPair?.peerID == id else { return }
            self.log.info("partner disconnected, unpairing")
            self.pendingPair = nil
            self.endPairing(notify: false)
        }
        audio.onStereoSyncOut = { [weak self] state in self?.sendSync(state) }
    }

    // MARK: Public

    /// Ask `peerID` to pair; this device plays `channel`, the partner the other one.
    func requestPair(with peerID: String, channel: ChannelMode) {
        guard channel != .normal else { return }
        if isPaired { endPairing(notify: true) }
        pendingPair = (peerID, channel)
        peers.send(peerID: peerID, .pair(channel: channel.rawValue))
    }

    func unpair() { endPairing(notify: true) }

    // MARK: Messages

    private func handle(_ peerID: String, _ msg: PeerMessage, _ arrived: Double) {
        switch msg {
        case let .pair(channel):
            // The partner takes `channel`; we take the other one.
            guard let theirs = ChannelMode(rawValue: channel), theirs != .normal else {
                peers.send(peerID: peerID, .pairAck(accepted: false)); return
            }
            if partnerID != nil && partnerID != peerID { endPairing(notify: true) }
            beginPairing(with: peerID, channel: theirs.opposite)
            peers.send(peerID: peerID, .pairAck(accepted: true))
        case let .pairAck(ok):
            guard let p = pendingPair, p.peerID == peerID else { return }
            pendingPair = nil
            guard ok else { log.info("pair refused"); return }
            beginPairing(with: peerID, channel: p.channel)
            // The requester's music carries over; if it has nothing loaded, adopt the partner's.
            if let state = audio.currentStereoState(lead: 1.5) {
                audio.applyStereoSync(state, tracks: audio.queue)
                sendSync(state)
            } else {
                peers.send(peerID: peerID, .syncRequest)
            }
        case .unpair:
            guard partnerID == peerID else { return }
            endPairing(notify: false)
        case let .pong(t0, t1):
            guard partnerID == peerID else { return }
            let rtt = arrived - t0
            guard rtt >= 0, rtt < 1 else { return }
            samples.append((rtt, t1 - (t0 + arrived) / 2))
            if samples.count > 20 { samples.removeFirst(samples.count - 20) }
            if let best = samples.min(by: { $0.rtt < $1.rtt }) {
                let changed = abs(best.offset - offset) > 0.0005
                offset = best.offset
                if changed, let at = remoteAnchorAt { audio.retimeStereoAnchor(hostTime: at - offset) }
                bestRTTms = best.rtt * 1000
                clockReady = samples.count >= 5
            }
        case let .stereoSync(songIDs, index, position, at, playing):
            guard partnerID == peerID else { return }
            let tracks = resolveTracks(songIDs)
            guard tracks.count == songIDs.count, tracks.indices.contains(index) else {
                log.error("ssync: could not resolve all \(songIDs.count) songs in the local catalog")
                return
            }
            let local = AudioPlayer.StereoSyncState(songIDs: songIDs, index: index, position: position,
                                                    hostTime: at - offset, playing: playing)
            remoteAnchorAt = at
            audio.applyStereoSync(local, tracks: tracks)
        case .syncRequest:
            guard partnerID == peerID, let state = audio.currentStereoState(lead: 1.5) else { return }
            audio.applyStereoSync(state, tracks: audio.queue)
            sendSync(state)
        default:
            break
        }
    }

    private func sendSync(_ s: AudioPlayer.StereoSyncState) {
        guard let id = partnerID else { return }
        remoteAnchorAt = nil       // we now follow our own (local-clock) anchor
        // Our host time → stamped as-is; the receiver converts with its own offset estimate.
        peers.send(peerID: id, .stereoSync(songIDs: s.songIDs, index: s.index, position: s.position,
                                           at: s.hostTime, playing: s.playing))
    }

    // MARK: Pairing lifecycle

    private func beginPairing(with peerID: String, channel: ChannelMode) {
        partnerID = peerID
        myChannel = channel
        samples = []
        offset = 0
        remoteAnchorAt = nil
        clockReady = false
        // Deterministic leader (advances tracks at song end): the lower instance id.
        audio.stereoIsLeader = peers.instanceID < peerID
        audio.pairChannelOverride = channel
        audio.setStereoPaired(true)
        startProbing()
        log.info("paired with \(peerID, privacy: .public) as \(channel.rawValue, privacy: .public), leader=\(self.audio.stereoIsLeader)")
    }

    private func endPairing(notify: Bool) {
        if notify, let id = partnerID { peers.send(peerID: id, .unpair) }
        probeTimer?.invalidate(); probeTimer = nil
        partnerID = nil
        clockReady = false
        audio.setStereoPaired(false)
        audio.pairChannelOverride = nil
    }

    /// A burst of probes (every 50 ms) right after pairing, then one every 2 s, so the
    /// offset estimate is ready within a second and keeps tracking clock drift.
    private func startProbing() {
        probeTimer?.invalidate()
        probeCount = 0
        probeTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, let id = self.partnerID else { t.invalidate(); return }
                self.probeCount += 1
                if self.probeCount <= 20 || self.probeCount % 40 == 0 {
                    self.peers.send(peerID: id, .ping(t0: AudioPlayer.hostNow()))
                }
            }
        }
    }
}
