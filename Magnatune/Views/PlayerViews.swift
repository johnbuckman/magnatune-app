import SwiftUI
import AVKit

/// System audio-output picker (AirPlay, Bluetooth, speakers). Tapping it shows the
/// list of available destinations and the current one.
struct RoutePickerView: UIViewRepresentable {
    /// When false the AirPlay glyph is drawn clear (invisible) so the view can be
    /// overlaid on another control purely as a tap target.
    var visible = true

    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.prioritizesVideoDevices = false
        v.backgroundColor = .clear
        apply(v)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { apply(uiView) }

    private func apply(_ v: AVRoutePickerView) {
        v.activeTintColor = visible ? UIColor(Color.accentColor) : .clear
        v.tintColor = visible ? .secondaryLabel : .clear
    }
}

/// An invisible AVRoutePickerView tap target that forces the system routing popover to
/// appear ABOVE the control (arrow pointing down). Used on the iPhone mini-player, which
/// is docked at the bottom of the screen where there's no room for the picker to open
/// downward. The picker presents through this controller (it's the nearest view controller
/// in the responder chain), so overriding `present` lets us set the arrow direction.
/// On a real iPhone the route list comes up as a bottom sheet (not a popover), so the
/// override is a harmless no-op there.
struct UpwardRoutePicker: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UpwardRoutePickerController { UpwardRoutePickerController() }
    func updateUIViewController(_ vc: UpwardRoutePickerController, context: Context) {}
}

final class UpwardRoutePickerController: UIViewController {
    private let picker = AVRoutePickerView()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        picker.translatesAutoresizingMaskIntoConstraints = false
        picker.prioritizesVideoDevices = false
        picker.backgroundColor = .clear
        picker.activeTintColor = .clear     // invisible — the SwiftUI glyph is the visible icon
        picker.tintColor = .clear
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: view.topAnchor),
            picker.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    override func present(_ vc: UIViewController, animated: Bool, completion: (() -> Void)? = nil) {
        if vc.modalPresentationStyle == .popover {
            vc.popoverPresentationController?.permittedArrowDirections = .down
        }
        super.present(vc, animated: animated, completion: completion)
    }
}

/// A peer's playback position for display, interpolated locally between the ~4s heartbeats
/// (advances only while the peer is actually playing).
func remoteDisplayPosition(_ peer: Peer, duration: Double) -> Double {
    var pos = peer.nowPlaying.position
    if peer.nowPlaying.state == .playing { pos += Date().timeIntervalSince(peer.lastActiveAt) }
    if duration > 0 { pos = min(pos, duration) }
    return max(0, pos)
}

