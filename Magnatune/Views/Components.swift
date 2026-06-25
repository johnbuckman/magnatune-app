import SwiftUI
import Kingfisher

/// Loads a bundled PNG (loose resource) by name.
struct BrandImage: View {
    let name: String
    var body: some View {
        if let ui = UIImage(named: name) ?? BrandImage.fromBundle(name) {
            Image(uiImage: ui).resizable().interpolation(.high)
        } else {
            Color.clear
        }
    }
    static func fromBundle(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

struct CoverImage: View {
    @Environment(\.displayScale) private var displayScale
    let artistName: String
    let albumName: String
    /// The dimension this cover is displayed at, in points. The actual download
    /// size is the smallest Magnatune tier that covers points × screen scale.
    var points: CGFloat
    var corner: CGFloat = 6

    // Available cover_N.jpg sizes; inline use is capped at 600 (1400 is reserved
    // for the full-screen viewer) so we never over-fetch.
    private static let tiers = [50, 100, 200, 300, 600]

    private var pixelSize: Int {
        let needed = points * displayScale
        return CoverImage.tiers.first { CGFloat($0) >= needed } ?? CoverImage.tiers.last!
    }

    var body: some View {
        KFImage(URLBuilder.coverURL(artistName: artistName, albumName: albumName, size: pixelSize))
            .resizable()
            .placeholder { placeholder }
            .fade(duration: 0.2)
            .aspectRatio(1, contentMode: .fill)
            .clipShape(RoundedRectangle(cornerRadius: corner))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: corner)
            .fill(.quaternary)
            .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary))
    }
}

struct ArtistPhoto: View {
    let artist: Artist
    var body: some View {
        KFImage(URLBuilder.artistPhotoURL(artist))
            .resizable()
            .placeholder {
                Circle().fill(.quaternary)
                    .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
            }
            .aspectRatio(contentMode: .fill)
    }
}

/// Tappable full-screen, pinch-zoomable image viewer (album art / artist photos).
/// Shows the already-cached lower-res image immediately, then swaps in the
/// high-res version in place once it finishes downloading.
struct FullScreenImage: View {
    let url: URL?                       // high-res
    var placeholderURL: URL? = nil      // already-cached lower-res, shown instantly
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            KFImage(url)
                .placeholder {
                    if let placeholderURL {
                        KFImage(placeholderURL).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(scale)
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale = max(1, $0) }
                        .onEnded { _ in withAnimation { if scale < 1.05 { scale = 1 } } }
                )
            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle).foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain).padding()
                }
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }
}

/// Inline search box, used in place of the navigation-bar `.searchable` so the
/// top bar can be hidden for more vertical space.
struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.14)))
        .padding(.horizontal).padding(.top, 8).padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .background(Color(.systemBackground))
    }
}

struct FavoriteButton: View {
    @EnvironmentObject var user: UserStore
    let kind: String
    let id: Int64
    var body: some View {
        Button {
            user.toggleFavorite(kind: kind, id: id)
        } label: {
            Image(systemName: user.isFavorite(kind: kind, id: id) ? "heart.fill" : "heart")
                .foregroundStyle(user.isFavorite(kind: kind, id: id) ? .pink : .secondary)
        }
        .buttonStyle(.borderless)
    }
}

/// Button (shown beside the heart) that opens an "Add to Playlist" sheet for the
/// given songs. `songIDs` is resolved lazily when tapped.
struct AddToPlaylistButton: View {
    let songIDs: () -> [Int64]
    @State private var show = false
    var body: some View {
        Button { show = true } label: {
            Image(systemName: "text.badge.plus").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $show) { AddToPlaylistSheet(songIDs: songIDs()) }
    }
}

struct AddToPlaylistSheet: View {
    @EnvironmentObject var user: UserStore
    @Environment(\.dismiss) private var dismiss
    let songIDs: [Int64]
    @State private var newName = ""
    @State private var rows: [UserStore.PlaylistRow] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Create playlist:") {
                    HStack {
                        TextField("New playlist name", text: $newName)
                            .textInputAutocapitalization(.words)
                        Button("Create") {
                            let id = user.createPlaylist(name: newName.trimmingCharacters(in: .whitespaces))
                            add(to: id)
                        }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("Your playlists") {
                    if rows.isEmpty {
                        Text("No playlists yet").foregroundStyle(.secondary)
                    } else {
                        ForEach(rows) { pl in
                            Button { add(to: pl.id) } label: {
                                HStack {
                                    Label(pl.name, systemImage: "music.note.list")
                                    Spacer()
                                    Text("\(pl.count)").foregroundStyle(.secondary)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle(songIDs.count == 1 ? "Add to Playlist" : "Add \(songIDs.count) Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { rows = user.playlists() }
        }
        .presentationDetents([.medium, .large])
    }

    private func add(to playlistID: Int64) {
        for s in songIDs { user.addSong(s, toPlaylist: playlistID) }
        dismiss()
    }
}

/// Row for a song with track number, title, duration, favorite + context menu.
/// Highlights itself when it is the track currently playing.
struct SongRow: View {
    @EnvironmentObject var user: UserStore
    @EnvironmentObject var audio: AudioPlayer
    let track: PlayableTrack
    var showArtwork = false
    var onPlay: () -> Void

    private var isCurrent: Bool { audio.current?.id == track.id }

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(track.song.name).lineLimit(1)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                if showArtwork {
                    Text("\(track.artistName) — \(track.album.name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(track.song.durationText).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            FavoriteButton(kind: "song", id: track.song.id)
            AddToPlaylistButton { [track.song.id] }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isCurrent ? Color.accentColor.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .contextMenu { AddToPlaylistMenu(songID: track.song.id) }
    }

    @ViewBuilder private var leading: some View {
        if isCurrent {
            Image(systemName: audio.isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: showArtwork ? 40 : 26)
        } else if showArtwork {
            CoverImage(artistName: track.artistName, albumName: track.album.name, points: 40)
                .frame(width: 40, height: 40)
        } else if let n = track.song.trackNo {
            Text("\(n)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
        } else {
            Color.clear.frame(width: 26)
        }
    }
}

/// Simple wrapping layout for chips/tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct ChipLabel: View {
    let text: String
    var prominent = false
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(prominent ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15)))
    }
}

struct AddToPlaylistMenu: View {
    @EnvironmentObject var user: UserStore
    let songID: Int64
    var body: some View {
        Menu("Add to Playlist") {
            ForEach(user.playlists()) { pl in
                Button(pl.name) { user.addSong(songID, toPlaylist: pl.id) }
            }
            if user.playlists().isEmpty { Text("No playlists yet").foregroundStyle(.secondary) }
        }
    }
}
