import Foundation
import Network
import Combine
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Wire types

/// What an instance is doing with audio. `songID` resolves against the shared catalog,
/// so peers exchange only an id (not titles/art).
enum PeerPlaybackState: String, Codable {
    case idle, playing, paused
}

struct PeerNowPlaying: Codable, Equatable {
    var state: PeerPlaybackState
    var songID: Int64?
    var position: Double
    /// Wall-clock time this playback (current track session) began. Used by the
    /// "most-recent play wins" auto-stop: a device that sees a peer which started more
    /// recently yields. Nil when not playing.
    var startedAt: Date? = nil
}

/// A transport command sent to a peer we are controlling.
enum PeerControl: String, Codable {
    case playPause, next, prev
}

/// Messages exchanged over the per-peer TCP connection (newline-delimited JSON).
enum PeerMessage: Codable {
    case hello(id: String, name: String, platform: String)
    case nowPlaying(PeerNowPlaying)
    case control(PeerControl)
}

/// A discovered peer instance, as published to the UI.
struct Peer: Identifiable, Equatable {
    let id: String
    var name: String
    var nowPlaying: PeerNowPlaying
    var lastActiveAt: Date
}

// MARK: - Per-connection bookkeeping

/// One TCP connection to a single peer. Holds the receive buffer and the peer's
/// last-known identity/state so the published `Peer` list can be rebuilt from links.
private final class PeerLink {
    let connection: NWConnection
    let initiatedByUs: Bool
    var remoteID: String?
    var remoteName: String?
    var nowPlaying = PeerNowPlaying(state: .idle, songID: nil, position: 0)
    var lastActiveAt = Date()
    var buffer = Data()

    init(connection: NWConnection, initiatedByUs: Bool) {
        self.connection = connection
        self.initiatedByUs = initiatedByUs
    }
}

// MARK: - PeerService

/// Discovers other Magnatune instances on the local network (Bonjour `_magnatune._tcp`),
/// keeps one TCP connection per peer, broadcasts our now-playing state, and relays
/// transport commands. Exactly one connection per pair is established via an id tie-break
/// (the lower instance id dials; the higher one listens).
@MainActor
final class PeerService: ObservableObject {
    @Published private(set) var peers: [Peer] = []

    /// Invoked when a peer sends us a transport command (i.e. we are being controlled).
    var onControl: ((PeerControl) -> Void)?

    private let instanceID = UUID().uuidString
    private var deviceName: String
    private(set) var enabled = false

    private var listener: NWListener?
    private var browser: NWBrowser?
    private var links: [PeerLink] = []
    private var lastSnapshot = PeerNowPlaying(state: .idle, songID: nil, position: 0)

    private static let serviceType = "_magnatune._tcp"
    private let netQueue = DispatchQueue(label: "com.magnatune.peer")
    private let log = Logger(subsystem: "com.magnatune.player", category: "peer")

    init(deviceName: String) {
        self.deviceName = deviceName
    }

    // MARK: Lifecycle

    func start() {
        guard !enabled else { return }
        enabled = true
        startListener()
        startBrowser()
        log.info("PeerService started as \(self.deviceName, privacy: .public) [\(self.instanceID, privacy: .public)]")
    }

    func stop() {
        guard enabled else { return }
        enabled = false
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        for l in links { l.connection.cancel() }
        links.removeAll()
        peers = []
        log.info("PeerService stopped")
    }

    // MARK: Outbound state

    /// Publish our current playback snapshot to every connected peer.
    func updateLocalState(_ snapshot: PeerNowPlaying) {
        lastSnapshot = snapshot
        let msg = PeerMessage.nowPlaying(snapshot)
        for l in links where l.remoteID != nil { send(msg, on: l) }
    }

    /// Send a transport command to a specific peer.
    func sendControl(peerID: String, _ control: PeerControl) {
        guard let link = links.first(where: { $0.remoteID == peerID }) else { return }
        send(.control(control), on: link)
    }

    // MARK: Listener (advertise + accept)

