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
    var touchHeight: CGFloat = 16
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double? = nil

    init(current: Double, duration: Double, touchHeight: CGFloat = 16, onSeek: @escaping (Double) -> Void) {
        self.current = current; self.duration = duration; self.touchHeight = touchHeight; self.onSeek = onSeek
    }

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let frac = dragFraction ?? (duration > 0 ? min(1, max(0, current / duration)) : 0)
            let dragging = dragFraction != nil
            // Thumb and track grow while dragging, like the system players.
            let thumb: CGFloat = touchHeight > 30 ? (dragging ? 26 : 16) : 13
            let track: CGFloat = touchHeight > 30 && dragging ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.25)).frame(height: track)
                Capsule().fill(Color.accentColor).frame(width: w * frac, height: track)
                Circle().fill(Color.accentColor)
                    .frame(width: thumb, height: thumb)
                    .shadow(radius: 1)
                    .offset(x: min(w - thumb / 2, max(thumb / 2, w * frac)) - thumb / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())        // the whole touchHeight-tall strip is grabbable
            .animation(.easeOut(duration: 0.12), value: dragging)
            // High priority so the sheet's swipe-down and the page swipe don't steal the drag.
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragFraction = min(1, max(0, v.location.x / w)) }
                    .onEnded { v in
                        let f = min(1, max(0, v.location.x / w))
                        dragFraction = nil
                        if duration > 0 { onSeek(f * duration) }
                    }
            )
        }
        .frame(height: touchHeight)
    }
}