/// Progress/seek bar that supports both tapping (jump to point) and dragging (scrub).
struct SeekBar: View {
    let current: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let frac = dragFraction ?? (duration > 0 ? min(1, max(0, current / duration)) : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: 4)
                Capsule().fill(Color.accentColor).frame(width: w * frac, height: 4)
                Circle().fill(Color.accentColor)
                    .frame(width: 13, height: 13)
                    .shadow(radius: 1)
                    .offset(x: min(w - 6.5, max(6.5, w * frac)) - 6.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragFraction = min(1, max(0, v.location.x / w)) }
                    .onEnded { v in
                        let f = min(1, max(0, v.location.x / w))
                        dragFraction = nil
                        if duration > 0 { onSeek(f * duration) }
                    }
            )
        }
        .frame(height: 16)
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var audio: AudioPlayer
    @EnvironmentObject var model: AppModel
    @Environment(\.isPhoneLayout) private var isPhone
    @State private var showVolumePopover = false
    var onExpand: () -> Void

    /// The peer we're controlling, if local audio is idle and a peer is active.
    private var remote: Peer? { model.remoteFocus }
    /// The track shown in the player — remote peer's track when controlling, else our own.
    private var displayTrack: PlayableTrack? {
        if let remote, let id = remote.nowPlaying.songID { return model.playableTrack(songID: id) }
        return audio.current
    }
    private var hasTrack: Bool { displayTrack != nil }
    private var isRemotePlaying: Bool { remote?.nowPlaying.state == .playing }

    var body: some View {
        // Always visible. When nothing is playing locally and a peer is active, it shows
        // that peer's track + a "Controlling …" banner; otherwise our own playback (or an
        // idle placeholder).
        VStack(spacing: 4) {
            if let remote { remoteBanner(remote) }
            HStack(spacing: 12) {
                artwork(displayTrack)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTrack?.song.name ?? "Not Playing")
                        .font(.callout).lineLimit(1)
                        .foregroundStyle(hasTrack ? .primary : .secondary)
                    Text(displayTrack?.artistName ?? "Magnatune")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if !isPhone && remote == nil { volumeControl }
                if isPhone && remote == nil { volumeButton }
                if remote == nil { airplayPill }
                // Repeat + shuffle toggles, left of the transport — matches the web player.
                if remote == nil {
                    transportToggle("repeat", on: audio.repeatEnabled) { audio.repeatEnabled.toggle() }
                    transportToggle("shuffle", on: audio.shuffleEnabled) { audio.shuffleEnabled.toggle() }
                }
                transportButton("backward.fill") { transport(.prev) }.disabled(!hasTrack)
                transportButton(playPauseIcon) { transport(.playPause) }.disabled(!hasTrack)
                transportButton("forward.fill") { transport(.next) }.disabled(!hasTrack)
            }
            .contentShape(Rectangle())
            .onTapGesture { if hasTrack { onExpand() } }

            progressRow
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.375), radius: 1.5, x: 0, y: 1)
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 2)
    }

    private var playPauseIcon: String {
        if remote != nil { return isRemotePlaying ? "pause.fill" : "play.fill" }
        return audio.isPlaying ? "pause.fill" : "play.fill"
    }

    /// Route a transport tap to the controlled peer, or to our own player.
    private func transport(_ cmd: PeerControl) {
        if let remote {
            model.peerService.sendControl(peerID: remote.id, cmd)
        } else {
            switch cmd {
            case .prev: audio.previous()
            case .playPause: audio.toggle()
            case .next: audio.next()
            }
        }
    }

    @ViewBuilder private func remoteBanner(_ peer: Peer) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("Controlling \(peer.name)").lineLimit(1)
            Spacer()
        }
        .font(.caption2.bold())
        .foregroundStyle(Color.accentColor)
    }

    @ViewBuilder private var progressRow: some View {
        if let remote {
            // Read-only remote scrubber; interpolate position locally between heartbeats.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let dur = Double(displayTrack?.song.duration ?? 0)
                let pos = remoteDisplayPosition(remote, duration: dur)
                HStack(spacing: 8) {
                    Text(timeText(pos)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    SeekBar(current: pos, duration: dur) { _ in }.disabled(true)
                    Text(timeText(dur)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        } else {
            HStack(spacing: 8) {
                Text(timeText(audio.currentTime)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                SeekBar(current: audio.currentTime, duration: audio.duration) { audio.seek(to: $0) }
                    .disabled(!hasTrack)
                Text(timeText(audio.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func artwork(_ track: PlayableTrack?) -> some View {
        let dim = coverDim(44, phone: isPhone)
        if let track {
            CoverImage(artistName: track.artistName, albumName: track.album.name, points: 44)
                .frame(width: dim, height: dim)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                .frame(width: dim, height: dim)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
    }

    /// Output-volume slider — shown only on large screens (iPad/Mac), left of AirPlay.
    @ViewBuilder private var volumeControl: some View {
        HStack(spacing: 6) {
            Image(systemName: volumeIcon)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 16)
            Slider(value: $audio.volume, in: 0...1)
                .frame(width: 84)
        }
    }

    private var volumeIcon: String {
        switch audio.volume {
        case ..<0.01: return "speaker.slash.fill"
        case ..<0.5:  return "speaker.wave.1.fill"
        default:      return "speaker.wave.2.fill"
        }
    }

    /// iPhone: a volume icon that opens a horizontal slider popover. (A rotated vertical Slider
    /// tracks drags incorrectly — the gesture space doesn't follow the rotation — so use a plain
    /// horizontal Slider, same as the iPad control.)
    @ViewBuilder private var volumeButton: some View {
        Button { showVolumePopover = true } label: {
            Image(systemName: volumeIcon)
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 30, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showVolumePopover) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $audio.volume, in: 0...1).frame(width: 150)
                Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .presentationCompactAdaptation(.popover)
        }
    }

    @ViewBuilder private var airplayPill: some View {
        if isPhone {
            // iPhone: just the AirPlay icon (no route text / pill).
            Image(systemName: "airplayaudio")
                .font(.subheadline)
                .foregroundStyle(audio.isExternalRoute ? Color.accentColor : .secondary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
                .overlay(UpwardRoutePicker())   // opens the route picker ABOVE the tap
        } else {
            HStack(spacing: 4) {
                Image(systemName: "airplayaudio")
                if !audio.outputRouteName.isEmpty {
                    Text(audio.outputRouteName).lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(audio.isExternalRoute ? Color.accentColor : .secondary)
            .frame(maxWidth: 140)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.5), lineWidth: 1))
            .overlay(RoutePickerView(visible: false))   // tap = open output picker
        }
    }

    private func transportButton(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.subheadline)
                .frame(width: isPhone ? 26 : 52, height: 28)   // iPhone: half width
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    /// A bordered ON/OFF transport toggle (shuffle / repeat) — fills accent when on, like the
    /// web player's shuffle button.
    private func transportToggle(_ system: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.subheadline)
                .frame(width: isPhone ? 26 : 52, height: 28)
                .foregroundStyle(on ? Color.white : Color.accentColor)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
    }

    private func timeText(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var audio: AudioPlayer
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPhoneLayout) private var isPhone
    /// Tapping the artwork / song / album opens the album page; the artist name opens
    /// the artist page. Both pass the current track's album (artist is resolved from it).
    var onOpenAlbum: (Album) -> Void = { _ in }
    var onOpenArtist: (Album) -> Void = { _ in }

    private var remote: Peer? { model.remoteFocus }
    private var displayTrack: PlayableTrack? {
        if let remote, let id = remote.nowPlaying.songID { return model.playableTrack(songID: id) }
        return audio.current
    }
    private var isRemotePlaying: Bool { remote?.nowPlaying.state == .playing }

    var body: some View {
        GeometryReader { geo in
            // Size the artwork to the available height so the controls always fit
            // (no bottom truncation) and the block stays vertically centered.
            let side = max(120, min(geo.size.width - 64, geo.size.height * 0.46))
            VStack(spacing: 16) {
                // Tap the grab handle (or the close button) to hide the player — on Mac
                // there's no swipe-to-dismiss.
                Button { dismiss() } label: {
                    Capsule().fill(.secondary).frame(width: 44, height: 5)
                        .padding(.top, 10).padding(.bottom, 4).padding(.horizontal, 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide player")
                if let remote { remoteBanner(remote) }
                if let track = displayTrack {
                    Spacer(minLength: 0)
                    CoverImage(artistName: track.artistName, albumName: track.album.name, points: 360, corner: 12)
                        .frame(width: side, height: side)
                        .shadow(radius: 12)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenAlbum(track.album) }
                    VStack(spacing: 4) {
                        Text(track.song.name).font(.title2.bold()).multilineTextAlignment(.center).lineLimit(2)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenAlbum(track.album) }
                        Text(track.artistName).font(.title3).foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenArtist(track.album) }
                        Text(track.album.name).font(.callout).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .contentShape(Rectangle())
                            .onTapGesture { onOpenAlbum(track.album) }
                        // Currently-playing audio format + bitrate (local playback only).
                        if remote == nil, !audio.currentFormat.isEmpty {
                            Text(audio.currentFormat)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.top, 1)
                        }
                    }
                    progressBar(track: track)
                    controls
                    Spacer(minLength: 0)
                } else {
                    Spacer()
                    ContentUnavailableView("Nothing Playing", systemImage: "music.note")
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.bottom, isPhone ? 28 : 24)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                .buttonStyle(.plain)
                .help("Hide player")
            }
        }
        .frame(minWidth: 380, idealWidth: isPhone ? 380 : 460,
               minHeight: 560, idealHeight: isPhone ? 600 : 680)
    }

    @ViewBuilder private func remoteBanner(_ peer: Peer) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("Controlling \(peer.name)")
        }
        .font(.subheadline.bold())
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }

    @ViewBuilder private func progressBar(track: PlayableTrack) -> some View {
        if let remote {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let dur = Double(track.song.duration ?? 0)
                let pos = remoteDisplayPosition(remote, duration: dur)
                VStack(spacing: 4) {
                    SeekBar(current: pos, duration: dur) { _ in }.disabled(true)
                    HStack {
                        Text(timeText(pos)).font(.caption.monospacedDigit())
                        Spacer()
                        Text(timeText(dur)).font(.caption.monospacedDigit())
                    }.foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 4) {
                SeekBar(current: audio.currentTime, duration: audio.duration) { audio.seek(to: $0) }
                HStack {
                    Text(timeText(audio.currentTime)).font(.caption.monospacedDigit())
                    Spacer()
                    Text(timeText(audio.duration)).font(.caption.monospacedDigit())
                }.foregroundStyle(.secondary)
            }
        }
    }

    private func transport(_ cmd: PeerControl) {
        if let remote {
            model.peerService.sendControl(peerID: remote.id, cmd)
        } else {
            switch cmd {
            case .prev: audio.previous()
            case .playPause: audio.toggle()
            case .next: audio.next()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: isPhone ? 28 : 36) {
            Button { audio.shuffleEnabled.toggle() } label: { Image(systemName: "shuffle").font(.title3) }
                .foregroundStyle(audio.shuffleEnabled ? Color.accentColor : .secondary)
                .disabled(remote != nil)
            Button { transport(.prev) } label: { Image(systemName: "backward.fill").font(.title) }
            Button { transport(.playPause) } label: {
                let playing = remote != nil ? isRemotePlaying : audio.isPlaying
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
            }
            Button { transport(.next) } label: { Image(systemName: "forward.fill").font(.title) }
            Button { audio.repeatEnabled.toggle() } label: { Image(systemName: "repeat").font(.title3) }
                .foregroundStyle(audio.repeatEnabled ? Color.accentColor : .secondary)
                .disabled(remote != nil)
        }
        .buttonStyle(.plain)
    }

    private func timeText(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
