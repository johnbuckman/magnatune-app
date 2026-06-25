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
    @Environment(\.isPhoneLayout) private var isPhone
    var onExpand: () -> Void

    private var hasTrack: Bool { audio.current != nil }

    var body: some View {
        // Always visible. When nothing is playing it shows an idle placeholder
        // (disabled transport + empty seek bar) rather than disappearing.
        VStack(spacing: 4) {
            HStack(spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(audio.current?.song.name ?? "Not Playing")
                        .font(.callout).lineLimit(1)
                        .foregroundStyle(hasTrack ? .primary : .secondary)
                    Text(audio.current?.artistName ?? "Magnatune")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                airplayPill
                transportButton("backward.fill") { audio.previous() }.disabled(!hasTrack)
                transportButton(audio.isPlaying ? "pause.fill" : "play.fill") { audio.toggle() }.disabled(!hasTrack)
                transportButton("forward.fill") { audio.next() }.disabled(!hasTrack)
            }
            .contentShape(Rectangle())
            .onTapGesture { if hasTrack { onExpand() } }

            HStack(spacing: 8) {
                Text(timeText(audio.currentTime)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                SeekBar(current: audio.currentTime, duration: audio.duration) { audio.seek(to: $0) }
                    .disabled(!hasTrack)
                Text(timeText(audio.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.375), radius: 1.5, x: 0, y: 1)
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 2)
    }

    @ViewBuilder private var artwork: some View {
        let dim = coverDim(44, phone: isPhone)
        if let track = audio.current {
            CoverImage(artistName: track.artistName, albumName: track.album.name, points: 44)
                .frame(width: dim, height: dim)
        } else {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                .frame(width: dim, height: dim)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
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
                .overlay(RoutePickerView(visible: false))
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

    private func timeText(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct NowPlayingView: View {
    @EnvironmentObject var audio: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPhoneLayout) private var isPhone
    /// Tapping the artwork / song / album opens the album page; the artist name opens
    /// the artist page. Both pass the current track's album (artist is resolved from it).
    var onOpenAlbum: (Album) -> Void = { _ in }
    var onOpenArtist: (Album) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 24) {
            if let track = audio.current {
                Capsule().fill(.secondary).frame(width: 40, height: 5).padding(.top, 8)
                Spacer()
                CoverImage(artistName: track.artistName, albumName: track.album.name, points: 360, corner: 12)
                    .frame(maxWidth: coverDim(360, phone: isPhone), maxHeight: coverDim(360, phone: isPhone))
                    .shadow(radius: 12)
                    .contentShape(Rectangle())
                    .onTapGesture { onOpenAlbum(track.album) }
                VStack(spacing: 4) {
                    Text(track.song.name).font(.title2.bold()).multilineTextAlignment(.center)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenAlbum(track.album) }
                    Text(track.artistName).font(.title3).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenArtist(track.album) }
                    Text(track.album.name).font(.callout).foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                        .onTapGesture { onOpenAlbum(track.album) }
                }
                progressBar
                controls
                Spacer()
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "music.note")
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, isPhone ? 28 : 0)   // keep the controls clear of the bottom edge on iPhone
        .frame(minWidth: 380, minHeight: 560)
    }

    private var progressBar: some View {
        VStack(spacing: 4) {
            SeekBar(current: audio.currentTime, duration: audio.duration) { audio.seek(to: $0) }
            HStack {
                Text(timeText(audio.currentTime)).font(.caption.monospacedDigit())
                Spacer()
                Text(timeText(audio.duration)).font(.caption.monospacedDigit())
            }.foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 44) {
            Button { audio.previous() } label: { Image(systemName: "backward.fill").font(.title) }
            Button { audio.toggle() } label: {
                Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
            }
            Button { audio.next() } label: { Image(systemName: "forward.fill").font(.title) }
        }
        .buttonStyle(.plain)
    }

    private func timeText(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