struct MiniPlayer: View {
    @EnvironmentObject var audio: AudioPlayer
    @EnvironmentObject var model: AppModel
    @Environment(\.isPhoneLayout) private var isPhone
    @State private var showPlayModes = false
    @State private var width: CGFloat = 1000
    var onExpand: () -> Void
    /// Phone-style controls (icon-only AirPlay, narrow transport buttons) on a
    /// phone, or wherever the player is too narrow for the full set to fit on one line.
    private var compactControls: Bool { isPhone || width < 700 }

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
                // Only the artwork + title area expands to Now Playing. The controls to the
                // right (AirPlay, volume, transport) must NOT be covered by this tap gesture:
                // AirPlay is a UIKit AVRoutePickerView, and a SwiftUI onTapGesture spanning it
                // would swallow the tap (opening Now Playing instead of the route picker).
                HStack(spacing: 12) {
                    artwork(displayTrack)
                    VStack(alignment: .leading, spacing: 2) {
                        MarqueeText(text: displayTrack?.song.name ?? "Not Playing", font: .callout)
                            .foregroundStyle(hasTrack ? .primary : .secondary)
                        MarqueeText(text: displayTrack?.artistName ?? "Magnatune", font: .caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { if hasTrack { onExpand() } }

                if remote == nil { airplayPill }
                // One play-mode button, left of the transport: opens a small popup with
                // Shuffle, Repeat and volume. (John, 2026-11-23: no volume control or
                // shuffle button on the player itself.)
                if remote == nil { playModeButton }
                transportButton("backward.fill") { transport(.prev) }.disabled(!hasTrack)
                transportButton(playPauseIcon) { transport(.playPause) }.disabled(!hasTrack)
                transportButton("forward.fill") { transport(.next) }.disabled(!hasTrack)
            }

            progressRow
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(GeometryReader { g in
            Color.clear.onAppear { width = g.size.width }
                .onChange(of: g.size.width) { width = $0 }
        })
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

    /// Repeat-icon button that opens the play-mode popup. Filled when shuffle or repeat is on.
    private var playModeButton: some View {
        let on = audio.shuffleEnabled || audio.repeatEnabled
        return Button { showPlayModes = true } label: {
            Image(systemName: playModeIcon(audio))
                .font(.subheadline)
                .frame(width: compactControls ? 26 : 52, height: 28)
                .foregroundStyle(on ? Color.white : Color.accentColor)
                .background(RoundedRectangle(cornerRadius: 7).fill(on ? Color.accentColor : .clear))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Shuffle, repeat and volume")
        .accessibilityLabel("Shuffle, repeat and volume")
        .popover(isPresented: $showPlayModes) { PlayModePopup().environmentObject(audio).keepPopoverCompat() }
    }

    @ViewBuilder private var airplayPill: some View {
        if compactControls {
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
                .frame(width: compactControls ? 26 : 52, height: 28)   // iPhone / narrow: half width
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
    /// Swipe pages (dots at the bottom): 0 player · 1 current playlist · 2 artist · 3 album.
    /// John, 2026-11-23 (to-do 10537188683): replaces the queue (top-left) and close
    /// (top-right) icons; the grab handle and swipe-down still hide the sheet.
    @State private var page = 0
    @State private var showPlayModes = false

    private var remote: Peer? { model.remoteFocus }
    private var displayTrack: PlayableTrack? {
        if let remote, let id = remote.nowPlaying.songID { return model.playableTrack(songID: id) }
        return audio.current
    }
    private var isRemotePlaying: Bool { remote?.nowPlaying.state == .playing }

    var body: some View {
        VStack(spacing: 0) {
            // Tap the grab handle to hide the player — on Mac there's no swipe-to-dismiss.
            Button { dismiss() } label: {
                Capsule().fill(.secondary).frame(width: 44, height: 5)
                    .padding(.top, 10).padding(.bottom, 4).padding(.horizontal, 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide player")
            if let remote { remoteBanner(remote) }
            if let track = displayTrack {
                TabView(selection: $page) {
                    playerPage(track).tag(0)
                    QueueView(inPlayer: true).tag(1)
                    artistPage(track).tag(2)
                    albumPage(track).tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))   // dots readable on light backgrounds
            } else {
                Spacer()
                EmptyStateView("Nothing Playing", systemImage: "music.note")
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 380, idealWidth: isPhone ? 380 : 460,
               minHeight: 560, idealHeight: isPhone ? 600 : 680)
        #else
        // No minimum height on iPhone/iPad: a landscape iPhone is only ~400 pt tall, and the
        // old 560 pt minimum pushed the controls off the screen.
        .frame(idealWidth: isPhone ? 380 : 460, idealHeight: isPhone ? 600 : 680)
        #endif
    }

    /// Page 1: the player. Portrait = cover above the controls; landscape (wider than tall) =
    /// cover on the left, title + controls on the right.
    @ViewBuilder private func playerPage(_ track: PlayableTrack) -> some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            if landscape {
                let side = max(100, min(geo.size.height - 56, geo.size.width * 0.42))
                HStack(spacing: 28) {
                    cover(track, side: side)
                    VStack(spacing: 12) {
                        trackText(track)
                        progressBar(track: track)
                        controls
                    }
                    .frame(maxWidth: 440)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 36)          // room for the page dots
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Size the artwork to the available height so the controls always fit.
                let side = max(120, min(geo.size.width - 64, geo.size.height * 0.46))
                VStack(spacing: 16) {
                    Spacer(minLength: 0)
                    cover(track, side: side)
                    trackText(track)
                    progressBar(track: track)
                    controls
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)          // room for the page dots
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func cover(_ track: PlayableTrack, side: CGFloat) -> some View {
        CoverImage(artistName: track.artistName, albumName: track.album.name, points: 360, corner: 12)
            .frame(width: side, height: side)
            .shadow(radius: 12)
            .contentShape(Rectangle())
            .onTapGesture { onOpenAlbum(track.album) }
    }

    private func trackText(_ track: PlayableTrack) -> some View {
        VStack(spacing: 4) {
            MarqueeText(text: track.song.name, font: .title2.bold(), alignment: .center)
                .contentShape(Rectangle())
                .onTapGesture { onOpenAlbum(track.album) }
            MarqueeText(text: track.artistName, font: .title3, alignment: .center)
                .foregroundStyle(.secondary)
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
            // Stereo pair / single-channel indicator.
            if remote == nil, audio.channelMode != .normal {
                Label(audio.stereoPaired
                      ? "Stereo pair · \(audio.channelMode == .left ? "Left" : "Right")"
                      : audio.channelMode.label,
                      systemImage: "hifispeaker.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Page 3: about the artist (photo, name, location, full bio).
    @ViewBuilder private func artistPage(_ track: PlayableTrack) -> some View {
        let artist = model.catalog?.artist(id: track.album.artistId)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    if let artist {
                        ArtistPhoto(artist: artist, points: 96)
                            .frame(width: 96, height: 96).clipShape(Circle())
                            .overlay(Circle().stroke(Color.artworkBorder, lineWidth: artworkBorderWidth))
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Artist").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(track.artistName).font(.title2.bold())
                        if let loc = artist?.locationText {
                            Label(loc, systemImage: "location.fill")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Button("Open artist page") { onOpenArtist(track.album) }
                            .font(.callout)
                    }
                    Spacer(minLength: 0)
                }
                if let bio = artist?.bio ?? artist?.description, !bio.isEmpty {
                    Text(bio).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 44)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// Page 4: about the album (cover, name, artist, release date, full description).
    @ViewBuilder private func albumPage(_ track: PlayableTrack) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    CoverImage(artistName: track.artistName, albumName: track.album.name, points: 120, corner: 8)
                        .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Album").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Text(track.album.name).font(.title2.bold())
                        Text(track.artistName).font(.subheadline).foregroundStyle(.secondary)
                        if let d = track.album.releaseDateValue {
                            Text(d.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Open album page") { onOpenAlbum(track.album) }
                            .font(.callout)
                    }
                    Spacer(minLength: 0)
                }
                if let desc = track.album.description, !desc.isEmpty {
                    Text(desc).font(.body).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 44)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
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
                    SeekBar(current: pos, duration: dur, touchHeight: 44) { _ in }.disabled(true)
                    HStack {
                        Text(timeText(pos)).font(.caption.monospacedDigit())
                        Spacer()
                        Text(timeText(dur)).font(.caption.monospacedDigit())
                    }.foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(spacing: 4) {
                SeekBar(current: audio.currentTime, duration: audio.duration, touchHeight: 44) { audio.seek(to: $0) }
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
            // Empty slot the size of the play-mode button, so play/pause stays centred.
            Color.clear.frame(width: 28, height: 28)
            Button { transport(.prev) } label: { Image(systemName: "backward.fill").font(.title) }
            Button { transport(.playPause) } label: {
                let playing = remote != nil ? isRemotePlaying : audio.isPlaying
                Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
            }
            Button { transport(.next) } label: { Image(systemName: "forward.fill").font(.title) }
            // Shuffle, repeat and volume live in one popup (John, 2026-11-23).
            Button { showPlayModes = true } label: {
                Image(systemName: playModeIcon(audio)).font(.title3).frame(width: 28, height: 28)
            }
            .foregroundStyle(audio.shuffleEnabled || audio.repeatEnabled ? Color.accentColor : .secondary)
            .disabled(remote != nil)
            .accessibilityLabel("Shuffle, repeat and volume")
            .popover(isPresented: $showPlayModes) { PlayModePopup().environmentObject(audio).keepPopoverCompat() }
        }
        .buttonStyle(.plain)
    }

    private func timeText(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// The "Current playlist" queue panel for Now Playing: the tracks the player is working
/// through, with the current one highlighted; tap a row to jump straight to it.
struct QueueView: View {
    @EnvironmentObject var audio: AudioPlayer
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Shown as a page of the Now Playing sheet: no Done button, and tapping a row plays it
    /// without closing the player.
    var inPlayer = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Current Playlist").font(.headline)
                Spacer()
                if !inPlayer { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            }
            .padding(.horizontal).padding(.vertical, 12)
            Divider()
            if model.remoteFocus != nil || audio.queue.isEmpty {
                Spacer()
                Text(model.remoteFocus != nil ? "The playlist is on the other device." : "Nothing queued.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
            List {
                ForEach(Array(audio.queue.enumerated()), id: \.element.id) { idx, t in
                    Button {
                        audio.jump(to: idx)
                        if !inPlayer { dismiss() }
                    } label: {
                        HStack(spacing: 12) {
                            if idx == audio.index {
                                Image(systemName: audio.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 20)
                            } else {
                                Text("\(idx + 1)").font(.footnote.monospacedDigit())
                                    .foregroundStyle(.secondary).frame(width: 20)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.song.name).lineLimit(1)
                                    .foregroundStyle(idx == audio.index ? Color.accentColor : .primary)
                                Text(t.artistName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(t.song.durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, inPlayer ? 30 : 0)   // clear of the page dots
            }
        }
    }
}

/// Icon for the play-mode button: shuffle when only shuffle is on, otherwise repeat.
@MainActor func playModeIcon(_ audio: AudioPlayer) -> String {
    audio.shuffleEnabled && !audio.repeatEnabled ? "shuffle" : "repeat"
}

/// Small popup behind the player's play-mode button: Shuffle and Repeat switches and the
/// volume slider. John, 2026-11-23 (to-do 10537243790): replaces the separate shuffle
/// button and the volume control on the player.
struct PlayModePopup: View {
    @EnvironmentObject var audio: AudioPlayer
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $audio.shuffleEnabled) { Label("Shuffle", systemImage: "shuffle") }
            Toggle(isOn: $audio.repeatEnabled) { Label("Repeat", systemImage: "repeat") }
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
                Slider(value: $audio.volume, in: 0...1)
                Image(systemName: "speaker.wave.2.fill").font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Volume")
        }
        .tint(.accentColor)
        .padding(16)
        .frame(width: 240)
    }
}