    private func startListener() {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let listener = try NWListener(using: params)
            let txt = NWTXTRecord(["id": instanceID, "name": deviceName])
            listener.service = NWListener.Service(name: instanceID, type: Self.serviceType,
                                                  domain: nil, txtRecord: txt.data)
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.adopt(PeerLink(connection: conn, initiatedByUs: false)) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.log.info("listener READY")
                case .waiting(let err):
                    self?.log.error("listener WAITING (likely Local Network not allowed): \(String(describing: err))")
                case .failed(let err):
                    self?.log.error("listener FAILED: \(String(describing: err))")
                default:
                    break
                }
            }
            listener.start(queue: netQueue)
            self.listener = listener
            log.info("listener starting, advertising \(Self.serviceType, privacy: .public) name=\(self.instanceID, privacy: .public)")
        } catch {
            log.error("listener create failed: \(String(describing: error))")
        }
    }

    // MARK: Browser (discover + dial)

    private func startBrowser() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handleBrowse(results) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log.info("browser READY")
            case .waiting(let err):
                self?.log.error("browser WAITING (likely Local Network not allowed): \(String(describing: err))")
            case .failed(let err):
                self?.log.error("browser FAILED: \(String(describing: err))")
            default:
                break
            }
        }
        browser.start(queue: netQueue)
        self.browser = browser
    }

    private func handleBrowse(_ results: Set<NWBrowser.Result>) {
        log.info("browse: \(results.count) result(s)")
        for result in results {
            // The peer's instance id is the Bonjour service name (we set it as such).
            var peerID: String?
            if case let .service(name, _, _, _) = result.endpoint { peerID = name }
            guard let peerID else { log.debug("  result has no service name: \(String(describing: result.endpoint))"); continue }
            if peerID == instanceID { log.debug("  (self)"); continue }
            // Tie-break so only one side dials: the lower id initiates.
            guard instanceID < peerID else { log.info("  \(peerID, privacy: .public): they dial us"); continue }
            if links.contains(where: { $0.remoteID == peerID }) { log.debug("  \(peerID, privacy: .public): already linked"); continue }
            log.info("  dialing \(peerID, privacy: .public)")
            let conn = NWConnection(to: result.endpoint, using: makeParams())
            let link = PeerLink(connection: conn, initiatedByUs: true)
            link.remoteID = peerID
            adopt(link)
        }
    }

    private func makeParams() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        return params
    }

    // MARK: Connection setup

    private func adopt(_ link: PeerLink) {
        log.info("adopt \(link.initiatedByUs ? "outbound" : "inbound", privacy: .public) link (remoteID=\(link.remoteID ?? "?", privacy: .public))")
        links.append(link)
        link.connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.linkState(link, state) }
        }
        link.connection.start(queue: netQueue)
        receive(on: link)
    }

    private func linkState(_ link: PeerLink, _ state: NWConnection.State) {
        switch state {
        case .ready:
            log.info("link READY (\(link.initiatedByUs ? "outbound" : "inbound", privacy: .public)) -> sending hello")
            // Both ends introduce themselves and share what they're playing right away.
            send(.hello(id: instanceID, name: deviceName, platform: Self.platform), on: link)
            send(.nowPlaying(lastSnapshot), on: link)
        case .waiting(let err):
            log.error("link WAITING: \(String(describing: err))")
        case .failed(let err):
            log.error("link FAILED: \(String(describing: err))")
            remove(link)
        case .cancelled:
            log.info("link cancelled")
            remove(link)
        default:
            break
        }
    }

    private func receive(on link: PeerLink) {
        link.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                Task { @MainActor in self?.ingest(link, data) }
            }
            if isComplete || error != nil {
                Task { @MainActor in self?.remove(link) }
            } else {
                Task { @MainActor in self?.receive(on: link) }
            }
        }
    }

    private func remove(_ link: PeerLink) {
        link.connection.cancel()
        links.removeAll { $0 === link }
        publishPeers()
    }

    // MARK: Message handling

    private func ingest(_ link: PeerLink, _ data: Data) {
        link.buffer.append(data)
        while let nl = link.buffer.firstIndex(of: 0x0A) {
            let line = Data(link.buffer[link.buffer.startIndex..<nl])
            link.buffer.removeSubrange(link.buffer.startIndex...nl)
            guard !line.isEmpty, let msg = try? JSONDecoder().decode(PeerMessage.self, from: line) else { continue }
            handle(link, msg)
        }
    }

    private func handle(_ link: PeerLink, _ msg: PeerMessage) {
        switch msg {
        case let .hello(id, name, _):
            // Drop a duplicate connection to a peer we already have (safety net).
            if id != instanceID, links.contains(where: { $0 !== link && $0.remoteID == id }) {
                remove(link)
                return
            }
            link.remoteID = id
            link.remoteName = name
            log.info("peer connected: \(name, privacy: .public) [\(id, privacy: .public)]")
            publishPeers()
        case let .nowPlaying(np):
            if link.nowPlaying.state != np.state || link.nowPlaying.songID != np.songID {
                log.info("peer \(link.remoteName ?? "?", privacy: .public) -> \(np.state.rawValue, privacy: .public) song=\(np.songID.map(String.init) ?? "nil", privacy: .public)")
            }
            link.nowPlaying = np
            link.lastActiveAt = Date()
            publishPeers()
        case let .control(cmd):
            onControl?(cmd)
        }
    }

    private func send(_ msg: PeerMessage, on link: PeerLink) {
        guard var data = try? JSONEncoder().encode(msg) else { return }
        data.append(0x0A)
        link.connection.send(content: data, completion: .contentProcessed { _ in })
    }

    // MARK: Publishing

    private func publishPeers() {
        var seen = Set<String>()
        var result: [Peer] = []
        for l in links {
            guard let id = l.remoteID, !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(Peer(id: id, name: l.remoteName ?? "Magnatune",
                               nowPlaying: l.nowPlaying, lastActiveAt: l.lastActiveAt))
        }
        peers = result
    }

    // MARK: Helpers

    private static var platform: String {
        #if targetEnvironment(macCatalyst)
        return "mac"
        #else
        return "ios"
        #endif
    }
}
